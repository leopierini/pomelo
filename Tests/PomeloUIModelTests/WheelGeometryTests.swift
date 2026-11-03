import CoreGraphics
import Foundation
import Testing
@testable import PomeloUIModel

@Suite struct WheelGeometryTests {
    @Test func fourSlicesClockwiseFromTop() {
        let g = WheelGeometry(sliceCount: 4)
        #expect(g.hitTest(CGPoint(x: 0, y: 120)) == .slice(0)); #expect(g.hitTest(CGPoint(x: 120, y: 0)) == .slice(1))
        #expect(g.hitTest(CGPoint(x: 0, y: -120)) == .slice(2)); #expect(g.hitTest(CGPoint(x: -120, y: 0)) == .slice(3))
    }
    @Test func hubAndOutside() {
        let g = WheelGeometry(sliceCount: 8)
        #expect(g.hitTest(CGPoint(x: 10, y: 10)) == .hub); #expect(g.hitTest(CGPoint(x: 0, y: 200)) == .outside)
    }
    @Test func sliceBoundariesForEight() {
        let g = WheelGeometry(sliceCount: 8)   // slice 0 spans −22.5°…+22.5° around 12 o'clock
        let r = 120.0, a = 22.0 * .pi / 180, b = 23.0 * .pi / 180
        #expect(g.hitTest(CGPoint(x: r * sin(a), y: r * cos(a))) == .slice(0))
        #expect(g.hitTest(CGPoint(x: r * sin(b), y: r * cos(b))) == .slice(1))
    }
    @Test func zeroSlicesOnlyHub() { #expect(WheelGeometry(sliceCount: 0).hitTest(CGPoint(x: 0, y: 120)) == .outside) }
    @Test func labelCenterOnMidRadius() {
        let p = WheelGeometry(sliceCount: 4).labelCenter(ofSlice: 1)
        #expect(abs(p.x - (66 + 170) / 2) < 0.5 && abs(p.y) < 0.5)
    }
    @Test func panelCenteredOnCursor() {
        #expect(WheelGeometry.panelOrigin(cursor: CGPoint(x: 500, y: 500), panelSize: CGSize(width: 360, height: 400),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)) == CGPoint(x: 320, y: 300))
    }
    @Test func panelClampedToVisibleFrame() {
        #expect(WheelGeometry.panelOrigin(cursor: CGPoint(x: 10, y: 890), panelSize: CGSize(width: 360, height: 400),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)) == CGPoint(x: 0, y: 500))
    }
    @Test func panelOnSecondaryScreenWithNegativeOrigin() {
        #expect(WheelGeometry.panelOrigin(cursor: CGPoint(x: -1900, y: 100), panelSize: CGSize(width: 360, height: 400),
                visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)) == CGPoint(x: -1920, y: 0))
    }
    @Test func panelLargerThanVisibleFramePinsToMinCorner() {
        #expect(WheelGeometry.panelOrigin(cursor: CGPoint(x: 100, y: 100), panelSize: CGSize(width: 500, height: 600),
                visibleFrame: CGRect(x: 10, y: 20, width: 300, height: 400)) == CGPoint(x: 10, y: 20))
    }
}

@Suite struct WheelInsertionIndexTests {
    private func ring(_ degrees: Double, radius: Double = 120) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: radius * sin(a), y: radius * cos(a))
    }

    @Test func insertionIndexSplitsEachSliceInHalves() {
        let g = WheelGeometry(sliceCount: 4)
        #expect(g.insertionIndex(at: ring(10)) == 1)
        #expect(g.insertionIndex(at: ring(350)) == 0)
        #expect(g.insertionIndex(at: ring(100)) == 2)
        #expect(g.insertionIndex(at: ring(80)) == 1)
        #expect(g.insertionIndex(at: ring(190)) == 3)
        #expect(g.insertionIndex(at: ring(260)) == 3)
        #expect(g.insertionIndex(at: ring(280)) == 4)   // after the last slice: append
    }

    @Test func insertionIndexIsNilOnHubAndOutside() {
        let g = WheelGeometry(sliceCount: 4)
        #expect(g.insertionIndex(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(g.insertionIndex(at: ring(45, radius: 200)) == nil)
    }

    @Test func insertionIndexWithNoSlicesIsZeroOnTheRing() {
        let g = WheelGeometry(sliceCount: 0)
        #expect(g.insertionIndex(at: ring(45)) == 0)
        #expect(g.insertionIndex(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(g.insertionIndex(at: ring(45, radius: 200)) == nil)
    }

    /// A view's top-left, y-down location: the top-right of the frame is up and to the right of the centre.
    @Test func centredFromTopLeft() {
        let g = WheelGeometry(sliceCount: 4)
        #expect(g.centred(fromTopLeft: CGPoint(x: 170, y: 170)) == .zero)
        #expect(g.centred(fromTopLeft: CGPoint(x: 290, y: 50)) == CGPoint(x: 120, y: 120))
        #expect(g.hitTest(g.centred(fromTopLeft: CGPoint(x: 170, y: 50))) == .slice(0))
        #expect(g.hitTest(g.centred(fromTopLeft: CGPoint(x: 170, y: 290))) == .slice(2))
    }
}
