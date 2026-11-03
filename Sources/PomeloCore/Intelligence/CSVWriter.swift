import Foundation

/// RFC 4180 CSV as Excel likes it: UTF-8 with a byte order mark, CRLF after every row.
public enum CSVWriter {
    public static func write(rows: [[String]]) -> Data {
        let width = rows.map(\.count).max() ?? 0
        var text = ""
        for row in rows {
            let cells = row + Array(repeating: "", count: width - row.count)
            text += cells.map(field).joined(separator: ",") + "\r\n"
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    /// A cell that a spreadsheet would read as a formula gets a leading apostrophe (OWASP's CSV injection advice).
    private static func field(_ cell: String) -> String {
        var value = cell
        if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), !isPlainNumber(value) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `-5.30` is data, not a formula; a leading apostrophe would show in Excel on every negative amount.
    private static func isPlainNumber(_ cell: String) -> Bool {
        var digits = Substring(cell.hasPrefix("-") ? cell.dropFirst() : Substring(cell))
        if let dot = digits.firstIndex(of: ".") {
            let fraction = digits[digits.index(after: dot)...]
            guard !fraction.isEmpty, fraction.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
            digits = digits[..<dot]
        }
        return !digits.isEmpty && digits.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}
