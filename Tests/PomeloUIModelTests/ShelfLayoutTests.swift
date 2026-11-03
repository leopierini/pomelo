import CoreGraphics
import PomeloUIModel
import Testing

@Suite struct ShelfLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let drawer = CGSize(width: 112, height: 132)

    @Test func sizesPerPresentation() {
        #expect(ShelfLayout.pillBand == 30)
        #expect(ShelfLayout.size(.empty) == CGSize(width: 128, height: 132))
        #expect(ShelfLayout.size(.collapsed) == CGSize(width: 128, height: 132 + 30))
        #expect(ShelfLayout.size(.tucked) == CGSize(width: 14, height: 56))
        #expect(ShelfLayout.size(.expanded(rows: 2)) == CGSize(width: 260, height: 28 + 64 + 8 + 30))
        #expect(ShelfLayout.size(.expanded(rows: 6)) == CGSize(width: 260, height: 258))
        #expect(ShelfLayout.size(.expanded(rows: 40)) == CGSize(width: 260, height: 258))
        #expect(ShelfLayout.size(.expanded(rows: 0)) == CGSize(width: 260, height: 66))
    }

    /// R30: the key pill's band is the drawer's bottom 30 pt, below everything else, in both presentations.
    @Test func thePillBandIsBelowEverything() {
        // Collapsed: the stack and its labels keep the 132 pt they had; the band is added under them.
        #expect(ShelfLayout.size(.collapsed).height - ShelfLayout.pillBand == ShelfLayout.size(.empty).height)
        // Expanded: the header, the rows and the list's padding end where the band starts, and no row is under it.
        for count in [1, 2, 6, 10] {
            let height = ShelfLayout.size(.expanded(rows: count)).height
            let rows = CGFloat(min(count, 6)) * ShelfLayout.rowHeight
            #expect(ShelfLayout.headerHeight + ShelfLayout.listPadding + rows == height - ShelfLayout.pillBand)
            #expect(ShelfLayout.row(atDepth: height - ShelfLayout.pillBand, scrollOffset: 0, count: count) == nil)
            #expect(ShelfLayout.row(atDepth: height - 1, scrollOffset: ShelfLayout.maxScrollOffset(count: count),
                                    count: count) == nil)
        }
    }

    @Test func centredWhenThereIsRoom() {
        let c = CGPoint(x: 700, y: 400)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: screen, keepingInside: c)
        #expect(f == CGRect(x: 644, y: 334, width: 112, height: 132))
    }

    @Test func cursorIsAlwaysInside() {
        let c = CGPoint(x: 1437, y: 2)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: screen, keepingInside: c)
        #expect(f.contains(c))
        #expect(f.maxX == 1440 && f.minY == 0)
        #expect(screen.contains(f))
    }

    @Test func cursorOverTheDockIsStillInside() {
        let aboveDock = CGRect(x: 0, y: 70, width: 1440, height: 830)
        let c = CGPoint(x: 700, y: 30)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: aboveDock, keepingInside: c)
        #expect(f.contains(c))
        #expect(f == CGRect(x: 644, y: 30, width: 112, height: 132))
    }

    @Test func cursorInTheMenuBarBandIsStillInside() {
        let belowBar = CGRect(x: 0, y: 0, width: 1440, height: 876)
        let c = CGPoint(x: 700, y: 890)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: belowBar, keepingInside: c)
        #expect(f.contains(c))
        #expect(f == CGRect(x: 644, y: 759, width: 112, height: 132))
    }

    @Test func cursorExactlyOnTheMaxEdgesIsInside() {
        for c in [CGPoint(x: 1440, y: 450), CGPoint(x: 700, y: 900), CGPoint(x: 1440, y: 900),
                  CGPoint(x: 1432, y: 450), CGPoint(x: 700, y: 892), CGPoint(x: 1432, y: 892)] {
            let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: screen, keepingInside: c)
            #expect(f.contains(c), "cursor \(c)")
        }
    }

    @Test func aVisibleFrameSmallerThanTheShelfKeepsTheCursorInside() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
        let c = CGPoint(x: 50, y: 50)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: tiny, keepingInside: c)
        #expect(f.contains(c))
        #expect(f.minX == 8 && f.maxY == 92)
    }

    @Test func aSecondDisplayWithANegativeOriginHoldsTheCursor() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let c = CGPoint(x: -3, y: 500)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: second, keepingInside: c)
        #expect(f == CGRect(x: -112, y: 434, width: 112, height: 132))
        #expect(f.contains(c))
    }

    @Test func cursorCloseToOneEdgeKeepsTheMarginOnTheOtherAxis() {
        let c = CGPoint(x: 1437, y: 450)
        let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: screen, keepingInside: c)
        #expect(f == CGRect(x: 1328, y: 384, width: 112, height: 132))
    }

    @Test func cursorAtTheScreenCorner() {
        for c in [CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 900), CGPoint(x: 0, y: 900), CGPoint(x: 1440, y: 0)] {
            let f = ShelfLayout.frame(centredOn: c, size: drawer, visibleFrame: screen, keepingInside: c)
            #expect(f.contains(c))
        }
    }

    @Test func dropPointIsClampedLikeAnEditor() {
        let p = CGPoint(x: 1400, y: 60)
        let f = ShelfLayout.frame(centredOn: p, size: drawer, visibleFrame: screen, keepingInside: nil)
        #expect(f == CGRect(x: 1320, y: 8, width: 112, height: 132))
        #expect(f == ScreenFit.clamp(CGRect(x: 1344, y: -6, width: 112, height: 132), into: screen, margin: 8))
    }

    @Test func menuFirstTimeIsRightMiddle() {
        let f = ShelfLayout.menuFrame(size: drawer, last: nil, visibleFrames: [screen], pointerScreen: screen)
        #expect(f == CGRect(x: 1320, y: 384, width: 112, height: 132))
    }

    @Test func menuReusesTheLastPlaceOnScreen() {
        let last = CGRect(x: 300, y: 200, width: 112, height: 132)
        let f = ShelfLayout.menuFrame(size: drawer, last: last, visibleFrames: [screen], pointerScreen: screen)
        #expect(f == last)
    }

    @Test func menuLastPlaceOffScreenGoesToThePointersScreen() {
        let gone = CGRect(x: 5000, y: 200, width: 112, height: 132)
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let f = ShelfLayout.menuFrame(size: drawer, last: gone, visibleFrames: [screen, second], pointerScreen: second)
        #expect(f == CGRect(x: 3240, y: 474, width: 112, height: 132))
    }

    @Test func menuLastPlaceKeepsItsScreenWhenSizeChanges() {
        let last = CGRect(x: 1300, y: 600, width: 112, height: 132)
        let f = ShelfLayout.menuFrame(size: ShelfLayout.size(.expanded(rows: 3)), last: last,
                                      visibleFrames: [screen], pointerScreen: screen)
        #expect(f.maxY == last.maxY)
        #expect(screen.contains(f))
    }

    @Test func tabOnTheNearestSide() {
        let left = ShelfLayout.tab(for: CGRect(x: 100, y: 300, width: 112, height: 132), visibleFrame: screen)
        #expect(left.side == .left)
        #expect(left.frame == CGRect(x: 0, y: 338, width: 14, height: 56))
        let right = ShelfLayout.tab(for: CGRect(x: 1000, y: 300, width: 112, height: 132), visibleFrame: screen)
        #expect(right.side == .right)
        #expect(right.frame == CGRect(x: 1426, y: 338, width: 14, height: 56))
    }

    @Test func tabStaysInsideTheVisibleFrame() {
        let t = ShelfLayout.tab(for: CGRect(x: 100, y: 0, width: 112, height: 20), visibleFrame: screen)
        #expect(screen.contains(t.frame))
        let top = ShelfLayout.tab(for: CGRect(x: 100, y: 890, width: 112, height: 132), visibleFrame: screen)
        #expect(screen.contains(top.frame))
    }

    @Test func tabOnANegativeOriginDisplay() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let left = ShelfLayout.tab(for: CGRect(x: -1800, y: 500, width: 112, height: 132), visibleFrame: second)
        #expect(left.side == .left)
        #expect(left.frame == CGRect(x: -1920, y: 538, width: 14, height: 56))
        let right = ShelfLayout.tab(for: CGRect(x: -300, y: 500, width: 112, height: 132), visibleFrame: second)
        #expect(right.side == .right)
        #expect(right.frame == CGRect(x: -14, y: 538, width: 14, height: 56))
    }

    @Test func menuUnchangedSizeStaysFlush() {
        let flush = CGRect(x: 1328, y: 0, width: 112, height: 132)
        let f = ShelfLayout.menuFrame(size: drawer, last: flush, visibleFrames: [screen], pointerScreen: screen)
        #expect(f == flush)
    }

    @Test func expandKeepsTheTopEdge() {
        let f = CGRect(x: 600, y: 400, width: 112, height: 132)
        let e = ShelfLayout.resized(f, to: ShelfLayout.size(.expanded(rows: 4)), visibleFrame: screen)
        #expect(e.maxY == f.maxY && e.minX == f.minX)
        #expect(e.size == CGSize(width: 260, height: 194))
    }

    @Test func expandNearTheRightEdgeStaysOnScreen() {
        let f = CGRect(x: 1320, y: 400, width: 112, height: 132)
        let e = ShelfLayout.resized(f, to: ShelfLayout.size(.expanded(rows: 4)), visibleFrame: screen)
        #expect(e.maxX == 1432 && e.maxY == f.maxY)
    }

    @Test func collapseKeepsTheTopEdge() {
        let f = CGRect(x: 600, y: 300, width: 260, height: 232)
        let c = ShelfLayout.resized(f, to: drawer, visibleFrame: screen)
        #expect(c.maxY == f.maxY)
    }

    @Test func settledIsClampedIntoItsScreen() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let hanging = CGRect(x: 1300, y: -50, width: 112, height: 132)
        #expect(ShelfLayout.settled(hanging, visibleFrames: [screen, second]) == CGRect(x: 1300, y: 8, width: 112, height: 132))
        let inside = CGRect(x: 500, y: 500, width: 112, height: 132)
        #expect(ShelfLayout.settled(inside, visibleFrames: [screen, second]) == inside)
    }

    @Test func settledOffEveryScreenGoesToTheNearest() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let far = CGRect(x: 5000, y: 300, width: 112, height: 132)
        let f = ShelfLayout.settled(far, visibleFrames: [screen, second])
        #expect(f == CGRect(x: 3240, y: 300, width: 112, height: 132))
    }

    @Test func settledOnANegativeOriginDisplay() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let hanging = CGRect(x: -1000, y: -50, width: 112, height: 132)
        #expect(ShelfLayout.settled(hanging, visibleFrames: [screen, second]) == CGRect(x: -1000, y: 8, width: 112, height: 132))
    }

    @Test func settledWithTheCentreOnTheSeamPicksTheFirstDisplayListed() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let onSeam = CGRect(x: 1384, y: 400, width: 112, height: 132)
        #expect(ShelfLayout.settled(onSeam, visibleFrames: [screen, second]) == CGRect(x: 1320, y: 400, width: 112, height: 132))
        #expect(ShelfLayout.settled(onSeam, visibleFrames: [second, screen]) == CGRect(x: 1448, y: 400, width: 112, height: 132))
    }

    @Test func replacedOntoALargerDisplayThanBefore() {
        let old = CGRect(x: 0, y: 0, width: 800, height: 600)
        let new = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let rightMiddle = CGRect(x: 680, y: 234, width: 112, height: 132)
        #expect(ShelfLayout.replaced(rightMiddle, from: old, to: new) == CGRect(x: 2440, y: 654, width: 112, height: 132))
    }

    @Test func replacedOntoANegativeOriginDisplay() {
        let old = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let new = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let f = ShelfLayout.replaced(CGRect(x: 8, y: 8, width: 112, height: 132), from: old, to: new)
        #expect(f == CGRect(x: -1912, y: 8, width: 112, height: 132))
    }

    @Test func replacedKeepsTheRelativePlace() {
        let old = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let new = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let rightMiddle = ShelfLayout.menuFrame(size: drawer, last: nil, visibleFrames: [old], pointerScreen: old)
        let f = ShelfLayout.replaced(rightMiddle, from: old, to: new)
        #expect(f == CGRect(x: 2440, y: 654, width: 112, height: 132))
    }

    @Test func replacedFollowsAnotherDisplaysOrigin() {
        let old = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let new = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let f = ShelfLayout.replaced(CGRect(x: 8, y: 8, width: 112, height: 132), from: old, to: new)
        #expect(f == CGRect(x: 1448, y: 8, width: 112, height: 132))
    }

    @Test func replacedIntoASmallerScreenStaysInside() {
        let old = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let new = CGRect(x: 0, y: 0, width: 800, height: 600)
        let f = ShelfLayout.replaced(CGRect(x: 2440, y: 1300, width: 112, height: 132), from: old, to: new)
        #expect(new.contains(f))
    }

    // MARK: The expanded list (S8)

    /// Rows start under the 28 pt header and half the list's 8 pt padding; depths are points from the drawer's top.
    @Test func rowAtADepth() {
        #expect(ShelfLayout.row(atDepth: 10, scrollOffset: 0, count: 3) == nil)
        #expect(ShelfLayout.row(atDepth: 31.9, scrollOffset: 0, count: 3) == nil)
        #expect(ShelfLayout.row(atDepth: 32, scrollOffset: 0, count: 3) == 0)
        #expect(ShelfLayout.row(atDepth: 63.9, scrollOffset: 0, count: 3) == 0)
        #expect(ShelfLayout.row(atDepth: 64, scrollOffset: 0, count: 3) == 1)
        #expect(ShelfLayout.row(atDepth: 127, scrollOffset: 0, count: 3) == 2)
        // Below the last row: the list's bottom padding.
        #expect(ShelfLayout.row(atDepth: 128, scrollOffset: 0, count: 3) == nil)
        // Scrolled by a row and a half: the top of the list shows the second row's lower half.
        #expect(ShelfLayout.row(atDepth: 32, scrollOffset: 48, count: 10) == 1)
        #expect(ShelfLayout.row(atDepth: 50, scrollOffset: 48, count: 10) == 2)
        // Six rows show; the seventh band is the padding even with more rows.
        #expect(ShelfLayout.row(atDepth: 32 + 6 * 32 - 1, scrollOffset: 0, count: 10) == 5)
        #expect(ShelfLayout.row(atDepth: 32 + 6 * 32, scrollOffset: 0, count: 10) == nil)
        #expect(ShelfLayout.row(atDepth: 40, scrollOffset: 0, count: 0) == nil)
    }

    @Test func visibleRowsAndScrolling() {
        #expect(ShelfLayout.visibleRows(scrollOffset: 0, count: 3) == 0..<3)
        #expect(ShelfLayout.visibleRows(scrollOffset: 0, count: 10) == 0..<6)
        #expect(ShelfLayout.visibleRows(scrollOffset: 48, count: 10) == 1..<8)
        #expect(ShelfLayout.visibleRows(scrollOffset: 128, count: 10) == 4..<10)
        #expect(ShelfLayout.maxScrollOffset(count: 3) == 0)
        #expect(ShelfLayout.maxScrollOffset(count: 10) == 128)
    }

    @Test func scrollingRevealsARow() {
        // Already visible: unchanged.
        #expect(ShelfLayout.scrollOffset(revealing: 2, from: 0, count: 10) == 0)
        // Below: its bottom meets the list's bottom.
        #expect(ShelfLayout.scrollOffset(revealing: 6, from: 0, count: 10) == 32)
        #expect(ShelfLayout.scrollOffset(revealing: 9, from: 0, count: 10) == 128)
        // Above: its top meets the list's top.
        #expect(ShelfLayout.scrollOffset(revealing: 1, from: 128, count: 10) == 32)
        #expect(ShelfLayout.scrollOffset(revealing: 0, from: 20, count: 10) == 0)
        // A list that shrank keeps no offset it no longer has.
        #expect(ShelfLayout.scrollOffset(revealing: 0, from: 128, count: 3) == 0)
    }

    /// Open the Wheel (S17) opens it beside the drawer: right when it fits, else left, never over it.
    @Test func wheelBesideTheDrawer() {
        let wheel = CGSize(width: 360, height: 400)
        let middle = CGRect(x: 600, y: 400, width: 112, height: 132)
        #expect(ShelfLayout.wheelCentre(beside: middle, wheelSize: wheel, visibleFrame: screen)
            == CGPoint(x: 712 + 180, y: 466))
        let rightEdge = CGRect(x: 1320, y: 400, width: 112, height: 132)
        #expect(ShelfLayout.wheelCentre(beside: rightEdge, wheelSize: wheel, visibleFrame: screen)
            == CGPoint(x: 1320 - 180, y: 466))
        // No room on either side: the side with more.
        let narrow = CGRect(x: 0, y: 0, width: 600, height: 900)
        let nearLeft = CGRect(x: 200, y: 400, width: 112, height: 132)
        #expect(ShelfLayout.wheelCentre(beside: nearLeft, wheelSize: wheel, visibleFrame: narrow)
            == CGPoint(x: 312 + 180, y: 466))
    }
}
