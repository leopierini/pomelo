import CoreGraphics
import Foundation

/// What the Rotate editor decided: quarter turns clockwise, then an optional horizontal flip of the turned picture.
/// Those eight values are every combination of turns and flips.
public struct RotateSpec: Codable, Sendable, Equatable {
    /// Clockwise, 0 to 3.
    public var quarterTurns: Int {
        didSet { quarterTurns = Self.normalised(quarterTurns) }
    }
    public var flipHorizontal: Bool

    public static let identity = RotateSpec(quarterTurns: 0, flipHorizontal: false)

    public init(quarterTurns: Int, flipHorizontal: Bool) {
        self.quarterTurns = Self.normalised(quarterTurns)
        self.flipHorizontal = flipHorizontal
    }

    private enum CodingKeys: String, CodingKey {
        case quarterTurns, flipHorizontal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quarterTurns: try container.decode(Int.self, forKey: .quarterTurns),
            flipHorizontal: try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false)
    }

    private static func normalised(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }

    public var isIdentity: Bool { quarterTurns == 0 && !flipHorizontal }

    // These four act on the picture the preview shows (turns, then the flip), so each result is that picture turned
    // or flipped. A turn after a flip is the opposite turn before it (T∘F = F∘T⁻¹), and a vertical flip is two
    // turns and a horizontal flip.
    public func rotatedRight() -> RotateSpec {
        RotateSpec(quarterTurns: quarterTurns + (flipHorizontal ? -1 : 1), flipHorizontal: flipHorizontal)
    }

    public func rotatedLeft() -> RotateSpec {
        RotateSpec(quarterTurns: quarterTurns + (flipHorizontal ? 1 : -1), flipHorizontal: flipHorizontal)
    }

    public func flippedHorizontally() -> RotateSpec {
        RotateSpec(quarterTurns: quarterTurns, flipHorizontal: !flipHorizontal)
    }

    public func flippedVertically() -> RotateSpec {
        RotateSpec(quarterTurns: quarterTurns + 2, flipHorizontal: !flipHorizontal)
    }

    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        quarterTurns % 2 == 1 ? (height, width) : (width, height)
    }

    /// Maps the upright source picture, `width` × `height` pixels, onto the turned bitmap. Both are in pixels with the
    /// origin at the top left and y pointing down (AVFoundation's and SwiftUI's, not Core Graphics' y-up): a pixel's
    /// centre (0.5, 0.5) of a 4 × 2 picture lands on (1.5, 0.5) after one turn, the top right of the 2 × 4 result.
    public func transform(width: Int, height: Int) -> CGAffineTransform {
        let (w, h) = (CGFloat(width), CGFloat(height))
        let turned: CGAffineTransform
        switch quarterTurns {
        case 1: turned = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: turned = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: turned = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: turned = .identity
        }
        guard flipHorizontal else { return turned }
        let turnedWidth = CGFloat(outputSize(width: width, height: height).width)
        return turned.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: turnedWidth, ty: 0))
    }
}

/// The rules for a rotation, shared by the image and video engines and the Rotate editor.
public enum RotateEdit {
    public static let nothingToRotateReason = "Nothing to rotate"

    public static func spec(_ edit: EditSpec?) throws -> RotateSpec {
        guard case .rotate(let spec) = edit, !spec.isIdentity else {
            throw ConversionError.notApplicable(reason: nothingToRotateReason)
        }
        return spec
    }
}
