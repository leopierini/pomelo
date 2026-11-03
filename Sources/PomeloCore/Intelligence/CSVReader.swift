import Foundation

/// Reads the CSV files people export from spreadsheets and bank sites: any of the usual encodings and delimiters,
/// RFC 4180 quoting.
public enum CSVReader {
    public struct Table: Equatable, Sendable {
        /// Every row has as many fields as the widest one.
        public var rows: [[String]]
        public var delimiter: Character
    }

    public enum Failure: Error, Equatable, Sendable {
        /// More rows or columns than an Excel sheet holds, or more cells than padding the rows to one width can hold.
        case tooLarge
    }

    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    /// Padding makes rows x width empty strings (16 bytes each), so a ragged file of a few KB must not ask for gigabytes.
    static let maxCells = 10_000_000
    private static let delimiters: [Character] = [",", ";", "\t", "|"]
    private static let sampledLines = 20

    public static func read(_ data: Data) throws -> Table {
        try read(data, maxRows: maxRows, maxColumns: maxColumns, maxCells: maxCells)
    }

    static func read(_ data: Data, maxRows: Int, maxColumns: Int, maxCells: Int) throws -> Table {
        let scalars = Array(decode(data).unicodeScalars)
        let delimiter = detectDelimiter(scalars)
        var rows = try records(scalars, delimiter: delimiter.unicodeScalars.first ?? ",", maxRows: maxRows)
        while rows.last == [""] { rows.removeLast() }
        let width = rows.map(\.count).max() ?? 0
        guard width <= maxColumns, rows.count * width <= maxCells else { throw Failure.tooLarge }
        return Table(rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) }, delimiter: delimiter)
    }

    /// A plain decimal as the XLSX writer takes it for a number: `-?\d+(\.\d+)?`, at most 15 digits, no leading zero
    /// (`007` is an ID, not 7) (P165).
    public static func isPlainDecimal(_ text: String) -> Bool {
        var digits = Substring(text.hasPrefix("-") ? text.dropFirst() : Substring(text))
        var fraction = Substring()
        if let dot = digits.firstIndex(of: ".") {
            fraction = digits[digits.index(after: dot)...]
            digits = digits[..<dot]
            guard !fraction.isEmpty else { return false }
        }
        let isDigit: (UInt8) -> Bool = { $0 >= 48 && $0 <= 57 }
        guard !digits.isEmpty, digits.utf8.allSatisfy(isDigit), fraction.utf8.allSatisfy(isDigit) else { return false }
        if digits.count > 1, digits.hasPrefix("0") { return false }
        return digits.count + fraction.count <= 15
    }

    /// The cell as a plain decimal, or nil when it is not a number. `1,5` is 1.5 only where the comma is the decimal
    /// mark (a semicolon-delimited file, written by a comma-decimal locale).
    public static func numberValue(_ cell: String, decimalComma: Bool) -> String? {
        guard decimalComma else { return isPlainDecimal(cell) ? cell : nil }
        let plain: String
        if cell.contains(".") {
            guard let grouped = withoutThousandsDots(cell) else { return nil }
            plain = grouped
        } else {
            plain = cell.filter({ $0 == "," }).count == 1 ? cell.replacingOccurrences(of: ",", with: ".") : cell
        }
        return isPlainDecimal(plain) ? plain : nil
    }

    /// `-?\d{1,3}(\.\d{3})+(,\d+)?` with its dots dropped and its comma made the decimal point (`1.234,56` is
    /// 1234.56), else nil. A lone group with no comma (`1.500`) could be 1.5 written the other way, so it is nil too
    /// and the cell stays text (P209).
    private static func withoutThousandsDots(_ cell: String) -> String? {
        let negative = cell.hasPrefix("-")
        let body = negative ? cell.dropFirst() : Substring(cell)
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let groups = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let isDigits: (Substring) -> Bool = { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
        guard groups.count >= 2, (1...3).contains(groups[0].count), groups.allSatisfy(isDigits),
              groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        if parts.count == 2 {
            guard isDigits(parts[1]) else { return nil }
        } else if groups.count == 2 {
            return nil
        }
        let integer = groups.joined()
        return (negative ? "-" : "") + integer + (parts.count == 2 ? ".\(parts[1])" : "")
    }

    // MARK: Decoding

    /// The subtitle engine's rule: UTF-16 with a BOM, else UTF-8 (a BOM dropped), else Windows-1252. UTF-8 is tried
    /// before the legacy code page, or the accents of an Italian export would turn into mojibake.
    private static func decode(_ data: Data) -> String {
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else {
            // Windows-1252 leaves five bytes undefined; Latin-1 maps them to controls rather than failing.
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    // MARK: Parsing

    /// The delimiter whose first `sampledLines` non-empty lines split into the same number of fields most often,
    /// that number being above 1. Comma wins a tie (and a file nobody splits). A quote toggles "inside quotes" wherever
    /// it stands, so a comma quoted in a semicolon file does not count.
    private static func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Character {
        var perDelimiter = delimiters.map { _ in [Int: Int]() }
        var counts = Array(repeating: 0, count: delimiters.count)
        var lines = 0
        var inQuotes = false
        var lineIsEmpty = true

        func endLine() {
            guard !lineIsEmpty else { return }
            for (index, count) in counts.enumerated() { perDelimiter[index][count + 1, default: 0] += 1 }
            counts = Array(repeating: 0, count: delimiters.count)
            lineIsEmpty = true
            lines += 1
        }
        for scalar in scalars {
            if lines >= sampledLines { break }
            if scalar == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, scalar == "\n" || scalar == "\r" {
                endLine()
                continue
            } else if !inQuotes, let index = delimiters.firstIndex(where: { $0.unicodeScalars.first == scalar }) {
                counts[index] += 1
            }
            lineIsEmpty = false
        }
        if lines < sampledLines { endLine() }

        var best: (delimiter: Character, score: Int) = (",", 0)
        for (index, candidate) in delimiters.enumerated() {
            guard let mode = perDelimiter[index].filter({ $0.key > 1 }).max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) else { continue }
            if mode.value > best.score { best = (candidate, mode.value) }
        }
        return best.delimiter
    }

    /// Scalars, not Characters: Swift fuses CR LF into one Character.
    private static func records(
        _ scalars: [Unicode.Scalar], delimiter: Unicode.Scalar, maxRows: Int
    ) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStart = true
        var index = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldStart = true
        }
        func endRow() throws {
            endField()
            rows.append(row)
            row = []
            if rows.count > maxRows { throw Failure.tooLarge }
        }

        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if inQuotes {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"" && fieldStart {
                inQuotes = true
                fieldStart = false
            } else if scalar == delimiter {
                endField()
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                try endRow()
            } else {
                field.append(scalar)
                fieldStart = false
            }
        }
        if !(row.isEmpty && field.isEmpty) || inQuotes { try endRow() }
        return rows
    }
}
