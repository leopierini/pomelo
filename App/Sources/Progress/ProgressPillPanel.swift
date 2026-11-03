// The progress pill's window (P25): a borderless, non-activating panel near the drop point that never becomes key,
// so a click on a pill neither activates Pomelo nor takes the selection from Finder.
import AppKit
import PomeloUIModel
import SwiftUI

final class ProgressPillPanel: NSPanel {
    /// The pills. Internal so the controller can replace its root view and the tests can check it.
    let host = ProgressPillHostingView(rootView: ProgressPillStack())

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PillLayout.width,
                                      height: PillLayout.collapsedHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Setting `isFloatingPanel` sets the level to `.floating`, so it comes first.
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        embed(host)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSPanel {
    /// The pill's and the editor's panels are sized from the host's fitting size, which is zero without the intrinsic
    /// content size (commit c7eb708). The host is not the content view, so it never resizes the panel by itself.
    func embed<Content: View>(_ host: NSHostingView<Content>) {
        host.sizingOptions = [.intrinsicContentSize]
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }
}

/// P22: the panel is never key, so without this the first click on a pill's button would only be swallowed.
final class ProgressPillHostingView: NSHostingView<ProgressPillStack> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
