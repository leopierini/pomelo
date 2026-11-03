import CoreGraphics
import Foundation

/// A page's four corners in pixels of the upright picture, origin at the top left and y down.
public struct PageQuad: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    private var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Every corner moved inside the `width` x `height` picture; a non-finite coordinate takes its picture corner's.
    public func clamped(width: Int, height: Int) -> PageQuad {
        let (right, bottom) = (Double(width), Double(height))
        func inside(_ point: CGPoint, _ fallback: CGPoint) -> CGPoint {
            let x = point.x.isFinite ? point.x : fallback.x
            let y = point.y.isFinite ? point.y : fallback.y
            return CGPoint(x: min(max(x, 0), right), y: min(max(y, 0), bottom))
        }
        return PageQuad(
            topLeft: inside(topLeft, .zero), topRight: inside(topRight, CGPoint(x: right, y: 0)),
            bottomRight: inside(bottomRight, CGPoint(x: right, y: bottom)),
            bottomLeft: inside(bottomLeft, CGPoint(x: 0, y: bottom))
        )
    }

    /// The quad's area (shoelace) over the picture's.
    public func coverage(width: Int, height: Int) -> Double {
        guard width > 0, height > 0 else { return 0 }
        let points = corners
        var twiceArea = 0.0
        for index in points.indices {
            let (a, b) = (points[index], points[(index + 1) % points.count])
            twiceArea += a.x * b.y - b.x * a.y
        }
        return abs(twiceArea) / 2 / (Double(width) * Double(height))
    }

    /// The mean of the top and bottom lengths, and of the left and right ones.
    public var meanSize: CGSize {
        CGSize(
            width: (Self.distance(topLeft, topRight) + Self.distance(bottomLeft, bottomRight)) / 2,
            height: (Self.distance(topLeft, bottomLeft) + Self.distance(topRight, bottomRight)) / 2
        )
    }

    /// The largest of the four corners' distances from a right angle, in degrees; 90 at a corner with no length.
    public var worstCornerDeviation: Double {
        let points = corners
        return points.indices.map { index in
            let corner = points[index]
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            let (ax, ay) = (previous.x - corner.x, previous.y - corner.y)
            let (bx, by) = (next.x - corner.x, next.y - corner.y)
            let lengths = (ax * ax + ay * ay).squareRoot() * (bx * bx + by * by).squareRoot()
            guard lengths > 0 else { return 90 }
            let cosine = min(1, max(-1, (ax * bx + ay * by) / lengths))
            return abs(acos(cosine) * 180 / .pi - 90)
        }.max() ?? 90
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(b.x - a.x, b.y - a.y)
    }
}

/// When Straighten document flattens a page and to what size (P262). The engine finds the quad; the rules are here so
/// they are tested without Vision.
public enum StraightenRules {
    public static let minimumConfidence = 0.6
    /// A quad smaller than this share of the picture is not taken for the page.
    public static let minimumCoverage = 0.15
    /// A quad this much of the picture, with every corner within `alreadyFlatDegrees` of square, is already flat.
    public static let alreadyFlatCoverage = 0.98
    public static let alreadyFlatDegrees = 1.0
    /// A page within this fraction of an A-series or a US Letter sheet's ratio is made exactly that ratio.
    public static let snapTolerance = 0.04
    public static let noDocumentReason = "No document found"
    public static let alreadyFlatReason = "It's already flat"

    /// Long side over short side: A-series (1 : √2) and US Letter (8.5 : 11).
    private static let sheetRatios = [Double(2).squareRoot(), 11 / 8.5]

    public enum Verdict: Equatable, Sendable {
        case straighten(PageQuad)
        case noDocument
        case alreadyFlat
    }

    /// The flattened page's pixel size: the quad's mean size, rounded, and snapped to a sheet's ratio either way up
    /// when within `snapTolerance` of it. The snap keeps the longer side and sets the shorter one from it: the same
    /// error at a corner is a smaller part of the longer side, so it is the better measured of the two.
    public static func outputSize(for quad: PageQuad) -> (width: Int, height: Int) {
        let mean = quad.meanSize
        let width = max(1, Int(mean.width.rounded()))
        let height = max(1, Int(mean.height.rounded()))
        let (long, short) = (max(width, height), min(width, height))
        let ratio = Double(long) / Double(short)
        guard let sheet = sheetRatios.filter({ abs(ratio - $0) / $0 <= snapTolerance })
            .min(by: { abs(ratio - $0) < abs(ratio - $1) })
        else { return (width, height) }
        let snapped = max(1, Int((Double(long) / sheet).rounded()))
        return width >= height ? (long, snapped) : (snapped, long)
    }

    /// What to do with the page Vision found, its quad clamped to the picture first.
    public static func verdict(confidence: Double, quad: PageQuad, imageWidth: Int, imageHeight: Int) -> Verdict {
        guard imageWidth > 0, imageHeight > 0, confidence >= minimumConfidence else { return .noDocument }
        let kept = quad.clamped(width: imageWidth, height: imageHeight)
        let coverage = kept.coverage(width: imageWidth, height: imageHeight)
        guard coverage >= minimumCoverage else { return .noDocument }
        if coverage >= alreadyFlatCoverage, kept.worstCornerDeviation <= alreadyFlatDegrees { return .alreadyFlat }
        return .straighten(kept)
    }
}
