// The wheel's window: a borderless, non-activating panel above everything, created once and reused. Its content
// view is the drop target, which hosts the SwiftUI wheel and hit-tests drops (and click-mode clicks) against
// `WheelGeometry`.
import AppKit
import PomeloUIModel
import SwiftUI

/// The reusable 360×400 panel that shows the wheel.
final class WheelPanel: NSPanel {
    static let size = WheelView.panelSize

    /// In click mode the panel becomes key, to track the mouse and receive keys; during a drag it only accepts the key
    /// the system gives it (`WheelController.show`).
    var allowsKey = false
    /// Called when the panel stops being key (a click elsewhere in click mode).
    var onResignKey: (() -> Void)?

    let dropTarget: DropTargetView

    init(model: WheelModel) {
        dropTarget = DropTargetView(model: model)
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.sizingOptions = []
        hosting.frame = dropTarget.bounds
        hosting.autoresizingMask = [.width, .height]
        // Drags must reach the drop target, never a hosting view registered for SwiftUI's own drop support.
        hosting.unregisterDraggedTypes()
        dropTarget.addSubview(hosting)
        contentView = dropTarget
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Receives the drag (and click-mode mouse events) for the whole panel, above the hosting view.
///
/// Points are converted to the wheel's frame (relative to the panel centre, y-up): the ring is centred in the
/// panel, so this holds even when the panel is clamped at a screen edge and the cursor is off-centre.
final class DropTargetView: FileDropView {
    /// A drop or click on an enabled slice: the slice and the files.
    var onChoose: ((WheelSlice, [URL]) -> Void)?
    /// A click on the hub or outside the ring in click mode.
    var onDismiss: (() -> Void)?
    /// A click anywhere once a choice is made (M3: the panel goes on taking clicks for a moment).
    var onClickClose: (() -> Void)?
    /// Click mode: a click on the hub while it shows a prompt (P23).
    var onActivatePrompt: (() -> Void)?
    /// Click mode: a navigation key went down in the key panel.
    var onKey: ((NavKey) -> Void)?
    /// When true, mouse moves hover, clicks choose and keys navigate.
    var clickMode = false

    private let model: WheelModel

    init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: WheelPanel.size))
        registerForDraggedTypes([.fileURL])
        // A near-invisible fill: the window server passes drags over fully transparent pixels to the window below
        // (where Finder would move the file), so every point of the panel must have some alpha.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        // `.inVisibleRect` keeps the area matched to the view, so it never needs updating.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                              .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Every mouse event lands here rather than in the (non-interactive) SwiftUI view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func wheelPoint(_ windowPoint: NSPoint) -> CGPoint {
        let p = convert(windowPoint, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
    }

    // MARK: - Drag destination

    override func dropLeft() {
        model.hover(at: nil)
    }

    /// `.copy` over an enabled slice; `[]` over the hub, outside the ring, a disabled slice, or once a drop has
    /// landed (P23: the wheel then only waits for that job).
    override func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        let point = wheelPoint(sender.draggingLocation)
        model.hover(at: point)
        return choosableSlice(at: point) != nil ? .copy : []
    }

    private func choosableSlice(at point: CGPoint) -> WheelSlice? {
        guard model.phase == .choosing, let slice = model.slice(at: point), slice.isEnabled else { return nil }
        return slice
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        choosableSlice(at: wheelPoint(sender.draggingLocation)) != nil
    }

    /// Chooses the slice under the drop; returns false (the files spring back) anywhere else.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let slice = choosableSlice(at: wheelPoint(sender.draggingLocation)) else { return false }
        let urls = sender.draggingPasteboard.fileURLs
        guard !urls.isEmpty else { return false }
        onChoose?(slice, urls)
        return true
    }

    // MARK: - Click mode

    /// First responder in click mode, so the panel's key-downs reach `keyDown`.
    override var acceptsFirstResponder: Bool { clickMode }

    /// Click mode: navigation keys go to `onKey`; anything else goes up the responder chain (and beeps).
    override func keyDown(with event: NSEvent) {
        guard clickMode, let key = NavKey(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            super.keyDown(with: event)
            return
        }
        onKey?(key)
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return }
        model.hover(at: wheelPoint(event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        guard clickMode else { return }
        model.hover(at: nil)
    }

    /// While a job is waited for or a note shows, any click on the panel dismisses it (the job goes on), in a drag
    /// too: the panel takes the click, so it never reaches whatever lies under the wheel (P23), nor does a second
    /// click while the content is hidden (M3). Click mode, while choosing: an enabled slice chooses, a disabled one
    /// does nothing, the hub or outside dismisses (a prompt's hub activates it). After a failure the same, a drag's
    /// wheel included (P191), but the hub or outside dismisses taking the click, as before the failure.
    override func mouseDown(with event: NSEvent) {
        guard !model.isContentHidden else { return }
        guard model.isChoosable else {
            onClickClose?()
            return
        }
        guard clickMode else { return }
        let point = wheelPoint(event.locationInWindow)
        switch model.geometry.hitTest(point) {
        case .slice:
            guard let slice = model.slice(at: point), slice.isEnabled else { return }
            onChoose?(slice, model.files)
        case .hub where model.prompt != nil:
            onActivatePrompt?()
        case .hub, .outside:
            if model.isFailed { onClickClose?() } else { onDismiss?() }
        }
    }
}
