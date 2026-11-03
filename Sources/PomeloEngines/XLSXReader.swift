import Foundation
import PomeloCore

/// Reads the sheets of an `.xlsx` as rows of text (P199). A workbook is untrusted input: the zip is checked and listed
/// before anything is extracted, only the parts that are needed are extracted, and every size, count and cell
/// reference is capped before it can decide how much memory the read takes.
public enum XLSXReader {
    public struct Sheet: Equatable, Sendable {
        public var name: String
        /// Each row ends at its last cell with text; a row can be shorter than the sheet is wide.
        public var rows: [[String]]

        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Over a limit of this reader or of Excel's grid: "It's too large to convert".
        case tooLarge
        /// An encrypted workbook, which is an OLE file and not a zip: "It's password-protected".
        case passwordProtected
        case damaged
    }

    struct Limits {
        /// Cells of every sheet together, counted as rows times the sheet's width: the CSV pads each row to it.
        var maxCells = 10_000_000
        /// The text of all cells (a shared string counts at every cell that uses it) plus the shared strings.
        var maxCharacters = 100_000_000
    }

    public static let maxEntries = 2_000
    public static let maxUncompressedBytes = 500_000_000
    /// Any one part, extracted to disk and streamed to the XML parser: a 200 MB sheet holds about 6.6 M cells, so for
    /// one big sheet this cap binds before the cell cap does.
    static let maxPartBytes = 200_000_000
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxXMLDepth = 64
    private static let workbookPart = "xl/workbook.xml"
    private static let workbookRelationshipsPart = "xl/_rels/workbook.xml.rels"
    private static let defaultSharedStringsPart = "xl/sharedStrings.xml"
    private static let defaultStylesPart = "xl/styles.xml"

    /// The visible sheets with data, in workbook order. `workDirectory` receives the extracted parts and is left
    /// for the caller to remove.
    public static func read(_ url: URL, workDirectory: URL, runner: ProcessRunner) async throws -> [Sheet] {
        try await read(url, workDirectory: workDirectory, runner: runner, limits: Limits())
    }

    static func read(_ url: URL, workDirectory: URL, runner: ProcessRunner, limits: Limits) async throws -> [Sheet] {
        try Task.checkCancellation()
        try Package.checkHeader(of: url)
        let entries = try await Package.list(url, runner: runner)
        guard entries[workbookPart] != nil, entries[workbookRelationshipsPart] != nil else { throw Failure.damaged }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let package = Package(url: url, workDirectory: workDirectory, runner: runner, entries: entries)

        try await package.extract([workbookPart, workbookRelationshipsPart])
        let workbook = try parse(WorkbookParser(), package.file(workbookPart))
        let relationships = try parse(RelationshipsParser(), package.file(workbookRelationshipsPart))

        var sheetParts: [(name: String, part: String)] = []
        for sheet in workbook.sheets where !sheet.isHidden {
            guard let relationship = relationships.targets[sheet.relationshipID] else { throw Failure.damaged }
            guard relationship.isWorksheet else { continue }
            let part = try resolve(relationship.target)
            guard entries[part] != nil else { throw Failure.damaged }
            sheetParts.append((sheet.name, part))
        }
        let sharedPart = try relationships.partForType("sharedStrings").map(resolve) ?? defaultSharedStringsPart
        let stylesPart = try relationships.partForType("styles").map(resolve) ?? defaultStylesPart
        let hasShared = entries[sharedPart] != nil, hasStyles = entries[stylesPart] != nil
        let wanted = Set(sheetParts.map(\.part) + (hasShared ? [sharedPart] : []) + (hasStyles ? [stylesPart] : []))
        try await package.extract(wanted.sorted())

        var budget = limits
        let styles = hasStyles ? try parse(StylesParser(), package.file(stylesPart)) : StylesParser()
        var shared: [String] = []
        if hasShared {
            let strings = try parse(SharedStringsParser(), package.file(sharedPart), characterBudget: budget.maxCharacters)
            budget.maxCharacters -= strings.characters
            shared = strings.strings
        }

        var sheets: [Sheet] = []
        for (name, part) in sheetParts {
            try Task.checkCancellation()
            let parser = SheetParser(
                shared: shared, dateStyles: styles.isDate, date1904: workbook.date1904,
                cellBudget: budget.maxCells, characterBudget: budget.maxCharacters)
            try run(parser, on: package.file(part))
            budget.maxCells -= parser.cellsUsed
            budget.maxCharacters -= parser.characters
            if !parser.rows.isEmpty { sheets.append(Sheet(name: name, rows: parser.rows)) }
        }
        return sheets
    }

