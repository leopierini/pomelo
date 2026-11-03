import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PomeloCore

/// Reads one upright page image and returns what it holds, in the page's top-left unit space. The real one is
/// Vision's `RecognizeDocumentsRequest` (`SystemDocumentRecognizer`); tests inject a fake so the writers and the
/// naming run on any Mac. Never logs the text.
public protocol DocumentRecognizing: Sendable {
    func recognize(_ page: CGImage) async throws -> [RecognizedDocument.Block]
}

/// Reads photos and PDFs into Markdown (scan-document) and into Excel or CSV tables (extract-tables), on the device
/// (P160). A PDF's first 20 pages are read, drawn at 200 dpi. PDF to Word reads every page (P196).
public struct DocumentScanEngine: ConversionEngine {
    static let scanDocument = "scan-document"
    static let extractTables = "extract-tables"
    static let needsMacOS26 = "Needs macOS 26."
    static let sources: [FormatID] = ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp", "pdf"]
    static let maxPages = 20
    static let pageDPI = 200
    static let word: FormatID = "docx"
    private static let edgeCost = 10

    private let recognizer: (any DocumentRecognizing)?

    /// Vision's recognizer where there is one (macOS 26), else an engine that reports itself unsupported.
    public init() {
        self.init(recognizer: Self.systemRecognizer())
    }

    /// `recognizer` nil is a Mac without `RecognizeDocumentsRequest`.
    public init(recognizer: (any DocumentRecognizing)?) {
        self.recognizer = recognizer
    }

    private static func systemRecognizer() -> (any DocumentRecognizing)? {
        if #available(macOS 26, *) { SystemDocumentRecognizer() } else { nil }
    }

    public var id: EngineID { "documentscan" }
    public var displayName: String { "Document scan" }
    public var maxConcurrentJobs: Int { 1 }

    public func availability() async -> EngineAvailability {
        recognizer == nil ? .unsupported(reason: Self.needsMacOS26) : .available(version: nil)
    }

    public func edges() -> [ConversionEdge] {
        let targets: [(operation: String, format: FormatID)] = [(Self.scanDocument, "md"), (Self.extractTables, "xlsx"), (Self.extractTables, "csv")]
        let tools = Self.sources.flatMap { source in
            targets.map {
                ConversionEdge(
                    from: source, to: $0.format, engineID: id, cost: Self.edgeCost, flags: [.lossy], operation: $0.operation)
            }
        }
        // Not lossy (the hub warns about layout instead), and direct only: never a hop of another route.
        let word = ConversionEdge(from: "pdf", to: Self.word, engineID: id, cost: Self.edgeCost, flags: [.directOnly, .layoutRisk])
        return tools + [word]
    }

    // MARK: Convert

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let allowed: [String: Set<FormatID>] = [Self.scanDocument: ["md"], Self.extractTables: ["xlsx", "csv"]]
        let toWord = step.operation == nil && step.from.id == "pdf" && step.to.id == Self.word
        guard toWord || (step.operation.flatMap { allowed[$0] }?.contains(step.to.id) == true && Self.sources.contains(step.from.id))
        else {
            throw ConversionError.engineFailed(
                engine: id, message: "can't \(step.operation ?? "convert") \(step.from.displayName) into \(step.to.displayName)")
        }
        guard let recognizer else { throw ConversionError.engineUnsupported(engine: id, reason: Self.needsMacOS26) }
        progress(0)
        let document = try await read(
            step.input, as: step.from.id, with: recognizer, pageLimit: toWord ? nil : Self.maxPages, progress: progress)
        try Task.checkCancellation()
        guard document.hasText else { throw ConversionError.notApplicable(reason: "No text found") }

