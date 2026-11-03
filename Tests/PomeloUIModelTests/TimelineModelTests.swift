import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Trim and Split editors' timeline (P27): handles, steps, points, the range played and what the footer says.
@Suite struct TimelineModelTests {
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// `#expect` can't take a mutating call.
    private func add(_ model: inout TimelineModel) -> Bool { model.addPoint() }

    @Test func clockFormats() {
        #expect(TimeFormat.clock(2.44) == "0:02.4")
        #expect(TimeFormat.clock(83) == "1:23.0")
        #expect(TimeFormat.clock(3723) == "1:02:03.0")
        #expect(TimeFormat.clock(0) == "0:00.0")
        // Rounded to tenths before the minutes are counted.
        #expect(TimeFormat.clock(59.96) == "1:00.0")
        #expect(TimeFormat.clock(3599.97) == "1:00:00.0")
        #expect(TimeFormat.clock(-1) == "0:00.0")
        #expect(TimeFormat.clock(.nan) == "0:00.0")
    }

    @Test func handlesStayInOrderAndApart() {
        var model = TimelineModel(duration: 10, frameRate: 30)
        #expect(model.start == 0 && model.end == 10 && model.playhead == 0)
        model.set(.start, to: 9.95)
        #expect(near(model.start, 9.9))
        model.set(.end, to: 2)
        #expect(near(model.end, 10), "the end stays the minimum length after the start")
        model.set(.start, to: 2)
        model.set(.end, to: 2.05)
        #expect(near(model.end, 2 + TimelineModel.minimumLength))
        model.set(.start, to: -3)
        #expect(model.start == 0)
        model.set(.end, to: 40)
        #expect(model.end == 10)
        model.set(.playhead, to: 11)
        #expect(model.playhead == 10)
        model.set(.playhead, to: -1)
        #expect(model.playhead == 0)
        #expect(TimelineModel.minimumLength == TimeEdit.minimumLength)
    }

    @Test func nudgeMovesAFrameOrASecond() {
        var model = TimelineModel(duration: 10, frameRate: 30)
        #expect(near(model.step, 1.0 / 30))
        model.nudge(.start, steps: 1, coarse: false)
        #expect(near(model.start, 1.0 / 30))
        model.nudge(.start, steps: 1, coarse: true)
        #expect(near(model.start, 1 + 1.0 / 30))
        model.nudge(.end, steps: -2, coarse: true)
        #expect(near(model.end, 8))
        model.nudge(.playhead, steps: -1, coarse: false)
        #expect(model.playhead == 0, "clamped at the start of the file")
    }

    @Test func audioStepsAreHundredths() {
        var model = TimelineModel(duration: 5, frameRate: nil)
        #expect(model.step == 0.01)
        model.nudge(.playhead, steps: 3, coarse: false)
        #expect(near(model.playhead, 0.03))
        #expect(TimelineModel(duration: 5, frameRate: 0).step == 0.01)
    }

    @Test func trimReadoutAndBlocker() {
        var model = TimelineModel(duration: 83, frameRate: 30)
        #expect(model.trimBlocker == "Nothing to trim")
        #expect(model.trimSpec == nil)
        model.set(.start, to: 2.4)
        model.set(.end, to: 10)
        #expect(model.trimReadout == "Keeps 7.6 s of 1:23.0")
        #expect(model.trimBlocker == nil)
        model.set(.end, to: 77.4)
        #expect(model.trimReadout == "Keeps 1:15.0 of 1:23.0")
        // Within the tolerance of both ends is still the whole file.
        model.set(.start, to: 0.05)
        model.set(.end, to: 82.96)
        #expect(model.trimBlocker == "Nothing to trim")
    }

    @Test func trimSpecUsesTheHandles() {
        var model = TimelineModel(duration: 10, frameRate: 30)
        model.set(.start, to: 2)
        model.set(.end, to: 6)
        #expect(model.trimSpec == .trim(TimeRange(start: 2, end: 6)))
    }

    @Test func pointsAddAtThePlayheadAndRefuseCrowding() {
        var model = TimelineModel(duration: 6, frameRate: 30)
        model.set(.playhead, to: 2)
        #expect(add(&model))
        #expect(model.points == [2])
        model.set(.playhead, to: 2.05)
        #expect(!add(&model))
        model.set(.playhead, to: 0.05)
        #expect(!add(&model))
        model.set(.playhead, to: 5.95)
        #expect(!add(&model))
        model.set(.playhead, to: 1)
        #expect(add(&model))
        #expect(model.points == [1, 2], "kept in order")
        model.set(.point(1), to: 0.5)
        #expect(near(model.points[1], 1.1), "a point stays the spacing after its neighbour")
        model.set(.point(0), to: 0)
        #expect(near(model.points[0], TimeEdit.pointSpacing))
        model.removePoint(0)
        #expect(model.points.count == 1 && near(model.points[0], 1.1))
        model.removePoint(5)
        #expect(model.points.count == 1)
    }

    @Test func splitReadoutListsParts() {
        var model = TimelineModel(duration: 6, frameRate: 30)
        #expect(model.splitBlocker == "Add a split point (S)")
        #expect(model.splitSpec == nil)
        for point in [2.0, 4.0] {
            model.set(.playhead, to: point)
            #expect(add(&model))
        }
        #expect(model.splitReadout == "3 parts: 0:02.0, 0:02.0, 0:02.0")
        #expect(model.splitBlocker == nil)
        #expect(model.splitSpec == .split([2, 4]))

        var many = TimelineModel(duration: 70, frameRate: 30)
        for point in stride(from: 10.0, through: 60, by: 10) {
            many.set(.playhead, to: point)
            #expect(add(&many))
        }
        #expect(many.splitReadout == "7 parts: 0:10.0, 0:10.0, 0:10.0, 0:10.0, 0:10.0, \u{2026}")
    }

    @Test func playRangeStartsAtThePlayheadInsideTheSelection() {
        var model = TimelineModel(duration: 10, frameRate: 30)
        model.set(.start, to: 2)
        model.set(.end, to: 6)
        model.set(.playhead, to: 4)
        #expect(model.playRange() == 4...6)
        model.set(.playhead, to: 7)
        #expect(model.playRange() == 2...6)
        // Stopped at the end grip: playing again starts over.
        model.set(.playhead, to: 6)
        #expect(model.playRange() == 2...6)
    }

    @Test func aFileShorterThanTheMinimumKeepsItsWholeRange() {
        var model = TimelineModel(duration: 0.05, frameRate: nil)
        model.set(.start, to: 0.03)
        #expect(model.start == 0 && model.end == 0.05)
        #expect(model.trimBlocker == "Nothing to trim")
    }

    @Test func valuesReadEachHandle() {
        var model = TimelineModel(duration: 6, frameRate: 30)
        model.set(.playhead, to: 3)
        #expect(add(&model))
        #expect(model.value(of: .playhead) == 3)
        #expect(model.value(of: .point(0)) == 3)
        #expect(model.value(of: .point(4)) == nil)
        #expect(model.value(of: .end) == 6)
    }
}
