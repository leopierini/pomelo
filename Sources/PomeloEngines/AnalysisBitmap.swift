import CoreGraphics
import Foundation

/// What Vision's page and subject finders look at: the picture redrawn in 8-bit sRGB with its long side at most
/// `side`, whatever its size or pixel format.
enum AnalysisBitmap {
    /// Vision finds a page or a subject at a lower resolution than this anyway, and a 48 MP photo has no more of
    /// either.
    static let side = 1024

    /// A picture already within `side` is returned as it is when `onWhite` is false. `onWhite` redraws every picture
    /// opaque on white, so a transparent page isn't read as black on black.
    static func redrawn(_ image: CGImage, onWhite: Bool) throws -> CGImage {
        let longSide = max(image.width, image.height)
        if !onWhite && longSide <= side { return image }
        let scale = min(1, Double(side) / Double(longSide))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let alpha: CGImageAlphaInfo = onWhite ? .noneSkipLast : .premultipliedLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: alpha.rawValue
        ) else { throw VisionEngine.Failure("cannot make a \(width)x\(height) bitmap to look at the picture in") }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        if onWhite {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(frame)
        }
        context.interpolationQuality = .high
        context.draw(image, in: frame)
        guard let drawn = context.makeImage() else { throw VisionEngine.Failure("cannot redraw the picture") }
        return drawn
    }
}