        let output: URL
        if toWord {
            output = try await writeWord(document, for: step)
        } else if step.operation == Self.scanDocument {
            output = try writeMarkdown(document, for: step)
        } else {
            let tables = document.tables()
            guard !tables.isEmpty else { throw ConversionError.notApplicable(reason: "No table found") }
            output = try await writeTables(tables, for: step)
        }
        try Task.checkCancellation()
        progress(1)
        return output
    }

    // MARK: Reading

    /// Recognizes the pages one at a time (the first `pageLimit` of them, all without one); a page is drawn only
    /// when its turn comes, so a long PDF never holds more than one bitmap. The first request after boot loads the
    /// model for about 25 s, so the progress moves per page and no timeout applies.
    private func read(
        _ input: URL, as format: FormatID, with recognizer: any DocumentRecognizing, pageLimit: Int?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RecognizedDocument {
        let count: Int
        let image: (Int) throws -> CGImage
        if format == "pdf" {
            let pdf: PDFDocument
            do {
                pdf = try PDFKitEngine().openDocument(input)
            } catch {
                throw ConversionError.engineFailed(engine: id, message: "\(error)")
            }
            count = min(pdf.pageCount, pageLimit ?? .max)
            image = { index in
                guard let page = pdf.page(at: index) else { throw PDFKitEngine.Failure("cannot read page \(index + 1)") }
                return try PDFPageRenderer.render(page, dpi: Self.pageDPI)
            }
        } else {
            count = 1
            image = { _ in
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
                    throw PDFKitEngine.Failure("cannot open \(input.lastPathComponent) as an image")
                }
                return try OrientedImage.decodeUpright(source)
            }
        }
        var pages: [[RecognizedDocument.Block]] = []
        for index in 0..<count {
            try Task.checkCancellation()
            progress(Double(index) / Double(count))
            do {
                pages.append(try await recognizer.recognize(try image(index)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ConversionError {
                throw error
            } catch {
                // The cause can carry text, so only the page is named.
                throw ConversionError.engineFailed(
                    engine: id, message: "cannot read the text on page \(index + 1) of \(input.lastPathComponent)")
            }
        }
        return RecognizedDocument(pages: pages)
    }

    // MARK: Writing

    private func writeMarkdown(_ document: RecognizedDocument, for step: ConversionStep) throws -> URL {
        let url = step.suggestedOutput
        do {
            try Data((document.markdown() + "\n").utf8).write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.engineFailed(engine: id, message: "cannot write \(url.lastPathComponent)")
        }
        return url
    }

    private func writeWord(_ document: RecognizedDocument, for step: ConversionStep) async throws -> URL {
        let url = step.suggestedOutput
        do {
            try await DOCXWriter.write(document, to: url)
        } catch let error as DOCXWriter.Failure {
            throw ConversionError.engineFailed(engine: id, message: error.description)
        }
        return url
    }

    /// An xlsx holds every table as a sheet. A csv holds one table as `<stem>.csv`, several as a folder of
    /// `<stem>-1.csv`..., published as `<stem>-tables` the way split's folder is (R-pre-4).
    private func writeTables(_ tables: [RecognizedDocument.Table], for step: ConversionStep) async throws -> URL {
        if step.to.id == "xlsx" {
            let url = step.suggestedOutput
            do {
                try await XLSXWriter.write(sheets: tables.map(\.rows), merges: tables.map(\.merges), to: url)
            } catch let error as XLSXWriter.Failure {
                throw ConversionError.engineFailed(engine: id, message: error.description)
            }
            return url
        }
        if tables.count == 1 {
            let url = step.suggestedOutput
            do {
                try CSVWriter.write(rows: tables[0].rows).write(to: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw ConversionError.engineFailed(engine: id, message: "cannot write \(url.lastPathComponent)")
            }
            return url
        }
        let folder = step.suggestedFolder
        let stem = OutputNamer.stem(of: step.input)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, table) in tables.enumerated() {
                try CSVWriter.write(rows: table.rows).write(to: folder.appending(path: "\(stem)-\(index + 1).csv", directoryHint: .notDirectory))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ConversionError.engineFailed(engine: id, message: "cannot write the tables of \(step.input.lastPathComponent)")
        }
        return folder
    }
}
