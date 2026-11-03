import CoreGraphics
import Foundation
import PomeloCore
import Vision

/// Where the page in an upright picture is, its corners in that picture's pixels (y down), and how sure the finder
/// is; nil when there is none. A seam, so tests give Straighten document fixed quads (P262).
public protocol DocumentSegmenting: Sendable {
    func page(in image: CGImage) async throws -> (quad: PageQuad, confidence: Double)?
}

/// Vision's `VNDetectDocumentSegmentationRequest`, its most confident quad. Only the corners leave it; nothing is
/// logged.
public struct SystemDocumentSegmenter: DocumentSegmenting {
    public init() {}

    public func page(in image: CGImage) async throws -> (quad: PageQuad, confidence: Double)? {
        try Task.checkCancellation()
        let (width, height) = (Double(image.width), Double(image.height))
        let page = try await VisionEngine.offThePool { _ -> (quad: PageQuad, confidence: Double)? in
            let handler = VNImageRequestHandler(cgImage: try AnalysisBitmap.redrawn(image, onWhite: true), orientation: .up, options: [:])
            let request = VNDetectDocumentSegmentationRequest()
            try handler.perform([request])
            guard let found = request.results?.max(by: { $0.confidence < $1.confidence }) else { return nil }
            // Vision's points are fractions of the picture with the origin at the bottom left.
            func pixels(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * width, y: (1 - point.y) * height) }
            let quad = PageQuad(
                topLeft: pixels(found.topLeft), topRight: pixels(found.topRight),
                bottomRight: pixels(found.bottomRight), bottomLeft: pixels(found.bottomLeft)
            )
            return (quad, Double(found.confidence))
        }
        try Task.checkCancellation()
        return page
    }
}
