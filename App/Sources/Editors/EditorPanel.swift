// The editor's window (P27): a borderless, non-activating floating panel that becomes key, so the editor takes
// typing and Esc while Finder stays the active app; Pomelo is never activated. The app has no Edit menu, so the
// panel maps the standard editing shortcuts itself.
import AppKit
import PomeloUIModel
import SwiftUI

final class EditorPanel: NSPanel {
    /// Esc, ⌘W or ⌘. went down in the panel.
    var onCancel: (() -> Void)?
    /// While a saved job runs, ⌘Z and ⇧⌘Z are taken and do nothing: the editor keeps showing the choices it sent.
    var freezesUndo = false
    /// The chrome. Internal so the controller can replace its root view and the tests can check it.
    let host = EditorHostingView(rootView: EditorChrome())

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: EditorLayout.width(for: .trim), height: 320),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Setting `isFloatingPanel` sets the level to `.floating`, so it comes first.
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Only the header moves the panel (`EditorDragArea`): a drag on a control or a crop handle must not.
        isMovableByWindowBackground = false
        embed(host)
        roundCorners()
    }

    /// While the panel is key, the window server draws its shadow rim around the whole content, which reached the
    /// window's square corners: an outline around the rounded card (macOS 27.2). The content view's layer is rounded
    /// like the card.
    private func roundCorners() {
        guard let view = contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = EditorLayout.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.cancels(event) {
            onCancel?()
            return true
        }
        if let action = Self.standardAction(for: event) {
            if freezesUndo, action == Selector(("undo:")) || action == Selector(("redo:")) { return true }
            if NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The Edit menu's actions an agent app without one would lose: ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z.
    static func standardAction(for event: NSEvent) -> Selector? {
        guard let (modifiers, key) = shortcut(of: event) else { return nil }
        switch (modifiers, key) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }

    /// ⌘W and ⌘. close the editor, as they close a window or stop an operation elsewhere.
    static func cancels(_ event: NSEvent) -> Bool {
        guard let (modifiers, key) = shortcut(of: event), modifiers == [.command] else { return false }
        return key == "w" || key == "."
    }

    private static func shortcut(of event: NSEvent) -> (NSEvent.ModifierFlags, String)? {
        // `charactersIgnoringModifiers` raises for anything but a key event.
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers else { return nil }
        // It still applies Shift ("Z" for ⇧⌘Z).
        return (event.modifierFlags.intersection([.command, .shift, .option, .control]), characters.lowercased())
    }
}

/// P22: a click on a control of the panel while it is not key works at once (and makes it key).
final class EditorHostingView: NSHostingView<EditorChrome> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The header's background: dragging it moves the panel.
struct EditorDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
