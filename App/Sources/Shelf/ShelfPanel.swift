// The Shelf's window (S24): a borderless, non-activating floating panel on every Space and over full-screen apps,
// under the wheel (.popUpMenu) and the pill (.statusBar) so both open over it. Its content view, an AppKit view
// holding the SwiftUI host, is the drop target and the drag source, so drags never reach SwiftUI's own handling.
import AppKit
import PomeloUIModel
import QuickLookUI
import SwiftUI

final class ShelfPanel: NSPanel {
    /// Room around the drawer for the shadow the SwiftUI view draws and its 1.03 drop-hover scale (S8).
    static let inset: CGFloat = 12

    /// False on the off-screen desktop of the tests; otherwise a click makes the panel key (never a summon).
    var allowsKey = true

    let itemsView: ShelfItemsView

    init(controller: ShelfController) {
        itemsView = ShelfItemsView(frame: NSRect(origin: .zero, size: Self.panelSize(for: ShelfLayout.size(.empty))))
        super.init(contentRect: itemsView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        // Setting `isFloatingPanel` sets the level to `.floating`, so it comes first.
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let hosting = ShelfHostingView(rootView: ShelfView(controller: controller))
        hosting.sizingOptions = []
        hosting.frame = itemsView.bounds
        hosting.autoresizingMask = [.width, .height]
        // Drags must reach the items view, never a hosting view registered for SwiftUI's own drop support.
        hosting.unregisterDraggedTypes()
        itemsView.addSubview(hosting)
        contentView = itemsView
    }

    static func panelSize(for drawer: CGSize) -> CGSize {
        CGSize(width: drawer.width + 2 * inset, height: drawer.height + 2 * inset)
    }

    // A non-activating panel becomes key on a click, never by being ordered in (`orderFrontRegardless`).
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Keys go to the items view (S17), whatever the click landed on. A ⌘-click that made it key sent its
    /// `flagsChanged` elsewhere: the key pill reads ⌘ now (R30).
    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(itemsView)
        itemsView.onCommandChanged?(NSEvent.modifierFlags.contains(.command))
    }

    /// ⌘ let go while another window has the keys never reaches the panel (R30).
    override func resignKey() {
        super.resignKey()
        itemsView.onCommandChanged?(false)
    }

    // MARK: Quick Look (S17)

    /// While key, the panel is the Quick Look panel's controller; `ShelfPreview` keeps it key while the preview shows.
    weak var previewSource: (any QLPreviewPanelDataSource)?

    // Quick Look asks its controller on the main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewSource != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = previewSource }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

/// P22: a click on the ✕ works while Finder is the active app and the panel is not key.
final class ShelfHostingView: NSHostingView<ShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Moves the panel with the mouse (S7, R29): the window server's drag (`EditorDragArea`) returns at once and may send
/// no mouse-up, so the panel follows the mouse itself and the Shelf settles it when let go.
struct ShelfWindowDrag {
    let mouse: NSPoint
    let origin: NSPoint

