import CoreGraphics
import Foundation
import ImageIO
import PomeloCore
import PDFKit

/// Converts PDF pages to images and text, and images to PDF, and compresses (also to a target size), splits,
/// merges and reorganizes PDFs, with the system's PDFKit and ImageIO.
public struct PDFKitEngine: CombiningEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private static let edgeCost = 10
    private static let imageSources: [FormatID] = ["png", "jpg", "heic", "tiff"]
    private static let combinableImages: [FormatID] = imageSources + ["avif", "gif", "bmp"]

    public init() {}

    public var id: EngineID { "pdfkit" }
    public var displayName: String { "PDFKit" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        // A multi-page PDF becomes a folder, and a folder can never be the input of a later hop, so the
        // image edges are direct-only. Extracted text is direct-only too: chaining it on (PDF to text to DOCX)
        // would offer documents that keep none of the PDF's layout. Image to PDF is direct-only so that no chain
        // leads through a PDF wrapped around a single image.
        var edges = [
            ConversionEdge(from: "pdf", to: "png", engineID: id, cost: Self.edgeCost, flags: [.directOnly]),
            ConversionEdge(from: "pdf", to: "jpg", engineID: id, cost: Self.edgeCost, flags: [.lossy, .directOnly]),
            ConversionEdge(from: "pdf", to: "txt", engineID: id, cost: Self.edgeCost, flags: [.directOnly]),
        ]
        for source in Self.imageSources {
            edges.append(ConversionEdge(from: source, to: "pdf", engineID: id, cost: Self.edgeCost, flags: [.directOnly]))
        }
        for operation in ["compress", "split", "combine", "organize"] {
            edges.append(ConversionEdge(
                from: "pdf", to: "pdf", engineID: id, cost: Self.edgeCost, flags: [], operation: operation
            ))
        }
        edges.append(ConversionEdge(
            from: "pdf", to: "pdf", engineID: id, cost: Self.edgeCost, flags: [.lossy], operation: "target-size"
        ))
        for source in Self.combinableImages {
            edges.append(ConversionEdge(
                from: source, to: "pdf", engineID: id, cost: Self.edgeCost, flags: [], operation: "combine"
            ))
        }
        return edges
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let output: URL
        switch (step.operation, step.from.id, step.to.id) {
        case (nil, "pdf", "txt"):
            output = try extractText(step)
        case (nil, "pdf", "png"), (nil, "pdf", "jpg"):
            output = try await renderPages(step, progress: progress)
        case (nil, _, "pdf"):
            output = try makePDF(step)
        case ("compress", "pdf", "pdf"):
            output = try compress(step)
        case ("split", "pdf", "pdf"):
            output = try split(step, progress: progress)
        case ("target-size", "pdf", "pdf"):
            output = try compressToSize(step, progress: progress)
        case ("organize", "pdf", "pdf"):
            output = try organize(step, progress: progress)
        default:
            throw Failure("\(step.from.displayName) to \(step.to.displayName) is not something PDFKit can do")
        }
        progress(1)
        return output
    }

    public func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard step.operation == "combine", step.to.id == "pdf", !step.inputs.isEmpty else {
            throw Failure("PDFKit cannot combine files into \(step.to.displayName)")
        }
        let output: URL
        if step.formats.allSatisfy({ $0.id == "pdf" }) {
            output = try mergePDFs(step, progress: progress)
        } else if step.formats.allSatisfy({ $0.id != "pdf" }) {
            output = try combineImages(step, progress: progress)
        } else {
            throw Failure("PDFKit cannot combine PDFs and images into one PDF")
        }
        progress(1)
        return output
    }

    // MARK: PDF tools

    func compress(_ step: ConversionStep) throws -> URL {
        let document = try openDocument(step.input)
        // PDFKit writes an unmodified document byte for byte and ignores the image options; adding and removing a
        // page marks it modified, so the images are re-encoded.
        if let page = document.page(at: 0)?.copy() as? PDFPage {
            document.insert(page, at: document.pageCount)
            document.removePage(at: document.pageCount - 1)
        }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        let options: [PDFDocumentWriteOption: Any] = [.optimizeImagesForScreenOption: true, .saveImagesAsJPEGOption: true]
        guard document.write(to: output, withOptions: options) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent)")
        }
        return output
    }

    private func split(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let document = try openDocument(step.input)
        let pageCount = document.pageCount
        guard pageCount > 1 else { throw ConversionError.notApplicable(reason: "It has only one page") }
        let folder = step.suggestedFolder
        let stem = OutputNamer.stem(of: step.input)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<pageCount {
                try Task.checkCancellation()
                progress(Double(index) / Double(pageCount))
                guard let page = document.page(at: index)?.copy() as? PDFPage else {
                    throw Failure("cannot read page \(index + 1) of \(step.input.lastPathComponent)")
                }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let destination = folder.appending(path: "\(stem)-\(index + 1).pdf", directoryHint: .notDirectory)
                guard single.write(to: destination) else { throw Failure("cannot write \(destination.lastPathComponent)") }
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private func mergePDFs(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let merged = PDFDocument()
        for (position, input) in step.inputs.enumerated() {
            try Task.checkCancellation()
            try CombineInputError.blaming(input) {
                let document = try openDocument(input)
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index)?.copy() as? PDFPage else {
                        throw Failure("cannot read page \(index + 1) of \(input.lastPathComponent)")
                    }
                    merged.insert(page, at: merged.pageCount)
                }
            }
            progress(Double(position + 1) / Double(step.inputs.count + 1))
        }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        guard merged.write(to: output) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent)")
        }
        return output
    }

    private func combineImages(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let output = step.suggestedOutput
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw Failure("cannot create a PDF file at \(output.lastPathComponent)")
        }
        do {
            for (position, input) in step.inputs.enumerated() {
                try Task.checkCancellation()
                try CombineInputError.blaming(input) { Self.appendPage(try loadImage(input), to: context) }
                progress(Double(position + 1) / Double(step.inputs.count + 1))
            }
            try Task.checkCancellation()
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.closePDF()
        guard FileManager.default.fileExists(atPath: output.path) else { throw Failure("cannot write \(output.lastPathComponent)") }
        return output
    }

    // MARK: PDF to text

    private func extractText(_ step: ConversionStep) throws -> URL {
        let document = try openDocument(step.input)
        let output = step.suggestedOutput
        do {
            try (document.string ?? "").write(to: output, atomically: false, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
        }
        return output
    }

    // MARK: PDF to images

    func renderPages(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let destinationType = step.to.utTypeIdentifier else {
            throw Failure("\(step.to.displayName) has no system type, so ImageIO cannot write it")
        }
        let document = try openDocument(step.input)
        let pageCount = document.pageCount
        let ext = step.to.extensions[0]
        let stem = OutputNamer.stem(of: step.input)

        let folder: URL?
        if pageCount > 1 {
            let directory = step.stagingDirectory.appending(path: stem, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw Failure("cannot create the folder \(stem): \(error.localizedDescription)")
            }
            folder = directory
        } else {
            folder = nil
        }

        do {
            for index in 0..<pageCount {
                try Task.checkCancellation()
                progress(Double(index) / Double(pageCount))
                guard let page = document.page(at: index) else {
                    throw Failure("cannot read page \(index + 1) of \(step.input.lastPathComponent)")
                }
                let image = try PDFPageRenderer.render(page, dpi: step.options.pdfRenderDPI)
                let destinationURL = folder?.appending(path: "\(stem)-\(index + 1).\(ext)", directoryHint: .notDirectory)
                    ?? step.suggestedOutput
                try write(image, as: destinationType, quality: step.options.quality, to: destinationURL, format: step.to)
            }
            try Task.checkCancellation()
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            else { try? FileManager.default.removeItem(at: step.suggestedOutput) }
            throw error
        }
        return folder ?? step.suggestedOutput
    }

    private func write(_ image: CGImage, as type: String, quality: Double, to url: URL, format: FileFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw Failure("cannot create a \(format.displayName) file at \(url.lastPathComponent)")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure("cannot write \(url.lastPathComponent) as \(format.displayName)")
        }
    }

    // MARK: Image to PDF

    private func makePDF(_ step: ConversionStep) throws -> URL {
        let image = try loadImage(step.input)
        let output = step.suggestedOutput
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw Failure("cannot create a PDF file at \(output.lastPathComponent)")
        }
        Self.appendPage(image, to: context)
        context.closePDF()
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw Failure("cannot write \(output.lastPathComponent)")
        }
        return output
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure("cannot open \(url.lastPathComponent) as an image")
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw Failure("\(url.lastPathComponent) contains no image")
        }
        return try decode(source, input: url)
    }

    /// One PDF point per image pixel, whatever DPI the image declares.
    private static func appendPage(_ image: CGImage, to context: CGContext) {
        var mediaBox = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let box = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
    }

    /// The first image of `source` with its EXIF orientation applied to the pixels, so the page is upright.
    private func decode(_ source: CGImageSource, input: URL) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation != 1, max(width, height) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ]
            if let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return upright }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("cannot decode \(input.lastPathComponent)")
        }
        return image
    }

    // MARK: Shared

    func openDocument(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw Failure("cannot open \(url.lastPathComponent) as a PDF")
        }
        guard !document.isLocked else {
            throw Failure("\(url.lastPathComponent) is password protected")
        }
        guard document.pageCount > 0 else {
            throw Failure("\(url.lastPathComponent) has no pages")
        }
        return document
    }
}
