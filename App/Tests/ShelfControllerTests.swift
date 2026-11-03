import AppKit
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-shelf-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func makeFiles(_ names: String..., in dir: URL) throws -> [URL] {
    try names.map { name in
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("shelf \(name)".utf8).write(to: url)
        return url
    }
}

/// Stands in for AppKit's dragging info, so the drop target is asked without a real drag.
final class StubDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingLocation: NSPoint

    /// `location` is in the panel's window; the default is inside the drawer in every state.
    @MainActor
    init(pasteboard: NSPasteboard, source: Any? = nil, location: NSPoint = NSPoint(x: 60, y: 60)) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// The Shelf's panel, drops and leave rules (S7 to S11, S24), on an off-screen desktop and a virtual clock: nothing
/// here starts a real drag, posts an event, takes key focus or shows on a real screen.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfControllerTests {
    private let clock = ManualClock()
    /// The off-screen desktop's cursor: the middle of its visible frame.
    private let cursor = CGPoint(x: -29_500, y: -29_500)

    private func makeShelf() -> ShelfController {
        ShelfController(desktop: .offScreen, clock: clock.timerClock, pasteboard: .withUniqueName(), reveal: { _ in },
                        preview: RecordingPreview())
    }

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // MARK: The panel (S24)

    @Test func panelConfiguration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        let panel = shelf.panel
        #expect(panel.level == .floating)
        #expect(panel.isFloatingPanel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless) || panel.styleMask == [.nonactivatingPanel])
        #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.hasShadow == false)
        for summon: ShelfController.Summon in [.shake(at: cursor), .tools(files: files, at: cursor), .menu] {
            shelf.summon(summon)
            #expect(shelf.isShown)
            #expect(!panel.isKeyWindow)
            #expect(!panel.isMainWindow)
        }
        shelf.close()
    }

    @Test func shakeShowsEmptyAroundTheCursor() {
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        #expect(shelf.isShown)
        #expect(shelf.panel.isVisible)
        #expect(shelf.presentation == .empty)
        #expect(shelf.model.isEmpty)
        #expect(shelf.drawerFrame.size == ShelfLayout.size(.empty))
        #expect(shelf.drawerFrame.contains(cursor))
        #expect(centre(shelf.drawerFrame) == cursor)
        // The panel holds the drawer with room for its shadow and the drop-hover scale.
        #expect(shelf.panel.frame.contains(shelf.drawerFrame))
        shelf.close()
    }

    @Test func toolsSummonShowsTheFilesAtTheCentre() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        let point = CGPoint(x: -29_600, y: -29_400)
        shelf.summon(.tools(files: files, at: point))
        #expect(shelf.isShown)
        #expect(shelf.model.items.map(\.url) == files)
        #expect(shelf.presentation == .collapsed)
        #expect(centre(shelf.drawerFrame) == point)
        shelf.close()
    }

    @Test func secondSummonMovesIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        let second = CGPoint(x: -29_300, y: -29_700)
        shelf.summon(.shake(at: second))
        #expect(centre(shelf.drawerFrame) == second)
        let third = CGPoint(x: -29_700, y: -29_300)
        shelf.summon(.tools(files: files, at: third))
        #expect(centre(shelf.drawerFrame) == third)
        // The menu leaves a visible Shelf where it is.
        shelf.summon(.menu)
        #expect(centre(shelf.drawerFrame) == third)
        shelf.close()
    }

    @Test func menuEmptyStaysUntilClosed() async {
        let shelf = makeShelf()
        shelf.summon(.menu)
        #expect(shelf.isShown)
        #expect(shelf.presentation == .empty)
        shelf.dragEnded()
        await clock.advance(by: .seconds(2))
        #expect(shelf.isShown)
        shelf.close()
        #expect(!shelf.isShown)
        #expect(!shelf.panel.isVisible)
    }

    // MARK: Leaving (S9)

    @Test func emptyShakeShelfLeavesAfterTheDragWithoutADrop() async {
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        await clock.advance(by: .seconds(1))
        #expect(shelf.isShown)
        shelf.dragEnded()
        await clock.advance(by: WheelController.closeDelay - .milliseconds(1))
        #expect(shelf.isShown)
        await clock.advance(by: .milliseconds(1))
        #expect(!shelf.isShown)
        #expect(!shelf.panel.isVisible)
    }

    @Test func dropBeforeButtonUpKeepsShakeShelf() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        shelf.add(files)
        shelf.dragEnded()
        await clock.advance(by: .seconds(2))
        #expect(shelf.isShown)
        #expect(shelf.model.items.map(\.url) == files)
        shelf.close()
    }

    /// Review Focus 1: the drop and the button-up poll arrive in either order.
    @Test func dropAfterButtonUpKeepsShakeShelf() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        shelf.dragEnded()
        await clock.advance(by: .milliseconds(200))
        #expect(shelf.isShown)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        #expect(shelf.panel.itemsView.performDragOperation(StubDrag(pasteboard: pasteboard)))
        await clock.advance(by: .seconds(2))
        #expect(shelf.isShown)
        #expect(shelf.model.items.map(\.url) == files)
        shelf.close()
    }

    // MARK: Adding (S11)

    @Test func addDeduplicatesAndBlinks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        var announced: [String] = []
        let shelf = ShelfController(desktop: .offScreen, announce: { announced.append($0) }, clock: clock.timerClock,
                                    pasteboard: .withUniqueName(), reveal: { _ in }, preview: RecordingPreview())
        shelf.add(files)
        #expect(shelf.model.items.count == 2)
        #expect(shelf.blink == nil)
        #expect(announced == ["Added 2 files to the Shelf"])
        let first = shelf.model.items[0].id

        // The same file by another spelling of its path is the same item (its identity, not its URL).
        let respelled = URL(fileURLWithPath: dir.path + "/./a.txt")
        shelf.add([respelled])
        #expect(shelf.model.items.count == 2)
        #expect(shelf.blink?.ids == [first])
        let serial = shelf.blink?.serial
        #expect(announced.count == 1)

        // A second blink of the same item is a new one for the view.
        shelf.add([files[0]])
        #expect(shelf.blink?.ids == [first])
        #expect(shelf.blink?.serial != serial)

        // Bookmarks are made off the main thread after the drop.
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
    }

    @Test func dropTargetTakesFileURLsOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.shake(at: cursor))
        let view = shelf.panel.itemsView
        #expect(view.registeredDraggedTypes == [.fileURL])

        let text = NSPasteboard.withUniqueName()
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("https://example.com", forType: .string)
        #expect(view.draggingEntered(StubDrag(pasteboard: text)) == [])
        #expect(!shelf.isDropTargeted)
        #expect(!view.performDragOperation(StubDrag(pasteboard: text)))
        #expect(shelf.model.isEmpty)

        let web = NSPasteboard.withUniqueName()
        defer { web.releaseGlobally() }
        web.clearContents()
        web.writeObjects([URL(string: "https://example.com/a.png")! as NSURL])
        #expect(view.draggingEntered(StubDrag(pasteboard: web)) == [])

        let urls = NSPasteboard.withUniqueName()
        defer { urls.releaseGlobally() }
        urls.clearContents()
        urls.writeObjects(files.map { $0 as NSURL })
        #expect(view.draggingEntered(StubDrag(pasteboard: urls)) == .copy)
        #expect(view.draggingUpdated(StubDrag(pasteboard: urls)) == .copy)
        #expect(shelf.isDropTargeted)
        view.draggingExited(StubDrag(pasteboard: urls))
        #expect(!shelf.isDropTargeted)
        #expect(view.performDragOperation(StubDrag(pasteboard: urls)))
        #expect(shelf.model.items.map(\.url) == files)
        #expect(!shelf.isDropTargeted)
        shelf.close()
    }

    @Test func dropTargetRefusesItsOwnDrags() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let view = shelf.panel.itemsView
        let urls = NSPasteboard.withUniqueName()
        defer { urls.releaseGlobally() }
        urls.clearContents()
        urls.writeObjects(files.map { $0 as NSURL })
        #expect(view.draggingEntered(StubDrag(pasteboard: urls, source: view)) == [])
        #expect(!shelf.isDropTargeted)
        #expect(!view.performDragOperation(StubDrag(pasteboard: urls, source: view)))
        #expect(shelf.model.items.count == 1)
        shelf.close()
    }

    // MARK: Clearing (S14)

    @Test func clearForgetsAndLeaves() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .contentModificationDateKey]
        func stamp(_ url: URL) throws -> (String, Date?) {
            let values = try url.resourceValues(forKeys: keys)
            return (String(describing: values.fileResourceIdentifier), values.contentModificationDate)
        }
        let before = try files.map(stamp)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.clear()
        #expect(shelf.model.isEmpty)
        #expect(!shelf.isShown)
        #expect(!shelf.panel.isVisible)
        let after = try files.map(stamp)
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.txt", "b.txt"])
    }
}

