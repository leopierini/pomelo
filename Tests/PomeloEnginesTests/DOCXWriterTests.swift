import AppKit
import Foundation
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct DOCXWriterTests {
    private typealias Block = RecognizedDocument.Block
    private let box = UnitRect(x: 0, y: 0, width: 0.8, height: 0.05)

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func documentXML(of pages: [[Block]], in dir: URL, name: String = "out.docx") async throws -> String {
        let url = dir.appending(path: name)
        try await DOCXWriter.write(RecognizedDocument(pages: pages), to: url)
        return try XLSXWriterTests.part("word/document.xml", of: url, in: dir)
    }

    @Test func packageParts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.docx")

        try await DOCXWriter.write(RecognizedDocument(pages: [[Block(.paragraph("Hello"), box: box)]]), to: url)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-t", "-f", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(Set(listing.split(separator: "\n").map(String.init)) == [
            "[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/numbering.xml", "word/_rels/document.xml.rels",
        ])
        for name in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/numbering.xml", "word/_rels/document.xml.rels"] {
            #expect(XMLParser(data: Data(try XLSXWriterTests.part(name, of: url, in: dir).utf8)).parse(), "\(name)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.docx"], "the parts folder is gone")
    }

    @Test func paragraphsListsTables() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let table = Block(
            .table([["Head", "", "C"], ["Tall", "x", "y"], ["", "z", "w"]]), box: box,
            merges: [
                .init(row: 0, column: 0, rowSpan: 1, columnSpan: 2),
                .init(row: 1, column: 0, rowSpan: 2, columnSpan: 1),
            ])
        let xml = try await documentXML(of: [[
            Block(.paragraph("Receipt"), box: UnitRect(x: 0, y: 0, width: 0.8, height: 0.05)),
            Block(.list(["Bread", "Milk"]), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.05)),
            Block(table.kind, box: UnitRect(x: 0, y: 0.3, width: 0.8, height: 0.1), merges: table.merges),
        ]], in: dir)

        #expect(XMLParser(data: Data(xml.utf8)).parse())
        #expect(count("<w:numPr>", in: xml) == 2)
        #expect(xml.contains("<w:t xml:space=\"preserve\">Receipt</w:t>"))
        #expect(xml.contains("Bread") && xml.contains("Milk"))
        #expect(count("<w:tbl>", in: xml) == 1 && count("<w:tr>", in: xml) == 3)
        #expect(count("<w:gridSpan w:val=\"2\"/>", in: xml) == 1)
        #expect(count("<w:vMerge w:val=\"restart\"/>", in: xml) == 1 && count("<w:vMerge/>", in: xml) == 1)
        // Row 0 holds two cells (the span and C), rows 1 and 2 three each.
        #expect(count("<w:tc>", in: xml) == 2 + 3 + 3)
    }

    @Test func aParagraphIsOneParagraphAndAListItemIsOneEach() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let single = try await documentXML(of: [[Block(.paragraph("One"), box: box)]], in: dir, name: "a.docx")
        #expect(count("<w:p>", in: single) == 1 && count("<w:numPr>", in: single) == 0)
        let list = try await documentXML(of: [[Block(.list(["A", "B"]), box: box)]], in: dir, name: "b.docx")
        #expect(count("<w:p>", in: list) == 2 && count("<w:numPr>", in: list) == 2)
    }

    private static let pageBreak = "<w:pageBreakBefore/>"

    @Test func pageBreakBetweenPages() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let two = try await documentXML(
            of: [[Block(.paragraph("One"), box: box)], [Block(.paragraph("Two"), box: box)]], in: dir, name: "a.docx")
        #expect(count(Self.pageBreak, in: two) == 1)
        let one = try await documentXML(of: [[Block(.paragraph("One"), box: box)]], in: dir, name: "b.docx")
        #expect(count(Self.pageBreak, in: one) == 0)
        let blank = try await documentXML(
            of: [[Block(.paragraph("One"), box: box)], [], [Block(.paragraph("Three"), box: box)]], in: dir, name: "c.docx")
        #expect(count(Self.pageBreak, in: blank) == 2, "a blank page stays a page")
    }

    /// The break belongs to the next page's first paragraph, so no page starts with an empty line in Word.
    @Test func aPageStartsWithItsOwnText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let two = try await documentXML(
            of: [[Block(.paragraph("One"), box: box)], [Block(.paragraph("Two"), box: box)]], in: dir, name: "a.docx")
        #expect(count("<w:p>", in: two) == 2)
        #expect(two.contains("<w:p><w:pPr>\(Self.pageBreak)</w:pPr><w:r><w:t xml:space=\"preserve\">Two</w:t></w:r></w:p>"))
        #expect(!two.contains("<w:br w:type=\"page\"/>"))

        // A page that opens on a list or a table, or on a block with no text, still breaks on its first paragraph.
        let list = try await documentXML(
            of: [[Block(.paragraph("One"), box: box)], [Block(.paragraph("  "), box: box), Block(.list(["A", "B"]), box: box)]],
            in: dir, name: "b.docx")
        #expect(count("<w:p>", in: list) == 3 && count(Self.pageBreak, in: list) == 1)
        #expect(list.contains("<w:p><w:pPr>\(Self.pageBreak)<w:numPr>"))
        let table = try await documentXML(
            of: [[Block(.paragraph("One"), box: box)], [Block(.table([["", "b"], ["c", "d"]]), box: box)]],
            in: dir, name: "c.docx")
        #expect(count(Self.pageBreak, in: table) == 1)
        #expect(table.contains("<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr><w:p><w:pPr>\(Self.pageBreak)</w:pPr></w:p></w:tc>"))
        #expect(XMLParser(data: Data(table.utf8)).parse())
    }

    @Test func textIsEscapedAndControlCharactersDropped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let xml = try await documentXML(of: [[
            Block(.paragraph("<a & \"b\">\u{0007}end"), box: box),
            Block(.list(["=1+1", "https://example.com"]), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.05)),
        ]], in: dir)

        #expect(xml.contains("&lt;a &amp; &quot;b&quot;&gt;end"))
        #expect(!xml.contains("\u{0007}"))
        for forbidden in ["<w:fldSimple", "<w:instrText", "<w:hyperlink", "<w:fldChar"] {
            #expect(!xml.contains(forbidden), "\(forbidden)")
        }
        #expect(XMLParser(data: Data(xml.utf8)).parse())
    }

    @Test func aLongParagraphIsNotCutAtACellLimit() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "word ", count: 10_000).trimmingCharacters(in: .whitespaces)
        let xml = try await documentXML(of: [[Block(.paragraph(long), box: box)]], in: dir)
        #expect(xml.contains(long))
    }

    @Test func lineBreaksInsideAParagraphAreBreaks() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let xml = try await documentXML(of: [[Block(.paragraph("one\ntwo\r\nthree"), box: box)]], in: dir)
        #expect(count("<w:p>", in: xml) == 1 && count("<w:br/>", in: xml) == 2)
    }

    @Test func blocksComeOutInReadingOrder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let xml = try await documentXML(of: [[
            Block(.paragraph("Second"), box: UnitRect(x: 0, y: 0.5, width: 0.8, height: 0.05)),
            Block(.paragraph("First"), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.05)),
        ]], in: dir)
        let first = try #require(xml.range(of: "First")), second = try #require(xml.range(of: "Second"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func mergesOutsideTheGridOrOverlappingAreIgnoredAndTheTableStaysRectangular() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let table = Block(
            .table([["a", "b"], ["c"]]), box: box,
            merges: [
                .init(row: 0, column: 1, rowSpan: 1, columnSpan: 5),
                .init(row: 0, column: 0, rowSpan: 0, columnSpan: 1),
                .init(row: 1, column: 0, rowSpan: 1, columnSpan: 2),
                .init(row: 1, column: 1, rowSpan: 1, columnSpan: 1),
            ])
        let xml = try await documentXML(of: [[table]], in: dir)
        #expect(XMLParser(data: Data(xml.utf8)).parse())
        #expect(count("<w:gridSpan w:val=\"2\"/>", in: xml) == 1)
        #expect(count("<w:tc>", in: xml) == 3, "row 0: two cells, row 1: the spanned one")
    }

    @Test func aStandInArchiverThatFailsLeavesNothingBehind() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.docx")
        await #expect(throws: DOCXWriter.Failure.self) {
            try await DOCXWriter.write(
                RecognizedDocument(pages: [[Block(.paragraph("x"), box: box)]]), to: url, bsdtar: URL(filePath: "/usr/bin/false"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anArchiveThatDoesNotListBackIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.docx")
        await #expect(throws: DOCXWriter.Failure.self) {
            try await DOCXWriter.write(
                RecognizedDocument(pages: [[Block(.paragraph("x"), box: box)]]), to: url, bsdtar: URL(filePath: "/usr/bin/true"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anExistingOutputIsNeverOverwritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.docx")
        try Data("mine".utf8).write(to: url)
        await #expect(throws: DOCXWriter.Failure.self) {
            try await DOCXWriter.write(RecognizedDocument(pages: [[Block(.paragraph("x"), box: box)]]), to: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
    }

    @Test func opensInTextKit() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.docx")
        try await DOCXWriter.write(
            RecognizedDocument(pages: [
                [
                    Block(.paragraph("Quarterly report"), box: UnitRect(x: 0, y: 0, width: 0.8, height: 0.05)),
                    Block(.list(["Bread", "Milk"]), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.05)),
                    Block(.table([["Item", "Qty"], ["Bread", "2"]]), box: UnitRect(x: 0, y: 0.3, width: 0.8, height: 0.1)),
                ],
                [Block(.paragraph("Second page"), box: box)],
            ]), to: url)

        let text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string

        for expected in ["Quarterly report", "Bread", "Milk", "Item", "Qty", "2", "Second page"] {
            #expect(text.contains(expected), "\(expected) in \(text)")
        }
    }
}
