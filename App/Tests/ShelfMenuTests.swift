import AppKit
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfMenuTests {
    /// Off-screen, with the clipboard, Finder and Quick Look injected.
    private func makeShelf(desktop: ShelfDesktop = .offScreen, clock: ManualClock = ManualClock()) -> ShelfController {
        ShelfController(desktop: desktop, clock: clock.timerClock, pasteboard: .withUniqueName(), reveal: { _ in },
                        preview: RecordingPreview())
    }

    @Test func itemsByState() {
        let empty = ShelfMenu.items(isEmpty: true)
        #expect(empty.map(\.title) == ["Show Shelf", "Clear Shelf"])
        #expect(empty.map(\.isEnabled) == [true, false])
        let holding = ShelfMenu.items(isEmpty: false)
        #expect(holding.map(\.title) == ["Show Shelf", "Clear Shelf"])
        #expect(holding.map(\.isEnabled) == [true, true])
    }

    /// S35: a shake during a file drag brings the empty Shelf under the cursor.
    @Test func aShakeEventSummonsTheShelfAtTheCursor() {
        let shelf = makeShelf()
        let wheel = WheelController(settings: SettingsStore(defaults: EphemeralDefaults()), desktop: .offScreen)
        defer { shelf.close(); wheel.close() }
        let point = CGPoint(x: -29_500, y: -29_500)
        AppEnvironment.route(.showShelf(at: point), wheel: wheel, shelf: shelf)
        #expect(shelf.isShown)
        #expect(shelf.drawerFrame.contains(point))
        #expect(!wheel.isOpen)
    }

    /// The button-up reaches both the wheel and the Shelf: the empty Shelf a shake brought leaves.
    @Test func dragEndedReachesTheShelfToo() async {
        let clock = ManualClock()
        let shelf = makeShelf(clock: clock)
        let wheel = WheelController(settings: SettingsStore(defaults: EphemeralDefaults()), desktop: .offScreen)
        defer { shelf.close(); wheel.close() }
        AppEnvironment.route(.showShelf(at: CGPoint(x: -29_500, y: -29_500)), wheel: wheel, shelf: shelf)
        AppEnvironment.route(.dragEnded(dropExpected: false), wheel: wheel, shelf: shelf)
        await clock.advance(by: WheelController.closeDelay + .milliseconds(50))
        #expect(!shelf.isShown)
    }

    @Test func showShelfFromTheMenuShowsTheEmptyDrawerAndClearForgets() throws {
        let shelf = makeShelf()
        defer { shelf.close() }
        ShelfMenu.perform(.show, on: shelf)
        #expect(shelf.isShown)
        #expect(shelf.model.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-menu-\(UUID().uuidString).txt")
        shelf.add([file])
        #expect(!shelf.model.isEmpty)
        ShelfMenu.perform(.clear, on: shelf)
        #expect(shelf.model.isEmpty)
        #expect(!shelf.isShown)
    }

    /// S6: Show Shelf brings a Shelf already up to the front where it is (an editor shares its level), and so does a
    /// second summon from the Tools slice; neither makes it key.
    @Test func showShelfRaisesAShelfAlreadyUp() {
        var raises = 0
        var desktop = ShelfDesktop.offScreen
        desktop.raised = { raises += 1 }
        let shelf = makeShelf(desktop: desktop)
        defer { shelf.close() }
        ShelfMenu.perform(.show, on: shelf)
        let frame = shelf.drawerFrame
        raises = 0
        ShelfMenu.perform(.show, on: shelf)
        #expect(raises == 1)
        #expect(shelf.drawerFrame == frame)
        #expect(!shelf.panel.isKeyWindow)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-menu-\(UUID().uuidString).txt")
        let point = CGPoint(x: -29_500, y: -29_500)
        shelf.summon(.tools(files: [file], at: point))
        raises = 0
        shelf.summon(.tools(files: [file], at: point))
        #expect(raises == 1)
        #expect(!shelf.panel.isKeyWindow)
    }
}
