// Where the Shelf sits (S7, S10) and how big it is (S8). Points are AppKit screen coordinates (y up); pure
// CoreGraphics so the panel code only applies what this returns.
import CoreGraphics

public enum ShelfPresentation: Equatable, Sendable {
    case empty
    case collapsed
    case expanded(rows: Int)
    case tucked
}

public enum ShelfSide: Sendable {
    case left, right
}

public enum ShelfLayout {
    /// Between the drawer and the edges of the visible frame, like the editors and the pill.
    public static let margin: CGFloat = 8

    static let visibleRowCount = 6
    public static let rowHeight: CGFloat = 32
    public static let headerHeight: CGFloat = 28
    /// Split between the list's top and bottom.
    public static let listPadding: CGFloat = 8
    /// The key pill's band at the bottom of a drawer holding files (R30), as tall as the wheel's.
    public static let pillBand: CGFloat = 30

    public static func size(_ presentation: ShelfPresentation) -> CGSize {
        switch presentation {
        // Wide enough for the key pill (R30) inside the collapsed drawer's corners; the empty one keeps that width.
        case .empty:
            CGSize(width: 128, height: 132)
        case .collapsed:
            CGSize(width: 128, height: 132 + pillBand)
        case .expanded(let rows):
            CGSize(width: 260, height: headerHeight + viewport(rows) + listPadding + pillBand)
        case .tucked:
            CGSize(width: 14, height: 56)
        }
    }

    // MARK: The expanded list (S8)

    /// Depths are points down from the drawer's top edge; the list starts under the header and half its padding.
    private static var listTop: CGFloat { headerHeight + listPadding / 2 }

    private static func viewport(_ count: Int) -> CGFloat { CGFloat(min(max(count, 0), visibleRowCount)) * rowHeight }

    /// The row at `depth` in a list of `count` scrolled by `scrollOffset`, or nil over the header or the padding.
    public static func row(atDepth depth: CGFloat, scrollOffset: CGFloat, count: Int) -> Int? {
        guard depth >= listTop, depth < listTop + viewport(count) else { return nil }
        let index = Int(((depth - listTop + scrollOffset) / rowHeight).rounded(.down))
        return index < count ? index : nil
    }

    /// The rows any part of which shows.
    public static func visibleRows(scrollOffset: CGFloat, count: Int) -> Range<Int> {
        let first = max(Int((scrollOffset / rowHeight).rounded(.down)), 0)
        let end = Int(((scrollOffset + viewport(count)) / rowHeight).rounded(.up))
        return min(first, count)..<min(max(end, first), count)
    }

    public static func maxScrollOffset(count: Int) -> CGFloat {
        CGFloat(max(count - visibleRowCount, 0)) * rowHeight
    }

    /// The least scroll from `offset` that shows all of row `index` (the arrow keys' focus).
    public static func scrollOffset(revealing index: Int, from offset: CGFloat, count: Int) -> CGFloat {
        let top = CGFloat(index) * rowHeight
        var next = offset
        if top < next { next = top }
        if top + rowHeight > next + viewport(count) { next = top + rowHeight - viewport(count) }
        return min(max(next, 0), maxScrollOffset(count: count))
    }

    /// Where Open the Wheel centres the wheel (S17): beside the drawer, right where it fits, else left, else on the
    /// side with more room; the wheel then keeps itself on screen.
    public static func wheelCentre(beside drawer: CGRect, wheelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let half = wheelSize.width / 2
        let right = drawer.maxX + half
        let left = drawer.minX - half
        let x: CGFloat
        if right + half <= visibleFrame.maxX {
            x = right
        } else if left - half >= visibleFrame.minX {
            x = left
        } else {
            x = visibleFrame.maxX - drawer.maxX >= drawer.minX - visibleFrame.minX ? right : left
        }
        return CGPoint(x: x, y: drawer.midY)
    }

