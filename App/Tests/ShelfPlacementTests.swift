import AppKit
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

/// Screens and a pointer the tests change between steps; far outside every real screen.
@MainActor
private final class TestScreens {
    static let main = ShelfScreen(id: 1, frame: CGRect(x: -30_000, y: -30_000, width: 1_000, height: 800),
                                  visibleFrame: CGRect(x: -30_000, y: -30_000, width: 1_000, height: 770))
    static let second = ShelfScreen(id: 2, frame: CGRect(x: -29_000, y: -30_000, width: 800, height: 600),
                                    visibleFrame: CGRect(x: -29_000, y: -30_000, width: 800, height: 600))

    var screens: [ShelfScreen]
    var pointer: CGPoint
    /// The items of each drag out begun, in place of AppKit's session.
    var dragsOut: [[NSDraggingItem]] = []

    init(_ screens: [ShelfScreen] = [main], pointer: CGPoint? = nil) {
        self.screens = screens
        self.pointer = pointer ?? CGPoint(x: screens[0].visibleFrame.midX, y: screens[0].visibleFrame.midY)
    }

    var desktop: ShelfDesktop {
        ShelfDesktop(screens: { self.screens }, pointer: { self.pointer }, watchesMouse: false, takesKey: false,
                     animates: false, anotherWindowIsKey: { false }, beginsDrag: { self.dragsOut.append($0) })
    }
}

