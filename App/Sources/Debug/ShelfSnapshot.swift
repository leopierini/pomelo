// DEBUG only: `Pomelo --snapshot-shelf <state> <out.png> [light|dark] <file>…` renders the Shelf (S8) holding the
// files in an off-screen window on a grey backdrop (the header's drag area is an AppKit view, which ImageRenderer
// draws as a placeholder), writes a PNG and exits. Glass falls back to the solid background. Copy the files into a
// temporary folder first: a file under ~/Desktop would make macOS ask for that folder.
#if DEBUG
import AppKit
import PomeloUIModel
import SwiftUI

enum ShelfSnapshot {
    static let flag = "--snapshot-shelf"

    enum State: String, CaseIterable {
        /// One file, several, or (with no files) the empty drawer, with files over it; the list of several;
        /// greyed files (S8): one file's card, or the list with the first file lost and the second in the Trash; the
        /// tab the files tuck into (S9); and the stack of one file or several with ⌘ held, its key pill on Move (R30).
        case empty, one, many, hover, expanded, missing, tucked, command
    }

    static var usage: String {
        "usage: Pomelo \(flag) <\(State.allCases.map(\.rawValue).joined(separator: "|"))> <out.png> [light|dark] <file>…"
    }

    @MainActor
    static func runIfRequested(arguments: [String]) -> Bool {
        guard var rest = DebugOutput.arguments(after: flag, in: arguments) else { return false }
        guard rest.count >= 2, let state = State(rawValue: rest[0]) else { DebugOutput.fail(usage, 64) }
        let output = URL(fileURLWithPath: rest[1])
        rest.removeFirst(2)
        let dark = DebugOutput.takeScheme(from: &rest, at: 0)
        let files = rest.map { URL(fileURLWithPath: $0) }
        switch state {
        case .empty where !files.isEmpty, .one where files.count != 1, .many where files.count < 2,
             .expanded where files.count < 2, .missing where files.isEmpty, .tucked where files.isEmpty,
             .command where files.isEmpty:
            DebugOutput.fail(usage, 64)
        default:
            break
        }
        Task { await render(state, files: files, dark: dark, to: output) }
        return true
    }

    @MainActor
    private static func render(_ state: State, files: [URL], dark: Bool, to output: URL) async {
        let shelf = ShelfController(desktop: .offScreen, files: state == .missing ? lost(files) : .live,
                                    pasteboard: .withUniqueName(), reveal: { _ in })
        let point = CGPoint(x: -29_500, y: -29_500)
        if files.isEmpty {
            shelf.summon(.shake(at: point))
        } else {
            shelf.summon(.tools(files: files, at: point))
        }
        if state == .missing { await shelf.resolve(shelf.model.items.map(\.id)) }
        if state == .expanded || (state == .missing && files.count > 1) {
            shelf.expand()
            if let first = shelf.model.items.first { shelf.select(first.id) }
            if shelf.model.items.count > 2 { shelf.select(shelf.model.items[2].id, modifiers: [.command]) }
        }
        await shelf.thumbnailsLoaded()
        if state == .tucked { shelf.tuck() }
        if state == .hover { shelf.dropHoverChanged(true) }
        if state == .command { shelf.commandChanged(held: true) }
        let size = ShelfPanel.panelSize(for: ShelfLayout.size(shelf.presentation))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ShelfView(controller: shelf)
            .frame(width: size.width, height: size.height)
            .padding(16)
            .background(Color(white: dark ? 0.25 : 0.7))
            .environment(\.wheelSolidBackground, true))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        await DebugOutput.writeDisplayOffScreen(host, in: window, appearance: appearance, to: output)
        print(output.path)
        exit(0)
    }

    /// The files as the Shelf would find them after the first was deleted and the second trashed; nothing is touched.
    private static func lost(_ files: [URL]) -> ShelfFiles {
        let live = ShelfFiles.live
        return ShelfFiles(item: live.item, bookmark: { _ in nil }, resolve: { item in
            switch files.firstIndex(of: item.url) {
            case 0: (item.url, item.name, .missing)
            case 1: (item.url, item.name, .inTrash)
            default: live.resolve(item)
            }
        })
    }
}
#endif
