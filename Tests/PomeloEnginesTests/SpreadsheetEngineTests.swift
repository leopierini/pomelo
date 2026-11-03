import Foundation
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct SpreadsheetEngineTests {
    private let formats = FormatRegistry.builtIn

    private func convert(csv text: String, named name: String = "table.csv", in dir: URL) async throws -> URL {
        let source = dir.appending(path: name)
        try Data(text.utf8).write(to: source)
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging,
            from: try #require(formats.format(for: source)), to: try #require(formats.format(id: "xlsx")),
            options: PresetOptions())
        return try await SpreadsheetEngine().convert(step) { _ in }
    }

    private func part(_ path: String, of archive: URL, in dir: URL) throws -> String {
        try XLSXWriterTests.part(path, of: archive, in: dir)
    }

    @Test func theEngineOffersCsvToXlsxAndBack() async {
        let engine = SpreadsheetEngine()
        #expect(engine.id == "spreadsheet")
        #expect(engine.maxConcurrentJobs == 2)
        #expect(engine.edges().map { "\($0.from)>\($0.to)" } == ["csv>xlsx", "xlsx>csv"])
        #expect(engine.edges().allSatisfy { $0.cost == 10 })
        #expect(engine.edges().map(\.flags) == [[], [.lossy]])
        #expect(await engine.availability() == .available(version: nil))
    }

    @Test func csvToXlsxOneSheetNamedAfterStem() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "a,b\n1,2\n", named: "sales 2026.csv", in: dir)

        #expect(output.pathExtension == "xlsx")
        let workbook = try part("xl/workbook.xml", of: output, in: dir)
        #expect(workbook.contains("<sheet name=\"sales 2026\" sheetId=\"1\" r:id=\"rId1\"/>"))
        #expect(workbook.components(separatedBy: "<sheet ").count == 2)
        #expect(try part("xl/worksheets/sheet1.xml", of: output, in: dir).contains("<c r=\"B2\"><v>2</v></c>"))
    }

    @Test func sheetNamesAreExcelLegal() {
        #expect(SpreadsheetEngine.sheetName(forStem: String(repeating: "a", count: 40)).count == 31)
        #expect(SpreadsheetEngine.sheetName(forStem: "a[b]:c*?/\\") == "a_b__c____")
        #expect(SpreadsheetEngine.sheetName(forStem: "'quoted'") == "quoted")
        #expect(SpreadsheetEngine.sheetName(forStem: "") == "Sheet1")
        #expect(SpreadsheetEngine.sheetName(forStem: String(repeating: "\u{1F34A}", count: 20)).utf16.count <= 31)
    }

    @Test func controlCharactersNeverMakeANamelessSheet() {
        #expect(SpreadsheetEngine.sheetName(forStem: "a\tb") == "a_b")
        #expect(SpreadsheetEngine.sheetName(forStem: "\u{1}\u{7}") == "__")
        #expect(SpreadsheetEngine.sheetName(forStem: "''") == "Sheet1")
    }

    @Test func aSheetBeyondExcelsLimitsIsTooLargeToConvert() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await convert(csv: String(repeating: ",", count: 16_384) + "x", in: dir)
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConversionError == .engineUnsupported(engine: "spreadsheet", reason: "It's too large to convert"))
        }
    }

    @Test func formulaStaysText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "x,y\n=1+1,@SUM(A1)\n", in: dir)

        let sheet = try part("xl/worksheets/sheet1.xml", of: output, in: dir)
        #expect(!sheet.contains("<f>"))
        #expect(sheet.contains("<c r=\"A2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">=1+1</t></is></c>"))
    }

    @Test func semicolonDecimalComma() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "a;1,5\nb;007\nc;1,2,3\n", in: dir)

        let sheet = try part("xl/worksheets/sheet1.xml", of: output, in: dir)
        #expect(sheet.contains("<c r=\"B1\"><v>1.5</v></c>"))
        #expect(sheet.contains("<c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">007</t></is></c>"))
        #expect(sheet.contains("<c r=\"B3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">1,2,3</t></is></c>"))
    }

    /// An Italian export: `1.234,56` is a number with a thousands mark, `1.500` and `2.50` are ambiguous there and
    /// stay text (P209).
    @Test func semicolonThousandsSeparators() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(
            csv: "Nome;Quantità;Prezzo\nMele;1.500;2,50\nPere;12;1.234,56\nUva;3;-0,75\nKiwi;2.50;1.234.567\n", in: dir)

        let sheet = try part("xl/worksheets/sheet1.xml", of: output, in: dir)
        #expect(sheet.contains("<c r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">1.500</t></is></c>"))
        #expect(sheet.contains("<c r=\"C2\"><v>2.50</v></c>"))
        #expect(sheet.contains("<c r=\"B3\"><v>12</v></c>"))
        #expect(sheet.contains("<c r=\"C3\"><v>1234.56</v></c>"))
        #expect(sheet.contains("<c r=\"C4\"><v>-0.75</v></c>"))
        #expect(sheet.contains("<c r=\"B5\" t=\"inlineStr\"><is><t xml:space=\"preserve\">2.50</t></is></c>"))
        #expect(sheet.contains("<c r=\"C5\"><v>1234567</v></c>"))
    }

    @Test func aCommaFileReadsADotAsTheDecimalPoint() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "a,1.500\nb,2.50\n", in: dir)

        let sheet = try part("xl/worksheets/sheet1.xml", of: output, in: dir)
        #expect(sheet.contains("<c r=\"B1\"><v>1.500</v></c>"))
        #expect(sheet.contains("<c r=\"B2\"><v>2.50</v></c>"))
    }

    @Test func aCommaFileKeepsADecimalCommaAsText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "a,\"1,5\"\n", in: dir)

        #expect(try part("xl/worksheets/sheet1.xml", of: output, in: dir)
            .contains("<c r=\"B1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">1,5</t></is></c>"))
    }

    @Test func accentedUtf8StaysAccented() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(csv: "città;prezzo\nRoma;1,5\n", in: dir)

        let sheet = try part("xl/worksheets/sheet1.xml", of: output, in: dir)
        #expect(sheet.contains(">città<"))
    }

    @Test func aSourceOtherThanCsvIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.srt(in: dir)
        let step = ConversionStep(
            input: source, stagingDirectory: dir,
            from: try #require(formats.format(for: source)), to: try #require(formats.format(id: "xlsx")),
            options: PresetOptions())
        await #expect(throws: ConversionError.self) { try await SpreadsheetEngine().convert(step) { _ in } }
    }

    // MARK: XLSX to CSV

    private func convert(
        xlsx parts: [XLSXFixture.Part], named name: String = "book.xlsx", in dir: URL
    ) async throws -> (output: URL, staging: URL) {
        let source = try XLSXFixture.write(parts, to: dir.appending(path: name))
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging,
            from: try #require(formats.format(for: source)), to: try #require(formats.format(id: "csv")),
            options: PresetOptions())
        return (try await SpreadsheetEngine().convert(step) { _ in }, staging)
    }

    private func expectFailure(_ expected: ConversionError, _ parts: [XLSXFixture.Part], in dir: URL) async throws {
        do {
            _ = try await convert(xlsx: parts, in: dir)
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConversionError == expected)
        }
    }

    /// Shown as written by the app (check 3); a workbook the reader can't make sense of reads "may be damaged".
    private static let tooLarge = ConversionError.engineUnsupported(engine: "spreadsheet", reason: "It's too large to convert")

    private func data(_ cell: String = "x") -> String { XLSXFixture.row(1, XLSXFixture.inline("A1", cell)) }

    @Test func oneSheetIsAFile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = XLSXFixture.row(1, XLSXFixture.inline("A1", "città") + XLSXFixture.inline("B1", "a,b") + XLSXFixture.number("C1", "46325", style: 1))
            + XLSXFixture.row(2, XLSXFixture.inline("A2", "=1+1") + XLSXFixture.inline("C2", "say \"hi\""))
        let parts = XLSXFixture.parts(sheets: [.init("Dati", cells: cells)], styles: XLSXFixture.datesStyles)

        let (output, staging) = try await convert(xlsx: parts, named: "sales.xlsx", in: dir)

        #expect(output.lastPathComponent == "sales.csv")
        #expect(output.deletingLastPathComponent().path == staging.path)
        let bytes = try Data(contentsOf: output)
        #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self) == "città,\"a,b\",2026-10-30\r\n'=1+1,,\"say \"\"hi\"\"\"\r\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["sales.csv"], "no work folder is left behind")
    }

    @Test func threeSheetsAreAFolder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let parts = XLSXFixture.parts(sheets: [
            .init("Q1/Q2", cells: data("one")), .init("Totals", cells: data("two")), .init("..hidden: name", cells: data("three")),
        ])

        let (output, staging) = try await convert(xlsx: parts, named: "report.xlsx", in: dir)

        #expect(output.lastPathComponent == "report")
        #expect(output.deletingLastPathComponent().path == staging.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names == ["report-Q1-Q2.csv", "report-Totals.csv", "report-hidden- name.csv"])
        #expect(String(decoding: try Data(contentsOf: output.appending(path: "report-Totals.csv")).dropFirst(3), as: UTF8.self) == "two\r\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["report"])
    }

    @Test func aFolderOfOneSheetPerFileKeepsOnlyTheBOMOnce() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rows = (1...12_000).map { XLSXFixture.row($0, XLSXFixture.inline("A\($0)", "r\($0)") + XLSXFixture.inline("C\($0)", "z")) }.joined()

        let (output, _) = try await convert(xlsx: XLSXFixture.parts(sheets: [.init("Big", cells: rows)]), in: dir)

        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        let lines = text.dropFirst().split(separator: "\r\n")
        #expect(lines.count == 12_000)
        #expect(lines.first == "r1,,z" && lines.last == "r12000,,z")
        #expect(!text.dropFirst().contains("\u{FEFF}"), "chunks carry no second byte order mark")
    }

    @Test func fileNamesAreSafeAndNeverCollide() {
        var taken: Set<String> = []
        func name(_ sheet: String, _ position: Int = 1) -> String {
            SpreadsheetEngine.fileName(stem: "book", sheet: sheet, position: position, taken: &taken)
        }
        #expect(name("Q1/Q2") == "book-Q1-Q2.csv")
        #expect(name("Q1:Q2") == "book-Q1-Q2 2.csv")
        #expect(name("q1-q2") == "book-q1-q2 3.csv", "APFS ignores case")
        #expect(name("...", 4) == "book-Sheet 4.csv")
        #expect(name("", 5) == "book-Sheet 5.csv")
        #expect(name("a\nb\tc") == "book-a-b-c.csv")
        #expect(name(String(repeating: "x", count: 100)) == "book-" + String(repeating: "x", count: 31) + ".csv")
        var longTaken: Set<String> = []
        let long = SpreadsheetEngine.fileName(stem: String(repeating: "s", count: 240), sheet: "abcdefghijklmnop", position: 1, taken: &longTaken)
        #expect(long.utf8.count <= 255)
    }

    @Test func emptyWorkbook() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let parts = XLSXFixture.parts(sheets: [.init("A", cells: ""), .init("B", cells: data(), state: "hidden")])

        do {
            _ = try await convert(xlsx: parts, in: dir)
            Issue.record("expected not applicable")
        } catch ConversionError.notApplicable(let reason) {
            #expect(reason == "The workbook is empty")
        }
    }

    @Test func failuresUseThePlansWords() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sheet = XLSXFixture.Sheet("S", cells: data())
        var tooMany = XLSXFixture.parts(sheets: [sheet])
        tooMany += (0...XLSXReader.maxEntries).map { XLSXFixture.Part("junk/\($0)", "") }
        var huge = XLSXFixture.parts(sheets: [sheet])
        huge.append(XLSXFixture.Part("big.bin", "x", declaredSize: 600_000_000))
        var traversal = XLSXFixture.parts(sheets: [sheet])
        traversal.append(XLSXFixture.Part("../evil", "x"))

        try await expectFailure(Self.tooLarge, tooMany, in: dir)
        try await expectFailure(Self.tooLarge, huge, in: dir)
        try await expectFailure(.engineFailed(engine: "spreadsheet", message: "it is not a valid Excel workbook"), traversal, in: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "evil").path))

        let locked = dir.appending(path: "locked.xlsx")
        try (Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 256)).write(to: locked)
        let staging = dir.appending(path: "locked-staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: locked, stagingDirectory: staging, from: try #require(formats.format(id: "xlsx")),
            to: try #require(formats.format(id: "csv")), options: PresetOptions())
        do {
            _ = try await SpreadsheetEngine().convert(step) { _ in }
            Issue.record("expected a failure")
        } catch {
            #expect(error as? ConversionError == .engineUnsupported(engine: "spreadsheet", reason: "It's password-protected"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func aSheetBeyondTheGridIsTooLargeAndLeavesNothingInStaging() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cells = data() + "<row r=\"1048576\">\(XLSXFixture.inline("XFD1048576", "y"))</row>"

        try await expectFailure(Self.tooLarge, XLSXFixture.parts(sheets: [.init("S", cells: cells)]), in: dir)
        let stagings = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("staging-") }
        for staging in stagings {
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: staging).path).isEmpty)
        }
    }

    @Test func csvToXlsxToCsvKeepsTheTable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let workbook = try await convert(csv: "a,b,c\n1,\"x,y\",\n,,z\n", named: "table.csv", in: dir)
        let staging = dir.appending(path: "back", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: workbook, stagingDirectory: staging, from: try #require(formats.format(id: "xlsx")),
            to: try #require(formats.format(id: "csv")), options: PresetOptions())

        let output = try await SpreadsheetEngine().convert(step) { _ in }

        #expect(String(decoding: try Data(contentsOf: output).dropFirst(3), as: UTF8.self) == "a,b,c\r\n1,\"x,y\",\r\n,,z\r\n")
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try XLSXFixture.write(XLSXFixture.parts(sheets: [.init("S", cells: data())]), to: dir.appending(path: "b.xlsx"))
        let staging = dir.appending(path: "s", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging, from: try #require(formats.format(id: "xlsx")),
            to: try #require(formats.format(id: "csv")), options: PresetOptions())
        let task = Task { try await SpreadsheetEngine().convert(step) { _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func theEvalsDateWorkbookConverts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.dateWorkbook(in: dir)
        let staging = dir.appending(path: "s", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging, from: try #require(formats.format(id: "xlsx")),
            to: try #require(formats.format(id: "csv")), options: PresetOptions())

        let output = try await SpreadsheetEngine().convert(step) { _ in }

        #expect(String(decoding: try Data(contentsOf: output).dropFirst(3), as: UTF8.self) == "Pomelo order,12.5,2026-10-30\r\n")
    }
}
