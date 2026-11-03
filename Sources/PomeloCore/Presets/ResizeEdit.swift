import CoreGraphics
import Foundation

/// What the Resize editor decided: how the new size follows from the source's. Coded flat by `"mode"`.
public enum ResizeSpec: Codable, Sendable, Equatable {
    /// A percentage of each file's own size.
    case scale(percent: Double)
    /// This width, the height following the file's own proportions.
    case width(Int)
    /// This height, the width following the file's own proportions.
    case height(Int)
    /// This box, filled by the picture and cut evenly from both sides, never stretched.
    case exact(width: Int, height: Int)

    private enum CodingKeys: String, CodingKey {
        case mode, percent, width, height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "scale": self = .scale(percent: try container.decode(Double.self, forKey: .percent))
        case "width": self = .width(try container.decode(Int.self, forKey: .width))
        case "height": self = .height(try container.decode(Int.self, forKey: .height))
        case "exact":
            self = .exact(
                width: try container.decode(Int.self, forKey: .width), height: try container.decode(Int.self, forKey: .height))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: container, debugDescription: "unknown resize mode \"\(mode)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scale(let percent):
            try container.encode("scale", forKey: .mode)
            try container.encode(percent, forKey: .percent)
        case .width(let width):
            try container.encode("width", forKey: .mode)
            try container.encode(width, forKey: .width)
        case .height(let height):
            try container.encode("height", forKey: .mode)
            try container.encode(height, forKey: .height)
        case .exact(let width, let height):
            try container.encode("exact", forKey: .mode)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        }
    }
}

/// The rules for a resize, shared by the image and video engines and the Resize editor (as `CropEdit` is for crops).
/// Sizes are the upright picture's.
public enum ResizeEdit {
    public static let maxSide = 16_384
    public static let percentRange: ClosedRange<Double> = 1...400

    public static let chooseSizeReason = "Choose a size"
    public static let alreadyThatSizeReason = "It's already that size"
    public static let pixelRangeReason = "Between 1 and 16,384 pixels"
    public static let percentRangeReason = "Between 1 and 400 %"

    /// The pixels an image gets, each side at least 1.
    public static func size(_ edit: EditSpec?, width: Int, height: Int) throws -> (width: Int, height: Int) {
        let exact = try exactSize(edit, width: width, height: height)
        let result = (width: max(1, Int(exact.width.rounded())), height: max(1, Int(exact.height.rounded())))
        try check(result)
        guard result != (width, height) else { throw ConversionError.notApplicable(reason: alreadyThatSizeReason) }
        return result
    }

    /// The part of the source an Exact resize keeps: the centre of the largest area with the target's proportions.
    public static func keptRect(width: Int, height: Int, target: (width: Int, height: Int)) -> CGRect {
        let (width, height) = (max(1, width), max(1, height))
        let wider = target.width * height >= target.height * width
        let kept = wider
            ? (width: width, height: min(height, max(1, Int((Double(width * target.height) / Double(max(1, target.width))).rounded()))))
            : (width: min(width, max(1, Int((Double(height * target.width) / Double(max(1, target.height))).rounded()))), height: height)
        return CGRect(x: (width - kept.width) / 2, y: (height - kept.height) / 2, width: kept.width, height: kept.height)
    }

    /// The pixels a video gets: each side rounded down to an even number (encoders want them) and at least 16. The
    /// proportions come from the unrounded size, so 721 wide on 1920 × 1080 is 720 × 404.
    public static func videoSize(_ edit: EditSpec?, width: Int, height: Int) throws -> (width: Int, height: Int) {
        _ = try size(edit, width: width, height: height)
        let exact = try exactSize(edit, width: width, height: height)
        func side(_ length: Double) -> Int {
            // The snap keeps 540 at 540 when the product came out as 539.9999999.
            max(16, Int(length + 1e-6) / 2 * 2)
        }
        let result = (width: side(exact.width), height: side(exact.height))
        guard result != (width, height) else { throw ConversionError.notApplicable(reason: alreadyThatSizeReason) }
        return result
    }

    public static func nameSuffix(width: Int, height: Int) -> String { "\(width)x\(height)" }

    /// The edit's size before rounding, with the range of what the person typed checked.
    private static func exactSize(_ edit: EditSpec?, width: Int, height: Int) throws -> (width: Double, height: Double) {
        guard case .resize(let spec) = edit else { throw ConversionError.notApplicable(reason: chooseSizeReason) }
        switch spec {
        case .scale(let percent):
            guard percentRange.contains(percent) else { throw ConversionError.notApplicable(reason: percentRangeReason) }
            return (Double(width) * percent / 100, Double(height) * percent / 100)
        case .width(let target):
            try check(side: target)
            return (Double(target), Double(height) * Double(target) / Double(max(1, width)))
        case .height(let target):
            try check(side: target)
            return (Double(width) * Double(target) / Double(max(1, height)), Double(target))
        case .exact(let targetWidth, let targetHeight):
            try check(side: targetWidth)
            try check(side: targetHeight)
            return (Double(targetWidth), Double(targetHeight))
        }
    }

    private static func check(side: Int) throws {
        guard (1...maxSide).contains(side) else { throw ConversionError.notApplicable(reason: pixelRangeReason) }
    }

    private static func check(_ size: (width: Int, height: Int)) throws {
        try check(side: size.width)
        try check(side: size.height)
    }
}
