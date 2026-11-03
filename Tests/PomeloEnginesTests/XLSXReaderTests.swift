import Foundation
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct XLSXReaderTests {
    typealias Part = XLSXFixture.Part
    typealias Sheet = XLSXFixture.Sheet

    private func read(
        _ parts: [Part], in dir: URL, limits: XLSXReader.Limits = XLSXReader.Limits()
    ) async throws -> [XLSXReader.Sheet] {
        let book = try XLSXFixture.write(parts, to: dir.appending(path: "book-\(UUID().uuidString.prefix(6)).xlsx"))
        return try await XLSXReader.read(
            book, workDirectory: dir.appending(path: "work-\(UUID().uuidString.prefix(6))"), runner: ProcessRunner(),
            limits: limits)
    }

    private func read(
        sheets: [Sheet], shared: [String]? = nil, styles: String? = nil, date1904: Bool = false, in dir: URL
    ) async throws -> [XLSXReader.Sheet] {
        try await read(XLSXFixture.parts(sheets: sheets, shared: shared, styles: styles, date1904: date1904), in: dir)
    }

    private func firstRow(_ cells: String, shared: [String]? = nil, styles: String? = nil, date1904: Bool = false, in dir: URL) async throws -> [String] {
        let sheets = try await read(sheets: [Sheet("S", cells: cells)], shared: shared, styles: styles, date1904: date1904, in: dir)
        return try #require(sheets.first?.rows.first)
    }

    private func failure(of work: () async throws -> some Any) async -> XLSXReader.Failure? {
        do {
            _ = try await work()
            return nil
        } catch let error as XLSXReader.Failure {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    // MARK: Values

    @Test func sharedInlineNumbersBooleansFormulasErrors() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1,
            "<c r=\"A1\" t=\"s\"><v>0</v></c>" + XLSXFixture.inline("B1", "inline")
            + XLSXFixture.number("C1", "3.50") + "<c r=\"D1\" t=\"b\"><v>1</v></c>"
            + "<c r=\"E1\"><f>SUM(A1:A2)</f><v>7</v></c>" + "<c r=\"F1\" t=\"e\"><v>#DIV/0!</v></c>")

        let row = try await firstRow(cells, shared: ["shared"], in: dir)

        #expect(row == ["shared", "inline", "3.50", "TRUE", "7", "#DIV/0!"])
    }

    @Test func booleanFalseAndAFormulaWithoutAValueIsEmpty() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1,
            "<c r=\"A1\" t=\"b\"><v>0</v></c><c r=\"B1\"><f>NOW()</f></c><c r=\"C1\" t=\"str\"><f>A1</f><v>text</v></c>")

        #expect(try await firstRow(cells, in: dir) == ["FALSE", "", "text"])
    }

    @Test func datesAreISO() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1,
            XLSXFixture.number("A1", "46325", style: 1) + XLSXFixture.number("B1", "46325", style: 2)
            + XLSXFixture.number("C1", "46325.5868", style: 3) + XLSXFixture.number("D1", "46325", style: 0))

        let row = try await firstRow(cells, styles: XLSXFixture.datesStyles, in: dir)

        #expect(row == ["2026-10-30", "2026-10-30", "2026-10-30 14:05:00", "46325"])
    }

    @Test func date1904() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.number("A1", "44863", style: 1))

        let row = try await firstRow(cells, styles: XLSXFixture.datesStyles, date1904: true, in: dir)

        #expect(row == ["2026-10-30"])
    }

    @Test func serialNumbersAroundExcelsLeapYearBug() {
        #expect(XLSXReader.isoDate(serial: 1, date1904: false) == "1900-01-01")
        #expect(XLSXReader.isoDate(serial: 59, date1904: false) == "1900-02-28")
        #expect(XLSXReader.isoDate(serial: 60, date1904: false) == "1900-02-29")
        #expect(XLSXReader.isoDate(serial: 61, date1904: false) == "1900-03-01")
        #expect(XLSXReader.isoDate(serial: 0, date1904: true) == "1904-01-01")
        #expect(XLSXReader.isoDate(serial: 0.75, date1904: false) == "18:00:00")
        #expect(XLSXReader.isoDate(serial: 46325.99999999, date1904: false) == "2026-10-31")
        #expect(XLSXReader.isoDate(serial: -1, date1904: false) == nil)
        #expect(XLSXReader.isoDate(serial: 1e300, date1904: false) == nil)
        #expect(XLSXReader.isoDate(serial: .nan, date1904: false) == nil)
    }

    @Test func customFormatsThatAreDates() {
        for code in ["dd/mm/yyyy", "yyyy\\-mm\\-dd", "[$-409]d-mmm-yy", "h:mm AM/PM", "[h]:mm:ss", "dd/mm/yyyy;@", "mmmm d, yyyy"] {
            #expect(XLSXReader.isDateFormat(code: code), "\(code)")
        }
        for code in ["General", "Standard", "0.00", "#,##0.00 \"days\"", "0.00E+00", "[Red]0.0;[Blue]-0.0", "@", "0\\d", "_(* #,##0_)"] {
            #expect(!XLSXReader.isDateFormat(code: code), "\(code)")
        }
    }

    @Test func gapsKeepColumns() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.inline("A1", "x") + XLSXFixture.inline("C1", "z"))

        #expect(try await firstRow(cells, in: dir) == ["x", "", "z"])
    }

    @Test func gapsKeepRowsAndCellsWithoutReferencesFollowTheLastOne() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = "<row r=\"2\"><c t=\"inlineStr\"><is><t>a</t></is></c><c t=\"inlineStr\"><is><t>b</t></is></c></row>"
            + "<row><c t=\"inlineStr\"><is><t>c</t></is></c></row>"

        let sheets = try await read(sheets: [Sheet("S", cells: cells)], in: dir)

        #expect(sheets.first?.rows == [[], ["a", "b"], ["c"]])
    }

    @Test func emptyStringsAndStyledBlankCellsAreNotData() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, "<c r=\"A1\" s=\"1\"/><c r=\"XFD1\" s=\"1\"/>" + XLSXFixture.inline("B1", ""))

        let sheets = try await read(sheets: [Sheet("S", cells: cells)], in: dir)

        #expect(sheets.isEmpty)
    }

    @Test func richTextRunsAreJoinedAndPhoneticTextIsDropped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let shared = "<?xml version=\"1.0\"?><sst xmlns=\"\(XLSXFixture.main)\">"
            + "<si><r><rPr><b/></rPr><t>Hel</t></r><r><t xml:space=\"preserve\">lo </t></r><r><t>wörld</t></r>"
            + "<rPh sb=\"0\" eb=\"1\"><t>ふりがな</t></rPh></si></sst>"
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, "<c r=\"A1\" t=\"s\"><v>0</v></c>"))])
        parts.append(Part("xl/sharedStrings.xml", shared))

        let sheets = try await read(parts, in: dir)

        #expect(sheets.first?.rows == [["Hello wörld"]])
    }

    @Test func namespacePrefixesAndEscapesAreRead() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("Q&amp;A", cells: "")])
        parts[2] = Part("xl/worksheets/sheet1.xml",
            "<x:worksheet xmlns:x=\"\(XLSXFixture.main)\"><x:sheetData><x:row r=\"1\"><x:c r=\"A1\" t=\"inlineStr\">"
            + "<x:is><x:t>a &lt; b &amp; &#8364;<![CDATA[ <raw>]]></x:t></x:is></x:c></x:row></x:sheetData></x:worksheet>")

        let sheets = try await read(parts, in: dir)

        #expect(sheets == [XLSXReader.Sheet(name: "Q&A", rows: [["a < b & € <raw>"]])])
    }

    @Test func negativeScientificNumbersStayNumbersInCSV() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.number("A1", "-1.5E-5") + XLSXFixture.number("B1", "2.5E-5")
            + XLSXFixture.number("C1", "-4"))

        // CSVWriter would put a formula guard in front of "-1.5E-5".
        #expect(try await firstRow(cells, in: dir) == ["-0.000015", "2.5E-5", "-4"])
    }

    @Test func absoluteTargetsAndDotSegmentsResolve() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "ok")))])
        parts[1] = Part("xl/_rels/workbook.xml.rels",
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(XLSXFixture.relationships)/worksheet\" Target=\"/xl/./worksheets/../worksheets/sheet1.xml\"/>"
            + "</Relationships>")

        #expect(try await read(parts, in: dir).first?.rows == [["ok"]])
    }

    // MARK: Sheets

    @Test func hiddenAndEmptySheetsSkipped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = XLSXFixture.row(1, XLSXFixture.inline("A1", "x"))

        let sheets = try await read(sheets: [
            Sheet("Shown", cells: data), Sheet("Hidden", cells: data, state: "hidden"),
            Sheet("Very", cells: data, state: "veryHidden"), Sheet("Empty", cells: ""), Sheet("Last", cells: data),
        ], in: dir)

        #expect(sheets.map(\.name) == ["Shown", "Last"])
    }

    @Test func aChartsheetIsNotASheetOfData() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x"))), Sheet("Chart", cells: "")])
        parts[1] = Part("xl/_rels/workbook.xml.rels",
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(XLSXFixture.relationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(XLSXFixture.relationships)/chartsheet\" Target=\"chartsheets/sheet1.xml\"/>"
            + "</Relationships>")

        #expect(try await read(parts, in: dir).map(\.name) == ["S"])
    }

    // MARK: The package

    @Test func tooManyEntries() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts += (0...XLSXReader.maxEntries).map { Part("junk/\($0).txt", "") }

        #expect(await failure { try await read(parts, in: dir) } == .tooLarge)
    }

    @Test func exactlyTheMaximumNumberOfEntriesIsFine() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts += (0..<(XLSXReader.maxEntries - parts.count)).map { Part("junk/\($0).txt", "") }
        #expect(parts.count == XLSXReader.maxEntries)

        #expect(try await read(parts, in: dir).count == 1)
    }

    @Test func tooLarge() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts.append(Part("xl/media/huge.bin", "tiny", declaredSize: 600_000_000))

        #expect(await failure { try await read(parts, in: dir) } == .tooLarge)
    }

    @Test func theListingParserReadsNamesWithSpacesAndSumsSizes() throws {
        let listing = """
            drwxr-xr-x  0 501    20          0 Oct 30 22:53 xl/
            -rw-r--r--  0 501    20       1234 Oct 30 22:53 xl/my sheet  one.xml
            -rw-r--r--  0 0      0          77 Oct 30  2026 a b
            """
        #expect(try XLSXReader.Package.parse(listing: listing) == ["xl/": 0, "xl/my sheet  one.xml": 1234, "a b": 77])
    }

    @Test func theListingParserRefusesWhatItCannotTrust() {
        let line = { (mode: String, size: String, name: String) in "\(mode)  0 501    20 \(size) Oct 30 22:53 \(name)" }
        let cases: [(String, XLSXReader.Failure)] = [
            ((0..<6).map { line("-rw-r--r--", "90000000", "p\($0)") }.joined(separator: "\n"), .tooLarge),
            (line("-rw-r--r--", "99999999999999999999999", "big"), .tooLarge),
            (line("-rw-r--r--", "500000001", "big"), .tooLarge),
            (line("lrwxr-xr-x", "0", "link -> /etc/passwd"), .damaged),
            (line("hrw-r--r--", "0", "hard"), .damaged),
            (line("-rw-r--r--", "-5", "neg"), .damaged),
            (line("-rw-r--r--", "abc", "bad"), .damaged),
            ("garbage", .damaged),
            (line("-rw-r--r--", "1", "../evil"), .damaged),
            (line("-rw-r--r--", "1", "xl/../../evil"), .damaged),
            (line("-rw-r--r--", "1", "/abs"), .damaged),
            (line("-rw-r--r--", "1", "tab\there"), .damaged),
            (line("-rw-r--r--", "1", "a") + "\n" + line("-rw-r--r--", "1", "a"), .damaged),
            ((0...XLSXReader.maxEntries).map { line("-rw-r--r--", "1", "n\($0)") }.joined(separator: "\n"), .tooLarge),
        ]
        for (listing, expected) in cases {
            do {
                _ = try XLSXReader.Package.parse(listing: listing)
                Issue.record("\(listing.prefix(80)) was accepted")
            } catch let error as XLSXReader.Failure {
                #expect(error == expected, Comment(rawValue: String(listing.prefix(80))))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func aHugeCentralDirectoryIsRefusedBeforeBsdtarLists() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var data = XLSXFixture.zip(XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))]))
        // The end record is the last 22 bytes: claim 60,000 entries.
        data.replaceSubrange((data.count - 12)..<(data.count - 10), with: [0x60, 0xEA])
        data.replaceSubrange((data.count - 14)..<(data.count - 12), with: [0x60, 0xEA])
        let book = dir.appending(path: "bomb.xlsx")
        try data.write(to: book)

        #expect(await failure { try await XLSXReader.read(book, workDirectory: dir.appending(path: "w"), runner: ProcessRunner()) } == .tooLarge)
    }

    @Test func aSheetOverThePartLimitIsTooLargeBeforeExtraction() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts[2].declaredSize = UInt32(XLSXReader.maxPartBytes + 1)

        #expect(await failure { try await read(parts, in: dir) } == .tooLarge)
        let work = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("work-") }
        #expect(work.allSatisfy { !FileManager.default.fileExists(atPath: dir.appending(path: "\($0)/xl/worksheets").path) })
    }

    @Test func traversalEntryRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let outer = dir.appending(path: "outer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts.append(Part("../evil", "pwned"))
        let book = try XLSXFixture.write(parts, to: outer.appending(path: "book.xlsx"))
        let work = outer.appending(path: "work", directoryHint: .isDirectory)

        #expect(await failure { try await XLSXReader.read(book, workDirectory: work, runner: ProcessRunner()) } == .damaged)
        #expect(!FileManager.default.fileExists(atPath: outer.appending(path: "evil").path))
        #expect(!FileManager.default.fileExists(atPath: outer.deletingLastPathComponent().appending(path: "evil").path))
    }

    @Test func absoluteAndNestedTraversalNamesAreRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let base = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        for name in ["/tmp/pomelo-evil", "xl/../../evil", "xl/worksheets/../../../evil"] {
            #expect(await failure { try await read(base + [Part(name, "x")], in: dir) } == .damaged, "\(name)")
        }
    }

    @Test func aSymlinkEntryIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts[0] = Part("xl/workbook.xml", "/etc/passwd", unixMode: 0o120755)

        #expect(await failure { try await read(parts, in: dir) } == .damaged)
    }

    @Test func duplicateEntriesAreRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts.append(Part("xl/workbook.xml", "<workbook/>"))

        #expect(await failure { try await read(parts, in: dir) } == .damaged)
    }

    @Test func encryptedWorkbook() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let book = dir.appending(path: "locked.xlsx")
        try (Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 512)).write(to: book)

        #expect(await failure { try await XLSXReader.read(book, workDirectory: dir.appending(path: "w"), runner: ProcessRunner()) } == .passwordProtected)
    }

    @Test func notAZipIsDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for bytes in [Data(), Data("hello, not a workbook".utf8), Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])] {
            let book = dir.appending(path: "x-\(UUID().uuidString.prefix(6)).xlsx")
            try bytes.write(to: book)
            #expect(await failure { try await XLSXReader.read(book, workDirectory: dir.appending(path: "w"), runner: ProcessRunner()) } == .damaged)
        }
    }

    @Test func aWorkbookWithoutItsPartsIsDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await failure { try await read([Part("readme.txt", "hi")], in: dir) } == .damaged)
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))])
        parts.remove(at: 2)
        #expect(await failure { try await read(parts, in: dir) } == .damaged, "a sheet the workbook names is missing")
    }

    @Test func aRealArchiverWorkbookReadsBack() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let book = dir.appending(path: "written.xlsx")
        try await XLSXWriter.write(sheets: [[["a", "1.5", "=1+1"], ["", "x"]], [["second"]]], sheetNames: ["One", "Two"], to: book)

        let sheets = try await XLSXReader.read(book, workDirectory: dir.appending(path: "work"), runner: ProcessRunner())

        #expect(sheets == [
            XLSXReader.Sheet(name: "One", rows: [["a", "1.5", "=1+1"], ["", "x"]]),
            XLSXReader.Sheet(name: "Two", rows: [["second"]]),
        ])
    }

    // MARK: Hostile sheets

    @Test func absurdReferencesAreTooLargeNotAllocated() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for reference in ["XFD1048576", "A99999999999", "ZZZZ1", "XFE1", "A1048577", "A18446744073709551616"] {
            let cells = XLSXFixture.row(1, XLSXFixture.inline("A1", "x")) + "<row r=\"2\">\(XLSXFixture.inline(reference, "y"))</row>"
            let error = await failure { try await read(sheets: [Sheet("S", cells: cells)], in: dir) }
            // The first four are inside Excel's grid but too big once every row is as wide as the sheet.
            #expect(error == .tooLarge, "\(reference)")
        }
    }

    @Test func aFarCornerAloneIsTooLarge() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = "<row r=\"1048576\">\(XLSXFixture.inline("XFD1048576", "y"))</row>"

        #expect(await failure { try await read(sheets: [Sheet("S", cells: cells)], in: dir) } == .tooLarge)
    }

    @Test func aRowNumberOutsideExcelIsTooLarge() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = "<row r=\"99999999999\">\(XLSXFixture.inline("A1", "y"))</row>"

        #expect(await failure { try await read(sheets: [Sheet("S", cells: cells)], in: dir) } == .tooLarge)
    }

    @Test func malformedReferencesAreDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for reference in ["1A", "A", "A0", "$A$1", "A-1", "é1"] {
            let cells = XLSXFixture.row(1, XLSXFixture.inline(reference, "y"))
            #expect(await failure { try await read(sheets: [Sheet("S", cells: cells)], in: dir) } == .damaged, "\(reference)")
        }
    }

    @Test func manyRowsOfMediumWidthStayUnderTheCellCap() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.inline("A1", "x")) + XLSXFixture.row(1000, XLSXFixture.inline("J1000", "y"))
        var limits = XLSXReader.Limits()
        limits.maxCells = 9_999

        #expect(await failure { try await read(XLSXFixture.parts(sheets: [Sheet("S", cells: cells)]), in: dir, limits: limits) } == .tooLarge)
        limits.maxCells = 10_000
        #expect(try await read(XLSXFixture.parts(sheets: [Sheet("S", cells: cells)]), in: dir, limits: limits).count == 1)
    }

    @Test func theCellCapIsSharedByAllSheets() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.inline("A1", "x")) + XLSXFixture.row(10, XLSXFixture.inline("A10", "y"))
        var limits = XLSXReader.Limits()
        limits.maxCells = 15
        let parts = XLSXFixture.parts(sheets: [Sheet("One", cells: cells), Sheet("Two", cells: cells)])

        #expect(await failure { try await read(parts, in: dir, limits: limits) } == .tooLarge)
    }

    @Test func aSharedStringReferencedAgainAndAgainIsTooLarge() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let big = String(repeating: "x", count: 1_000)
        let cells = (1...50).map { XLSXFixture.row($0, "<c r=\"A\($0)\" t=\"s\"><v>0</v></c>") }.joined()
        var limits = XLSXReader.Limits()
        limits.maxCharacters = 20_000
        let parts = XLSXFixture.parts(sheets: [Sheet("S", cells: cells)], shared: [big])

        #expect(await failure { try await read(parts, in: dir, limits: limits) } == .tooLarge)
        limits.maxCharacters = 60_000
        #expect(try await read(parts, in: dir, limits: limits).first?.rows.count == 50)
    }

    @Test func sharedStringIndexesOutOfRangeAreDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for index in ["1", "99999999", "-1", "99999999999999999999", "abc"] {
            let cells = XLSXFixture.row(1, "<c r=\"A1\" t=\"s\"><v>\(index)</v></c>")
            let error = await failure { try await read(sheets: [Sheet("S", cells: cells)], shared: ["only"], in: dir) }
            #expect(error == .damaged, "\(index)")
        }
        let none = XLSXFixture.row(1, "<c r=\"A1\" t=\"s\"><v>0</v></c>")
        #expect(await failure { try await read(sheets: [Sheet("S", cells: none)], in: dir) } == .damaged, "no shared strings part")
    }

    @Test func entityDeclarationsAreRefusedBeforeTheyExpand() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let laughs = """
            <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol">\
            <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
            <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">\
            <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">\
            <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">\
            <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">]>\
            <worksheet xmlns="\(XLSXFixture.main)"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>&lol6;</t></is></c></row></sheetData></worksheet>
            """
        let external = """
            <?xml version="1.0"?><!DOCTYPE d [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>\
            <worksheet xmlns="\(XLSXFixture.main)"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>&xxe;</t></is></c></row></sheetData></worksheet>
            """
        let hiddenBehindAComment = "<?xml version=\"1.0\"?><!--" + String(repeating: " ", count: 70_000) + "-->"
            + laughs.replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
        let smallEntityBehindAComment = "<?xml version=\"1.0\"?><!--" + String(repeating: " ", count: 70_000) + "-->"
            + "<!DOCTYPE d [<!ENTITY a \"b\">]><worksheet xmlns=\"\(XLSXFixture.main)\"><sheetData><row r=\"1\">"
            + "<c r=\"A1\" t=\"inlineStr\"><is><t>&a;</t></is></c></row></sheetData></worksheet>"
        for hostile in [laughs, external, hiddenBehindAComment, smallEntityBehindAComment] {
            var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: "")])
            parts[2] = Part("xl/worksheets/sheet1.xml", hostile)
            let started = ContinuousClock.now
            #expect(await failure { try await read(parts, in: dir) } == .damaged)
            #expect(ContinuousClock.now - started < .seconds(10))
        }
    }

    @Test func aDoctypeInTheWorkbookOrSharedStringsIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let declaration = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"b\">]>"
        for index in [0, 2, 3, 4] {
            var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: XLSXFixture.row(1, XLSXFixture.inline("A1", "x")))], shared: ["s"], styles: XLSXFixture.datesStyles)
            let victim = parts[index]
            parts[index] = Part(victim.name, declaration + String(decoding: victim.data, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: ""))
            #expect(await failure { try await read(parts, in: dir) } == .damaged, Comment(rawValue: victim.name))
        }
    }

    @Test func deeplyNestedXMLIsDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: "")])
        let depth = 5_000
        parts[2] = Part("xl/worksheets/sheet1.xml",
            "<worksheet xmlns=\"\(XLSXFixture.main)\"><sheetData>" + String(repeating: "<a>", count: depth)
            + String(repeating: "</a>", count: depth) + "</sheetData></worksheet>")

        #expect(await failure { try await read(parts, in: dir) } == .damaged)
    }

    @Test func malformedXMLIsDamaged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for xml in ["", "not xml", "<worksheet><sheetData><row r=\"1\"><c r=\"A1\"", "<worksheet></sheetData></worksheet>"] {
            var parts = XLSXFixture.parts(sheets: [Sheet("S", cells: "")])
            parts[2] = Part("xl/worksheets/sheet1.xml", xml)
            #expect(await failure { try await read(parts, in: dir) } == .damaged, "\(xml)")
        }
    }

    @Test func cancellationStopsTheRead() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = (1...20_000).map { XLSXFixture.row($0, XLSXFixture.inline("A\($0)", "x")) }.joined()
        let book = try XLSXFixture.write(XLSXFixture.parts(sheets: [Sheet("S", cells: cells)]), to: dir.appending(path: "big.xlsx"))
        let task = Task {
            try await XLSXReader.read(book, workDirectory: dir.appending(path: "work"), runner: ProcessRunner())
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
