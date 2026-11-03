import CoreGraphics
import Foundation
import ImageIO
import PomeloCore
import QuickLookThumbnailing

/// SVG to PNG through Quick Look. It renders in the system's own sandboxed extension, so an untrusted SVG's scripts
/// and remote references never run inside Pomelo; ImageIO can't read SVG and WebKit would need a web process.
public struct SVGEngine: ConversionEngine {
    private static let edgeCost = 10
    private static let defaultSide = 2048

    public init() {}

    public var id: EngineID { "quicklook" }
    public var displayName: String { "Quick Look" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        [ConversionEdge(from: "svg", to: "png", engineID: id, cost: Self.edgeCost, flags: [])]
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let side = CGFloat(max(1, step.options.maxPixelSize ?? Self.defaultSide))
        // The request is only handed to the generator, which is thread-safe, and to its cancel(_:).
        nonisolated(unsafe) let request = QLThumbnailGenerator.Request(
            fileAt: step.input, size: CGSize(width: side, height: side), scale: 1, representationTypes: .thumbnail
        )
        let representation: QLThumbnailRepresentation
        do {
            representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
        } catch {
            try Task.checkCancellation()
            throw ConversionError.engineFailed(engine: id, message: "Quick Look can't draw this file")
        }
        // An icon is Quick Look's fallback for a file it can't draw, not a picture of the file.
        guard representation.type != .icon else {
            throw ConversionError.engineFailed(engine: id, message: "Quick Look can't draw this file")
        }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        try writePNG(representation.cgImage, to: output)
        progress(1)
        return output
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.engineFailed(engine: id, message: "cannot write the PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.engineFailed(engine: id, message: "cannot write the PNG")
        }
    }
}
