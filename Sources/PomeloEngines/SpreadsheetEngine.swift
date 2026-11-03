import Foundation
import PomeloCore

/// Spreadsheet conversions that need no outside program: CSV into a workbook (`XLSXWriter`) and a workbook's sheets
/// into CSV (`XLSXReader`).
public struct SpreadsheetEngine: ConversionEngine {
    private static let edgeCost = 10
    /// Excel refuses a longer sheet name, and these characters in one.
    private static let maxSheetNameUnits = 31
    private static let forbiddenInSheetName: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
    /// `engineUnsupported`, the failure the app shows as written: an `engineFailed` reads "may be damaged" (§3.11).
    private static let tooLarge = ConversionError.engineUnsupported(
        engine: "spreadsheet", reason: "It's too large to convert")
    private static let passwordProtected = ConversionError.engineUnsupported(
        engine: "spreadsheet", reason: "It's password-protected")

    private let runner: ProcessRunner

    /// bsdtar writes nothing while it extracts, and the timeout measures silence.
    public init(runner: ProcessRunner = ProcessRunner(timeout: .seconds(300))) {
        self.runner = runner
    }

    public var id: EngineID { "spreadsheet" }
    public var displayName: String { "Spreadsheets" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    /// A sheet back to CSV loses its formatting, formulas and every other sheet's place in one file.
    private static let pairs: [(from: FormatID, to: FormatID, flags: EdgeFlags)] = [
        ("csv", "xlsx", []), ("xlsx", "csv", [.lossy]),
    ]

    public func edges() -> [ConversionEdge] {
        Self.pairs.map { ConversionEdge(from: $0.from, to: $0.to, engineID: id, cost: Self.edgeCost, flags: $0.flags) }
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let output: URL
        switch (step.from.id, step.to.id) {
        case ("csv", "xlsx"): output = try await csvToXLSX(step)
        case ("xlsx", "csv"): output = try await xlsxToCSV(step, progress: progress)
        default:
            throw ConversionError.engineFailed(
                engine: id, message: "can't turn \(step.from.displayName) into \(step.to.displayName)")
        }
        try Task.checkCancellation()
        progress(1)
        return output
    }

    // MARK: CSV to XLSX

    private func csvToXLSX(_ step: ConversionStep) async throws -> URL {
        let table: CSVReader.Table
        do {
            table = try CSVReader.read(try Data(contentsOf: step.input))
        } catch CSVReader.Failure.tooLarge {
            throw Self.tooLarge
        } catch {
            throw ConversionError.engineFailed(engine: id, message: "cannot read \(step.input.lastPathComponent)")
        }
        try Task.checkCancellation()
        let url = step.suggestedOutput
        do {
            // Semicolon files come from comma-decimal locales (P199, P209): `1,5` is the number 1.5 there, text elsewhere.
            try await XLSXWriter.write(
                sheets: [table.rows], sheetNames: [Self.sheetName(forStem: OutputNamer.stem(of: step.input))],
                decimalComma: table.delimiter == ";", to: url)
        } catch let error as XLSXWriter.Failure {
            throw ConversionError.engineFailed(engine: id, message: error.description)
        }
        return url
    }

    // MARK: XLSX to CSV

    private static let sheetRowsPerChunk = 5_000
    private static let maxSheetNameInFileName = 31
    private static let maxFileNameBytes = 255

    private func xlsxToCSV(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let work = step.stagingDirectory.appending(path: "xlsx-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let sheets: [XLSXReader.Sheet]
        do {
            sheets = try await XLSXReader.read(step.input, workDirectory: work, runner: runner)
        } catch XLSXReader.Failure.tooLarge {
            throw Self.tooLarge
        } catch XLSXReader.Failure.passwordProtected {
            throw Self.passwordProtected
        } catch is XLSXReader.Failure {
            throw ConversionError.engineFailed(engine: id, message: "it is not a valid Excel workbook")
        } catch ProcessRunnerError.timedOut {
            throw ConversionError.converterTimedOut(engine: id)
        } catch ProcessRunnerError.launchFailed(let code) {
            throw ConversionError.converterUnavailable(engine: id, message: "could not launch bsdtar: \(String(cString: strerror(code)))")
        }
        try Task.checkCancellation()
        guard !sheets.isEmpty else { throw ConversionError.notApplicable(reason: "The workbook is empty") }
        progress(0.5)
        if sheets.count == 1 { return try writeCSV(sheets[0], to: step.suggestedOutput) }

        let folder = step.suggestedFolder
        let stem = OutputNamer.stem(of: step.input)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken: Set<String> = []
            for (index, sheet) in sheets.enumerated() {
                let name = Self.fileName(stem: stem, sheet: sheet.name, position: index + 1, taken: &taken)
                try writeCSV(sheet, to: folder.appending(path: name, directoryHint: .notDirectory))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Streamed in chunks of rows (each padded to the sheet's width) so a big sheet is never one string.
    @discardableResult
    private func writeCSV(_ sheet: XLSXReader.Sheet, to url: URL) throws -> URL {
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let width = sheet.rows.map(\.count).max() ?? 0
            let byteOrderMark = CSVWriter.write(rows: []).count
            for start in stride(from: 0, to: sheet.rows.count, by: Self.sheetRowsPerChunk) {
                try Task.checkCancellation()
                let chunk = sheet.rows[start..<min(start + Self.sheetRowsPerChunk, sheet.rows.count)]
                    .map { $0 + Array(repeating: "", count: width - $0.count) }
                let data = CSVWriter.write(rows: chunk)
                try handle.write(contentsOf: start == 0 ? data : data.dropFirst(byteOrderMark))
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.engineFailed(engine: id, message: "cannot write \(url.lastPathComponent)")
        }
        return url
    }

    /// `<stem>-<sheet>.csv` with the sheet name made file-safe: `/` and `:` become `-`, control characters too,
    /// leading dots go, the name is cut to Excel's 31 characters (and further for a long stem), and a name already
    /// taken (compared without case) gets ` 2`, ` 3`.
    static func fileName(stem: String, sheet: String, position: Int, taken: inout Set<String>) -> String {
        var safe = String(sheet.map { character -> Character in
            let isControl = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            return character == "/" || character == ":" || isControl ? "-" : character
        }.prefix(maxSheetNameInFileName))
        while safe.hasPrefix(".") { safe.removeFirst() }
        safe = safe.trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "Sheet \(position)" }
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            var base = "\(stem)-\(safe)\(suffix)"
            while base.utf8.count + 4 > maxFileNameBytes, safe.count > 1 {
                safe.removeLast()
                base = "\(stem)-\(safe)\(suffix)"
            }
            let name = "\(base).csv"
            if taken.insert(name.lowercased()).inserted { return name }
            number += 1
        }
    }

    /// The stem as a legal Excel sheet name: forbidden and control characters become `_` (the writer would drop the
    /// control ones and could leave a nameless sheet), cut to 31 UTF-16 units, no leading or trailing apostrophe,
    /// never empty.
    static func sheetName(forStem stem: String) -> String {
        var name = ""
        var units = 0
        for character in stem {
            units += character.utf16.count
            if units > maxSheetNameUnits { break }
            let isControl = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            name.append(forbiddenInSheetName.contains(character) || isControl ? "_" : character)
        }
        while name.hasPrefix("'") { name.removeFirst() }
        while name.hasSuffix("'") { name.removeLast() }
        return name.isEmpty ? "Sheet1" : name
    }
}
