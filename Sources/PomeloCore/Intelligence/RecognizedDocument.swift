import Foundation

/// Text recognized in a scan: pages of blocks with their boxes (unit coordinates, origin top left), rendered as
/// Markdown in reading order.
public struct RecognizedDocument: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph(String)
            case list([String])
            case table([[String]])
        }

        public var kind: Kind
        public var box: UnitRect
        /// The spans of a table's merged cells; empty for every other block.
        public var merges: [TableMerge]

        public init(_ kind: Kind, box: UnitRect, merges: [TableMerge] = []) {
            self.kind = kind
            self.box = box
            self.merges = merges
        }
    }

    /// Cells that span more than one row or column. The text sits in the top-left cell of the span and the other
    /// cells it covers are empty strings, in the rows and in every output.
    public struct TableMerge: Equatable, Sendable {
        /// Zero-based position of the span's top-left cell.
        public var row: Int
        public var column: Int
        public var rowSpan: Int
        public var columnSpan: Int

        public init(row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
            self.row = row
            self.column = column
            self.rowSpan = rowSpan
            self.columnSpan = columnSpan
        }
    }

    /// A table as written out: its grid and its merged spans.
    public struct Table: Equatable, Sendable {
        public var rows: [[String]]
        public var merges: [TableMerge]

        public init(rows: [[String]], merges: [TableMerge] = []) {
            self.rows = rows
            self.merges = merges
        }
    }

    public var pages: [[Block]]

    public init(pages: [[Block]]) {
        self.pages = pages
    }

    /// Pages that hold no text leave no trace. No trailing newline.
    public func markdown() -> String {
        pages
            .map { Self.readingOrder($0).compactMap(Self.render).joined(separator: "\n\n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    /// Every page's blocks in reading order, empty pages included (a Word page break per page).
    public func pagesInReadingOrder() -> [[Block]] {
        pages.map(Self.readingOrder)
    }

    /// Whether any block holds a character that is not whitespace.
    public var hasText: Bool {
        pages.joined().contains { block in
            switch block.kind {
            case let .paragraph(text): Self.hasInk(text)
            case let .list(items): items.contains(where: Self.hasInk)
            case let .table(rows): rows.joined().contains(where: Self.hasInk)
            }
        }
    }

    /// The tables with some text, page by page in reading order, their cells trimmed and the rows padded to the
    /// widest one.
    public func tables() -> [Table] {
        pages.flatMap { page in
            Self.readingOrder(page).compactMap { block -> Table? in
                guard case let .table(rows) = block.kind, rows.joined().contains(where: Self.hasInk) else { return nil }
                let width = rows.map(\.count).max() ?? 0
                return Table(
                    rows: rows.map { row in
                        row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            + Array(repeating: "", count: width - row.count)
                    },
                    merges: block.merges)
            }
        }
    }

    private static func hasInk(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Top to bottom; blocks whose boxes overlap vertically by over half of the shorter one share a row and read left
    /// to right (a block joins a row when it overlaps any block already in it).
    private static func readingOrder(_ blocks: [Block]) -> [Block] {
        let sorted = blocks.enumerated()
            .sorted { ($0.element.box.y, $0.offset) < ($1.element.box.y, $1.offset) }
            .map(\.element)
        var rows: [[Block]] = []
        for block in sorted {
            if let index = rows.lastIndex(where: { row in row.contains { overlapsVertically($0.box, block.box) } }) {
                rows[index].append(block)
            } else {
                rows.append([block])
            }
        }
        return rows.flatMap { row in
            row.enumerated()
                .sorted { ($0.element.box.x, $0.element.box.y, $0.offset) < ($1.element.box.x, $1.element.box.y, $1.offset) }
                .map(\.element)
        }
    }

    private static func overlapsVertically(_ a: UnitRect, _ b: UnitRect) -> Bool {
        let shorter = min(a.height, b.height)
        guard shorter > 0 else { return false }
        let overlap = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return overlap > shorter / 2
    }

    private static func render(_ block: Block) -> String? {
        switch block.kind {
        case let .paragraph(text):
            return text.isEmpty ? nil : text
        case let .list(items):
            guard !items.isEmpty else { return nil }
            return items.map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }.joined(separator: "\n")
        case let .table(rows):
            return renderTable(rows)
        }
    }

    private static func renderTable(_ rows: [[String]]) -> String? {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return nil }
        let lines = rows.map { row in
            "| " + (row + Array(repeating: "", count: width - row.count)).map(cell).joined(separator: " | ") + " |"
        }
        let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        return ([lines[0], separator] + lines.dropFirst()).joined(separator: "\n")
    }

    private static func cell(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }
}
