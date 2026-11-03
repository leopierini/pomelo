import Foundation
import PDFKit
import PomeloCore
import Vision

/// The text of a document, for the language model (P161): a PDF's text layer, else Vision's OCR of its first 20
/// pages drawn at 200 dpi (P160); an image's OCR; an office or web document through the attributed-string readers;
/// plain text and Markdown with the subtitle engine's decoding fallbacks. Never logs the text, and no error carries it.
enum DocumentText {
    static let maxOCRPages = 20
    static let pageDPI = 200
    static let noText = "No text found"

    /// The text, trimmed; none at all is "No text found". `progress` runs 0 to 1 over the pages a PDF has read by OCR.
    static func read(
        _ url: URL, as format: FileFormat, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        let text: String
        switch format.id {
        case "pdf":
            text = try await VisionEngine.offThePool { isCancelled in
                try pdfText(url, progress: progress, isCancelled: isCancelled)
            }
        case "png", "jpg", "heic", "tiff":
            text = try await VisionEngine.offThePool { _ in
                try VisionEngine.recognizeTextSynchronously(
                    with: VNImageRequestHandler(url: url, options: [:]), name: url.lastPathComponent)
            }
        case "txt", "md":
            do {
                text = try SubtitleEngine.read(url)
            } catch {
                throw ConversionError.engineFailed(engine: "intelligence", message: "cannot read \(url.lastPathComponent)")
            }
        default:
            text = try await AttributedTextEngine.plainText(of: url, as: format)
        }
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversionError.notApplicable(reason: noText) }
        return trimmed
    }

    /// Page by page: the text layer where a page has one, OCR for a page without one among the first 20.
    private static func pdfText(
        _ url: URL, progress: @Sendable (Double) -> Void, isCancelled: @Sendable () -> Bool
    ) throws -> String {
        let document = try PDFKitEngine().openDocument(url)
        let ocrPages = min(document.pageCount, maxOCRPages)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if isCancelled() { throw CancellationError() }
            guard let page = document.page(at: index) else { continue }
            let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !layer.isEmpty {
                pages.append(layer)
            } else if index < ocrPages {
                let image = try PDFPageRenderer.render(page, dpi: pageDPI)
                pages.append(try VisionEngine.recognizeTextSynchronously(
                    with: VNImageRequestHandler(cgImage: image, options: [:]), name: "page \(index + 1) of \(url.lastPathComponent)"))
            }
            if index < ocrPages { progress(Double(index + 1) / Double(ocrPages)) }
        }
        return pages.joined(separator: "\n\n")
    }
}
