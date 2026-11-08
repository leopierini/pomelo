// Where the editor panel opens (P27): centred on the drop point and kept inside the visible frame of its screen, by
// the same clamp the progress pill uses (P66). Points are AppKit screen coordinates (y up).
import CoreGraphics

public enum ScreenFit {
    /// `frame` moved inside `visible` inset by `margin`. A frame larger than the inset frame keeps its top-left
    /// corner there, so a panel's header (or the pill stack's oldest job) stays on screen.
    public static func clamp(_ frame: CGRect, into visible: CGRect, margin: CGFloat) -> CGRect {
        let inset = visible.insetBy(dx: margin, dy: margin)
        var origin = frame.origin
        origin.x = frame.width > inset.width
            ? inset.minX : min(max(origin.x, inset.minX), inset.maxX - frame.width)
        origin.y = frame.height > inset.height
            ? inset.maxY - frame.height : min(max(origin.y, inset.minY), inset.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}

public enum EditorLayout {
    public static let maxHeight: CGFloat = 560
    /// Between the panel and the edges of the visible frame.
    public static let margin: CGFloat = 8
    /// The card's corners, and the panel's: the window's own corners must match the card's (see `EditorPanel`).
    public static let cornerRadius: CGFloat = 16

    public static func width(for kind: EditorKind) -> CGFloat {
        switch kind {
        case .targetSize, .resize: 340
        case .trim, .split, .crop, .rotate: 520
        case .redact, .organizePages: 600
        }
    }

    public static func frame(contentSize: CGSize, anchor: CGPoint, visibleFrame: CGRect) -> CGRect {
        let centred = CGRect(x: anchor.x - contentSize.width / 2, y: anchor.y - contentSize.height / 2,
                             width: contentSize.width, height: contentSize.height)
        return ScreenFit.clamp(centred, into: visibleFrame, margin: margin)
    }
}
