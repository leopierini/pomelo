import Foundation
import Testing
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct XLSXWriterTests {
    /// Unzips `archive` with bsdtar and returns the text of the part at `path`.
    static func part(_ path: String, of archive: URL, in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        // Extraction patterns are globs: `[Content_Types].xml` needs its brackets escaped.
        let pattern = path.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        process.arguments = ["-x", "-O", "-f", archive.path, pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Fixtures.Failure("no part \(path) in \(archive.lastPathComponent)") }
        return String(decoding: data, as: UTF8.self)
    }

    private func wellFormed(_ xml: String) -> Bool {
        let parser = XMLParser(data: Data(xml.utf8))
        return parser.parse()
    }

    @Test func thePackageHasTheMinimalPartsAndEveryOneIsWellFormedXML() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "book.xlsx")

        try await XLSXWriter.write(sheets: [[["a"]], [["b"]]], to: url)

        let names = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
            "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"]
        for name in names {
            #expect(wellFormed(try Self.part(name, of: url, in: dir)), "\(name)")
        }
        let workbook = try Self.part("xl/workbook.xml", of: url, in: dir)
        #expect(workbook.contains("<sheet name=\"Table 1\" sheetId=\"1\" r:id=\"rId1\"/>"))
        #expect(workbook.contains("<sheet name=\"Table 2\" sheetId=\"2\" r:id=\"rId2\"/>"))
        let rels = try Self.part("xl/_rels/workbook.xml.rels", of: url, in: dir)
        #expect(rels.contains("Id=\"rId3\"") && rels.contains("Target=\"styles.xml\""))
        #expect(try Self.part("[Content_Types].xml", of: url, in: dir).contains("/xl/worksheets/sheet2.xml"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["book.xlsx"], "the parts folder is gone")
    }

    @Test func plainNumbersAreNumbersAndEverythingElseIsAnInlineString() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "book.xlsx")
        let rows = [["Item", "Qty", "Price"], ["Bread", "2", "3.50"], ["Refund", "-4", "1,80"], ["Code", "007", "1e5"]]

        try await XLSXWriter.write(sheets: [rows], to: url)

        let sheet = try Self.part("xl/worksheets/sheet1.xml", of: url, in: dir)
        #expect(sheet.contains("<c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">Item</t></is></c>"))
        #expect(sheet.contains("<c r=\"B2\"><v>2</v></c><c r=\"C2\"><v>3.50</v></c>"))
        #expect(sheet.contains("<c r=\"B3\"><v>-4</v></c>"))
        #expect(sheet.contains("<c r=\"C3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">1,80</t></is></c>"), "a decimal comma is text")
        #expect(sheet.contains("<c r=\"B4\" t=\"inlineStr\"><is><t xml:space=\"preserve\">007</t></is></c>"), "an ID keeps its zeros")
        #expect(sheet.contains("<c r=\"C4\" t=\"inlineStr\">"), "an exponent is text")
    }

    @Test func sheetNamesAreWritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "book.xlsx")

        try await XLSXWriter.write(sheets: [[["a"]], [["b"]], [["c"]]], sheetNames: ["Q&A <1>", "say \"hi\""], to: url)

        let workbook = try Self.part("xl/workbook.xml", of: url, in: dir)
        #expect(workbook.contains("<sheet name=\"Q&amp;A &lt;1&gt;\" sheetId=\"1\" r:id=\"rId1\"/>"))
        #expect(workbook.contains("<sheet name=\"say &quot;hi&quot;\" sheetId=\"2\" r:id=\"rId2\"/>"))
        #expect(workbook.contains("<sheet name=\"Table 3\" sheetId=\"3\" r:id=\"rId3\"/>"), "a missing name keeps the default")
        #expect(wellFormed(workbook))
    }

    @Test func formulasAreNeverWrittenAndMarkupIsEscaped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "book.xlsx")

        try await XLSXWriter.write(sheets: [[["=1+1", "@SUM(A1)", "a & b <c> \"d\"", "line\none", "bell\u{7}"]]], to: url)

        let sheet = try Self.part("xl/worksheets/sheet1.xml", of: url, in: dir)
        #expect(!sheet.contains("<f>"))
        #expect(sheet.contains("<t xml:space=\"preserve\">=1+1</t>"))
        #expect(sheet.contains("<t xml:space=\"preserve\">@SUM(A1)</t>"))
        #expect(sheet.contains("a &amp; b &lt;c&gt; &quot;d&quot;"))
        #expect(sheet.contains("line\none"))
        #expect(sheet.contains("<t xml:space=\"preserve\">bell</t>"), "a control character XML forbids is dropped")
        #expect(wellFormed(sheet))
    }

    @Test func emptyCellsAreSkippedAndColumnsAreLettered() {
        #expect(XLSXWriter.sheetXML([["", "x"], [], ["y"]]).contains("<row r=\"1\"><c r=\"B1\" t=\"inlineStr\">"))
        #expect(!XLSXWriter.sheetXML([["", "x"], [], ["y"]]).contains("<row r=\"2\">"))
        #expect(XLSXWriter.sheetXML([["", "x"], [], ["y"]]).contains("<row r=\"3\"><c r=\"A3\""))
        #expect([0, 1, 25, 26, 27, 51, 52, 701, 702, 16_383].map(XLSXWriter.columnName)
            == ["A", "B", "Z", "AA", "AB", "AZ", "BA", "ZZ", "AAA", "XFD"])
    }

    @Test(arguments: [
        ("0", true), ("7", true), ("-7", true), ("3.50", true), ("-0.5", true), ("0.0", true), ("123456789012345", true),
        ("1234567890123456", false), ("12345678.12345678", false), ("007", false), ("00.5", false), ("", false),
        ("-", false), (".5", false), ("5.", false), ("1.2.3", false), ("+5", false), ("1e5", false), ("1,5", false),
        (" 5", false), ("５", false),
    ] as [(String, Bool)])
    func numbersAreExactlyPlainDecimals(_ text: String, _ expected: Bool) {
        #expect(XLSXWriter.isNumber(text) == expected, "\(text)")
    }

    @Test func aCellLongerThanExcelAllowsIsCutAndStaysWellFormed() {
        let escaped = XLSXWriter.escaped(String(repeating: "a", count: 40_000))
        #expect(escaped.count == XLSXWriter.maxCellCharacters)
        #expect(XLSXWriter.escaped(String(repeating: "\u{1F34A}", count: 20_000)).utf16.count <= XLSXWriter.maxCellCharacters)
    }

    @Test func aWorkbookWithoutSheetsIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: XLSXWriter.Failure.self) { try await XLSXWriter.write(sheets: [], to: dir.appending(path: "x.xlsx")) }
    }

    @Test func aZipThatFailsLeavesNoOutputAndNoParts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: XLSXWriter.Failure.self) {
            try await XLSXWriter.write(sheets: [[["a"]]], to: dir.appending(path: "book.xlsx"), bsdtar: URL(filePath: "/usr/bin/false"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func aWorkbookThatDoesNotReadBackIsAnError() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // `true` exits 0 and writes nothing, so the listing is empty.
        await #expect(throws: XLSXWriter.Failure("the workbook does not read back")) {
            try await XLSXWriter.write(sheets: [[["a"]]], to: dir.appending(path: "book.xlsx"), bsdtar: URL(filePath: "/usr/bin/true"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anExistingFileIsNeverOverwritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "book.xlsx")
        try Data("mine".utf8).write(to: url)
        await #expect(throws: XLSXWriter.Failure.self) { try await XLSXWriter.write(sheets: [[["a"]]], to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
    }

    @Test func mergeReferencesSpanFromTheTopLeftCell() {
        func reference(_ row: Int, _ column: Int, _ rows: Int, _ columns: Int) -> String {
            XLSXWriter.reference(of: .init(row: row, column: column, rowSpan: rows, columnSpan: columns))
        }
        #expect(reference(0, 1, 1, 2) == "B1:C1")
        #expect(reference(1, 0, 2, 1) == "A2:A3")
        #expect(reference(2, 25, 3, 3) == "Z3:AB5")
        #expect(!XLSXWriter.sheetXML([["a"]]).contains("mergeCells"))
    }
}
