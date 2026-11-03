import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

private func page(_ kind: WheelPageKind, _ count: Int, disabled: Set<Int> = []) -> WheelPage {
    WheelPage(kind: kind, slices: (0..<count).map { i in
        WheelSlice(id: "s\(i)", title: "Slice \(i)", symbol: "circle", kind: .preset(id: "s\(i)"),
                   isEnabled: !disabled.contains(i))
    })
}

@Suite struct WheelNavigatorTests {
    @Test func arrowsWrapAndDigitsActivate() {
        let pages = [page(.convert, 3), page(.tools, 2)]
        var n = WheelNavigator(pages: pages)
        #expect(n.selected == nil)
        #expect(n.handle(.right) == .moved)
        #expect(n.selected == 0)
        _ = n.handle(.left)
        #expect(n.selected == 2)
        #expect(n.handle(.digit(2)) == .activate(pages[0].slices[1]))
        #expect(n.handle(.tab) == .pageChanged)
        #expect(n.pageIndex == 1 && n.selected == nil)
        #expect(n.handle(.escape) == .dismiss)
    }

    @Test func clockwiseAndCounterClockwiseKeys() {
        var n = WheelNavigator(pages: [page(.convert, 4)])
        #expect(n.handle(.down) == .moved)
        #expect(n.selected == 0)
        _ = n.handle(.right)
        #expect(n.selected == 1)
        _ = n.handle(.down)
        #expect(n.selected == 2)
        _ = n.handle(.up)
        #expect(n.selected == 1)
        _ = n.handle(.left)
        _ = n.handle(.left)
        #expect(n.selected == 3)
        _ = n.handle(.right)
        #expect(n.selected == 0)
    }

    @Test func firstCounterClockwiseStepSelectsTheLast() {
        var n = WheelNavigator(pages: [page(.convert, 5)])
        #expect(n.handle(.up) == .moved)
        #expect(n.selected == 4)
    }

    @Test func enterActivatesTheSelection() {
        let pages = [page(.convert, 3)]
        var n = WheelNavigator(pages: pages)
        #expect(n.handle(.enter) == .none)
        _ = n.handle(.right)
        _ = n.handle(.right)
        #expect(n.handle(.enter) == .activate(pages[0].slices[1]))
    }

    @Test func navigatorSkipsDisabledOnEnter() {
        var n = WheelNavigator(pages: [page(.convert, 3, disabled: [1])])
        _ = n.handle(.right)
        #expect(n.handle(.right) == .moved)
        #expect(n.selected == 1)
        #expect(n.handle(.enter) == .none)
        #expect(n.selected == 1)
    }

    @Test func disabledDigitDoesNothing() {
        var n = WheelNavigator(pages: [page(.convert, 3, disabled: [0])])
        #expect(n.handle(.digit(1)) == .none)
        #expect(n.selected == nil)
    }

    @Test func outOfRangeDigitsDoNothing() {
        var n = WheelNavigator(pages: [page(.convert, 3)])
        #expect(n.handle(.digit(0)) == .none)
        #expect(n.handle(.digit(4)) == .none)
        #expect(n.handle(.digit(-1)) == .none)
        #expect(n.selected == nil)
    }

    @Test func tabAlternatesTheTwoPagesAndClearsSelection() {
        var n = WheelNavigator(pages: [page(.convert, 2), page(.tools, 2)])
        _ = n.handle(.right)
        #expect(n.handle(.tab) == .pageChanged)
        #expect(n.pageIndex == 1 && n.selected == nil)
        _ = n.handle(.right)
        #expect(n.handle(.tab) == .pageChanged)
        #expect(n.pageIndex == 0 && n.selected == nil)
    }

    @Test func tabOnASinglePageWrapsToItself() {
        var n = WheelNavigator(pages: [page(.convert, 2)])
        _ = n.handle(.right)
        #expect(n.handle(.tab) == .pageChanged)
        #expect(n.pageIndex == 0)
        #expect(n.selected == nil)
    }

    @Test func digitsFollowTheCurrentPage() {
        let pages = [page(.convert, 3), page(.tools, 2)]
        var n = WheelNavigator(pages: pages)
        _ = n.handle(.tab)
        #expect(n.handle(.digit(3)) == .none)
        #expect(n.handle(.digit(2)) == .activate(pages[1].slices[1]))
    }

    @Test func emptyNavigatorOnlyDismisses() {
        var n = WheelNavigator(pages: [])
        #expect(n.handle(.right) == .none)
        #expect(n.handle(.up) == .none)
        #expect(n.handle(.digit(1)) == .none)
        #expect(n.handle(.enter) == .none)
        #expect(n.handle(.tab) == .none)
        #expect(n.handle(.escape) == .dismiss)
    }

    @Test func emptyPageArrowsDoNothing() {
        var n = WheelNavigator(pages: [page(.convert, 0)])
        #expect(n.handle(.right) == .none)
        #expect(n.selected == nil)
    }
    @Test func selectSeedsTheNextStepAndEnter() {
        let pages = [page(.convert, 4)]
        var n = WheelNavigator(pages: pages)
        n.select(2)
        #expect(n.selected == 2)
        #expect(n.handle(.enter) == .activate(pages[0].slices[2]))
        #expect(n.handle(.right) == .moved)
        #expect(n.selected == 3)
        n.select(nil)
        #expect(n.selected == nil)
        #expect(n.handle(.enter) == .none)
    }

    @Test func selectClearsTheSelectionForAnIndexOffThePage() {
        var n = WheelNavigator(pages: [page(.convert, 3)])
        n.select(1)
        n.select(3)
        #expect(n.selected == nil)
        n.select(-1)
        #expect(n.selected == nil)
    }

    /// When a readability verdict disables slices, the keyboard carries on where it was, over the new pages.
    @Test func aNavigatorRebuiltOverNewPagesKeepsItsPageAndSelection() {
        let disabled = [page(.convert, 3, disabled: [0, 1, 2]), page(.tools, 2)]
        var n = WheelNavigator(pages: disabled, pageIndex: 0, selected: 1)
        #expect(n.pageIndex == 0 && n.selected == 1)
        #expect(n.handle(.enter) == .none)
        #expect(n.handle(.digit(1)) == .none)

        let clamped = WheelNavigator(pages: disabled, pageIndex: 5, selected: 9)
        #expect(clamped.pageIndex == 0 && clamped.selected == nil)
        let second = WheelNavigator(pages: disabled, pageIndex: 1, selected: 1)
        #expect(second.pageIndex == 1 && second.selected == 1)
    }
}
