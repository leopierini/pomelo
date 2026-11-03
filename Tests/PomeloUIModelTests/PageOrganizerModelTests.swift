import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Organize pages editor's choices (P27): the output's pages, their rotations and the selection.
@Suite struct PageOrganizerModelTests {
    private func model(_ count: Int = 5) -> PageOrganizerModel { PageOrganizerModel(pageCount: count) }

    private func order(_ model: PageOrganizerModel) -> [Int] { model.pages.map(\.page) }

    @Test func startsAsTheIdentityAndBlocks() {
        let model = model()
        #expect(order(model) == [0, 1, 2, 3, 4])
        #expect(model.pages.allSatisfy { $0.rotation == 0 })
        #expect(model.selection.isEmpty)
        #expect(model.blocker == PageOrganizerModel.noChanges)
        #expect(model.blocker == "No changes")
        #expect(model.spec == nil)
        #expect(model.summary == "5 pages")
    }

    @Test func moveReorders() {
        var model = model()
        model.move(from: [0], to: 3)
        #expect(order(model) == [1, 2, 0, 3, 4])
        #expect(model.blocker == nil)

        model.move(from: [4], to: 0)
        #expect(order(model) == [4, 1, 2, 0, 3])
        model.move(from: [0], to: 5)
        #expect(order(model) == [1, 2, 0, 3, 4], "past the last page means the end")
    }

    @Test func moveKeepsTheOrderOfSeveralPages() {
        var model = model()
        model.move(from: [1, 3], to: 5)
        #expect(order(model) == [0, 2, 4, 1, 3])
        model.move(from: [3, 4], to: 0)
        #expect(order(model) == [1, 3, 0, 2, 4])
        model.move(from: [], to: 2)
        model.move(from: [9], to: 2)
        #expect(order(model) == [1, 3, 0, 2, 4], "nothing to lift")
    }

    @Test func movingPutsThePagesBackWhereTheyWereIsNoChange() {
        var model = model()
        model.move(from: [2], to: 2)
        model.move(from: [2], to: 3)
        #expect(order(model) == [0, 1, 2, 3, 4])
        #expect(model.blocker == PageOrganizerModel.noChanges)
    }

    @Test func moveSelectedFollowsTheSelection() {
        var model = model()
        model.click(2)
        model.moveSelected(by: -1)
        #expect(order(model) == [0, 2, 1, 3, 4])
        #expect(model.selection == [1])
        model.moveSelected(by: 3)
        #expect(order(model) == [0, 1, 3, 4, 2])
        #expect(model.selection == [4])
        model.moveSelected(by: 1)
        #expect(order(model) == [0, 1, 3, 4, 2], "the last page stays")
        #expect(model.selection == [4])
    }

    @Test func aSeveralPageSelectionStopsAtTheEdgeTogether() {
        var model = model()
        model.click(1)
        model.click(3, toggle: true)
        model.moveSelected(by: -1)
        #expect(order(model) == [1, 0, 3, 2, 4])
        #expect(model.selection == [0, 2])
        model.moveSelected(by: -1)
        #expect(order(model) == [1, 3, 0, 2, 4], "the one at the edge stays, the other goes on")
        #expect(model.selection == [0, 1])
    }

    @Test func rotationAddsClockwiseAndWraps() {
        var model = model()
        model.click(0)
        for _ in 0..<5 { model.rotateSelected(clockwise: true) }
        #expect(model.pages[0].rotation == 90)
        #expect(model.pages[1].rotation == 0, "only the selection turns")
        model.click(1)
        model.rotateSelected(clockwise: false)
        #expect(model.pages[1].rotation == 270)
        model.rotateSelected(clockwise: true)
        #expect(model.pages[1].rotation == 0)
        #expect(model.summary == "5 pages, 1 rotated")
    }

    @Test func rotatingNothingChangesNothing() {
        var model = model()
        model.rotateSelected(clockwise: true)
        #expect(model == self.model())
    }

    @Test func deletingTheSelectionDropsThosePages() {
        var model = model()
        model.click(1)
        model.click(3, toggle: true)
        model.deleteSelected()
        #expect(order(model) == [0, 2, 4])
        #expect(model.selection == [1], "the page that took the first one's place")
        model.deleteSelected()
        model.deleteSelected()
        #expect(order(model) == [0])
        #expect(model.selection == [0], "the last page is selected once the end is reached")
    }

