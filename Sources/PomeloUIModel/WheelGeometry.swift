// Pure geometry of the conversion wheel: which slice a point falls in, where each label sits, and where the
// wheel's panel goes on screen. Only Foundation and CoreGraphics: no AppKit.
import CoreGraphics
import Foundation

/// What lies under a point on the wheel.
public enum WheelHit: Equatable, Sendable {
    case slice(Int)
    case hub
    case outside
}

/// The wheel's layout: `sliceCount` equal slices around a hub, slice 0 centred at 12 o'clock, clockwise.
/// Points are relative to the wheel's centre with y pointing up (AppKit's, not SwiftUI's).
public struct WheelGeometry: Sendable, Equatable {
    public static let defaultDiameter: CGFloat = 340
    public static let defaultHubDiameter: CGFloat = 132

    public let sliceCount: Int
    public let diameter: CGFloat
    public let hubDiameter: CGFloat

    public init(sliceCount: Int, diameter: CGFloat = WheelGeometry.defaultDiameter,
                hubDiameter: CGFloat = WheelGeometry.defaultHubDiameter) {
        self.sliceCount = max(0, sliceCount)
        self.diameter = diameter
        self.hubDiameter = hubDiameter
    }

    private var sliceWidth: Double { 2 * .pi / Double(sliceCount) }

    /// The slice, hub or nothing under `p`. A point on the hub's edge belongs to the ring, one on the rim is
    /// outside, and one exactly on a slice boundary belongs to the clockwise slice. With no slices only the hub
    /// answers; everything else is `.outside`.
    public func hitTest(_ p: CGPoint) -> WheelHit {
        let radius = Double(hypot(p.x, p.y))
        if radius < Double(hubDiameter) / 2 { return .hub }
        if radius >= Double(diameter) / 2 || sliceCount == 0 { return .outside }
        var angle = atan2(Double(p.x), Double(p.y))   // 0 at 12 o'clock, clockwise positive
        if angle < 0 { angle += 2 * .pi }
        let shifted = (angle + sliceWidth / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return .slice(min(Int(shifted / sliceWidth), sliceCount - 1))
    }

    /// Where a new slice would go if dropped at `p`: before slice `i` in its counter-clockwise half, after it in its
    /// clockwise half. Nil on the hub or outside; 0 when there are no slices.
    public func insertionIndex(at p: CGPoint) -> Int? {
        switch hitTest(p) {
        case .hub: return nil
        case .outside: return sliceCount == 0 && hypot(p.x, p.y) < diameter / 2 ? 0 : nil
        case .slice(let i):
            var offset = atan2(Double(p.x), Double(p.y)) - centerAngle(ofSlice: i)
            if offset > .pi { offset -= 2 * .pi } else if offset < -.pi { offset += 2 * .pi }
            return offset > 0 ? i + 1 : i
        }
    }

    /// `p` measured from the top-left of the wheel's square frame, y down (a SwiftUI view's local location), as
    /// the centre-relative, y-up point the rest of this type takes.
    public func centred(fromTopLeft p: CGPoint) -> CGPoint {
        let radius = diameter / 2
        return CGPoint(x: p.x - radius, y: radius - p.y)
    }

    /// The angle, in radians, of slice `i`'s centre: 0 at 12 o'clock, clockwise positive.
    public func centerAngle(ofSlice i: Int) -> Double {
        guard sliceCount > 0 else { return 0 }
        return Double(i) * sliceWidth
    }

    /// Where slice `i`'s label is centred: on the radius midway between the hub and the rim, y-up.
    public func labelCenter(ofSlice i: Int) -> CGPoint {
        let radius = Double(hubDiameter / 2 + diameter / 2) / 2
        let angle = centerAngle(ofSlice: i)
        return CGPoint(x: radius * sin(angle), y: radius * cos(angle))
    }

    /// The origin (lower-left, as AppKit's `setFrameOrigin`) that centres a panel of `panelSize` on `cursor`,
    /// clamped to lie inside `visibleFrame`. A panel larger than the frame cannot fit: it is pinned to the
    /// frame's minX/minY (left and bottom edges) rather than crashing.
    public static func panelOrigin(cursor: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = cursor.x - panelSize.width / 2
        let y = cursor.y - panelSize.height / 2
        return CGPoint(x: max(visibleFrame.minX, min(x, visibleFrame.maxX - panelSize.width)),
                       y: max(visibleFrame.minY, min(y, visibleFrame.maxY - panelSize.height)))
    }
}
