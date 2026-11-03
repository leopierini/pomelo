import CoreGraphics
import Foundation
import Testing
@testable import PomeloUIModel

/// A shake that fits in 0.3 s, so "wholly before arming" is possible (R5).
private let quickShake = Trace.shake(hz: 12, leg: 80, strokes: 4)

private func still(from t0: Double, seconds: Double, rate: Double = 60) -> [TracePoint] {
    (0...Int(seconds * rate)).map { TracePoint(t: t0 + Double($0) / rate, x: Trace.origin.x, y: Trace.origin.y) }
}

private func trace(_ label: DragTrace.Label = .ordinary, poll: [TracePoint], events: [TracePoint] = [],
                   filesSeenAt: Double? = 0.2) -> DragTrace {
    DragTrace(label: label, poll: poll, events: events, filesSeenAt: filesSeenAt, fileCount: filesSeenAt == nil ? 0 : 1,
              screen: CGRect(x: -500, y: -500, width: 1512, height: 982), wouldFire: [:])
}

/// A quick shake starting at the arming instant, after a still start, with files seen at 0.2 s.
private func firing(_ label: DragTrace.Label) -> DragTrace {
    trace(label, poll: still(from: 0, seconds: 0.5) + Trace.shifted(quickShake, by: 0.2 + DragSession.shakeArming))
}

private func quiet(_ label: DragTrace.Label) -> DragTrace {
    trace(label, poll: still(from: 0, seconds: 1.5))
}

@Suite struct DragTraceTests {
    @Test func codingRoundTrip() throws {
        let original = DragTrace(
            label: .shakeTrackpad,
            poll: [TracePoint(t: 0, x: 0, y: 0), TracePoint(t: 0.017, x: 3.5, y: -1.2)],
            events: [TracePoint(t: 0.004, x: 0.4, y: 0)],
            filesSeenAt: 0.25, fileCount: 3, screen: CGRect(x: -812, y: -340, width: 1512, height: 982),
            wouldFire: ["careful": false, "normal": true, "easy": true]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DragTrace.self, from: data) == original)
        #expect(String(decoding: data, as: UTF8.self).contains("\"shakeTrackpad\""))
        let withoutFiles = DragTrace(label: .ordinary, poll: [], events: [], filesSeenAt: nil, fileCount: 0,
                                     screen: .zero, wouldFire: [:])
        #expect(try JSONDecoder().decode(DragTrace.self, from: JSONEncoder().encode(withoutFiles)) == withoutFiles)
        #expect(DragTrace.Label.shakeMouse.isShake && DragTrace.Label.shakeTrackpad.isShake)
        #expect(!DragTrace.Label.ordinary.isShake)
    }

    @Test func roundsTo0_1ptAnd1ms() {
        let raw = DragTrace(
            label: .ordinary,
            poll: [TracePoint(t: 0.123456, x: 12.345, y: -7.86)],
            events: [TracePoint(t: 1.0004, x: -0.04, y: 99.96)],
            filesSeenAt: 0.0996, fileCount: 2, screen: CGRect(x: -812.34, y: -340.06, width: 1512, height: 981.98),
            wouldFire: ["normal": true]
        )
        let rounded = raw.rounded()
        #expect(rounded.poll == [TracePoint(t: 0.123, x: 12.3, y: -7.9)])
        #expect(rounded.events == [TracePoint(t: 1.0, x: 0, y: 100)])
        #expect(rounded.filesSeenAt == 0.1)
        #expect(rounded.screen == CGRect(x: -812.3, y: -340.1, width: 1512, height: 982))
        #expect(rounded.fileCount == 2 && rounded.label == .ordinary && rounded.wouldFire == ["normal": true])
        #expect(rounded.rounded() == rounded)
    }

    /// R5: the detector is fed only from files seen + the arming delay, so a whole shake before it never fires.
    @Test func replayAppliesArming() {
        let filesSeenAt = 0.2
        let armed = filesSeenAt + DragSession.shakeArming
        #expect(quickShake.last!.t < DragSession.shakeArming)
        let early = trace(poll: still(from: 0, seconds: filesSeenAt) + Trace.shifted(quickShake, by: filesSeenAt),
                          filesSeenAt: filesSeenAt)
        #expect(!ShakeReport.replay(early, sensitivity: .normal).fired)
        let late = trace(poll: still(from: 0, seconds: armed) + Trace.shifted(quickShake, by: armed),
                         filesSeenAt: filesSeenAt)
        let replay = ShakeReport.replay(late, sensitivity: .normal)
        #expect(replay.fired)
        #expect(replay.checks == .all)
    }

    @Test func replayWithoutFilesNeverFires() {
        var noFiles = firing(.shakeMouse)
        noFiles.filesSeenAt = nil
        for sensitivity in ShakeSensitivity.allCases {
            let replay = ShakeReport.replay(noFiles, sensitivity: sensitivity)
            #expect(!replay.fired)
            #expect(replay.checks.isEmpty)
        }
        #expect(ShakeReport.replay(firing(.shakeMouse), sensitivity: .normal).fired)
        #expect(!ShakeReport.replay(firing(.shakeMouse), sensitivity: .off).fired)
    }

    @Test func replayCanUseEvents() {
        let start = 0.2 + DragSession.shakeArming
        let shaking = trace(poll: still(from: 0, seconds: 1.5),
                            events: Trace.shifted(Trace.shake(hz: 5, leg: 80, strokes: 6, rate: 1000), by: start))
        #expect(!ShakeReport.replay(shaking, sensitivity: .normal).fired)
        #expect(ShakeReport.replay(shaking, sensitivity: .normal, source: .events).fired)
    }

    @Test func summarizeCountsFalseFiresAndRecall() {
        let traces: [(name: String, trace: DragTrace)] = [
            ("o1", quiet(.ordinary)), ("o2", firing(.ordinary)),
            ("m1", firing(.shakeMouse)), ("m2", quiet(.shakeMouse)),
            ("t1", firing(.shakeTrackpad)), ("t2", firing(.shakeTrackpad)),
        ]
        let summary = ShakeReport.summarize(traces, sensitivity: .normal)
        #expect(summary.ordinary == 2)
        #expect(summary.shakes == 4)
        #expect(summary.falseFires == 1)
        #expect(summary.hits == 3)
        #expect(summary.recallPercent == 75)
        #expect(summary.lines.map(\.name) == ["o1", "o2", "m1", "m2", "t1", "t2"])
        #expect(summary.lines.map(\.fired) == [false, true, true, false, true, true])
        #expect(summary.lines.map(\.label) == [.ordinary, .ordinary, .shakeMouse, .shakeMouse, .shakeTrackpad, .shakeTrackpad])
        #expect(summary.lines[1].checks == ["amplitude", "speed", "rhythm", "uniformity", "inPlace", "horizontal"])
        #expect(summary.lines[0].checks.isEmpty)
    }

    /// The margin report names the checks the nearest-to-firing window passed, so the one doing the work shows.
    @Test func marginNamesTheChecksThatPassed() {
        let slow = trace(poll: still(from: 0, seconds: 0.5)
                         + Trace.shifted(Trace.shake(hz: 3, leg: 60, strokes: 6), by: 0.5))
        let summary = ShakeReport.summarize([("slow", slow)], sensitivity: .normal)
        #expect(summary.falseFires == 0)
        #expect(summary.recallPercent == 0)
        #expect(summary.lines[0].checks == ["amplitude", "rhythm", "uniformity", "inPlace", "horizontal"])
    }
}
