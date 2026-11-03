import AppKit
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-shelf-drag-test-\(UUID().uuidString)", directoryHint: .isDirectory)
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

/// The Trash stand-in: a folder of the test's own named `.Trash`, never the real Trash.
private func moveToTestTrash(_ url: URL, in dir: URL) throws -> URL {
    let trash = dir.appending(path: ".Trash", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let moved = trash.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
    try FileManager.default.moveItem(at: url, to: moved)
    return moved
}

/// The operation mask the Shelf offers as a drag source (S12, S33).
@Suite struct ShelfDragOperationsTests {
    @Test func maskWithoutCommandIsCopyOnly() {
        #expect(ShelfDragOperations.mask(commandHeld: false) == [.copy])
    }

    @Test func maskWithCommandAddsMove() {
        #expect(ShelfDragOperations.mask(commandHeld: true) == [.copy, .move, .generic])
    }

    /// Review Focus 4: the Trash takes only `.delete`, and `.link` would make an alias.
    @Test func maskNeverOffersDeleteOrLink() {
        for commandHeld in [false, true] {
            let mask = ShelfDragOperations.mask(commandHeld: commandHeld)
            #expect(!mask.contains(.delete))
            #expect(!mask.contains(.link))
            #expect(!mask.contains(.private))
            #expect(mask != .every)
        }
    }
}

/// Dragging out of the Shelf (S12, S13, S15), with the drag source's callbacks driven directly: nothing here starts a
/// real drag, posts an event, shows on a real screen or touches the real Trash.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfDragOutTests {
    private let clock = ManualClock()
    private let cursor = CGPoint(x: -29_500, y: -29_500)

    private func makeShelf(announce: @escaping (String) -> Void = { _ in }) -> ShelfController {
        ShelfController(desktop: .offScreen, announce: announce, clock: clock.timerClock, pasteboard: .withUniqueName(),
                        reveal: { _ in }, preview: RecordingPreview())
    }

    /// What a drag starting now on the stack would carry, as AppKit gets it.
    private func dragged(_ shelf: ShelfController) -> [URL] {
        let view = shelf.panel.itemsView
        let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        return view.draggingItems(at: point).compactMap { ($0.item as? NSURL) as URL? }
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: The pasteboard (S12)

    @Test func dragPasteboardHoldsTheURLs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let view = shelf.panel.itemsView
        let items = view.draggingItems(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        #expect(items.count == 3)
        // One NSURL writer per item, in the Shelf's order, each with an image to drag.
        #expect(items.map { $0.item is NSURL } == [true, true, true])
        #expect(items.compactMap { ($0.item as? NSURL) as URL? } == files)
        #expect(items.allSatisfy { $0.imageComponents?.isEmpty == false })
        shelf.dragOutEnded(operation: [])
        shelf.close()
    }

    /// S12 expanded: a pressed selected row drags the selection, an unselected one only itself.
    @Test func pressedRowDragsItsSelectionElseItself() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.expand()
        func row(_ index: Int) -> CGPoint {
            CGPoint(x: 60, y: ShelfLayout.headerHeight + ShelfLayout.listPadding / 2
                + ShelfLayout.rowHeight * (CGFloat(index) + 0.5))
        }
        let ids = shelf.model.items.map(\.id)
        shelf.select(ids[0])
        shelf.select(ids[2], modifiers: [.command])
        shelf.pressed(at: row(2))
        #expect(dragged(shelf) == [files[0], files[2]])
        shelf.dragOutEnded(operation: [])
        shelf.pressed(at: row(1))
        #expect(dragged(shelf) == [files[1]])
        // The selection is left as it was.
        #expect(shelf.model.selection == [ids[0], ids[2]])
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.url) == [files[0], files[2]])
        shelf.close()
    }

    @Test func nothingToDragOnAnEmptyShelf() {
        let shelf = makeShelf()
        shelf.summon(.menu)
        #expect(dragged(shelf).isEmpty)
        #expect(!shelf.isDraggingOut([]))
        shelf.close()
    }

    // MARK: What leaves (S13)

    @Test func deliveredItemsLeave() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        shelf.summon(.tools(files: files, at: cursor))
        #expect(dragged(shelf) == files)
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.isEmpty)
        #expect(announced.last == "2 files left the Shelf")
        // S9: emptied, it leaves.
        #expect(!shelf.isShown)
        // Pomelo itself touched nothing: the copy is the destination's.
        #expect(try names(in: dir) == ["a.txt", "b.txt"])
    }

    @Test func movedItemsLeave() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(dragged(shelf) == files)
        // With ⌘ held AppKit narrows the mask to `.generic`, which Finder reads as move.
        shelf.dragOutEnded(operation: .generic)
        #expect(shelf.model.isEmpty)

        let more = try makeFiles("b.txt", in: dir)
        shelf.summon(.tools(files: more, at: cursor))
        #expect(dragged(shelf) == more)
        shelf.dragOutEnded(operation: .move)
        #expect(shelf.model.isEmpty)
        #expect(try names(in: dir) == ["a.txt", "b.txt"])
    }

    @Test func cancelledItemsStay() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)
        #expect(dragged(shelf) == files)
        shelf.dragOutEnded(operation: [])
        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)
        #expect(!announced.contains { $0.contains("left the Shelf") })
        shelf.close()
    }

    @Test func onlyDraggedItemsLeave() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", "c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        _ = try moveToTestTrash(files[1], in: dir)
        // The trashed one is never dragged, so it stays when the others are delivered.
        #expect(dragged(shelf) == [files[0], files[2]])
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.name) == ["b.txt"])
        #expect(shelf.model.items.first?.state == .inTrash)
        #expect(shelf.isShown)
        shelf.close()
    }

    /// Review Focus 2: the wheel's drop answers `.copy`, which would look delivered.
    @Test func droppedOnPomeloStays() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)
        #expect(dragged(shelf) == files)
        shelf.dragOutLandedInPomelo()
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)

        // The landing is the one drag's: the next drag that is delivered leaves.
        #expect(dragged(shelf) == files)
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.isEmpty)
    }

    /// The wheel opened by a drag out of the Shelf, dropped on its own Shelf slice: the slice's re-adding must not be
    /// forgotten when the drag ends as a `.copy`.
    @Test func droppedOnTheWheelsShelfSliceStays() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)
        #expect(dragged(shelf) == files)
        shelf.wheelOpened(on: files)
        shelf.wheelChoseShelfSlice(files, at: cursor)
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)
        shelf.close()
    }

    @Test func aShelfSliceDropFromFinderChangesNothingAboutDragOuts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: [files[0]], at: cursor))
        #expect(dragged(shelf) == [files[0]])
        shelf.wheelOpened(on: files)
        shelf.wheelChoseShelfSlice(files, at: cursor)
        #expect(shelf.model.items.count == 2)
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.url.lastPathComponent) == ["b.txt"])
        shelf.close()
    }

    @Test func landingInPomeloWithoutADragOutChangesNothing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.dragOutLandedInPomelo()
        #expect(dragged(shelf) == files)
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.isEmpty)
    }

    @Test func droppedBackOnTheShelfStays() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)
        let view = shelf.panel.itemsView
        let items = view.draggingItems(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(items.compactMap { $0.item as? NSURL })
        // The drawer refuses its own drag, so the session ends with no operation.
        let back = StubDrag(pasteboard: pasteboard, source: view)
        #expect(view.draggingEntered(back) == [])
        #expect(!view.performDragOperation(back))
        shelf.dragOutEnded(operation: [])
        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)
        shelf.close()
    }

    @Test func isDraggingOutMatchesTheSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let other = try makeFiles("c.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(!shelf.isDraggingOut(files))
        #expect(dragged(shelf) == files)
        #expect(shelf.isDraggingOut(files))
        // The same files in another order or spelling, as the drag pasteboard gives them back.
        #expect(shelf.isDraggingOut([URL(fileURLWithPath: dir.path + "/./b.txt"), files[0]]))
        #expect(!shelf.isDraggingOut([files[0]]))
        #expect(!shelf.isDraggingOut(files + other))
        #expect(!shelf.isDraggingOut(other))
        #expect(!shelf.isDraggingOut([]))
        shelf.dragOutEnded(operation: [])
        #expect(!shelf.isDraggingOut(files))
        shelf.close()
    }

    // MARK: Originals that move (S15)

    /// Review Focus 3: the drag carries the new URL.
    @Test func renamedFileFollows() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        let renamed = dir.appending(path: "renamed.txt", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: files[0], to: renamed)
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.model.items.first?.name == "renamed.txt")
        #expect(shelf.model.items.first?.url.standardizedFileURL == renamed.standardizedFileURL)
        #expect(shelf.model.items.first?.state == .present)
        #expect(dragged(shelf).map(\.standardizedFileURL) == [renamed.standardizedFileURL])
        shelf.dragOutEnded(operation: [])
        shelf.close()
    }

    /// The drag resolves what it carries as it starts (S15), with no hover first.
    @Test func renamedFileFollowsAtDragStart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        let renamed = dir.appending(path: "renamed.txt", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: files[0], to: renamed)
        #expect(dragged(shelf).map(\.standardizedFileURL) == [renamed.standardizedFileURL])
        #expect(shelf.isDraggingOut([renamed]))
        shelf.dragOutEnded(operation: [])
        shelf.close()
    }

    /// Review Focus 3: a trashed file is greyed and never dragged.
    @Test func trashedFileGreysAndIsNotDragged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        _ = try moveToTestTrash(files[0], in: dir)
        #expect(dragged(shelf) == [files[1]])
        let trashed = shelf.model.items[0]
        #expect(trashed.state == .inTrash)
        #expect(trashed.state.reason == "Moved to the Trash")
        // Kept until removed: never dropped silently, even when the rest is delivered.
        shelf.dragOutEnded(operation: .copy)
        #expect(shelf.model.items.map(\.id) == [trashed.id])
        #expect(dragged(shelf).isEmpty)
        #expect(!shelf.isDraggingOut([]))
        shelf.close()
    }

    @Test func deletedFileCantBeFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[0])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.model.items.first?.state == .missing)
        #expect(shelf.model.items.first?.state.reason == "Can't be found")
        #expect(shelf.model.items.first?.name == "a.txt")
        #expect(dragged(shelf).isEmpty)
        shelf.close()
    }

    @Test func replacedInPlaceShowsThePath() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[0])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.model.items.first?.state == .missing)
        // A new file with the same name: the path is tried and the item comes back.
        try Data("a new a".utf8).write(to: files[0])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.model.items.first?.state == .present)
        #expect(shelf.model.items.first?.url.standardizedFileURL == files[0].standardizedFileURL)
        #expect(dragged(shelf) == files)
        shelf.dragOutEnded(operation: [])
        shelf.close()
    }

    @Test func pointerEnteringResolves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        let renamed = dir.appending(path: "renamed.txt", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: files[0], to: renamed)
        shelf.pointerInsideChanged(true)
        #expect(await eventually { shelf.model.items.first?.name == "renamed.txt" })
        shelf.close()
    }

    // MARK: The drawer takes the mouse (S12, S24)

    @Test func mouseDownsReachTheItemsViewButTheClose() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        shelf.pointerInsideChanged(true)
        let view = shelf.panel.itemsView
        view.layoutSubtreeIfNeeded()
        let drawer = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        func hit(_ point: NSPoint) -> NSView? {
            view.hitTest(view.superview.map { view.convert(point, to: $0) } ?? point)
        }
        #expect(hit(NSPoint(x: drawer.midX, y: drawer.midY)) === view)
        #expect(hit(NSPoint(x: drawer.minX + 4, y: drawer.minY + 4)) === view)
        // The ✕ in the top-trailing corner stays SwiftUI's.
        let close = hit(NSPoint(x: drawer.maxX - 14, y: drawer.maxY - 14))
        #expect(close != nil)
        #expect(close !== view)
        shelf.close()
    }

    // MARK: The key pill (R30)

    /// A ⌘ key change as the key panel gets it: made, never posted.
    private func flagsChanged(_ shelf: ShelfController, _ modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: shelf.panel.windowNumber, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        shelf.panel.itemsView.flagsChanged(with: event)
    }

    @Test func pillSaysCommandThenCopyAndMove() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf()
        shelf.summon(.tools(files: try makeFiles("a.txt", in: dir), at: cursor))
        let pill = try #require(shelf.pill)
        #expect(pill.key == "⌘")
        #expect(pill.titles == ["Copy", "Move"])
        #expect(pill.current == 0)
        shelf.close()
    }

    /// The drag source is asked its mask again when the modifiers change: the pill follows ⌘, and the drag's end
    /// puts it back on Copy.
    @Test func pillFollowsCommandDuringADragOut() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        let view = shelf.panel.itemsView
        #expect(dragged(shelf) == files)
        #expect(view.dragOutMask(commandHeld: true) == [.copy, .move, .generic])
        #expect(shelf.pill?.current == 1)
        #expect(view.dragOutMask(commandHeld: false) == [.copy])
        #expect(shelf.pill?.current == 0)
        _ = view.dragOutMask(commandHeld: true)
        #expect(shelf.pill?.current == 1)
        shelf.dragOutEnded(operation: [])
        #expect(shelf.pill?.current == 0)
        #expect(shelf.model.items.count == 2)
        shelf.close()
    }

    /// While the Shelf is key its panel hears ⌘ go down and up (no key monitor).
    @Test func pillFollowsCommandWhileKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf()
        shelf.summon(.tools(files: try makeFiles("a.txt", "b.txt", in: dir), at: cursor))
        flagsChanged(shelf, .command)
        #expect(shelf.pill?.current == 1)
        flagsChanged(shelf, [.command, .shift])
        #expect(shelf.pill?.current == 1)
        flagsChanged(shelf, .shift)
        #expect(shelf.pill?.current == 0)
        flagsChanged(shelf, .command)
        shelf.expand()
        #expect(shelf.pill?.current == 1)
        flagsChanged(shelf, [])
        #expect(shelf.pill?.current == 0)
        shelf.close()
    }

    /// Not on the empty drawer, the tab, or a Shelf whose files are all missing; collapsed and expanded otherwise. A
    /// click on the expanded drawer's pill band selects nothing.
    @Test func pillShowsOnlyWithSomethingToDrag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", "b.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.menu)
        #expect(shelf.pill == nil)
        shelf.add(files)
        #expect(shelf.pill != nil)
        shelf.expand()
        #expect(shelf.pill != nil)
        let height = ShelfLayout.size(shelf.presentation).height
        shelf.clicked(at: CGPoint(x: 130, y: height - ShelfLayout.pillBand / 2), modifiers: [])
        #expect(shelf.model.selection.isEmpty)
        #expect(shelf.isExpanded)
        shelf.collapse()
        shelf.tuck()
        #expect(shelf.isTucked)
        #expect(shelf.pill == nil)
        shelf.untuck()
        #expect(shelf.pill != nil)
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        try FileManager.default.removeItem(at: files[0])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.pill != nil)
        try FileManager.default.removeItem(at: files[1])
        await shelf.resolve(shelf.model.items.map(\.id))
        #expect(shelf.model.items.allSatisfy { $0.state == .missing })
        #expect(shelf.pill == nil)
        shelf.close()
    }

    @Test func helpTagSaysHowToMove() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.txt", in: dir)
        let shelf = makeShelf()
        shelf.summon(.menu)
        let view = shelf.panel.itemsView
        // Nothing to drag on the empty drawer, so nothing to say.
        #expect(view.toolTip == nil)
        shelf.add(files)
        // The tool tip is AppKit's, since the mouse lands in the items view; the VoiceOver hint is the SwiftUI
        // stack's, which SwiftUI vends only to a connected assistive app (P146), so the audit and the lint cover it.
        #expect(view.toolTip == ShelfCopy.dragHint)
        #expect(ShelfCopy.dragHint == "Drag to copy. Hold Command to move.")
        shelf.clear()
        #expect(view.toolTip == nil)
    }
}
