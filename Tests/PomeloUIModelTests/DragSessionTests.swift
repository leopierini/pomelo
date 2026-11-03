import CoreGraphics
import Foundation
import Testing
@testable import PomeloUIModel

private let f = [URL(fileURLWithPath: "/a.png")]
private func snap(_ down: Bool = true, cc: Int = 1, files: [URL] = f, mods: ModifierSet = [], at p: CGPoint = .zero) -> DragSnapshot {
    DragSnapshot(buttonDown: down, changeCount: cc, fileURLs: files, modifiers: mods, location: p)
}

@Suite struct DragSessionTests {
    @Test func opensOnTriggerTapDuringFileDrag() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        #expect(s.poll(snap()) == [])
        #expect(s.poll(snap(mods: .shift, at: CGPoint(x: 5, y: 6))) == [.openWheel(files: f, at: CGPoint(x: 5, y: 6))])
        #expect(s.isWheelOpen)
    }
    @Test func ignoresNonFileDrag() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        #expect(s.poll(snap(files: [], mods: .shift)) == [])
    }
    @Test func noDragNoWheel() {   // shift tapped while just holding the button on a file, pasteboard unchanged
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 7, files: f))
        #expect(s.poll(snap(cc: 7, mods: .shift)) == [])
    }
    @Test func triggerHeldAtMouseDownIgnoredUntilRetap() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: [], mods: .shift))
        #expect(s.poll(snap(mods: .shift)) == [])
        #expect(s.poll(snap(mods: [])) == [])
        #expect(s.poll(snap(mods: .shift)).count == 1)
    }
    @Test func secondTapCyclesPage() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        _ = s.poll(snap(mods: .shift)); _ = s.poll(snap())
        #expect(s.poll(snap(mods: .shift)) == [.cyclePage])
    }
    @Test func buttonUpEndsDrag() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        _ = s.poll(snap(mods: .shift))
        #expect(s.poll(snap(false)) == [.dragEnded(dropExpected: true)]); #expect(s.isWheelOpen == false)
        s.mouseDown(snap(cc: 1, files: f)); _ = s.poll(snap(cc: 2))
        #expect(s.poll(snap(false, cc: 2)) == [.dragEnded(dropExpected: false)])
    }
    @Test func optionTrigger() {
        var s = DragSession(trigger: .option); s.mouseDown(snap(cc: 0, files: []))
        #expect(s.poll(snap(mods: .shift)) == []); #expect(s.poll(snap(mods: .option)).count == 1)
    }
    @Test func pollsAfterDragEndedAreIgnored() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        _ = s.poll(snap(mods: .shift))
        #expect(s.poll(snap(false)) == [.dragEnded(dropExpected: true)])
        #expect(s.poll(snap(false)) == [])                  // a second button-up poll adds nothing
        #expect(s.poll(snap(false, mods: .shift)) == [])    // nor does a trigger tap after the drop
        #expect(s.poll(snap(mods: [])) == [])
        #expect(s.poll(snap(mods: .shift)) == [])
        #expect(s.isWheelOpen == false)
    }
    @Test func pollBeforeAnyMouseDownIsIgnored() {
        var s = DragSession(trigger: .shift)
        #expect(s.poll(snap(mods: .shift)) == [])
    }
    /// ⌥ during a drag is Finder's copy gesture: it never opens or changes the wheel.
    @Test func optionDuringAFileDragDoesNothing() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: []))
        #expect(s.poll(snap(mods: .option)) == [])
        #expect(s.poll(snap()) == [])
        _ = s.poll(snap(mods: .shift)); _ = s.poll(snap())
        #expect(s.poll(snap(mods: .option)) == [])
        #expect(s.poll(snap()) == [])
    }
    @Test func optionCopyDragThenTriggerOpensTheWheel() {
        var s = DragSession(trigger: .shift); s.mouseDown(snap(cc: 0, files: [], mods: .option))
        #expect(s.poll(snap(mods: .option)) == [])
        #expect(s.poll(snap(mods: [.option, .shift])) == [.openWheel(files: f, at: .zero)])
        #expect(s.poll(snap(mods: .option)) == [])
        #expect(s.poll(snap(mods: [.option, .shift])) == [.cyclePage])
    }
    @Test func optionTriggerCyclesInsteadOfJumping() {
        var s = DragSession(trigger: .option); s.mouseDown(snap(cc: 0, files: []))
        _ = s.poll(snap(mods: .option)); _ = s.poll(snap())
        #expect(s.poll(snap(mods: .option)) == [.cyclePage])
    }
}

