// What the Shelf offers on its stack and rows (S17, S22): the context menu, VoiceOver's actions and Quick Look. The
// actions act on the selection while the list shows one, else on every item; none of them touches a file (S14).
import AppKit
import PomeloUIModel
import QuickLookUI

enum ShelfAction: Hashable, CaseIterable {
    case openWheel, quickLook, showInFinder, copy, remove, expand, tuckAway, bringBack, clear

    var title: String {
        switch self {
        case .openWheel: ShelfCopy.openWheel
        case .quickLook: ShelfCopy.quickLook
        case .showInFinder: ShelfCopy.showInFinder
        case .copy: ShelfCopy.copy
        case .remove: ShelfCopy.remove
        case .expand: ShelfCopy.expand
        case .tuckAway: ShelfCopy.tuckAway
        case .bringBack: ShelfCopy.bringBack
        case .clear: ShelfCopy.clearShelf
        }
    }

    /// VoiceOver's actions on the collapsed stack (S22).
    static let stack: [ShelfAction] = [.openWheel, .quickLook, .showInFinder, .copy, .expand, .tuckAway, .clear]
    /// VoiceOver's actions on a row of the list (S22).
    static let row: [ShelfAction] = [.openWheel, .quickLook, .showInFinder, .copy, .remove]

    /// The context menu (S17), in groups; Remove only on a row, Bring Back instead of Tuck Away on the tab.
    static func menu(onRow: Bool, tucked: Bool) -> [[ShelfAction]] {
        [[.openWheel], [.quickLook, .showInFinder, .copy] + (onRow ? [.remove] : []),
         [tucked ? .bringBack : .tuckAway, .clear]]
    }
}

/// What VoiceOver reads for the stack (S22): "5 files" with its first names, or one file's name with its size or
/// why it is greyed.
enum ShelfSpoken {
    static func stackValue(of model: ShelfModel) -> String {
        model.items.count == 1 ? model.items[0].detail ?? "" : model.stackAccessibilityValue
    }
}

/// A menu item that runs a closure.
final class ShelfMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

/// Quick Look for the Shelf (S17). A parameter of the controller, so the tests never show the real panel.
@MainActor
protocol ShelfPreviewing: AnyObject {
    var isShown: Bool { get }
    func show(_ urls: [URL])
    func hide()
    /// Gives the keys back to the app that was in front before the preview made Pomelo active; true when it did.
    func handBackActivation() -> Bool
    /// Forgets that app without activating it: the person moved on to another Pomelo window (M8).
    func forgetActivation()
}

/// The live Quick Look panel. Its controller is the Shelf's panel, found through the key window's responder chain.
///
/// S17's probe, decided from AppKit's rules (no live check is possible unattended): `QLPreviewPanel` is an `NSPanel`,
/// whose `hidesOnDeactivate` keeps it hidden while its app is inactive, and it follows the key and main windows to find
/// its controller. The Shelf's panel is non-activating and never main, so Pomelo is never active while it is key and
/// the preview can't be relied on to show. Pomelo activates for it (the person asked for a window) and keeps the Shelf
/// key, so Space, Esc and the arrows stay the Shelf's and the preview follows its selection.
@MainActor
final class ShelfPreview: NSObject, ShelfPreviewing {
    /// The Shelf's panel, which controls the preview while it is key.
    weak var window: NSWindow?
    private var urls: [URL] = []
    /// The app in front when the preview activated Pomelo, to give the keys back to when the Shelf lets them go.
    private var previousApp: NSRunningApplication?

    var isShown: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        NSApp.activate()
        window?.makeKey()
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        guard isShown else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    func forgetActivation() {
        previousApp = nil
    }

    func handBackActivation() -> Bool {
        defer { previousApp = nil }
        // Someone who clicked another app meanwhile already took the keys elsewhere.
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return false }
        return previousApp.activate()
    }
}

// Quick Look calls its data source on the main thread.
extension ShelfPreview: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