/// Quick Look's stand-in: records what it was asked to show, never the real panel.
@MainActor
final class RecordingPreview: ShelfPreviewing {
    private(set) var shown: [[URL]] = []
    private(set) var isShown = false
    /// Showing stands for Pomelo going active; a hand-back gives that up once.
    private(set) var activated = false
    private(set) var handBacks = 0

    func show(_ urls: [URL]) {
        shown.append(urls)
        isShown = true
        activated = true
    }

    func hide() { isShown = false }

    func handBackActivation() -> Bool {
        guard activated else { return false }
        activated = false
        handBacks += 1
        return true
    }

    func forgetActivation() { activated = false }
}

/// The list, its keys, the context menu and Quick Look (S8, S14, S17, S22), on an off-screen desktop with an injected
/// pasteboard, reveal and preview: nothing here touches the clipboard, Finder or the real Quick Look panel.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfListTests {
    private let clock = ManualClock()
    private let cursor = CGPoint(x: -29_500, y: -29_500)
    private let pasteboard = NSPasteboard.withUniqueName()
    private let preview = RecordingPreview()

    private func makeShelf(announce: @escaping (String) -> Void = { _ in }, files: ShelfFiles = .live,
                           reveal: @escaping ([URL]) -> Void = { _ in }) -> ShelfController {
        ShelfController(desktop: .offScreen, files: files, announce: announce, clock: clock.timerClock,
                        pasteboard: pasteboard, reveal: reveal, preview: preview)
    }

    /// A point on row `index` of the expanded list, from the drawer's top-left corner.
    private func row(_ index: Int) -> CGPoint {
        CGPoint(x: 60, y: ShelfLayout.headerHeight + ShelfLayout.listPadding / 2 + ShelfLayout.rowHeight * (CGFloat(index) + 0.5))
    }

    private func pasteboardURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    // MARK: Expanding (S8)

    @Test func clickOnTheStackExpandsAndRowsSelect() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let top = shelf.drawerFrame.maxY
        let left = shelf.drawerFrame.minX
        shelf.clicked(at: CGPoint(x: 50, y: 60), modifiers: [])
        #expect(shelf.presentation == .expanded(rows: 3))
        // It grows down and right from the stack's top-left corner.
        #expect(shelf.drawerFrame.size == ShelfLayout.size(.expanded(rows: 3)))
        #expect(shelf.drawerFrame.maxY == top)
        #expect(shelf.drawerFrame.minX == left)

        let ids = shelf.model.items.map(\.id)
        shelf.clicked(at: row(1), modifiers: [])
        #expect(shelf.model.selection == [ids[1]])
        shelf.clicked(at: row(2), modifiers: [.command])
        #expect(shelf.model.selection == [ids[1], ids[2]])
        shelf.clicked(at: row(0), modifiers: [.shift])
        #expect(shelf.model.selection == Set(ids))
        // The header and the padding select nothing.
        shelf.clicked(at: CGPoint(x: 60, y: 10), modifiers: [])
        #expect(shelf.model.selection == Set(ids))
        shelf.collapse()
        #expect(shelf.presentation == .collapsed)
        #expect(shelf.drawerFrame.size == ShelfLayout.size(.collapsed))
        shelf.close()
    }

    @Test func keysDriveTheList() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a", "b", "c", "d", "e", "f", "g", "h", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let ids = shelf.model.items.map(\.id)
        // An arrow on the stack opens the list on the first item.
        #expect(shelf.handle(.down))
        #expect(shelf.presentation == .expanded(rows: 8))
        #expect(shelf.model.selection == [ids[0]])
        for _ in 0..<6 { shelf.handle(.down) }
        #expect(shelf.model.selection == [ids[6]])
        // The focused row is scrolled into view.
        #expect(shelf.scrollOffset == ShelfLayout.rowHeight)
        shelf.handle(.extendDown)
        #expect(shelf.model.selection == [ids[6], ids[7]])
        shelf.handle(.extendUp)
        shelf.handle(.extendUp)
        #expect(shelf.model.selection == [ids[5], ids[6]])
        shelf.handle(.up)
        #expect(shelf.model.selection == [ids[4]])
        shelf.handle(.selectAll)
        #expect(shelf.model.selection == Set(ids))
        shelf.scrolled(by: 1_000)
        #expect(shelf.scrollOffset == 0)
        shelf.scrolled(by: -1_000)
        #expect(shelf.scrollOffset == ShelfLayout.maxScrollOffset(count: 8))
        shelf.close()
    }

    @Test func escapeCollapsesThenCloses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.expand()
        shelf.quickLook()
        // Quick Look closes first, then the list collapses.
        #expect(shelf.handle(.escape))
        #expect(!preview.isShown)
        #expect(shelf.presentation == .expanded(rows: 2))
        shelf.handle(.escape)
        #expect(shelf.presentation == .collapsed)
        // With files it stays: Esc only gives the keys back.
        shelf.handle(.escape)
        #expect(shelf.isShown)
        #expect(shelf.model.items.count == 2)
        shelf.close()

        let empty = makeShelf()
        empty.summon(.menu)
        empty.handle(.escape)
        #expect(!empty.isShown)
    }

    /// Pomelo went active for Quick Look: the last Esc gives the keys back to the app before it, never leaving Pomelo
    /// active with no key window; the preview's own ✕ followed by Esc does the same.
    @Test func escapeAfterQuickLookHandsTheKeysBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.expand()
        shelf.handle(.quickLook)
        shelf.handle(.escape)
        #expect(!preview.isShown)
        #expect(preview.handBacks == 0)
        shelf.handle(.escape)
        #expect(shelf.presentation == .collapsed)
        #expect(preview.handBacks == 0)
        shelf.handle(.escape)
        #expect(preview.handBacks == 1)
        #expect(shelf.isShown)
        // Nothing more to give back.
        shelf.handle(.escape)
        #expect(preview.handBacks == 1)

        // Closed by the preview's own ✕: the next Esc on the collapsed Shelf hands back.
        shelf.handle(.quickLook)
        preview.hide()
        shelf.handle(.escape)
        #expect(preview.handBacks == 2)
        shelf.close()
    }

    /// M8: someone who moved on to Settings or an editor after Quick Look keeps Pomelo in front when the Shelf closes,
    /// and the app from before the preview is forgotten; with the keys still the Shelf's, close hands them back.
    @Test func closeLeavesTheKeysWithAnotherPomeloWindow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        var elsewhere = false
        var desktop = ShelfDesktop.offScreen
        desktop.anotherWindowIsKey = { elsewhere }
        let shelf = ShelfController(desktop: desktop, clock: clock.timerClock, pasteboard: pasteboard,
                                    reveal: { _ in }, preview: preview)
        shelf.summon(.tools(files: files, at: cursor))
        shelf.quickLook()
        elsewhere = true
        shelf.close()
        #expect(preview.handBacks == 0)
        #expect(!preview.activated)

        elsewhere = false
        shelf.summon(.menu)
        shelf.quickLook()
        shelf.close()
        #expect(preview.handBacks == 1)
    }

    // MARK: Copy, remove, the wheel, Quick Look (S14, S17)

    @Test func copyWritesTheURLsToThePasteboard() async throws {
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            pasteboard.releaseGlobally()
        }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[1])
        // Collapsed: every item but the missing one.
        #expect(shelf.handle(.copy))
        #expect(pasteboardURLs() == [files[0], files[2]])
        #expect(shelf.model.items[1].state == .missing)
        // Expanded with a selection: the selection.
        shelf.expand()
        shelf.select(shelf.model.items[2].id)
        shelf.perform(.copy)
        #expect(pasteboardURLs() == [files[2]])
        // Only missing items selected: the pasteboard is left as it was.
        shelf.select(shelf.model.items[1].id)
        shelf.copySelection()
        #expect(pasteboardURLs() == [files[2]])
        shelf.close()
    }

    @Test func removeForgetsAndNeverTouchesTheFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        // ⌫ on the stack removes nothing: Remove is a row's (S17).
        shelf.handle(.remove)
        #expect(shelf.model.items.count == 3)
        shelf.expand()
        let ids = shelf.model.items.map(\.id)
        shelf.select(ids[0])
        shelf.select(ids[2], modifiers: [.command])
        #expect(shelf.handle(.remove))
        #expect(shelf.model.items.map(\.url) == [files[1]])
        #expect(shelf.presentation == .expanded(rows: 1))
        // A row's Remove acts on that row.
        shelf.perform(.remove, onRow: shelf.model.items[0].id)
        #expect(shelf.model.isEmpty)
        #expect(!shelf.isShown)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
    }

    @Test func openWheelUsesTheSelectionElseAll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        var opened: [([URL], CGPoint)] = []
        let shelf = makeShelf()
        shelf.onOpenWheel = { opened.append(($0, $1)) }
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[2])
        shelf.handle(.openWheel)
        // Every present item, beside the Shelf.
        #expect(opened.last?.0 == [files[0], files[1]])
        let drawer = shelf.drawerFrame
        #expect(opened.last?.1 == ShelfLayout.wheelCentre(beside: drawer, wheelSize: WheelPanel.size,
                                                          visibleFrame: CGRect(x: -30_000, y: -30_000, width: 1_000, height: 1_000)))
        shelf.expand()
        shelf.select(shelf.model.items[1].id)
        shelf.perform(.openWheel)
        #expect(opened.last?.0 == [files[1]])
        // Nothing present selected: no wheel.
        shelf.select(shelf.model.items[2].id)
        shelf.openWheel()
        #expect(opened.count == 2)
        // ⌥⌘K goes to Finder unless the Shelf is key (S17); the off-screen panel never is.
        #expect(!shelf.takesClickModeHotkey())
        #expect(opened.count == 2)
        shelf.close()
    }

    /// ⌥⌘K on a key Shelf opens the wheel on it, and is Finder's again when nothing on it can open one.
    @Test func hotkeyIsTakenOnlyWhenAWheelOpens() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        var desktop = ShelfDesktop.offScreen
        desktop.isKey = { true }
        var opened: [[URL]] = []
        let shelf = ShelfController(desktop: desktop, announce: { _ in }, clock: clock.timerClock,
                                    pasteboard: pasteboard, reveal: { _ in }, preview: preview)
        shelf.onOpenWheel = { urls, _ in opened.append(urls) }
        #expect(!shelf.takesClickModeHotkey())
        shelf.summon(.tools(files: files, at: cursor))
        #expect(shelf.takesClickModeHotkey())
        #expect(opened == [files])
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[0])
        #expect(!shelf.takesClickModeHotkey())
        #expect(opened == [files])
        shelf.close()
    }

    @Test func quickLookShowsTheSelectionElseAllAndRevealToo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        var revealed: [[URL]] = []
        let shelf = makeShelf(reveal: { revealed.append($0) })
        shelf.summon(.tools(files: files, at: cursor))
        shelf.handle(.quickLook)
        #expect(preview.shown == [files])
        // Space again closes it.
        shelf.handle(.quickLook)
        #expect(!preview.isShown)
        shelf.expand()
        shelf.select(shelf.model.items[1].id)
        shelf.perform(.quickLook)
        #expect(preview.shown.last == [files[1]])
        // While it shows, it follows the selection.
        shelf.handle(.up)
        #expect(preview.shown.last == [files[0]])
        shelf.perform(.showInFinder)
        #expect(revealed == [[files[0]]])
        shelf.close()
    }

    // MARK: Announcements and the menu (S17, S22)

    @Test func announcesAddedAndLeft() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        var announced: [String] = []
        let shelf = makeShelf(announce: { announced.append($0) })
        shelf.summon(.tools(files: files, at: cursor))
        shelf.expand()
        shelf.handle(.selectAll)
        shelf.select(shelf.model.items[2].id, modifiers: [.command])
        shelf.removeSelection()
        #expect(announced == ["Added 3 files to the Shelf", "2 files left the Shelf"])
        shelf.close()
    }

    @Test func contextMenuItems() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        #expect(shelf.contextMenu(at: CGPoint(x: 50, y: 60)) == nil)
        shelf.summon(.tools(files: files, at: cursor))
        let view = shelf.panel.itemsView
        func menu(at point: CGPoint) -> NSMenu? {
            let drawer = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
            let local = NSPoint(x: drawer.minX + point.x, y: drawer.maxY - point.y)
            // Made, never posted: only `menu(for:)` reads it.
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(local, to: nil),
                                           modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return view.menu(for: event)
        }
        func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
        let stack = menu(at: CGPoint(x: 50, y: 60))
        #expect(titles(stack) == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Tuck Away", "Clear Shelf"])
        shelf.expand()
        let onRow = menu(at: row(1))
        #expect(titles(onRow) == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Remove from Shelf",
                                  "Tuck Away", "Clear Shelf"])
        // A right-click on an unselected row selects it, as in Finder.
        #expect(shelf.model.selection == [shelf.model.items[1].id])
        onRow?.items.first { $0.title == "Remove from Shelf" }.map { onRow?.performActionForItem(at: onRow!.index(of: $0)) }
        #expect(shelf.model.items.map(\.url) == [files[0]])
        #expect(titles(menu(at: CGPoint(x: 60, y: 10))).contains("Remove from Shelf") == false)
        shelf.close()
    }

    // MARK: Originals (S15) and the deferred minors

    @Test func expandingResolves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        let renamed = dir.appending(path: "renamed.txt", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: files[0], to: renamed)
        shelf.expand()
        #expect(await eventually { shelf.model.items.first?.name == "renamed.txt" })
        shelf.close()
    }

    /// A resolve that started before a newer one finished never writes its older answer over it.
    @Test func staleResolveIsDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let renamed = dir.appending(path: "renamed.txt", directoryHint: .notDirectory)
        let gate = ResolveGate()
        let live = ShelfFiles.live
        let gated = ShelfFiles(item: live.item, bookmark: { _ in nil }, resolve: { item in
            // The first resolve stalls until released, then answers from before the rename.
            if gate.enter() { return (item.url, item.name, .missing) }
            return (renamed, "renamed.txt", .present)
        })
        let shelf = makeShelf(files: gated)
        shelf.summon(.tools(files: files, at: cursor))
        let ids = shelf.model.items.map(\.id)
        let slow = Task { await shelf.resolve(ids) }
        #expect(await eventually { gate.isWaiting })
        // A copy resolves now and follows the rename.
        shelf.copySelection()
        #expect(shelf.model.items[0].url == renamed)
        gate.release()
        await slow.value
        #expect(shelf.model.items[0].url == renamed)
        #expect(shelf.model.items[0].state == .present)
        pasteboard.releaseGlobally()
        shelf.close()
    }

    /// A newer answer that the file is gone, at the same URL, is never undone by an older one that found it.
    @Test func staleResolveNeverRevertsADeletion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let gate = ResolveGate()
        let live = ShelfFiles.live
        let gated = ShelfFiles(item: live.item, bookmark: { _ in nil }, resolve: { item in
            gate.enter() ? (item.url, item.name, .present) : (item.url, item.name, .missing)
        })
        let shelf = makeShelf(files: gated)
        shelf.summon(.tools(files: files, at: cursor))
        let ids = shelf.model.items.map(\.id)
        let slow = Task { await shelf.resolve(ids) }
        #expect(await eventually { gate.isWaiting })
        shelf.copySelection()
        #expect(shelf.model.items[0].state == .missing)
        gate.release()
        await slow.value
        #expect(shelf.model.items[0].state == .missing)
        #expect(shelf.model.items[0].url == files[0])
        pasteboard.releaseGlobally()
        shelf.close()
    }

    @Test func dragHintHidesWhenEveryItemIsMissing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(shelf.panel.itemsView.toolTip == ShelfCopy.dragHint)
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[0])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.panel.itemsView.toolTip == nil)
        shelf.close()
    }

    @Test func iconIsMadeOncePerItem() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let item = shelf.model.items[0]
        #expect(shelf.icon(for: item) === shelf.icon(for: item))
        shelf.close()
    }

    /// The shadow's margin takes no clicks; in the list the header is SwiftUI's (its chevron and ✕), rows the drawer's.
    @Test func hitTestingKeepsToTheDrawer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let view = shelf.panel.itemsView
        func hit(_ point: NSPoint) -> NSView? {
            view.layoutSubtreeIfNeeded()
            return view.hitTest(view.superview.map { view.convert(point, to: $0) } ?? point)
        }
        #expect(hit(NSPoint(x: 2, y: 2)) == nil)
        #expect(hit(NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 2)) == nil)
        shelf.expand()
        let drawer = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        #expect(hit(NSPoint(x: drawer.minX + 14, y: drawer.maxY - 14)) !== view)
        #expect(hit(NSPoint(x: drawer.minX + 60, y: drawer.maxY - row(0).y)) === view)
        shelf.close()
    }

    /// The whole drawer takes drops, the list's header included (its SwiftUI controls are no drop targets); the
    /// shadow's margin takes none.
    @Test func dropsLandOnTheDrawerNotTheMargin() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let more = try makeFiles("c.txt", "d.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.expand()
        let view = shelf.panel.itemsView
        let drawer = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        let urls = NSPasteboard.withUniqueName()
        defer { urls.releaseGlobally() }
        urls.clearContents()
        urls.writeObjects([more[0] as NSURL])
        func drag(at point: NSPoint) -> StubDrag {
            StubDrag(pasteboard: urls, location: view.convert(point, to: nil))
        }
        let margin = NSPoint(x: drawer.minX - 4, y: drawer.midY)
        #expect(view.draggingEntered(drag(at: margin)) == [])
        #expect(!view.performDragOperation(drag(at: margin)))
        #expect(shelf.model.items.count == 2)
        let header = NSPoint(x: drawer.midX, y: drawer.maxY - ShelfLayout.headerHeight / 2)
        #expect(view.draggingEntered(drag(at: header)) == .copy)
        #expect(view.performDragOperation(drag(at: header)))
        #expect(shelf.model.items.map(\.url) == files + [more[0]])
        shelf.close()
    }

    /// VoiceOver's hit test passes the items view (which takes every mouse-down) to the SwiftUI elements under it.
    @Test func accessibilityHitTestReachesTheHost() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let drawer = shelf.drawerFrame
        let hit = shelf.panel.itemsView.accessibilityHitTest(NSPoint(x: drawer.midX, y: drawer.midY)) as AnyObject?
        // Without the forwarding the answer is the window: the items view is no element of its own.
        #expect(hit is ShelfHostingView)
        shelf.close()
    }
}

