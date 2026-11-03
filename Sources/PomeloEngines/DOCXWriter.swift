import Foundation
import PomeloCore

/// Writes the smallest WordprocessingML package Word, Pages and Google Docs open: paragraphs, bulleted lists and
/// tables, a page break between source pages, all as runs of plain text. Nothing active is ever written (no field,
/// hyperlink, macro or embedded object), so scanned text like `=1+1` or a URL stays text. Pictures, fonts and colours
/// are not carried (P196).
public enum DOCXWriter {
    public typealias Failure = XLSXWriter.Failure

    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    /// US Letter with one-inch margins leaves 9360 twentieths of a point for a table.
    private static let tableWidth = 9360

    /// The package is built next to `url` in a folder of its own, zipped to `url` with the system's bsdtar and listed
    /// back before the folder is removed. Blocks are written in reading order, page by page.
    public static func write(
        _ document: RecognizedDocument, to url: URL, runner: ProcessRunner = ProcessRunner(timeout: .seconds(120))
    ) async throws {
        try await write(document, to: url, runner: runner, bsdtar: XLSXWriter.bsdtar)
    }

    /// Tests run stand-ins for the archiver.
    static func write(
        _ document: RecognizedDocument, to url: URL, runner: ProcessRunner = ProcessRunner(timeout: .seconds(120)),
        bsdtar: URL
    ) async throws {
        try await XLSXWriter.zipPackage(
            parts(for: document), to: url, folderPrefix: "docx", noun: "document", runner: runner, bsdtar: bsdtar)
    }

    // MARK: Parts

