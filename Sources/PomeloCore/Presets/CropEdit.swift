import CoreGraphics
import Foundation

/// The rules for a crop rectangle, shared by the engines and the Crop editor (as `TimeEdit` is for trims, P76). The
/// rectangle is in the displayed orientation, so these sizes are the upright picture's.
public enum CropEdit {
    /// The smallest side the editor lets a crop have, and the smallest a cropped video renders.
    public static let minimumSide = 16

    public static let wholeImageReason = "Nothing to crop"
    public static let tooSmallReason = "The area is too small"

    /// Whether `rect` keeps the whole picture, within one pixel.
    public static func keepsEverything(_ rect: UnitRect, width: Int, height: Int) -> Bool {
        let kept = rect.pixels(width: width, height: height)
        return kept.width >= CGFloat(width - 1) && kept.height >= CGFloat(height - 1)
    }

    /// The pixels an image crop keeps, rounded outwards as `UnitRect.pixels` rounds them.
    public static func imagePixels(_ edit: EditSpec?, width: Int, height: Int) throws -> CGRect {
        try cropRect(edit, width: width, height: height).pixels(width: width, height: height)
    }

    /// The part of a video picture a crop keeps: the origin as `UnitRect.pixels` rounds it, the size rounded down to
    /// even numbers (encoders want them) and at least `minimumSide`, moved back inside the picture if that grew it.
    public static func videoPixels(_ edit: EditSpec?, width: Int, height: Int) throws -> CGRect {
        let rect = try cropRect(edit, width: width, height: height).clamped()
        let origin = rect.pixels(width: width, height: height).origin
        func side(_ fraction: Double, of length: Int) -> Int {
            // The snap keeps 0.5 × 640 at 320 when the fraction came back from pixels as 0.49999999.
            let even = Int(fraction * Double(length) + 1e-6) / 2 * 2
            return min(max(even, minimumSide), max(2, length / 2 * 2))
        }
        let keptWidth = side(rect.width, of: width)
        let keptHeight = side(rect.height, of: height)
        let x = max(0, min(Int(origin.x), width - keptWidth))
        let y = max(0, min(Int(origin.y), height - keptHeight))
        return CGRect(x: x, y: y, width: keptWidth, height: keptHeight)
    }

    /// The edit's rectangle, refused when it keeps everything or less than a pixel.
    private static func cropRect(_ edit: EditSpec?, width: Int, height: Int) throws -> UnitRect {
        guard case .crop(let rect) = edit, !keepsEverything(rect, width: width, height: height) else {
            throw ConversionError.notApplicable(reason: wholeImageReason)
        }
        let kept = rect.pixels(width: width, height: height)
        guard kept.width >= 1, kept.height >= 1 else { throw ConversionError.notApplicable(reason: tooSmallReason) }
        return rect
    }
}