    // MARK: Parts

    /// A relationship target as a package path: relative to `xl/` unless it starts with `/`; `.` and `..` resolved
    /// and never above the root. Only paths under `xl/` are read.
    static func resolve(_ target: String) throws -> String {
        var components: [Substring] = target.hasPrefix("/") ? [] : ["xl"]
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": guard components.popLast() != nil else { throw Failure.damaged }
            default: components.append(component)
            }
        }
        let path = components.joined(separator: "/")
        guard path.hasPrefix("xl/") else { throw Failure.damaged }
        return path
    }

    private static func parse<Parser: XLSXXMLDelegate>(
        _ parser: Parser, _ url: URL, characterBudget: Int = Int.max
    ) throws -> Parser {
        parser.characterBudget = characterBudget
        try run(parser, on: url)
        return parser
    }

    private static func run(_ delegate: XLSXXMLDelegate, on url: URL) throws {
        try refuseDoctype(in: url)
        guard let stream = InputStream(url: url) else { throw Failure.damaged }
        let parser = XMLParser(stream: stream)
        // The head check misses a DTD hidden behind a long comment, and Foundation reports only internal entity
        // declarations to the delegate, which aborts on them before they expand; an external one is never resolved.
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        delegate.attach(parser)
        parser.delegate = delegate
        let parsed = parser.parse()
        if delegate.wasCancelled { throw CancellationError() }
        if let failure = delegate.failure { throw failure }
        if !parsed { throw Failure.damaged }
    }

    /// A workbook never has a DTD, and it would come before the root element, so the head of a part shows it.
    private static func refuseDoctype(in url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.damaged }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 65_536)) ?? Data()
        for marker in ["<!DOCTYPE", "<!ENTITY"] where head.range(of: Data(marker.utf8)) != nil { throw Failure.damaged }
    }

    // MARK: Dates and numbers

    /// ISO 8601 for a date-formatted serial: `2026-10-30`, with the time (`2026-10-30 14:05:00`) when there is one,
    /// the time alone for a value under one day; nil outside the range Excel can show.
    static func isoDate(serial: Double, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        let totalSeconds = Int((serial * 86_400).rounded())
        let days = totalSeconds / 86_400
        let seconds = totalSeconds % 86_400
        let time = String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        if days == 0, !date1904 || seconds != 0 { return time }
        let unixDays: Int
        if date1904 {
            unixDays = days - 24_107
        } else if days == 60 {
            // Excel's 1900 system counts a 29 February 1900 that never existed.
            return seconds == 0 ? "1900-02-29" : "1900-02-29 \(time)"
        } else {
            unixDays = days - (days < 60 ? 25_568 : 25_569)
        }
        let (year, month, day) = civil(fromUnixDays: unixDays)
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        return seconds == 0 ? date : "\(date) \(time)"
    }

    /// Howard Hinnant's days-to-civil algorithm.
    private static func civil(fromUnixDays days: Int) -> (Int, Int, Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static let builtInDateFormats: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    static func isDateFormat(id: Int, code: String?) -> Bool {
        if let code { return isDateFormat(code: code) }
        return builtInDateFormats.contains(id)
    }

    /// Whether a number format shows a date or a time: a d, m, y, h or s outside quotes, escapes and brackets
    /// (`[h]` and `[mm]` are elapsed time and count), in the first section.
    static func isDateFormat(code: String) -> Bool {
        let lowered = code.lowercased()
        guard lowered != "general", lowered != "standard", code.utf8.count <= 255 else { return false }
        var characters = lowered.makeIterator()
        while let character = characters.next() {
            switch character {
            case "\"": while let inner = characters.next(), inner != "\"" {}
            case "\\", "_", "*": _ = characters.next()
            case "[":
                var inner = ""
                while let next = characters.next(), next != "]" { inner.append(next) }
                if !inner.isEmpty, inner.allSatisfy({ "hms".contains($0) }) { return true }
            case ";": return false
            case "d", "m", "y", "h", "s": return true
            default: continue
            }
        }
        return false
    }

    /// `-1.5E-5` as plain decimal text: `CSVWriter` puts a formula guard in front of a minus that isn't followed
    /// by a plain number, and the guard would show in the spreadsheet.
    static func plainNumber(_ text: String) -> String {
        guard text.hasPrefix("-"), text.contains(where: { $0 == "e" || $0 == "E" }),
              let value = Decimal(string: text) else { return text }
        let plain = "\(value)"
        return plain.contains(where: { $0 == "e" || $0 == "E" }) ? text : plain
    }
}