/// Holds the first resolve until the test releases it.
final class ResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var calls = 0
    private var waiting = false

    /// True for the first call, after the test released it.
    func enter() -> Bool {
        let first = lock.withLock {
            calls += 1
            waiting = calls == 1
            return calls == 1
        }
        if first { semaphore.wait() }
        return first
    }

    var isWaiting: Bool { lock.withLock { waiting } }

    func release() { semaphore.signal() }
}

/// The thumbnails keep the most recently used and go with their items (S26).
@Suite struct ShelfThumbnailsTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var renders: Int { lock.withLock { value } }
    }

    private static func pixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func keepsTheMostRecentAndForgetsRemovedItems() async {
        let count = Count()
        let thumbnails = ShelfThumbnails(capacity: 2) { _, _, _ in
            count.bump()
            return Self.pixel()
        }
        let (a, b, c) = (UUID(), UUID(), UUID())
        let url = URL(fileURLWithPath: "/tmp/x.png")
        _ = await thumbnails.image(for: a, url: url, side: 64, scale: 2)
        _ = await thumbnails.image(for: b, url: url, side: 64, scale: 2)
        _ = await thumbnails.image(for: a, url: url, side: 64, scale: 2)
        #expect(count.renders == 2)
        _ = await thumbnails.image(for: c, url: url, side: 64, scale: 2)
        #expect(count.renders == 3)
        // b was the least recently used.
        _ = await thumbnails.image(for: a, url: url, side: 64, scale: 2)
        #expect(count.renders == 3)
        _ = await thumbnails.image(for: b, url: url, side: 64, scale: 2)
        #expect(count.renders == 4)
        // c went for b; a and b stay.
        _ = await thumbnails.image(for: a, url: url, side: 64, scale: 2)
        #expect(count.renders == 4)
        await thumbnails.forget([a, b, c])
        _ = await thumbnails.image(for: a, url: url, side: 64, scale: 2)
        _ = await thumbnails.image(for: b, url: url, side: 64, scale: 2)
        #expect(count.renders == 6)
    }
}