    @Test func deletingEveryPageBlocks() {
        var model = model(3)
        model.selectAll()
        model.deleteSelected()
        #expect(model.pages.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.blocker == "Keep at least one page")
        #expect(model.spec == nil)
        #expect(model.summary == "0 pages, 3 removed")
    }

    @Test func summaryCountsChanges() {
        var model = model()
        model.click(4)
        model.deleteSelected()
        model.click(0)
        model.rotateSelected(clockwise: true)
        #expect(model.summary == "4 pages, 1 removed, 1 rotated")

        var one = self.model(2)
        one.click(1)
        one.deleteSelected()
        #expect(one.summary == "1 page, 1 removed")
    }

    @Test func specListsTheOutputPages() {
        var model = model(3)
        model.move(from: [2], to: 0)
        model.click(1)
        model.rotateSelected(clockwise: true)
        model.click(2)
        model.deleteSelected()
        #expect(model.spec == .organize([PageEdit(page: 2, rotation: 0), PageEdit(page: 0, rotation: 90)]))
        #expect(model.blocker == nil)
    }

    @Test func anIdentityWithRotationIsAChange() {
        var model = model(2)
        model.click(0)
        model.rotateSelected(clockwise: true)
        #expect(model.blocker == nil)
        model.rotateSelected(clockwise: false)
        #expect(model.blocker == PageOrganizerModel.noChanges)
    }

    @Test func aDocumentWithNoPagesBlocks() {
        #expect(PageOrganizerModel(pageCount: 0).blocker == "Keep at least one page")
    }

    // MARK: Selection

    @Test func aClickSelectsOnePage() {
        var model = model()
        model.click(2)
        model.click(3)
        #expect(model.selection == [3])
        model.click(9)
        #expect(model.selection == [3], "outside the pages")
    }

    @Test func commandClickToggles() {
        var model = model()
        model.click(1)
        model.click(3, toggle: true)
        #expect(model.selection == [1, 3])
        model.click(1, toggle: true)
        #expect(model.selection == [3])
    }

    @Test func shiftClickSelectsFromTheAnchor() {
        var model = model()
        model.click(1)
        model.click(3, extend: true)
        #expect(model.selection == [1, 2, 3])
        model.click(0, extend: true)
        #expect(model.selection == [0, 1], "the anchor stays at the first click")
        model.click(4, toggle: true)
        model.click(2, extend: true)
        #expect(model.selection == [2, 3, 4], "a ⌘-click moves the anchor")
    }

    @Test func theArrowsMoveAndExtendTheSelection() {
        var model = model()
        model.step(by: 1, extend: false)
        #expect(model.selection == [0], "the first page when nothing is selected")
        model.step(by: 1, extend: false)
        #expect(model.selection == [1])
        model.step(by: 1, extend: true)
        model.step(by: 1, extend: true)
        #expect(model.selection == [1, 2, 3])
        model.step(by: -1, extend: true)
        #expect(model.selection == [1, 2])
        model.step(by: 1, extend: false)
        #expect(model.selection == [3], "past the end of a plain selection")
        for _ in 0..<9 { model.step(by: 1, extend: false) }
        #expect(model.selection == [4], "it stops at the last page")

        var fresh = self.model()
        fresh.step(by: -1, extend: false)
        #expect(fresh.selection == [4], "the last page when going back with nothing selected")
    }

    @Test func aMoveKeepsTheSelectionOnItsPages() {
        var model = model()
        model.click(1)
        model.click(2, extend: true)
        model.move(from: [1, 2], to: 5)
        #expect(order(model) == [0, 3, 4, 1, 2])
        #expect(model.selection == [3, 4])
        model.step(by: 1, extend: false)
        #expect(model.selection == [4], "the keys go on from the moved page")
    }

    @Test func selectAllSelectsEveryPage() {
        var model = model()
        model.selectAll()
        #expect(model.selection == [0, 1, 2, 3, 4])
        model.clearSelection()
        #expect(model.selection.isEmpty)
    }

    @Test func aPageReadsItsNumberPositionAndRotation() {
        var model = model()
        model.move(from: [3], to: 0)
        #expect(model.label(at: 0) == "Page 4, position 1 of 5")
        model.click(0)
        model.rotateSelected(clockwise: true)
        #expect(model.label(at: 0) == "Page 4, position 1 of 5, rotated 90\u{00B0}")
        #expect(model.label(at: 9) == "")
    }
}
