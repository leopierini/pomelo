import CoreGraphics
import CoreVideo
import Foundation
import PomeloCore
import Vision

/// Where the subject of an upright picture is, in its top-left unit space; nil when there is none. A seam, so tests
/// give Smart crop fixed boxes (P261).
public protocol SubjectFinding: Sendable {
    func subject(in image: CGImage) async throws -> UnitRect?
}

/// Vision's answer (P261): nil for a featureless picture, else the union of the faces and of the three most confident
/// salient objects, else the box of the attention heat map above half its peak. Only the box leaves it; nothing is
/// logged.
public struct SystemSubjectFinder: SubjectFinding {
    private static let objectCount = 3
    /// Under this `detail`, a picture has no subject (manual check 5): Vision's attention map of one colour, a ramp
    /// or a blank page is its centre prior, which boxed the middle. Measured: such pictures 0.006 at most (a page
    /// with grain included), the faintest real subject tried, a 6 % grey disc, 0.075; 0.02 sits between them.
    static let featurelessDetail = 0.02
    private static let detailSide = 32

    public init() {}

    public func subject(in image: CGImage) async throws -> UnitRect? {
        try Task.checkCancellation()
        let box = try await VisionEngine.offThePool { isCancelled in
            try Self.findSynchronously(in: try AnalysisBitmap.redrawn(image, onWhite: false), isCancelled: isCancelled)
        }
        try Task.checkCancellation()
        return box
    }

    private static func findSynchronously(in image: CGImage, isCancelled: @Sendable () -> Bool) throws -> UnitRect? {
        guard detail(of: image) >= featurelessDetail else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        if isCancelled() { throw CancellationError() }
        try handler.perform([faces, objects])
        let salient = (objects.results?.first?.salientObjects ?? [])
            .sorted { $0.confidence > $1.confidence }.prefix(objectCount).map(\.boundingBox)
        let boxes = (faces.results ?? []).map(\.boundingBox) + salient
        if let first = boxes.first {
            return topLeft(boxes.dropFirst().reduce(first) { $0.union($1) })
        }

        if isCancelled() { throw CancellationError() }
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        try handler.perform([attention])
        return attention.results?.first.flatMap { heatMapBox($0.pixelBuffer) }
    }

    /// Vision's normalized box (origin bottom left) as a top-left `UnitRect`.
    private static func topLeft(_ box: CGRect) -> UnitRect {
        UnitRect(x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width), height: Double(box.height))
            .clamped()
    }

    /// The largest change of slope between neighbouring cells, in any of red, green and blue, of the picture shrunk to
    /// `detailSide` px on its long side: 0 for one colour and near 0 for a linear ramp, while any edge is a jump. The
    /// shrinking averages grain away. Transparent pixels count as black.
    static func detail(of image: CGImage) -> Double {
        let scale = Double(detailSide) / Double(max(image.width, image.height, 1))
        let width = max(3, Int((Double(image.width) * scale).rounded()))
        let height = max(3, Int((Double(image.height) * scale).rounded()))
        let floats = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: 0, space: space,
            bitmapInfo: floats
        ), let data = context.data else { return .infinity }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = context.bytesPerRow / MemoryLayout<Float>.size
        let cells = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: row * height)
        var most: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                for at in (y * row + 4 * x)..<(y * row + 4 * x + 3) {
                    let slopeChange = 4 * cells[at] - cells[at - 4] - cells[at + 4] - cells[at - row] - cells[at + row]
                    most = max(most, abs(slopeChange))
                }
            }
        }
        return Double(most)
    }

    /// The cells of the attention map at half its peak or more, as a top-left `UnitRect`; nil for a map with no heat.
    /// The map is one 32-bit float per cell, its first row the top of the picture.
    static func heatMapBox(_ map: CVPixelBuffer) -> UnitRect? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let (width, height) = (CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map))
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        func row(_ index: Int) -> UnsafePointer<Float> {
            UnsafePointer((base + index * rowBytes).assumingMemoryBound(to: Float.self))
        }
        var peak: Float = 0
        for y in 0..<height {
            for x in 0..<width { peak = max(peak, row(y)[x]) }
        }
        guard peak > 0 else { return nil }
        var (left, top, right, bottom) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where row(y)[x] >= peak / 2 {
                (left, top, right, bottom) = (min(left, x), min(top, y), max(right, x), max(bottom, y))
            }
        }
        return UnitRect(
            x: Double(left) / Double(width), y: Double(top) / Double(height),
            width: Double(right + 1 - left) / Double(width), height: Double(bottom + 1 - top) / Double(height)
        )
    }
}
