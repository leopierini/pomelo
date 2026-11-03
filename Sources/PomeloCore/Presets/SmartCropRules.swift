import CoreGraphics
import Foundation

/// The geometry that turns a subject box into Smart crop's rectangle (P261). The engine finds the box; the rules are
/// here so they are tested without Vision.
public enum SmartCropRules {
    /// Added to the subject on each side, as a fraction of the subject's own width and height.
    public static let margin = 0.06
    /// A result this much of the picture on both sides is "Nothing to crop".
    public static let keepsEverythingFraction = 0.98
    /// A result that keeps this much of the picture's area is "Nothing to crop" too (P271). Vision's box is a few
    /// percent off, so a crop that removes little gains less than it risks cutting into the subject, and running
    /// Smart crop on its own result shaved it a little more each time. With a shape chosen it applies only to a
    /// picture that already has that shape: reshaping a big subject still crops.
    public static let keepsMostArea = 0.70
    /// How near a picture's long over short side must be to a shape's, as a fraction, to already have that shape.
    private static let sameShapeTolerance = 0.02
    public static let noSubjectReason = "No subject found"

    /// The long side over the short side of a Shape option, or nil for "fit the subject" and unknown values.
    public static func longOverShort(of shape: String?) -> Double? {
        switch shape {
        case "1:1": 1
        case "4:5": 1.25
        case "4:3": 4.0 / 3
        case "16:9": 16.0 / 9
        default: nil
        }
    }

    /// The crop for a subject, top-left origin like the Crop editor stores it, or nil when it keeps the whole picture.
    public static func rect(subject: UnitRect, shape: String?, imageWidth: Int, imageHeight: Int) -> UnitRect? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let unit = subject.clamped()
        // `clamped()` collapses a non-finite or fully outside box to zero size; there is nothing to centre a crop on.
        guard unit.width > 0, unit.height > 0 else { return nil }

        let left = max(0, (unit.x - unit.width * margin) * width)
        let top = max(0, (unit.y - unit.height * margin) * height)
        let right = min(width, (unit.x + unit.width * (1 + margin)) * width)
        let bottom = min(height, (unit.y + unit.height * (1 + margin)) * height)
        let centreX = (left + right) / 2
        let centreY = (top + bottom) / 2
        var cropWidth = right - left
        var cropHeight = bottom - top

        let minimum = Double(CropEdit.minimumSide)
        if let longOverShort = longOverShort(of: shape) {
            // Landscape when the subject is wider than tall, else portrait.
            let ratio = cropWidth > cropHeight ? longOverShort : 1 / longOverShort
            if cropWidth / max(cropHeight, .leastNonzeroMagnitude) < ratio {
                cropWidth = cropHeight * ratio
            } else {
                cropHeight = cropWidth / ratio
            }
            if min(cropWidth, cropHeight) < minimum {
                let scale = minimum / min(cropWidth, cropHeight)
                cropWidth *= scale
                cropHeight *= scale
            }
            if cropWidth > width || cropHeight > height {
                // No rectangle of this ratio holds the subject: take the largest that fits, over its centre.
                if width / height >= ratio {
                    cropHeight = height
                    cropWidth = height * ratio
                } else {
                    cropWidth = width
                    cropHeight = width / ratio
                }
            }
        } else {
            cropWidth = min(max(cropWidth, minimum), width)
            cropHeight = min(max(cropHeight, minimum), height)
        }

        let x = min(max(centreX - cropWidth / 2, 0), width - cropWidth)
        let y = min(max(centreY - cropHeight / 2, 0), height - cropHeight)
        let result = UnitRect(x: x / width, y: y / height, width: cropWidth / width, height: cropHeight / height)
        if result.width >= keepsEverythingFraction && result.height >= keepsEverythingFraction { return nil }
        if result.width * result.height >= keepsMostArea && hasShape(shape, width: width, height: height) { return nil }
        return result
    }

    /// Whether a picture already has the shape: any picture has "fit the subject".
    private static func hasShape(_ shape: String?, width: Double, height: Double) -> Bool {
        guard let wanted = longOverShort(of: shape) else { return true }
        return abs(max(width, height) / min(width, height) / wanted - 1) < sameShapeTolerance
    }
}