private let origin = CGPoint(x: Trace.origin.x, y: Trace.origin.y)

/// A shake that fits in 0.3 s, so "wholly before arming" is possible.
private let quickShake = Trace.shake(hz: 12, leg: 80, strokes: 4)

private func shakeSnap(_ p: TracePoint, cc: Int = 1, files: [URL] = f, down: Bool = true, mods: ModifierSet = []) -> DragSnapshot {
    DragSnapshot(buttonDown: down, changeCount: cc, fileURLs: files, modifiers: mods, location: CGPoint(x: p.x, y: p.y), time: p.t)
}

/// Mouse-down at t = 0, files first seen at `filesAt`, then the trace shifted to start at `traceAt`, then a still tail.
private func drive(_ s: inout DragSession, trace: [TracePoint], filesAt: Double = 0, traceAt: Double,
                   tail: Double = 1.0, startedInPomelo: Bool = false) -> [(DragSnapshot, [DragSessionEvent])] {
    s.mouseDown(shakeSnap(TracePoint(t: 0, x: origin.x, y: origin.y), cc: 0, files: []), startedInPomelo: startedInPomelo)
    var out: [(DragSnapshot, [DragSessionEvent])] = []
    let first = shakeSnap(TracePoint(t: filesAt, x: origin.x, y: origin.y))
    out.append((first, s.poll(first)))
    let points = Trace.shifted(trace, by: traceAt)
    for p in points + stillTail(after: points, seconds: tail) {
        let snapshot = shakeSnap(p, files: p.t < filesAt ? [] : f, mods: [])
        out.append((snapshot, s.poll(snapshot)))
    }
    return out
}

private func stillTail(after points: [TracePoint], seconds: Double) -> [TracePoint] {
    guard let last = points.last, seconds >= 1 / 60 else { return [] }
    return (1...Int(seconds * 60)).map { TracePoint(t: last.t + Double($0) / 60, x: last.x, y: last.y) }
}

private func shelves(_ run: [(DragSnapshot, [DragSessionEvent])]) -> [CGPoint] {
    run.flatMap(\.1).compactMap { if case .showShelf(let p) = $0 { p } else { nil } }
}

