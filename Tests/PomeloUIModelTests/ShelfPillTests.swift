import Foundation
import Testing
@testable import PomeloUIModel

private func item(_ path: String, state: ShelfItemState = .present) -> ShelfItem {
    let url = URL(fileURLWithPath: path)
    return ShelfItem(url: url, identity: path, name: url.lastPathComponent, byteCount: 1000, state: state)
}

private func shelf(_ items: ShelfItem...) -> ShelfModel {
    var model = ShelfModel()
    model.add(items)
    return model
}

/// The key pill (R30): ⌘ over Copy and Move, like the wheel's page pill.
@Suite struct ShelfPillTests {
    private let two = shelf(item("/t/a.txt"), item("/t/b.txt"))

    @Test func saysCommandThenCopyAndMove() throws {
        let pill = try #require(ShelfPill(for: two, presentation: .collapsed, commandHeld: false))
        #expect(pill.key == "⌘")
        #expect(pill.titles == ["Copy", "Move"])
        #expect(ShelfCopy.move == "Move")
        // P32: separate labels, none holding a separator.
        #expect(([pill.key] + pill.titles).allSatisfy { !$0.contains("·") && !$0.contains("—") })
    }

    @Test func copyIsCurrentUnlessCommandIsHeld() {
        #expect(ShelfPill(for: two, presentation: .collapsed, commandHeld: false)?.current == 0)
        #expect(ShelfPill(for: two, presentation: .collapsed, commandHeld: true)?.current == 1)
        #expect(ShelfPill(for: two, presentation: .expanded(rows: 2), commandHeld: false)?.current == 0)
        #expect(ShelfPill(for: two, presentation: .expanded(rows: 2), commandHeld: true)?.current == 1)
    }

    @Test func shownOnlyWhileSomethingCanBeDraggedOut() {
        #expect(ShelfPill(for: ShelfModel(), presentation: .empty, commandHeld: false) == nil)
        #expect(ShelfPill(for: two, presentation: .tucked, commandHeld: true) == nil)
        let lost = shelf(item("/t/a.txt", state: .missing), item("/t/b.txt", state: .inTrash))
        #expect(ShelfPill(for: lost, presentation: .collapsed, commandHeld: false) == nil)
        #expect(ShelfPill(for: lost, presentation: .expanded(rows: 2), commandHeld: false) == nil)
        let oneLeft = shelf(item("/t/a.txt", state: .missing), item("/t/b.txt"))
        #expect(ShelfPill(for: oneLeft, presentation: .collapsed, commandHeld: false) != nil)
        #expect(ShelfPill(for: oneLeft, presentation: .expanded(rows: 2), commandHeld: false) != nil)
    }
}
