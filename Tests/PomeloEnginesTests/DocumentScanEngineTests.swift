import CoreGraphics
import CoreText
import Foundation
import ImageIO
import os
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// A `DocumentRecognizing` that answers every page with `pages[i]` (the last one repeats) and remembers the sizes of
/// the images it was handed.
private final class FakeRecognizer: DocumentRecognizing, @unchecked Sendable {
    typealias Block = RecognizedDocument.Block
    private let pages: [[Block]]
    private let failure: (any Error)?
    private let suspendAt: Int?
    private let sizes = OSAllocatedUnfairLock(initialState: [CGSize]())

    /// `suspendAt`: the call with that index never answers until its task is cancelled.
    init(_ pages: [[Block]], failure: (any Error)? = nil, suspendAt: Int? = nil) {
        self.pages = pages
        self.failure = failure
        self.suspendAt = suspendAt
    }

    var handed: [CGSize] { sizes.withLock { $0 } }

    func recognize(_ page: CGImage) async throws -> [Block] {
        let index = sizes.withLock { sizes -> Int in
            sizes.append(CGSize(width: page.width, height: page.height))
            return sizes.count - 1
        }
        if let failure { throw failure }
        if index == suspendAt { try await Task.sleep(for: .seconds(120)) }
        return pages.isEmpty ? [] : pages[min(index, pages.count - 1)]
    }
}

private struct SecretError: Error, LocalizedError {
    var errorDescription: String? { "SECRET TEXT" }
}

@Suite struct DocumentScanEngineTests {
    private typealias Block = RecognizedDocument.Block

    private static let hasMacOS26: Bool = if #available(macOS 26, *) { true } else { false }

    private func box(_ y: Double) -> UnitRect { UnitRect(x: 0, y: y, width: 0.8, height: 0.05) }