    @MainActor func follow(_ window: NSWindow, to now: NSPoint) {
        window.setFrameOrigin(NSPoint(x: origin.x + now.x - mouse.x, y: origin.y + now.y - mouse.y))
    }
}

/// What the Shelf offers as a drag source (S12, S33): copy alone, plus move only while ⌘ is held. Never `.delete`
/// (the Trash refuses a drag from the Shelf) or `.link` (no alias).
enum ShelfDragOperations {
    static func mask(commandHeld: Bool) -> NSDragOperation {
        // With ⌘ held AppKit narrows the mask to `.generic`, which Finder reads as move, across volumes too.
        commandHeld ? [.copy, .move, .generic] : [.copy]
    }
}

/// The whole drawer: the drop destination (S11: file URLs only, answered `.copy` so Finder never moves a source on a
/// drop, never the Shelf's own drags) and the drag source (S12, S13).
final class ShelfItemsView: FileDropView {
    /// Files dropped on the drawer.
    var onDrop: (([URL]) -> Void)?
    /// A drag the Shelf would take is over it, or no longer is.
    var onDropHover: ((Bool) -> Void)?
    /// The pointer entered or left the drawer (an event, never a poll: S26).
    var onPointerInside: ((Bool) -> Void)?
    /// The files a drag starting now carries, with the image each is dragged as; empty for nothing to drag.
    var onDragOut: (() -> [(url: URL, image: NSImage)])?
    /// A drag out ended: `[]` when it was cancelled or refused.
    var onDragOutEnded: ((NSDragOperation) -> Void)?
    /// ⌘ went down or up during a drag out, or while the panel is key (R30).
    var onCommandChanged: ((Bool) -> Void)?
    /// A mouse-down, and a click that started no drag; points from the drawer's top-left corner, y down.
    var onPress: ((CGPoint) -> Void)?
    var onClick: ((CGPoint, ModifierSet) -> Void)?
    /// Points to scroll the list by, positive toward its top.
    var onScroll: ((CGFloat) -> Void)?
    /// A Shelf key while the panel is key (S17); false when it did nothing.
    var onKey: ((ShelfKey) -> Bool)?
    var onMenu: ((CGPoint) -> NSMenu?)?
    /// The height of the drawer's top band whose mouse-downs stay SwiftUI's: the header that moves the Shelf (S7).
    var headerBand: CGFloat = 0
    /// The Shelf is its tab (S9): every mouse-down is the tab's, to bring it back.
    var isTab = false
    /// The collapsed drawer (R29): a drag anywhere off its stack moves the Shelf; the stack drags the files out.
    var movesOffTheStack = false
    /// A drag off the collapsed stack moved the Shelf and let go.
    var onMoveEnded: (() -> Void)?
    /// Where the pointer is on screen (`ShelfDesktop.pointer`).
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    /// Takes a drag out's items in place of AppKit's session (`ShelfDesktop.beginsDrag`).
    var beginsDrag: (@MainActor ([NSDraggingItem]) -> Void)?

    private let fill = CALayer()
    private var mouseDownEvent: NSEvent?
    /// A press off the collapsed stack (R29), and whether its drag has passed the threshold and moves the panel.
    private var move: (drag: ShelfWindowDrag, started: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        // A near-invisible fill over the drawer: the window server passes drags over fully transparent pixels to
        // the window below (where Finder would move the file). The inset around it stays transparent, so the
        // shadow's margin neither takes drops nor clicks.
        wantsLayer = true
        fill.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        fill.cornerRadius = ShelfView.cornerRadius
        layer?.addSublayer(fill)
        placeFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The drawer's part of the view: the panel's inset is only room for the shadow.
    private var drawerRect: NSRect { bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeFill()
    }

    private func placeFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = drawerRect
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: drawerRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mouse-downs land here, not in the SwiftUI host above, so a drag can start anywhere on the drawer; only the
    /// top corners (the ✕ and the tuck chevron, else their corner moves the Shelf) and the header stay SwiftUI's, and
    /// the shadow's margin takes none.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard drawerRect.contains(local), let hit = super.hitTest(point) else { return nil }
        guard !isTab else { return self }
        let side = ShelfView.closeCorner
        let inHeader = local.y >= drawerRect.maxY - headerBand
        let inCorner = local.y >= drawerRect.maxY - side
            && (local.x >= drawerRect.maxX - side || local.x < drawerRect.minX + side)
        return inHeader || inCorner ? hit : self
    }

    override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }

    override func mouseExited(with event: NSEvent) { onPointerInside?(false) }

