import CoreGraphics
import Foundation

/// A span of a recording, in seconds.
public struct TimeRange: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// A rectangle as fractions of the image: 0...1, origin top-left, in the displayed orientation (EXIF orientation or
/// a video's preferred transform applied), so it lands on what the editor showed whatever the stored pixels are.
public struct UnitRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Both edges pulled inside 0...1; a rectangle wholly outside collapses to zero size.
    public func clamped() -> UnitRect {
        func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
        let left = unit(x)
        let top = unit(y)
        let right = unit(x + width)
        let bottom = unit(y + height)
        return UnitRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
    }

    /// The pixels it covers in an image of this size: the origin rounded down and the far edge up, so a redaction
    /// never covers less than its box, then clamped to the image.
    public func pixels(width imageWidth: Int, height imageHeight: Int) -> CGRect {
        let rect = clamped()
        let left = Self.floor(rect.x * Double(imageWidth))
        let top = Self.floor(rect.y * Double(imageHeight))
        let right = Self.ceil((rect.x + rect.width) * Double(imageWidth))
        let bottom = Self.ceil((rect.y + rect.height) * Double(imageHeight))
        let clampedRight = min(max(right, left), Double(imageWidth))
        let clampedBottom = min(max(bottom, top), Double(imageHeight))
        return CGRect(x: left, y: top, width: clampedRight - left, height: clampedBottom - top)
    }

    /// 0.1 + 0.2 times 100 is 30.000000000000004: without the snap the far edge would round up to 31.
    private static let snap = 1e-6

    private static func floor(_ value: Double) -> Double {
        let nearest = value.rounded()
        return abs(value - nearest) < snap ? nearest : value.rounded(.down)
    }

    private static func ceil(_ value: Double) -> Double {
        let nearest = value.rounded()
        return abs(value - nearest) < snap ? nearest : value.rounded(.up)
    }
}

public enum RedactionStyle: String, Codable, Sendable {
    case fill, pixelate
}

public struct RedactionSpec: Codable, Sendable, Equatable {
    public var boxes: [UnitRect]
    public var style: RedactionStyle

    public init(boxes: [UnitRect], style: RedactionStyle) {
        self.boxes = boxes
        self.style = style
    }
}

/// One page of the organized document.
public struct PageEdit: Codable, Sendable, Equatable {
    /// 0-based index in the source.
    public var page: Int
    /// 0, 90, 180 or 270, added clockwise to the page's own rotation.
    public var rotation: Int

    public init(page: Int, rotation: Int) {
        self.page = page
        self.rotation = rotation
    }
}

/// What an editor decided, carried to its engine as a preset option. Coded flat, keyed by `"kind"`.
public enum EditSpec: Sendable, Equatable {
    case trim(TimeRange)
    case split([Double])
    case crop(UnitRect)
    case redact(RedactionSpec)
    case organize([PageEdit])
    case resize(ResizeSpec)
    case rotate(RotateSpec)
}

extension EditSpec: Codable {
    private enum Kind: String {
        case trim, split, crop, redact, organize, resize, rotate
    }

    private enum CodingKeys: String, CodingKey {
        case kind, start, end, points, x, y, width, height, style, boxes, pages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown edit kind \"\(name)\"")
        }
        switch kind {
        case .trim:
            self = .trim(TimeRange(
                start: try container.decode(Double.self, forKey: .start), end: try container.decode(Double.self, forKey: .end)))
        case .split:
            self = .split(try container.decode([Double].self, forKey: .points))
        case .crop:
            self = .crop(try Self.rect(in: container))
        case .redact:
            self = .redact(RedactionSpec(
                boxes: try container.decode([UnitRect].self, forKey: .boxes),
                style: try container.decode(RedactionStyle.self, forKey: .style)))
        case .organize:
            self = .organize(try container.decode([PageEdit].self, forKey: .pages))
        case .resize:
            self = .resize(try ResizeSpec(from: decoder))
        case .rotate:
            self = .rotate(try RotateSpec(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trim(let range):
            try container.encode(Kind.trim.rawValue, forKey: .kind)
            try container.encode(range.start, forKey: .start)
            try container.encode(range.end, forKey: .end)
        case .split(let points):
            try container.encode(Kind.split.rawValue, forKey: .kind)
            try container.encode(points, forKey: .points)
        case .crop(let rect):
            try container.encode(Kind.crop.rawValue, forKey: .kind)
            try container.encode(rect.x, forKey: .x)
            try container.encode(rect.y, forKey: .y)
            try container.encode(rect.width, forKey: .width)
            try container.encode(rect.height, forKey: .height)
        case .redact(let spec):
            try container.encode(Kind.redact.rawValue, forKey: .kind)
            try container.encode(spec.style, forKey: .style)
            try container.encode(spec.boxes, forKey: .boxes)
        case .organize(let pages):
            try container.encode(Kind.organize.rawValue, forKey: .kind)
            try container.encode(pages, forKey: .pages)
        case .resize(let spec):
            try container.encode(Kind.resize.rawValue, forKey: .kind)
            try spec.encode(to: encoder)
        case .rotate(let spec):
            try container.encode(Kind.rotate.rawValue, forKey: .kind)
            try spec.encode(to: encoder)
        }
    }

    private static func rect(in container: KeyedDecodingContainer<CodingKeys>) throws -> UnitRect {
        UnitRect(
            x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y),
            width: try container.decode(Double.self, forKey: .width),
            height: try container.decode(Double.self, forKey: .height))
    }
}