    /// Centred on `centredOn` and clamped like an editor. With a `cursor`, each axis drops its margin to 0 where
    /// the margin would leave the cursor outside the frame, and if the visible frame still can't hold it (the
    /// cursor over the Dock or the menu bar) the frame moves the least distance to contain it, so the release of a
    /// shake lands on the drawer (S7, R17). Containment is `CGRect.contains`, which excludes the max edges.
    public static func frame(centredOn: CGPoint, size: CGSize, visibleFrame: CGRect,
                             keepingInside cursor: CGPoint?) -> CGRect {
        let centred = CGRect(x: centredOn.x - size.width / 2, y: centredOn.y - size.height / 2,
                             width: size.width, height: size.height)
        let inset = ScreenFit.clamp(centred, into: visibleFrame, margin: margin)
        guard let cursor else { return inset }
        let flush = ScreenFit.clamp(centred, into: visibleFrame, margin: 0)
        var origin = inset.origin
        if cursor.x < inset.minX || cursor.x >= inset.maxX { origin.x = flush.minX }
        if cursor.y < inset.minY || cursor.y >= inset.maxY { origin.y = flush.minY }
        if cursor.x < origin.x { origin.x = cursor.x } else if cursor.x >= origin.x + size.width {
            origin.x = cursor.x + 1 - size.width
        }
        if cursor.y < origin.y { origin.y = cursor.y } else if cursor.y >= origin.y + size.height {
            origin.y = cursor.y + 1 - size.height
        }
        return CGRect(origin: origin, size: size)
    }

    /// The menu's place: where the Shelf last was while its centre is still on a screen, else right-middle of
    /// the pointer's screen (S7). `pointerScreen` is that screen's visible frame.
    public static func menuFrame(size: CGSize, last: CGRect?, visibleFrames: [CGRect],
                                 pointerScreen: CGRect) -> CGRect {
        if let last, let screen = visibleFrames.first(where: { containsClosed($0, CGPoint(x: last.midX, y: last.midY)) }) {
            // Unchanged size: margin 0, so a flush Shelf doesn't shift 8 pt.
            if last.size == size { return ScreenFit.clamp(last, into: screen, margin: 0) }
            return resized(last, to: size, visibleFrame: screen)
        }
        let rightMiddle = CGRect(x: pointerScreen.maxX - margin - size.width,
                                 y: pointerScreen.midY - size.height / 2,
                                 width: size.width, height: size.height)
        return ScreenFit.clamp(rightMiddle, into: pointerScreen, margin: margin)
    }

    /// The tab on the side edge nearest the drawer's centre, at the drawer's height (S8).
    public static func tab(for drawer: CGRect, visibleFrame: CGRect) -> (frame: CGRect, side: ShelfSide) {
        let tabSize = size(.tucked)
        let side: ShelfSide = drawer.midX < visibleFrame.midX ? .left : .right
        let x = side == .left ? visibleFrame.minX : visibleFrame.maxX - tabSize.width
        let tab = CGRect(x: x, y: drawer.midY - tabSize.height / 2, width: tabSize.width, height: tabSize.height)
        return (ScreenFit.clamp(tab, into: visibleFrame, margin: 0), side)
    }

    /// Keeps the top edge (grows downward, S8) and the left edge (widens rightward from where the stack was),
    /// then keeps the drawer on screen.
    public static func resized(_ frame: CGRect, to size: CGSize, visibleFrame: CGRect) -> CGRect {
        let grown = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        return ScreenFit.clamp(grown, into: visibleFrame, margin: margin)
    }

    /// After a header drag (S7): into the visible frame holding its centre, else the nearest one.
    public static func settled(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let screen = visibleFrames.first { containsClosed($0, centre) }
            ?? visibleFrames.min { distance(from: centre, to: $0) < distance(from: centre, to: $1) }
        guard let screen else { return frame }
        return ScreenFit.clamp(frame, into: screen, margin: margin)
    }

    /// After a display change (S10): the same relative place in the inset frame, size kept. A frame at the
    /// right-middle of one display stays at the right-middle of another.
    public static func replaced(_ frame: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        let oldInset = old.insetBy(dx: margin, dy: margin)
        let newInset = new.insetBy(dx: margin, dy: margin)
        let fx = fraction(frame.minX - oldInset.minX, of: oldInset.width - frame.width)
        let fy = fraction(frame.minY - oldInset.minY, of: oldInset.height - frame.height)
        let moved = CGRect(x: newInset.minX + fx * (newInset.width - frame.width),
                           y: newInset.minY + fy * (newInset.height - frame.height),
                           width: frame.width, height: frame.height)
        return ScreenFit.clamp(moved, into: new, margin: margin)
    }

    private static func fraction(_ offset: CGFloat, of free: CGFloat) -> CGFloat {
        free > 0 ? min(max(offset / free, 0), 1) : 0.5
    }

    // CGRect.contains is half-open at the max edges; a point on the visible frame's top or right edge is on it.
    private static func containsClosed(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