    static func parts(for document: RecognizedDocument) -> [(name: String, text: String)] {
        let contentTypes = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>"
        let rootRelationships = header + "<Relationships xmlns=\"\(packageRelationships)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relationshipsNamespace)/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let documentRelationships = header + "<Relationships xmlns=\"\(packageRelationships)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relationshipsNamespace)/numbering\" Target=\"numbering.xml\"/></Relationships>"
        return [
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rootRelationships), ("word/document.xml", documentXML(document)),
            ("word/numbering.xml", numberingXML), ("word/_rels/document.xml.rels", documentRelationships),
        ]
    }

    /// One abstract numbering with a bullet at its first level; every list item points at numId 1.
    private static let numberingXML = header + "<w:numbering xmlns:w=\"\(wordNamespace)\">"
        + "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        + "<w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u{2022}\"/><w:lvlJc w:val=\"left\"/>"
        + "<w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"

    /// Each page after the first starts on its first paragraph marked `pageBreakBefore`: a break in a paragraph of its
    /// own would leave that paragraph as an empty line at the top of the page in Word.
    static func documentXML(_ document: RecognizedDocument) -> String {
        var body = ""
        for (index, page) in document.pagesInReadingOrder().enumerated() {
            var breaksBefore = index > 0
            for block in page {
                let xml = blockXML(block, breaksBefore: breaksBefore)
                if !xml.isEmpty { breaksBefore = false }
                body += xml
            }
            // A page with no text still turns a page.
            if breaksBefore { body += "<w:p><w:pPr>\(pageBreakBefore)</w:pPr></w:p>" }
        }
        return header + "<w:document xmlns:w=\"\(wordNamespace)\"><w:body>" + body
            + "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
            + "</w:sectPr></w:body></w:document>"
    }

    private static let pageBreakBefore = "<w:pageBreakBefore/>"

    /// `breaksBefore` puts the page break on the block's first paragraph (a table's first cell).
    private static func blockXML(_ block: RecognizedDocument.Block, breaksBefore: Bool) -> String {
        switch block.kind {
        case let .paragraph(text):
            return hasInk(text)
                ? paragraph(text.trimmingCharacters(in: .whitespacesAndNewlines), breaksBefore: breaksBefore) : ""
        case let .list(items):
            return items.filter(hasInk).enumerated().map {
                paragraph($0.element.trimmingCharacters(in: .whitespacesAndNewlines), numbered: true,
                          breaksBefore: breaksBefore && $0.offset == 0)
            }.joined()
        case let .table(rows):
            return table(rows, merges: block.merges, breaksBefore: breaksBefore)
        }
    }

    private static func hasInk(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func paragraph(_ text: String, numbered: Bool = false, breaksBefore: Bool = false) -> String {
        // The schema orders pageBreakBefore before numPr.
        let properties = (breaksBefore ? pageBreakBefore : "")
            + (numbered ? "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>" : "")
        return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs(text) + "</w:p>"
    }

    /// One run per line, a `<w:br/>` between lines.
    private static func runs(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map {
            "<w:r><w:t xml:space=\"preserve\">\(XLSXWriter.escaped(String($0), maxUnits: .max))</w:t></w:r>"
        }.joined(separator: "<w:r><w:br/></w:r>")
    }

    // MARK: Tables

    /// What sits in one grid position once the merges are placed.
    private enum Slot {
        case plain
        /// The top-left cell of a span.
        case origin(RecognizedDocument.TableMerge)
        /// Under an origin in its column: continues the vertical merge.
        case continuation(RecognizedDocument.TableMerge)
        /// Inside a span's other columns: Word has no cell there, `gridSpan` stands in for it.
        case covered
    }

    /// Merges that leave the grid or overlap an earlier one are ignored, so the table always stays rectangular.
    private static func slots(rows: Int, width: Int, merges: [RecognizedDocument.TableMerge]) -> [[Slot]] {
        var grid = Array(repeating: Array(repeating: Slot.plain, count: width), count: rows)
        var taken = Array(repeating: Array(repeating: false, count: width), count: rows)
        for merge in merges {
            guard merge.row >= 0, merge.column >= 0, merge.rowSpan >= 1, merge.columnSpan >= 1,
                merge.rowSpan > 1 || merge.columnSpan > 1,
                merge.rowSpan <= rows - merge.row, merge.columnSpan <= width - merge.column
            else { continue }
            let area = (merge.row..<merge.row + merge.rowSpan).flatMap { row in
                (merge.column..<merge.column + merge.columnSpan).map { (row, $0) }
            }
            guard !area.contains(where: { taken[$0.0][$0.1] }) else { continue }
            for (row, column) in area {
                taken[row][column] = true
                if row == merge.row && column == merge.column {
                    grid[row][column] = .origin(merge)
                } else if column == merge.column {
                    grid[row][column] = .continuation(merge)
                } else {
                    grid[row][column] = .covered
                }
            }
        }
        return grid
    }

    private static func table(
        _ rows: [[String]], merges: [RecognizedDocument.TableMerge], breaksBefore: Bool
    ) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0, rows.joined().contains(where: hasInk) else { return "" }
        let slots = slots(rows: rows.count, width: width, merges: merges)
        let border = { (side: String) in "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>" }
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(tableWidth)\" w:type=\"dxa\"/><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map(border).joined()
            + "</w:tblBorders></w:tblPr><w:tblGrid>"
            + String(repeating: "<w:gridCol w:w=\"\(tableWidth / width)\"/>", count: width) + "</w:tblGrid>"
        for (rowIndex, row) in rows.enumerated() {
            xml += "<w:tr>"
            for column in 0..<width {
                let text = column < row.count ? row[column].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                // The top-left position is never covered or a continuation, so it is always the first cell written.
                let first = breaksBefore && rowIndex == 0 && column == 0
                switch slots[rowIndex][column] {
                case .covered: continue
                case .plain: xml += cell(text, span: 1, vMerge: nil, breaksBefore: first)
                case let .origin(merge):
                    xml += cell(text, span: merge.columnSpan, vMerge: merge.rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : nil,
                                breaksBefore: first)
                case let .continuation(merge): xml += cell("", span: merge.columnSpan, vMerge: "<w:vMerge/>")
                }
            }
            xml += "</w:tr>"
        }
        // Word wants a paragraph between a table and whatever follows it.
        return xml + "</w:tbl><w:p/>"
    }

    private static func cell(_ text: String, span: Int, vMerge: String?, breaksBefore: Bool = false) -> String {
        var properties = "<w:tcW w:w=\"0\" w:type=\"auto\"/>"
        if span > 1 { properties += "<w:gridSpan w:val=\"\(span)\"/>" }
        if let vMerge { properties += vMerge }
        let content = text.isEmpty
            ? (breaksBefore ? "<w:p><w:pPr>\(pageBreakBefore)</w:pPr></w:p>" : "<w:p/>")
            : paragraph(text, breaksBefore: breaksBefore)
        return "<w:tc><w:tcPr>\(properties)</w:tcPr>" + content + "</w:tc>"
    }
}