/// Tucking, moving and displays (S7, S9, S10, S23, S26), on injected screens far outside the real ones and a virtual
/// clock: nothing here moves a window on a real screen, starts a real drag or waits real time.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfPlacementTests {
    private let clock = ManualClock()

    private func makeShelf(_ screens: TestScreens) -> ShelfController {
        ShelfController(desktop: screens.desktop, clock: clock.timerClock, pasteboard: .withUniqueName(), reveal: { _ in },
                        preview: RecordingPreview())
    }

    private func makeFiles(_ count: Int) throws -> (dir: URL, files: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-shelf-placement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try (0..<count).map { index in
            let url = dir.resolvingSymlinksInPath().appending(path: "file-\(index).txt", directoryHint: .notDirectory)
            try Data("shelf \(index)".utf8).write(to: url)
            return url
        }
        return (dir, files)
    }

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// A drag over the tab, in the items view's window.
    private func dragOverTheTab(_ shelf: ShelfController, files: [URL]) -> (StubDrag, NSPasteboard) {
        let view = shelf.panel.itemsView
        let tab = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        return (StubDrag(pasteboard: pasteboard, location: view.convert(NSPoint(x: tab.midX, y: tab.midY), to: nil)),
                pasteboard)
    }

    // MARK: Tucking (S9)

    @Test func tuckShowsTheTabOnTheNearestSide() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let visible = TestScreens.main.visibleFrame
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: files, at: CGPoint(x: visible.maxX - 150, y: visible.midY + 100)))
        let drawer = shelf.drawerFrame
        shelf.tuck()
        #expect(shelf.presentation == .tucked)
        #expect(shelf.isShown)
        #expect(shelf.tabSide == .right)
        #expect(shelf.drawerFrame.size == ShelfLayout.size(.tucked))
        #expect(shelf.drawerFrame.maxX == visible.maxX)
        #expect(shelf.drawerFrame.midY == drawer.midY)
        // The tab counts what it holds; tucking leaves the files where they are.
        #expect(shelf.model.items.map(\.url) == files)
        shelf.close()

        let left = makeShelf(screens)
        left.summon(.tools(files: files, at: CGPoint(x: visible.minX + 200, y: visible.midY)))
        left.perform(.tuckAway)
        #expect(left.presentation == .tucked)
        #expect(left.tabSide == .left)
        #expect(left.drawerFrame.minX == visible.minX)
        left.close()
    }

    @Test func clickOnTheTabBringsItBack() throws {
        let (dir, files) = try makeFiles(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf(TestScreens())
        shelf.summon(.tools(files: files, at: CGPoint(x: -29_300, y: -29_600)))
        let drawer = shelf.drawerFrame
        shelf.tuck()
        // The whole tab takes the click, its top half too (where the drawer keeps its ✕).
        let view = shelf.panel.itemsView
        let tab = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        view.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: tab.midX, y: tab.maxY - 4), NSPoint(x: tab.midX, y: tab.midY)] {
            #expect(view.hitTest(view.superview.map { view.convert(point, to: $0) } ?? point) === view)
        }
        shelf.pressed(at: CGPoint(x: 7, y: 28))
        shelf.clicked(at: CGPoint(x: 7, y: 28), modifiers: [])
        #expect(shelf.presentation == .collapsed)
        #expect(shelf.drawerFrame == drawer)

        // The menus' Tuck Away and Bring Back are live; the list comes back as the list (S17, S22).
        func run(_ title: String) -> Bool {
            guard let menu = shelf.contextMenu(at: CGPoint(x: 7, y: 20)),
                  let item = menu.items.first(where: { $0.title == title }), item.isEnabled else { return false }
            menu.performActionForItem(at: menu.index(of: item))
            return true
        }
        shelf.expand()
        let list = shelf.drawerFrame
        #expect(run("Tuck Away"))
        #expect(shelf.presentation == .tucked)
        let titles = shelf.contextMenu(at: CGPoint(x: 7, y: 28))?.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Bring Back", "Clear Shelf"])
        #expect(ShelfCopy.tab(3) == "Shelf, 3 files")
        #expect(run("Bring Back"))
        #expect(shelf.presentation == .expanded(rows: 3))
        #expect(shelf.drawerFrame == list)
        // A drag on the tab drags nothing out.
        shelf.tuck()
        #expect(shelf.panel.itemsView.draggingItems(at: .zero).isEmpty)
        shelf.close()
    }

    /// A press on the tab that wanders past the drag threshold is still a click (nothing drags out of a tab).
    @Test func aWanderingClickOnTheTabStillBringsItBack() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf(TestScreens())
        shelf.summon(.tools(files: files, at: CGPoint(x: -29_300, y: -29_600)))
        let drawer = shelf.drawerFrame
        shelf.tuck()
        let view = shelf.panel.itemsView
        let tab = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        // Made, never posted: the view's handlers read them directly.
        func event(_ type: NSEvent.EventType, dy: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: tab.midX, y: tab.midY + dy), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, dy: 0))
        view.mouseDragged(with: event(.leftMouseDragged, dy: 6))
        view.mouseUp(with: event(.leftMouseUp, dy: 6))
        #expect(shelf.presentation == .collapsed)
        #expect(shelf.drawerFrame == drawer)
        shelf.close()
    }

    @Test func hoveringTheTabDuringADragSpringsItOpenAfter0_3s() async throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: [files[0]], at: CGPoint(x: -29_200, y: -29_600)))
        shelf.tuck()
        let tab = shelf.drawerFrame
        screens.pointer = centre(tab)
        let view = shelf.panel.itemsView
        let (drag, pasteboard) = dragOverTheTab(shelf, files: [files[1]])
        defer { pasteboard.releaseGlobally() }

        // A drag that leaves before 0.3 s leaves it tucked.
        #expect(view.draggingEntered(drag) == .copy)
        await clock.advance(by: .milliseconds(200))
        view.draggingExited(drag)
        await clock.advance(by: .seconds(1))
        #expect(shelf.presentation == .tucked)

        #expect(view.draggingEntered(drag) == .copy)
        await clock.advance(by: .milliseconds(150))
        #expect(view.draggingUpdated(drag) == .copy)
        await clock.advance(by: .milliseconds(140))
        #expect(shelf.presentation == .tucked)
        await clock.advance(by: .milliseconds(10))
        #expect(shelf.presentation == .collapsed)
        // It opens under the drag, so the drop lands on it.
        #expect(shelf.drawerFrame.contains(screens.pointer))
        #expect(shelf.model.items.count == 1)
        shelf.close()
    }

    @Test func dropOnTheTabAddsWithoutOpening() async throws {
        let (dir, files) = try makeFiles(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf(TestScreens())
        shelf.summon(.tools(files: [files[0]], at: CGPoint(x: -29_200, y: -29_600)))
        shelf.tuck()
        let tab = shelf.drawerFrame
        let view = shelf.panel.itemsView
        let (drag, pasteboard) = dragOverTheTab(shelf, files: Array(files[1...]))
        defer { pasteboard.releaseGlobally() }
        #expect(view.draggingEntered(drag) == .copy)
        #expect(shelf.isDropTargeted)
        await clock.advance(by: .milliseconds(100))
        #expect(view.performDragOperation(drag))
        await clock.advance(by: .seconds(1))
        #expect(shelf.presentation == .tucked)
        #expect(shelf.drawerFrame == tab)
        #expect(!shelf.isDropTargeted)
        #expect(shelf.model.items.map(\.url) == files)
        shelf.close()
    }

    @Test func shakeUntucksToTheCursor() throws {
        let (dir, files) = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = makeShelf(TestScreens())
        shelf.summon(.tools(files: files, at: CGPoint(x: -29_200, y: -29_600)))
        shelf.tuck()
        let cursor = CGPoint(x: -29_700, y: -29_400)
        shelf.summon(.shake(at: cursor))
        #expect(shelf.presentation == .collapsed)
        #expect(centre(shelf.drawerFrame) == cursor)
        // The Tools slice brings it out too, at the wheel's centre.
        shelf.tuck()
        let wheel = CGPoint(x: -29_500, y: -29_500)
        shelf.summon(.tools(files: files, at: wheel))
        #expect(shelf.presentation == .collapsed)
        #expect(centre(shelf.drawerFrame) == wheel)
        // Show Shelf brings it back where it was.
        shelf.tuck()
        shelf.summon(.menu)
        #expect(shelf.presentation == .collapsed)
        #expect(centre(shelf.drawerFrame) == wheel)
        shelf.close()
    }

    // MARK: Moving (S7)

    @Test func headerDragSettlesInsideTheScreen() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens([TestScreens.main, TestScreens.second])
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: files, at: CGPoint(x: -29_500, y: -29_500)))
        shelf.expand()
        let size = shelf.drawerFrame.size
        let visible = TestScreens.main.visibleFrame
        // Released half off the bottom-left of the main screen: pulled back inside it, 8 pt in.
        func release(at origin: CGPoint) {
            let drawer = CGRect(origin: origin, size: size)
            shelf.panel.setFrame(drawer.insetBy(dx: -ShelfPanel.inset, dy: -ShelfPanel.inset), display: false)
            shelf.headerDragEnded()
        }
        release(at: CGPoint(x: visible.minX - 100, y: visible.minY - 50))
        #expect(shelf.drawerFrame.origin == CGPoint(x: visible.minX + 8, y: visible.minY + 8))
        // Released on no screen: into the nearest one.
        let second = TestScreens.second.visibleFrame
        release(at: CGPoint(x: second.maxX + 400, y: second.midY))
        #expect(shelf.drawerFrame.maxX == second.maxX - 8)
        #expect(second.contains(shelf.drawerFrame))
        // Released inside: it stays where it was put, and the menu brings it back there.
        let inside = CGPoint(x: visible.minX + 300, y: visible.minY + 200)
        release(at: inside)
        #expect(shelf.drawerFrame.origin == inside)
        shelf.close()
        shelf.summon(.menu)
        #expect(shelf.drawerFrame.origin == inside)
        shelf.close()
    }

    /// A press at `point` (from the drawer's top-left corner, y down) dragged by `delta` on screen, then let go. The
    /// pointer moves with it; the events are made, never posted.
    private func drag(_ shelf: ShelfController, _ screens: TestScreens, from point: CGPoint, by delta: CGVector,
                      release: Bool = true) {
        let view = shelf.panel.itemsView
        let drawer = view.bounds.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        let start = view.convert(NSPoint(x: drawer.minX + point.x, y: drawer.maxY - point.y), to: nil)
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                               windowNumber: shelf.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: 1)!
        }
        let pointer = screens.pointer
        view.mouseDown(with: event(.leftMouseDown, start))
        screens.pointer = CGPoint(x: pointer.x + delta.dx / 2, y: pointer.y + delta.dy / 2)
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + delta.dx / 2, y: start.y + delta.dy / 2)))
        screens.pointer = CGPoint(x: pointer.x + delta.dx, y: pointer.y + delta.dy)
        // The panel has moved under the pointer: in its window the pointer is where it was pressed.
        view.mouseDragged(with: event(.leftMouseDragged, start))
        if release { view.mouseUp(with: event(.leftMouseUp, start)) }
    }

    private func letGo(_ shelf: ShelfController) {
        let view = shelf.panel.itemsView
        view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(centre(view.bounds), to: nil),
                                              modifierFlags: [], timestamp: 0, windowNumber: shelf.panel.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    /// The collapsed drawer laid out, as it is once on screen: the stack's place comes from SwiftUI's layout.
    private func laidOut(_ shelf: ShelfController) {
        shelf.panel.itemsView.layoutSubtreeIfNeeded()
        shelf.panel.displayIfNeeded()
    }

    /// R29: everywhere off the stack (the labels, the side margins, the bottom and its key pill, the band between the
    /// ✕ and the chevron) a drag moves the collapsed drawer by the drag's delta, and it settles inside the screen when let go.
    @Test func collapsedDrawerMovesByItsBackground() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let visible = TestScreens.main.visibleFrame
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: files, at: centre(visible)))
        laidOut(shelf)
        #expect(shelf.presentation == .collapsed)
        let width = ShelfLayout.size(.collapsed).width
        let height = ShelfLayout.size(.collapsed).height
        // The key pill (R30) counts as background too.
        let spots = [CGPoint(x: width / 2, y: 97), CGPoint(x: width / 2, y: height - 4), CGPoint(x: 4, y: height / 2),
                     CGPoint(x: width - 4, y: 60), CGPoint(x: width / 2, y: 6),
                     CGPoint(x: width / 2, y: height - ShelfLayout.pillBand / 2)]
        for spot in spots {
            let before = shelf.drawerFrame
            drag(shelf, screens, from: spot, by: CGVector(dx: 40, dy: -30), release: false)
            #expect(shelf.drawerFrame.origin == CGPoint(x: before.minX + 40, y: before.minY - 30), "\(spot)")
            letGo(shelf)
            #expect(shelf.drawerFrame.origin == CGPoint(x: before.minX + 40, y: before.minY - 30), "\(spot)")
            #expect(shelf.presentation == .collapsed, "\(spot)")
        }
        #expect(screens.dragsOut.isEmpty)
        #expect(shelf.model.items.count == 2)
        // Let go half off the screen's left edge: pulled back inside it, 8 pt in.
        let drawer = shelf.drawerFrame
        drag(shelf, screens, from: CGPoint(x: width / 2, y: 97), by: CGVector(dx: visible.minX - drawer.maxX + 20, dy: 0))
        #expect(shelf.drawerFrame.minX == visible.minX + 8)
        #expect(shelf.drawerFrame.minY == drawer.minY)
        #expect(screens.dragsOut.isEmpty)
        shelf.close()
    }

    /// R29: the stack still drags the files out and leaves the drawer where it is; the list is unchanged (a row
    /// drags out, nothing moves).
    @Test func collapsedStackStillDragsOut() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: files, at: centre(TestScreens.main.visibleFrame)))
        laidOut(shelf)
        let drawer = shelf.drawerFrame
        drag(shelf, screens, from: CGPoint(x: ShelfLayout.size(.collapsed).width / 2, y: 45),
             by: CGVector(dx: 40, dy: -30), release: false)
        #expect(screens.dragsOut.map { $0.compactMap { ($0.item as? NSURL) as URL? } } == [files])
        #expect(shelf.drawerFrame == drawer)
        shelf.dragOutEnded(operation: [])

        shelf.expand()
        let list = shelf.drawerFrame
        drag(shelf, screens, from: CGPoint(x: 60, y: ShelfLayout.headerHeight + ShelfLayout.listPadding / 2
                                               + ShelfLayout.rowHeight * 0.5),
             by: CGVector(dx: 40, dy: -30), release: false)
        #expect(screens.dragsOut.count == 2)
        #expect(shelf.drawerFrame == list)
        shelf.dragOutEnded(operation: [])
        shelf.close()
    }

    /// R29: a click on the labels still opens the list.
    @Test func clickOnTheCollapsedLabelsStillExpands() throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let shelf = makeShelf(screens)
        shelf.summon(.tools(files: files, at: centre(TestScreens.main.visibleFrame)))
        laidOut(shelf)
        drag(shelf, screens, from: CGPoint(x: ShelfLayout.size(.collapsed).width / 2, y: 97), by: CGVector(dx: 2, dy: 1))
        #expect(shelf.presentation == .expanded(rows: 2))
        #expect(screens.dragsOut.isEmpty)
        shelf.close()
    }

    // MARK: Displays (S10)

    @Test func screenChangeKeepsTheRelativePlace() throws {
        let (dir, files) = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let shelf = makeShelf(screens)
        // The menu's first place: right-middle, 8 pt in. The file comes first: the collapsed drawer is taller than
        // the empty one by the key pill's band (R30), and grows downward.
        shelf.add(files)
        shelf.summon(.menu)
        let before = shelf.drawerFrame
        #expect(before.maxX == TestScreens.main.visibleFrame.maxX - 8)
        #expect(before.midY == TestScreens.main.visibleFrame.midY)
        var smaller = TestScreens.main
        smaller.frame.size = CGSize(width: 700, height: 500)
        smaller.visibleFrame = CGRect(x: -30_000, y: -30_000, width: 700, height: 470)
        screens.screens = [smaller]
        shelf.screensChanged()
        #expect(shelf.drawerFrame.size == before.size)
        #expect(shelf.drawerFrame.maxX == smaller.visibleFrame.maxX - 8)
        #expect(shelf.drawerFrame.midY == smaller.visibleFrame.midY)

        // Tucked, the tab follows its display and comes back to the drawer's new place.
        shelf.tuck()
        screens.screens = [TestScreens.main]
        shelf.screensChanged()
        #expect(shelf.drawerFrame.maxX == TestScreens.main.visibleFrame.maxX)
        shelf.untuck()
        #expect(shelf.drawerFrame == before)
        shelf.close()
    }

    @Test func lostDisplayMovesToThePointersScreen() throws {
        let (dir, files) = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens([TestScreens.main, TestScreens.second])
        let shelf = makeShelf(screens)
        let second = TestScreens.second.visibleFrame
        // Bottom-left of the second display, 8 pt in.
        shelf.summon(.tools(files: files, at: CGPoint(x: second.minX + 20, y: second.minY + 20)))
        #expect(shelf.drawerFrame.origin == CGPoint(x: second.minX + 8, y: second.minY + 8))
        screens.screens = [TestScreens.main]
        screens.pointer = CGPoint(x: TestScreens.main.visibleFrame.midX, y: TestScreens.main.visibleFrame.midY)
        shelf.screensChanged()
        let main = TestScreens.main.visibleFrame
        #expect(shelf.drawerFrame.origin == CGPoint(x: main.minX + 8, y: main.minY + 8))
        shelf.close()
    }

    // MARK: Motion (S23) and idle (S26)

    @Test func reduceMotionUsesFadesOnly() {
        let reduced = ShelfMotion(reduceMotion: true)
        #expect(reduced.duration == 0.15)
        #expect(reduced.appearScale == 1)
        #expect(reduced.dropHoverScale == 1)
        #expect(!reduced.slides)
        let full = ShelfMotion(reduceMotion: false)
        #expect(full.duration == 0.2)
        #expect(full.appearScale == 0.97)
        #expect(full.dropHoverScale == 1.03)
        #expect(full.slides)
    }

    @Test func nothingScheduledAtRest() async throws {
        let (dir, files) = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let screens = TestScreens()
        let shelf = makeShelf(screens)
        shelf.summon(.shake(at: CGPoint(x: -29_500, y: -29_500)))
        shelf.dragEnded()
        // Files landing cancel the leave check at once, rather than letting it run out.
        shelf.add([files[0]])
        await clock.advance(by: .milliseconds(100))
        #expect(clock.waiting == 0)
        #expect(shelf.isAtRest)
        shelf.tuck()
        let view = shelf.panel.itemsView
        let (drag, pasteboard) = dragOverTheTab(shelf, files: [files[1]])
        defer { pasteboard.releaseGlobally() }
        _ = view.draggingEntered(drag)
        await clock.advance(by: .milliseconds(100))
        #expect(!shelf.isAtRest)
        // The spring-open timer goes with the drag that leaves.
        view.draggingExited(drag)
        shelf.screensChanged()
        await clock.advance(by: .milliseconds(100))
        #expect(clock.waiting == 0)
        #expect(shelf.isAtRest)
        await clock.advance(by: .seconds(1))
        #expect(shelf.presentation == .tucked)
        shelf.untuck()
        shelf.pointerInsideChanged(true)
        await clock.advance(by: .seconds(1))
        #expect(clock.waiting == 0)
        #expect(shelf.isAtRest)
        shelf.close()
    }
}