@Suite struct DragSessionShakeTests {
    @Test func shakeShowsShelfAtTheCompletingPoint() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)
        let fired = run.filter { $0.1.contains { if case .showShelf = $0 { true } else { false } } }
        #expect(fired.count == 1)
        #expect(fired[0].1 == [.showShelf(at: fired[0].0.location)])
    }

    @Test func noShakeBeforeArming() {
        var s = DragSession(trigger: .shift, shake: .normal)
        #expect(quickShake.last!.t < DragSession.shakeArming)
        #expect(shelves(drive(&s, trace: quickShake, traceAt: 0)).isEmpty)
        var control = DragSession(trigger: .shift, shake: .normal)
        #expect(shelves(drive(&control, trace: quickShake, traceAt: DragSession.shakeArming)).count == 1)
    }

    @Test func armingCountsFromFilesFirstSeen() {
        let filesAt = 0.5
        let armed = filesAt + DragSession.shakeArming
        var early = DragSession(trigger: .shift, shake: .normal)
        #expect(shelves(drive(&early, trace: quickShake, filesAt: filesAt, traceAt: filesAt)).isEmpty)
        var late = DragSession(trigger: .shift, shake: .normal)
        #expect(shelves(drive(&late, trace: quickShake, filesAt: filesAt, traceAt: armed)).count == 1)
    }

    @Test func noShakeWhileWheelOpen() {
        var s = DragSession(trigger: .shift, shake: .normal)
        s.mouseDown(shakeSnap(Trace.origin, cc: 0, files: []))
        _ = s.poll(shakeSnap(Trace.origin))
        #expect(s.poll(shakeSnap(Trace.origin, mods: .shift)) == [.openWheel(files: f, at: origin)])
        var shown = 0
        for p in Trace.shifted(Trace.shake(hz: 5, leg: 80, strokes: 6), by: 0.35) {
            for case .showShelf in s.poll(shakeSnap(p)) { shown += 1 }
        }
        #expect(shown == 0)
    }

    @Test func triggerAfterShakeStillOpensWheel() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming, tail: 0.1)
        #expect(shelves(run).count == 1)
        let last = run.last!.0
        var tap = last
        tap.modifiers = .shift
        tap.time += 1 / 60
        #expect(s.poll(tap) == [.openWheel(files: f, at: last.location)])
    }

    @Test func shakeOncePerDrag() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 12), traceAt: DragSession.shakeArming)
        #expect(shelves(run).count == 1)
        let again = Trace.shifted(Trace.shake(hz: 5, leg: 80, strokes: 6), by: run.last!.0.time + 0.5)
        #expect(again.map { s.poll(shakeSnap($0)) }.flatMap { $0 }.isEmpty)
    }

    @Test func newDragCanShakeAgain() {
        var s = DragSession(trigger: .shift, shake: .normal)
        var first = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)
        #expect(shelves(first).count == 1)
        _ = s.poll(shakeSnap(Trace.origin, down: false))
        first = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)
        #expect(shelves(first).count == 1)
    }

    /// The poll index at which a probe session fires, so a test can rebuild the run and change that one snapshot.
    private func completingIndex(of run: [(DragSnapshot, [DragSessionEvent])]) -> Int {
        run.firstIndex { !$0.1.isEmpty }!
    }

    private func replay(_ run: [(DragSnapshot, [DragSessionEvent])], before index: Int) -> DragSession {
        var s = DragSession(trigger: .shift, shake: .normal)
        s.mouseDown(shakeSnap(Trace.origin, cc: 0, files: []))
        for (snapshot, _) in run[..<index] { _ = s.poll(snapshot) }
        return s
    }

    @Test func theWheelWinsATieWithTheShake() {
        var probe = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&probe, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)
        let index = completingIndex(of: run)
        var s = replay(run, before: index)
        var completing = run[index].0
        completing.modifiers = .shift
        #expect(s.poll(completing) == [.openWheel(files: f, at: completing.location)])
    }

    @Test func aShakeCompletingOnTheButtonUpPollEmitsNothingToShow() {
        var probe = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&probe, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)
        let index = completingIndex(of: run)
        var s = replay(run, before: index)
        var completing = run[index].0
        completing.buttonDown = false
        #expect(s.poll(completing) == [.dragEnded(dropExpected: false)])
    }

    /// `.showShelf` and `.dragEnded` can't share a poll (R12), nor can a wheel event and `.showShelf`: only the
    /// order across polls is reachable.
    @Test func shelfThenWheelThenEndAcrossPolls() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming, tail: 0.1)
        var last = run.last!.0
        last.time += 1 / 60
        var tap = last
        tap.modifiers = .shift
        var up = tap
        up.buttonDown = false
        up.time += 1 / 60
        let events = run.flatMap(\.1) + s.poll(tap) + s.poll(up)
        #expect(events == [.showShelf(at: run.first { !$0.1.isEmpty }!.0.location), .openWheel(files: f, at: tap.location),
                           .dragEnded(dropExpected: true)])
    }

    @Test func noShakeForDragStartedInPomelo() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming, startedInPomelo: true)
        #expect(shelves(run).isEmpty)
    }

    @Test func noShakeForNonFileDrag() {
        var s = DragSession(trigger: .shift, shake: .normal)
        s.mouseDown(shakeSnap(Trace.origin, cc: 0, files: []))
        let shown = Trace.shifted(Trace.shake(hz: 5, leg: 80, strokes: 6), by: 0.35).flatMap { s.poll(shakeSnap($0, files: [])) }
        #expect(shown.isEmpty)
    }

    @Test func offNeverShakes() {
        var s = DragSession(trigger: .shift, shake: .off)
        #expect(shelves(drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)).isEmpty)
        var defaulted = DragSession(trigger: .shift)
        #expect(defaulted.shake == .off)
        #expect(shelves(drive(&defaulted, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)).isEmpty)
    }

    @Test func settingTheSensitivityAfterInitEnablesTheShake() {
        var s = DragSession(trigger: .shift, shake: .off)
        s.shake = .normal
        #expect(shelves(drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming)).count == 1)
    }

    @Test func changingTheSensitivityAfterAShakeDoesNotFireAgain() {
        var s = DragSession(trigger: .shift, shake: .normal)
        let run = drive(&s, trace: Trace.shake(hz: 5, leg: 80, strokes: 6), traceAt: DragSession.shakeArming, tail: 0)
        #expect(shelves(run).count == 1)
        s.shake = .easy
        let again = Trace.shifted(Trace.shake(hz: 5, leg: 80, strokes: 6), by: run.last!.0.time + 0.5)
        #expect(again.flatMap { s.poll(shakeSnap($0)) }.isEmpty)
    }
}