    /// From the drawer's top-left corner, y down, as the controller and `ShelfLayout` count.
    private func drawerPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x - drawerRect.minX, y: drawerRect.maxY - local.y)
    }

    // MARK: - Keys and the list (S8, S17)

    override var acceptsFirstResponder: Bool { true }

    /// Keys reach the panel only while it is key, after a click: never a key monitor (S17, S25).
    override func keyDown(with event: NSEvent) {
        if let key = shelfKey(event), onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    /// No menu item takes ⌘A or ⌘C (the app has no Edit menu), so they reach the view as key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, let key = shelfKey(event), key == .selectAll || key == .copy else {
            return super.performKeyEquivalent(with: event)
        }
        return onKey?(key) ?? false
    }

    private func shelfKey(_ event: NSEvent) -> ShelfKey? {
        // `charactersIgnoringModifiers` raises for anything but a key event.
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers else { return nil }
        return ShelfKey.key(characters: characters, modifiers: DragMonitor.modifierSet(event.modifierFlags))
    }

    /// Reaches the panel only while it is key, as `keyDown` does: the key pill's ⌘ (R30).
    override func flagsChanged(with event: NSEvent) {
        onCommandChanged?(event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * ShelfLayout.rowHeight
        onScroll?(delta)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu?(drawerPoint(event)) }

    // MARK: - Drag source (S12, S13)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownEvent = event
        move = nil
        if movesOffTheStack, !isTab, !isOnStack(event), let window {
            move = (ShelfWindowDrag(mouse: pointer(), origin: window.frame.origin), false)
        }
        onPress?(drawerPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        let moved = move?.started == true
        move = nil
        if moved {
            onMoveEnded?()
            return
        }
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(drawerPoint(event), DragMonitor.modifierSet(event.modifierFlags))
    }

    /// On the tab a press that wanders is still a click: nothing drags out of it (S9). Off the collapsed stack it
    /// moves the Shelf (R29), as the header does.
    override func mouseDragged(with event: NSEvent) {
        if let move, move.started, let window { return move.drag.follow(window, to: pointer()) }
        guard !isTab, let down = mouseDownEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return }
        mouseDownEvent = nil
        if let drag = move?.drag, let window {
            move?.started = true
            return drag.follow(window, to: pointer())
        }
        let items = draggingItems(at: convert(start, from: nil))
        guard !items.isEmpty else { return }
        if let beginsDrag { return beginsDrag(items) }
        // The source must be this view: the drop target refuses drags whose source it is (S13).
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.draggingFormation = .stack
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private static let dragThreshold: CGFloat = 3

    /// The stack is a `ShelfStackArea` in the SwiftUI host, so this follows its layout (one thumbnail or the fan).
    private func isOnStack(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        return super.hitTest(superview.convert(event.locationInWindow, from: nil)) is ShelfStackArea.Area
    }

    /// One item per file, its URL as the pasteboard writer, each image centred on `point` (in this view).
    func draggingItems(at point: NSPoint) -> [NSDraggingItem] {
        let side = ShelfController.thumbnailSide
        let frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        return (onDragOut?() ?? []).map { url, image in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
    }

    // MARK: - Drag destination

    override func dropLeft() {
        onDropHover?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDropHover?(false)
    }

    override func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        let takes = accepts(sender)
        onDropHover?(takes)
        return takes ? .copy : []
    }

    /// Text, web links, browser images and file promises carry no file URL; a drag out of the Shelf comes back
    /// here only to stay (S13).
    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard (sender.draggingSource as AnyObject?) !== self,
              drawerRect.contains(convert(sender.draggingLocation, from: nil)) else { return false }
        return sender.draggingPasteboard.hasFileURLs
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onDropHover?(false) }
        guard accepts(sender) else { return false }
        let urls = sender.draggingPasteboard.fileURLs
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

extension ShelfItemsView: NSDraggingSource {
    /// ⌘ as it is when AppKit asks; whether AppKit asks again when ⌘ changes mid-drag is S12's live probe.
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragOutMask(commandHeld: NSEvent.modifierFlags.contains(.command))
    }

    /// The key pill follows the ⌘ each request sees (R30).
    func dragOutMask(commandHeld: Bool) -> NSDragOperation {
        onCommandChanged?(commandHeld)
        return ShelfDragOperations.mask(commandHeld: commandHeld)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragOutEnded?(operation)
    }
}
