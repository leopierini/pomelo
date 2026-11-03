import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI
import Testing
@testable import Pomelo

/// The audit behind `--eval-accessibility` walks a window's own accessibility tree in-process (no permission). SwiftUI
/// builds its tree only for a connected assistive app (P146), so these tests use AppKit views, which always answer.
@MainActor
@Suite struct AccessibilityAuditTests {
    private func findings(_ view: NSView) -> [AccessibilityFinding] {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.frame = NSRect(x: 10, y: 10, width: 80, height: 40)
        container.addSubview(view)
        return findings(container: container)
    }

    private func findings(container: NSView, style: NSWindow.StyleMask = [.borderless]) -> [AccessibilityFinding] {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 200, height: 100),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        // A table makes its rows as it draws.
        window.displayIfNeeded()
        defer { window.close() }
        return AccessibilityAudit.findings(in: window)
    }

    /// `view` as the app's own AppKit views are met: inside a hosting view, whose accessibility tree is empty in-process,
    /// so the walk reaches the view through the subviews.
    private func hostedFindings(_ view: @escaping @MainActor () -> NSView) -> [AccessibilityFinding] {
        let host = NSHostingView(rootView: Hosted(make: view).frame(width: 80, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return findings(container: container)
    }

    /// Drawn, not a symbol: AppKit names a symbol image after its symbol ("xmark" reads "Close").
    private var icon: NSImage { Self.drawnIcon }

    fileprivate static var drawnIcon: NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }

    @Test func anUnlabeledIconButtonIsAFinding() {
        let found = findings(NSButton(image: icon, target: nil, action: nil))
        #expect(found.count == 1, "\(found)")
        #expect(found.first?.role == NSAccessibility.Role.button.rawValue)
    }

    @Test func aLabeledIconButtonIsNot() {
        let button = NSButton(image: icon, target: nil, action: nil)
        button.setAccessibilityLabel("Close")
        let found = findings(button)
        #expect(found.isEmpty, "\(found)")
    }

    /// The cell stands for an AppKit control in the tree, so that is where a decorative image is hidden.
    @Test func decorativeImagesAreNotFindings() {
        let found = hostedFindings {
            let image = NSImageView(image: Self.drawnIcon)
            image.cell?.setAccessibilityElement(false)
            return image
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func anUnlabeledHostedImageIsAFinding() {
        let found = hostedFindings { NSImageView(image: Self.drawnIcon) }
        #expect(found.map(\.role) == [NSAccessibility.Role.image.rawValue], "\(found)")
    }

    @Test func anUnlabeledImageIsAFinding() {
        let found = findings(NSImageView(image: icon))
        #expect(found.map(\.role) == [NSAccessibility.Role.image.rawValue], "\(found)")
    }

    @Test func aLabelWithASeparatorGlyphIsAFinding() {
        let found = findings(NSButton(title: "Convert \u{00B7} Tools", target: nil, action: nil))
        #expect(found.count == 1, "\(found)")
        #expect(found.first?.problem.contains("separator") == true, "\(found)")
    }

    @Test func hiddenViewsAreSkipped() {
        let found = hostedFindings {
            let button = NSButton(image: Self.drawnIcon, target: nil, action: nil)
            button.isHidden = true
            return button
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aHiddenContainerHidesItsControls() {
        let found = hostedFindings {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
            container.addSubview(NSButton(image: Self.drawnIcon, target: nil, action: nil))
            container.isHidden = true
            return container
        }
        #expect(found.isEmpty, "\(found)")
    }

    /// An AppKit view a SwiftUI view hosts is reached through the subviews, past the hosting view's empty tree.
    @Test func anAppKitControlInsideSwiftUIIsWalked() {
        let found = hostedFindings { NSButton(image: Self.drawnIcon, target: nil, action: nil) }
        #expect(found.map(\.role) == [NSAccessibility.Role.button.rawValue], "\(found)")
    }

    /// SwiftUI labels the AppKit view behind its own controls in the tree it builds for an assistive app, which an
    /// in-process walk cannot read: such views are not judged.
    @Test func aSwiftUIControlIsLeftToSwiftUI() {
        let host = NSHostingView(rootView: Toggle("Enabled", isOn: .constant(true)).toggleStyle(.switch).labelsHidden()
            .frame(width: 80, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let container = NSView(frame: host.frame)
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let found = findings(container: container)
        #expect(found.isEmpty, "\(found)")
    }

    /// A table answers its rows as NSTableRow elements, which only the old attribute API reads: its row views stand in.
    @Test func aControlInATableRowIsWalked() {
        let source = OneButtonRows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("only")))
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        let container = NSView(frame: table.frame)
        container.addSubview(scroll)
        let found = withExtendedLifetime(source) { findings(container: container) }
        #expect(found.map(\.role) == [NSAccessibility.Role.button.rawValue], "\(found)")
    }

    /// The Resize panel (P197) as the audit opens it: nothing unlabeled or with a separator in the AppKit it draws, and
    /// the strings the view gives VoiceOver for the lock and chips. Whether the view applies them is the source lint's
    /// (`pomelo-evals a11y-lint`), since SwiftUI's tree can't be read in-process (P146).
    @Test func theResizePanelIsLabeledAndSaysTheLock() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-audit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let controller = EditorController(
            settings: settings, perform: { _, _, _, _ in preconditionFailure("the audit saved an edit") },
            release: { _, _ in }, desktop: .offScreen
        )
        defer { controller.cancel() }
        let preset = try #require(EditorSessions.preset(for: .resize, settings: settings.settings))
        controller.open(EditorRequest(kind: .resize, preset: preset, files: [photo],
                                      anchor: AccessibilityEval.offScreen, flags: []))
        let session = try #require(controller.session as? ResizeSession)
        #expect(await eventually { session.isLoaded })
        controller.panel.displayIfNeeded()
        let found = AccessibilityAudit.findings(in: controller.panel)
        #expect(found.isEmpty, "\(found)")

        func spokenLock() -> String {
            "\(ResizeLock.label), \(ResizeLock.value(locked: session.model.isLocked))"
        }
        #expect(spokenLock() == "Keep proportions, on")
        session.model.toggleLock()
        #expect(spokenLock() == "Keep proportions, off")
        #expect(session.model.chips.map(\.spokenTitle) == ["50 %", "25 %", "1080 by 1080", "1920 wide"])
    }

    /// The Rotate panel (P198) as the audit opens it, the four buttons' names and the preview's value in words, with no
    /// separator (P32). As for Resize, whether the view applies them is the source lint's (P146).
    @Test func theRotatePanelNamesItsButtonsAndSaysTheTurn() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-audit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let controller = EditorController(
            settings: settings, perform: { _, _, _, _ in preconditionFailure("the audit saved an edit") },
            release: { _, _ in }, desktop: .offScreen
        )
        defer { controller.cancel() }
        let preset = try #require(EditorSessions.preset(for: .rotate, settings: settings.settings))
        controller.open(EditorRequest(kind: .rotate, preset: preset, files: [photo],
                                      anchor: AccessibilityEval.offScreen, flags: []))
        let session = try #require(controller.session as? RotateSession)
        #expect(await eventually { session.preview != nil })
        controller.panel.displayIfNeeded()
        let found = AccessibilityAudit.findings(in: controller.panel)
        #expect(found.isEmpty, "\(found)")

        #expect(RotateAction.allCases.map(\.title) == ["Rotate Left", "Rotate Right", "Flip Horizontal", "Flip Vertical"])
        #expect(RotatePreview.label == "Preview")
        func spoken(_ turns: Int, _ flip: Bool) -> String {
            RotatePreview.value(RotateSpec(quarterTurns: turns, flipHorizontal: flip))
        }
        #expect(spoken(0, false) == "Not turned")
        #expect(spoken(1, false) == "Turned right")
        #expect(spoken(2, false) == "Upside down")
        #expect(spoken(3, false) == "Turned left")
        #expect(spoken(0, true) == "Flipped horizontally")
        #expect(spoken(2, true) == "Flipped vertically")
        #expect(spoken(1, true) == "Turned right and flipped horizontally")
        #expect(spoken(3, true) == "Turned left and flipped horizontally")
        session.perform(.rotateRight)
        #expect(RotatePreview.value(session.spec) == "Turned right")
    }

    /// The Shelf (S22) in its states with files, its tab included: nothing unlabeled or with a separator in the AppKit it draws, and
    /// the strings and actions the view gives VoiceOver for the drawer, the stack and the rows. Whether the view
    /// applies them is the source lint's, since SwiftUI's tree can't be read in-process (P146).
    @Test func theShelfIsLabeledInEveryState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-audit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["photo.heic", "report.pdf", "c.txt", "d.txt", "e.txt"].map { name in
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            try Data(repeating: 1, count: 1_000).write(to: url)
            return url
        }
        let size = ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file)
        let shelf = ShelfController(desktop: .offScreen, pasteboard: .withUniqueName(), reveal: { _ in },
                                    preview: RecordingPreview())
        defer { shelf.close() }
        func audit(_ state: String) {
            shelf.panel.displayIfNeeded()
            let found = AccessibilityAudit.findings(in: shelf.panel)
            #expect(found.isEmpty, "\(state): \(found)")
        }

        shelf.summon(.tools(files: [files[0]], at: AccessibilityEval.offScreen))
        audit("one")
        #expect(shelf.model.accessibilityValue == "photo.heic, \(size)")
        #expect(shelf.model.title == "photo.heic")
        #expect(ShelfSpoken.stackValue(of: shelf.model) == size)

        shelf.add(Array(files.dropFirst()))
        audit("many")
        #expect(ShelfCopy.shelf == "Shelf")
        #expect(shelf.model.title == "5 files")
        #expect(shelf.model.accessibilityValue == "5 files, \(ByteCountFormatter.string(fromByteCount: 5_000, countStyle: .file))")
        #expect(ShelfSpoken.stackValue(of: shelf.model) == "photo.heic, report.pdf and 3 more")
        #expect(ShelfCopy.dragHint == "Drag to copy. Hold Command to move.")
        #expect(ShelfAction.stack.map(\.title)
            == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Expand", "Tuck Away", "Clear Shelf"])

        shelf.expand()
        audit("expanded")
        #expect(shelf.model.items.map(\.name) == ["photo.heic", "report.pdf", "c.txt", "d.txt", "e.txt"])
        #expect(shelf.model.items.map(\.detail) == Array(repeating: size, count: 5))
        #expect(ShelfAction.row.map(\.title)
            == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Remove from Shelf"])

        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[1])
        await shelf.resolve(shelf.model.items.map(\.id))
        audit("missing")
        #expect(shelf.model.items[1].detail == "Can't be found")
        shelf.collapse()
        audit("missing, collapsed")
        shelf.tuck()
        audit("tucked")
        #expect(shelf.isTucked)
        #expect(ShelfCopy.tab(5) == "Shelf, 5 files")
        #expect(ShelfCopy.tab(1) == "Shelf, 1 file")
        #expect(ShelfCopy.bringBack == "Bring Back")
    }

    @Test func windowButtonsAreNamedByTheirSubrole() {
        let found = findings(container: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                             style: [.titled, .closable, .miniaturizable, .resizable])
        #expect(found.isEmpty, "\(found)")
    }
}

private struct Hosted: NSViewRepresentable {
    let make: @MainActor () -> NSView

    func makeNSView(context: Context) -> NSView { make() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class OneButtonRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSButton(image: AccessibilityAuditTests.drawnIcon, target: nil, action: nil)
    }
}