    private let page: [Block] = [
        Block(.paragraph("Receipt"), box: UnitRect(x: 0, y: 0, width: 0.8, height: 0.05)),
        Block(.list(["Bread", "Milk"]), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.05)),
        Block(.table([["Item", "Qty", "Price"], ["Bread", "2", "3.50"]]), box: UnitRect(x: 0, y: 0.3, width: 0.8, height: 0.1)),
    ]

    private func runner(_ recognizer: (any DocumentRecognizing)?) -> JobRunner {
        JobRunner(
            registry: EngineRegistry(engines: [DocumentScanEngine(recognizer: recognizer)], priority: ["documentscan"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true })
        )
    }

    /// Runs the preset on `source` and returns its result.
    private func run(
        _ presetID: String, on source: URL, format: FormatID? = nil, recognizer: any DocumentRecognizing
    ) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == presetID })
        if let format { preset.target = format }
        let results = await runner(recognizer).run(ConversionRequest.from(preset, inputs: [source]))
        return try #require(results.first)
    }

    private func succeeded(_ result: FileResult) throws -> URL {
        guard case .succeeded(_, let outputs, _) = result, outputs.count == 1 else { throw Fixtures.Failure("\(result)") }
        return outputs[0]
    }

    private func failure(_ result: FileResult) -> ConversionError? {
        if case .failed(_, let error) = result { error } else { nil }
    }

    /// A PNG named `scan.png` in `dir`.
    private func scanPNG(in dir: URL) throws -> URL {
        let source = dir.appending(path: "scan.png")
        try FileManager.default.moveItem(at: try Fixtures.png(width: 120, height: 80, in: dir), to: source)
        return source
    }

    // MARK: Edges, availability, presets

    @Test func everyImageFormatAndPDFOffersBothToolsAndNothingElseDoes() {
        let edges = DocumentScanEngine(recognizer: FakeRecognizer([])).edges()
        let sources: Set<FormatID> = ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp", "pdf"]
        func targets(_ operation: String) -> [FormatID: Set<FormatID>] {
            Dictionary(grouping: edges.filter { $0.operation == operation }, by: \.from).mapValues { Set($0.map(\.to)) }
        }
        #expect(Set(targets("scan-document").keys) == sources)
        #expect(Set(targets("extract-tables").keys) == sources)
        #expect(targets("scan-document").values.allSatisfy { $0 == ["md"] })
        #expect(targets("extract-tables").values.allSatisfy { $0 == ["xlsx", "csv"] })
        #expect(edges.count == 8 * 3 + 1 && edges.allSatisfy { $0.engineID == "documentscan" })
    }

    @Test func availabilityIsMacOS26() async {
        #expect(await DocumentScanEngine(recognizer: FakeRecognizer([])).availability() == .available(version: nil))
        #expect(await DocumentScanEngine(recognizer: nil).availability() == .unsupported(reason: "Needs macOS 26."))
        #expect(await DocumentScanEngine().availability() == (Self.hasMacOS26 ? .available(version: nil) : .unsupported(reason: "Needs macOS 26.")))
    }

    @Test func theTwoPresetsAreImageAndPDFTools() throws {
        let scan = try #require(Preset.builtIns.first { $0.id == "scan-document" })
        #expect(scan.target == "md" && scan.nameSuffix == nil && scan.operation == "scan-document")
        #expect(scan.categories == [.image, .pdf] && scan.outputNaming == .fromSource)
        let tables = try #require(Preset.builtIns.first { $0.id == "extract-tables" })
        #expect(tables.target == "xlsx" && tables.nameSuffix == "tables" && tables.operation == "extract-tables")
        #expect(tables.categories == [.image, .pdf] && tables.outputNaming == .fromSource)
    }

    @Test func withoutARecognizerTheStepIsUnsupported() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let formats = FormatRegistry.builtIn
        let step = ConversionStep(
            input: source, stagingDirectory: dir, from: try #require(formats.format(forExtension: "png")),
            to: try #require(formats.format(forExtension: "md")), options: PresetOptions(), operation: "scan-document")
        await #expect(throws: ConversionError.engineUnsupported(engine: "documentscan", reason: "Needs macOS 26.")) {
            _ = try await DocumentScanEngine(recognizer: nil).convert(step) { _ in }
        }
    }

    // MARK: Scan to Markdown

    @Test func scanToMarkdownWritesTheRenderingWithATrailingNewlineNextToTheSource() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)

        let output = try succeeded(try await run("scan-document", on: source, recognizer: FakeRecognizer([page])))

        #expect(output.lastPathComponent == "scan.md" && output.deletingLastPathComponent() == dir)
        #expect(try String(contentsOf: output, encoding: .utf8) == """
            Receipt

            - Bread
            - Milk

            | Item | Qty | Price |
            | --- | --- | --- |
            | Bread | 2 | 3.50 |

            """)
    }

    @Test func aScanWithNoTextIsNoTextFound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        for blocks in [[], [Block(.paragraph("  "), box: box(0))]] {
            let result = try await run("scan-document", on: source, recognizer: FakeRecognizer([blocks]))
            #expect(failure(result) == .notApplicable(reason: "No text found"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["scan.png"])
    }

    @Test func aRecognizerFailureNamesThePageNeverTheText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let result = try await run("scan-document", on: source, recognizer: FakeRecognizer([], failure: SecretError()))
        guard case .engineFailed(_, let message)? = failure(result) else { throw Fixtures.Failure("\(result)") }
        #expect(message == "cannot read the text on page 1 of scan.png")
        #expect(!"\(result)".contains("SECRET"))
    }

    // MARK: Pages

    @Test func aPDFIsReadPageByPageAtTwoHundredDpiAndJoinedWithARule() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appending(path: "scan.pdf")
        try FileManager.default.moveItem(at: try Fixtures.pdf(pages: 3, in: dir), to: pdf)
        let recognizer = FakeRecognizer([
            [Block(.paragraph("One"), box: box(0))], [Block(.paragraph("Two"), box: box(0))], [],
        ])
        let progress = OSAllocatedUnfairLock(initialState: [Double]())
        let engine = DocumentScanEngine(recognizer: recognizer)
        let formats = FormatRegistry.builtIn
        let step = ConversionStep(
            input: pdf, stagingDirectory: dir, from: try #require(formats.format(forExtension: "pdf")),
            to: try #require(formats.format(forExtension: "md")), options: PresetOptions(), operation: "scan-document")

        let output = try await engine.convert(step) { value in progress.withLock { $0.append(value) } }

        #expect(try String(contentsOf: output, encoding: .utf8) == "One\n\n---\n\nTwo\n")
        #expect(recognizer.handed.count == 3)
        // 612 x 792 pt at 200 dpi.
        #expect(recognizer.handed.allSatisfy { $0 == CGSize(width: 1700, height: 2200) }, "\(recognizer.handed)")
        let values = progress.withLock { $0 }
        #expect(values.first == 0 && values.last == 1 && values.count == 5, "\(values)")
        #expect(values == values.sorted())
    }

    @Test func onlyTheFirstTwentyPagesAreRead() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appending(path: "long.pdf")
        try FileManager.default.moveItem(at: try Fixtures.pdf(pages: 23, in: dir), to: pdf)
        let recognizer = FakeRecognizer([[Block(.paragraph("x"), box: box(0))]])

        _ = try succeeded(try await run("scan-document", on: pdf, recognizer: recognizer))

        #expect(recognizer.handed.count == 20)
    }

    @Test func anImageIsHandedOverUprightWhateverItsExifOrientation() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // 40 x 20 pixels stored, orientation 6 (rotate 90 clockwise): shown as 20 x 40.
        let source = dir.appending(path: "turned.jpg")
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let recognizer = FakeRecognizer([[Block(.paragraph("x"), box: box(0))]])

        _ = try succeeded(try await run("scan-document", on: source, recognizer: recognizer))

        #expect(recognizer.handed == [CGSize(width: 20, height: 40)])
    }

    // MARK: Extract tables

    private let twoTables: [[Block]] = [[
        Block(.table([["Item", "Qty"], ["Bread", "2"]]), box: UnitRect(x: 0, y: 0.1, width: 0.8, height: 0.1)),
        Block(.table([["Total", "5.30"]]), box: UnitRect(x: 0, y: 0.5, width: 0.8, height: 0.1)),
    ]]

    @Test func extractTablesToExcelIsOneSheetPerTableNamedScanTables() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)

        let output = try succeeded(try await run("extract-tables", on: source, recognizer: FakeRecognizer(twoTables)))

        #expect(output.lastPathComponent == "scan-tables.xlsx" && output.deletingLastPathComponent() == dir)
        let first = try XLSXWriterTests.part("xl/worksheets/sheet1.xml", of: output, in: dir)
        let second = try XLSXWriterTests.part("xl/worksheets/sheet2.xml", of: output, in: dir)
        #expect(first.contains(">Item</t>") && first.contains("<c r=\"B2\"><v>2</v></c>"))
        #expect(second.contains(">Total</t>") && second.contains("<c r=\"B1\"><v>5.30</v></c>"))
    }

    @Test func oneTableAsCSVIsScanTablesDotCSV() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)

        let output = try succeeded(try await run("extract-tables", on: source, format: "csv", recognizer: FakeRecognizer([[page[2]]])))

        #expect(output.lastPathComponent == "scan-tables.csv")
        #expect(try Data(contentsOf: output) == CSVWriter.write(rows: [["Item", "Qty", "Price"], ["Bread", "2", "3.50"]]))
    }

    @Test func severalTablesAsCSVAreAFolderOfScanDashNumberFiles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)

        let output = try succeeded(try await run("extract-tables", on: source, format: "csv", recognizer: FakeRecognizer(twoTables)))

        #expect(output.lastPathComponent == "scan-tables" && output.deletingLastPathComponent() == dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["scan-1.csv", "scan-2.csv"])
        #expect(try Data(contentsOf: output.appending(path: "scan-2.csv")) == CSVWriter.write(rows: [["Total", "5.30"]]))
    }

    @Test func tablesOnSeveralPagesAreNumberedInPageOrder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appending(path: "scan.pdf")
        try FileManager.default.moveItem(at: try Fixtures.pdf(pages: 2, in: dir), to: pdf)
        let recognizer = FakeRecognizer([
            [Block(.table([["page one"]]), box: box(0))], [Block(.table([["page two"]]), box: box(0))],
        ])

        let output = try succeeded(try await run("extract-tables", on: pdf, format: "csv", recognizer: recognizer))

        #expect(try String(decoding: Data(contentsOf: output.appending(path: "scan-1.csv")), as: UTF8.self).contains("page one"))
        #expect(try String(decoding: Data(contentsOf: output.appending(path: "scan-2.csv")), as: UTF8.self).contains("page two"))
    }

    @Test func textWithoutATableIsNoTableFoundAndNothingIsLeftBehind() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        for format: FormatID in ["xlsx", "csv"] {
            let result = try await run("extract-tables", on: source, format: format, recognizer: FakeRecognizer([[page[0]]]))
            #expect(failure(result) == .notApplicable(reason: "No table found"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["scan.png"])
    }

    @Test func aPageWithNoTextAtAllIsNoTextFoundForTablesToo() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let result = try await run("extract-tables", on: source, recognizer: FakeRecognizer([[]]))
        #expect(failure(result) == .notApplicable(reason: "No text found"))
    }

    @Test func aStepOfAnotherOperationOrTargetIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let formats = FormatRegistry.builtIn
        let png = try #require(formats.format(forExtension: "png"))
        let engine = DocumentScanEngine(recognizer: FakeRecognizer([[page[0]]]))
        for (operation, target) in [("scan-document", "xlsx"), ("extract-tables", "md"), ("translate", "md")] as [(String, String)] {
            let step = ConversionStep(
                input: source, stagingDirectory: dir, from: png, to: try #require(formats.format(forExtension: target)),
                options: PresetOptions(), operation: operation)
            await #expect(throws: ConversionError.self) { _ = try await engine.convert(step) { _ in } }
        }
    }

    // MARK: PDF to Word

    private func wordStep(_ pdf: URL, staging: URL) throws -> ConversionStep {
        let formats = FormatRegistry.builtIn
        return ConversionStep(
            input: pdf, stagingDirectory: staging, from: try #require(formats.format(forExtension: "pdf")),
            to: try #require(formats.format(forExtension: "docx")), options: PresetOptions(), operation: nil)
    }

    private func longPDF(pages: Int, in dir: URL) throws -> URL {
        let pdf = dir.appending(path: "long.pdf")
        try FileManager.default.moveItem(at: try Fixtures.pdf(pages: pages, in: dir), to: pdf)
        return pdf
    }

    @Test func pdfToDocxReadsEveryPage() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let pdf = try longPDF(pages: 25, in: dir)
        let recognizer = FakeRecognizer([[Block(.paragraph("x"), box: box(0))]])
        let progress = OSAllocatedUnfairLock(initialState: [Double]())

        let output = try await DocumentScanEngine(recognizer: recognizer).convert(try wordStep(pdf, staging: staging)) { value in
            progress.withLock { $0.append(value) }
        }

        #expect(recognizer.handed.count == 25)
        #expect(output.deletingLastPathComponent() == staging && output.lastPathComponent == "long.docx")
        let xml = try XLSXWriterTests.part("word/document.xml", of: output, in: dir)
        #expect(xml.components(separatedBy: "<w:pageBreakBefore/>").count - 1 == 24)
        let values = progress.withLock { $0 }
        #expect(values.first == 0 && values.last == 1 && values == values.sorted(), "\(values)")
        #expect(values.contains(24.0 / 25.0))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["long.docx"])
    }

    @Test func pdfToDocxEdgeFlags() throws {
        let edge = try #require(DocumentScanEngine(recognizer: FakeRecognizer([])).edges().first { $0.to == "docx" })
        #expect(edge.from == "pdf" && edge.engineID == "documentscan" && edge.cost == 10 && edge.operation == nil)
        #expect(edge.flags == [.directOnly, .layoutRisk])
        let planner = RoutePlanner(
            edges: DocumentScanEngine(recognizer: FakeRecognizer([])).edges() + [
                ConversionEdge(from: "docx", to: "odt", engineID: "other", cost: 1, flags: [])
            ], enginePriority: ["documentscan", "other"])
        #expect(planner.route(from: "pdf", to: "odt") == nil, "docx is never an intermediate hop")
    }

    @Test func pdfToDocxNoText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try longPDF(pages: 3, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        await #expect(throws: ConversionError.notApplicable(reason: "No text found")) {
            _ = try await DocumentScanEngine(recognizer: FakeRecognizer([[], [Block(.paragraph(" "), box: box(0))]]))
                .convert(try wordStep(pdf, staging: staging)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func pdfToDocxCancel() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try longPDF(pages: 25, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let recognizer = FakeRecognizer([[Block(.paragraph("x"), box: box(0))]], suspendAt: 2)
        let step = try wordStep(pdf, staging: staging)
        let engine = DocumentScanEngine(recognizer: recognizer)

        let task = Task { try await engine.convert(step) { _ in } }
        let deadline = ContinuousClock.now + .seconds(30)
        while recognizer.handed.count < 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(recognizer.handed.count >= 3)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(recognizer.handed.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func toolsStillStopAt20Pages() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try longPDF(pages: 25, in: dir)
        let recognizer = FakeRecognizer([[Block(.paragraph("x"), box: box(0))]])

        _ = try succeeded(try await run("scan-document", on: pdf, recognizer: recognizer))

        #expect(recognizer.handed.count == 20)
    }

    @Test func aWordStepFromAnImageIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let formats = FormatRegistry.builtIn
        let step = ConversionStep(
            input: source, stagingDirectory: dir, from: try #require(formats.format(forExtension: "png")),
            to: try #require(formats.format(forExtension: "docx")), options: PresetOptions(), operation: nil)
        await #expect(throws: ConversionError.self) {
            _ = try await DocumentScanEngine(recognizer: FakeRecognizer([[page[0]]])).convert(step) { _ in }
        }
    }

    // MARK: Vision blocks

    @Test func visionsLowerLeftBoxesBecomeTopLeftUnitRects() {
        // The probe's table: y 0.413, height 0.133 from the bottom.
        let rect = DocumentBlocks.unitRect(x: 0.086, y: 0.413, width: 0.785, height: 0.133)
        #expect(rect.x == 0.086 && rect.width == 0.785 && rect.height == 0.133)
        #expect(abs(rect.y - (1 - 0.413 - 0.133)) < 1e-12)
    }

    @Test func paragraphsInsideAListOrATableAreNotBlocksOfTheirOwn() {
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> UnitRect {
            UnitRect(x: x, y: y, width: width, height: height)
        }
        let blocks = DocumentBlocks.assemble(
            paragraphs: [
                (text: "Intro", box: rect(0.1, 0.05, 0.7, 0.04)),
                (text: "• Apples", box: rect(0.1, 0.20, 0.2, 0.02)),
                (text: "• Pears", box: rect(0.1, 0.23, 0.2, 0.02)),
                (text: "Item", box: rect(0.1, 0.50, 0.1, 0.02)),
                (text: "Qty", box: rect(0.4, 0.50, 0.1, 0.02)),
                (text: "Outro", box: rect(0.1, 0.80, 0.7, 0.04)),
            ],
            lists: [(items: ["Apples", "Pears"], box: rect(0.1, 0.20, 0.2, 0.05))],
            tables: [(cells: [
                DocumentBlocks.Cell(text: "Item", rows: 0...0, columns: 0...0),
                DocumentBlocks.Cell(text: "Qty", rows: 0...0, columns: 1...1),
            ], box: rect(0.1, 0.48, 0.5, 0.06))])
        #expect(blocks.map(\.kind) == [
            .paragraph("Intro"), .paragraph("Outro"), .list(["Apples", "Pears"]), .table([["Item", "Qty"]]),
        ])
        #expect(RecognizedDocument(pages: [blocks]).markdown() == """
            Intro

            - Apples
            - Pears

            | Item | Qty |
            | --- | --- |

            Outro
            """)
    }

    // MARK: Merged cells

    /// Vision lists a merged cell once, with the ranges it covers: "Sales" spans columns 1 and 2 of row 0, "Group"
    /// rows 1 and 2 of column 0.
    private let mergedCells: [DocumentBlocks.Cell] = [
        .init(text: "Name", rows: 0...0, columns: 0...0), .init(text: "Sales", rows: 0...0, columns: 1...2),
        .init(text: "Note", rows: 0...0, columns: 3...3),
        .init(text: "Group", rows: 1...2, columns: 0...0), .init(text: "12", rows: 1...1, columns: 1...1),
        .init(text: "7", rows: 1...1, columns: 2...2), .init(text: "x", rows: 1...1, columns: 3...3),
        .init(text: "3", rows: 2...2, columns: 1...1), .init(text: "4", rows: 2...2, columns: 2...2),
        .init(text: "y", rows: 2...2, columns: 3...3),
    ]

    private var mergedBlock: Block {
        let grid = DocumentBlocks.grid(of: mergedCells)
        return Block(.table(grid.rows), box: UnitRect(x: 0, y: 0, width: 0.8, height: 0.2), merges: grid.merges)
    }

    @Test func aMergedCellSitsAtItsTopLeftAndTheSpanItCoversIsEmpty() {
        let grid = DocumentBlocks.grid(of: mergedCells)
        #expect(grid.rows == [["Name", "Sales", "", "Note"], ["Group", "12", "7", "x"], ["", "3", "4", "y"]])
        #expect(grid.merges == [
            .init(row: 0, column: 1, rowSpan: 1, columnSpan: 2), .init(row: 1, column: 0, rowSpan: 2, columnSpan: 1),
        ])
    }

    @Test func aCellListedInEveryRowItSpansIsPlacedOnce() {
        let again = mergedCells + [.init(text: "Group", rows: 1...2, columns: 0...0)]
        let grid = DocumentBlocks.grid(of: again)
        #expect(grid.rows[1][0] == "Group" && grid.merges.count == 2)
    }

    @Test func cellsOutsideAnyReasonableGridAreIgnored() {
        let grid = DocumentBlocks.grid(of: [.init(text: "a", rows: 0...0, columns: 0...0), .init(text: "far", rows: 0...0, columns: 0...99_999), .init(text: "neg", rows: -1...0, columns: 0...0)])
        #expect(grid.rows == [["a"]] && grid.merges.isEmpty)
    }

    @Test func mergedCellsKeepEveryColumnAlignedInCSVAndMarkdown() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)
        let recognizer = FakeRecognizer([[mergedBlock]])

        let csv = try succeeded(try await run("extract-tables", on: source, format: "csv", recognizer: recognizer))
        #expect(try Data(contentsOf: csv) == CSVWriter.write(rows: [["Name", "Sales", "", "Note"], ["Group", "12", "7", "x"], ["", "3", "4", "y"]]))

        let markdown = try succeeded(try await run("scan-document", on: source, recognizer: recognizer))
        #expect(try String(contentsOf: markdown, encoding: .utf8) == """
            | Name | Sales |  | Note |
            | --- | --- | --- | --- |
            | Group | 12 | 7 | x |
            |  | 3 | 4 | y |

            """)
    }

    @Test func mergedCellsBecomeMergeCellsInTheWorksheetAndItStaysWellFormed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try scanPNG(in: dir)

        let xlsx = try succeeded(try await run("extract-tables", on: source, recognizer: FakeRecognizer([[mergedBlock]])))

        let sheet = try XLSXWriterTests.part("xl/worksheets/sheet1.xml", of: xlsx, in: dir)
        #expect(sheet.contains("<mergeCells count=\"2\"><mergeCell ref=\"B1:C1\"/><mergeCell ref=\"A2:A3\"/></mergeCells></worksheet>"))
        #expect(sheet.contains("<c r=\"D1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">Note</t></is></c>"), "Note stays in column D")
        #expect(!sheet.contains("r=\"C1\""), "the covered cell is empty")
        let file = dir.appending(path: "sheet1.xml")
        try Data(sheet.utf8).write(to: file)
        let lint = Process()
        lint.executableURL = URL(filePath: "/usr/bin/xmllint")
        lint.arguments = ["--noout", file.path]
        try lint.run()
        lint.waitUntilExit()
        #expect(lint.terminationStatus == 0, "xmllint --noout")
    }

    // MARK: Real recognition (macOS 26)

    /// A 1700 x 1100 white page with a ruled table in 40 pt Helvetica, the shape the research probe read. A cell of
    /// `rows` that is nil is covered by the cell to its left (no rule between them in that row): that is how a merged
    /// cell is drawn.
    private func tableImage(_ rows: [[String?]], in dir: URL) throws -> URL {
        let width = 1700, height = 1100
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let columns = rows.map(\.count).max() ?? 0
        let left = 150.0, top = 200.0, columnWidth = columns <= 3 ? 460.0 : 350.0, rowHeight = 120.0
        context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)
        for line in 0...rows.count {
            let y = Double(height) - top - Double(line) * rowHeight
            context.move(to: CGPoint(x: left, y: y)); context.addLine(to: CGPoint(x: left + Double(columns) * columnWidth, y: y))
        }
        for (r, row) in rows.enumerated() {
            let y = Double(height) - top - Double(r) * rowHeight
            for line in 0...columns where line == 0 || line == columns || row[line] != nil {
                let x = left + Double(line) * columnWidth
                context.move(to: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x, y: y - rowHeight))
            }
        }
        context.strokePath()
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                guard let text else { continue }
                context.textPosition = CGPoint(
                    x: left + Double(c) * columnWidth + 30, y: Double(height) - top - Double(r) * rowHeight - 75)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
        }
        let url = dir.appending(path: "scan.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(.enabled(if: DocumentScanEngineTests.hasMacOS26), .timeLimit(.minutes(2)))
    func visionReadsAGeneratedTableIntoCSVAndMarkdown() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tableImage([["Item", "Qty", "Price"], ["Bread", "2", "3.50"], ["Milk", "1", "1.80"]], in: dir)
        var csvPreset = try #require(Preset.builtIns.first { $0.id == "extract-tables" })
        csvPreset.target = "csv"
        let real = JobRunner(
            registry: EngineRegistry(engines: [DocumentScanEngine()], priority: ["documentscan"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }))

        let csv = try succeeded(try #require(await real.run(ConversionRequest.from(csvPreset, inputs: [source])).first))
        #expect(csv.lastPathComponent == "scan-tables.csv")
        let text = String(decoding: try Data(contentsOf: csv), as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "")
        #expect(text == "Item,Qty,Price\r\nBread,2,3.50\r\nMilk,1,1.80\r\n", "\(text)")

        let scan = try #require(Preset.builtIns.first { $0.id == "scan-document" })
        let markdown = try succeeded(try #require(await real.run(ConversionRequest.from(scan, inputs: [source])).first))
        #expect(try String(contentsOf: markdown, encoding: .utf8)
            == "| Item | Qty | Price |\n| --- | --- | --- |\n| Bread | 2 | 3.50 |\n| Milk | 1 | 1.80 |\n")
    }

    @Test(.enabled(if: DocumentScanEngineTests.hasMacOS26), .timeLimit(.minutes(2)))
    func visionReadsAHeaderMergedOverTwoColumnsWithEveryColumnInPlace() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tableImage([["Name", "Sales", nil, "Note"], ["Bob", "12", "75", "soon"], ["Ann", "30", "41", "late"]], in: dir)
        var csvPreset = try #require(Preset.builtIns.first { $0.id == "extract-tables" })
        csvPreset.target = "csv"
        let real = JobRunner(
            registry: EngineRegistry(engines: [DocumentScanEngine()], priority: ["documentscan"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }))

        let csv = try succeeded(try #require(await real.run(ConversionRequest.from(csvPreset, inputs: [source])).first))

        let text = String(decoding: try Data(contentsOf: csv), as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "")
        #expect(text == "Name,Sales,,Note\r\nBob,12,75,soon\r\nAnn,30,41,late\r\n", "\(text)")
    }
}
