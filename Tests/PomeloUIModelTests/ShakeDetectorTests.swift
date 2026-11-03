import Foundation
import Testing
@testable import PomeloUIModel

private func detector(_ parameters: ShakeParameters = .normal, feeding points: [TracePoint]) -> (fires: Int, detector: ShakeDetector) {
    var d = ShakeDetector(parameters: parameters)
    var fires = 0
    for p in points where d.feed(p) { fires += 1 }
    return (fires, d)
}

private func fires(_ points: [TracePoint], _ parameters: ShakeParameters = .normal) -> Int {
    detector(parameters, feeding: points).fires
}

@Suite struct ShakeDetectorTests {
    @Test func firesOnA5HzShakeOf80ptLegs() {
        #expect(fires(Trace.shake(hz: 5, leg: 80, strokes: 6)) == 1)
    }

    @Test func firesOnceOnTheCompletingPoint() {
        let points = Trace.shake(hz: 5, leg: 80, strokes: 12)
        var d = ShakeDetector(parameters: .normal)
        let results = points.map { d.feed($0) }
        #expect(results.filter { $0 }.count == 1)
        let first = results.firstIndex(of: true)!
        #expect(first < points.count / 2)
        d.reset()
        #expect(points.map { d.feed($0) }.filter { $0 }.count == 1)
    }

    @Test func rateIndependence() {
        for rate in [60.0, 120, 1000] {
            let points = Trace.shake(hz: 5, leg: 80, strokes: 6, rate: rate, jitter: 0.2, seed: UInt64(rate))
            #expect(fires(points) == 1, "rate \(rate)")
        }
    }

    @Test func slowLongLegsReadTheSameAtAnyRate() {   // Easy, 2.5 Hz, 65 pt legs: under 0.5 pt a sample at 1000 Hz and up
        for rate in [60.0, 120, 500, 1000, 4000] {
            let points = Trace.shake(hz: 2.5, leg: 65, strokes: 6, rate: rate)
            #expect(fires(points, .easy) == 1, "rate \(rate)")
        }
    }

    @Test func slowShakeDoesNotFire() {
        #expect(fires(Trace.shake(hz: 3, leg: 60, strokes: 8)) == 0)
    }

    @Test func overshootAndCorrectDoesNotFire() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let reach = Trace.reach(distance: 300 + 600 * rng.unit(), duration: 0.3 + 0.5 * rng.unit(), overshoot: 0.05 + 0.15 * rng.unit())
            #expect(fires(reach) == 0)
        }
    }

    @Test func wideSweepsDoNotFire() {   // maxLeg
        let result = detector(feeding: Trace.sweep(width: 600, speed: 1500, count: 8))
        #expect(result.fires == 0)
        #expect(!result.detector.bestChecks.contains(.amplitude))
    }

    @Test func nervousWiggleDoesNotFire() {
        let result = detector(feeding: Trace.wiggle(amplitude: 25, hz: 6, duration: 3))
        #expect(result.fires == 0)
        #expect(!result.detector.bestChecks.contains(.amplitude))
    }

    @Test func ditheringDoesNotFire() {
        #expect(fires(Trace.shake(hz: 5, leg: 30, strokes: 6)) == 0)
    }

    @Test func flickThenTwitchesDoesNotFire() {   // uniformity, and nothing else
        let result = detector(feeding: Trace.flickThenTwitches())
        #expect(result.fires == 0)
        #expect(result.detector.bestChecks == ShakeCheck.all.subtracting(.uniformity))
    }

    @Test func travellingWiggleDoesNotFire() {   // in place, and nothing else
        let result = detector(feeding: Trace.travellingWiggle(leg: 60, drift: 60))
        #expect(result.fires == 0)
        #expect(result.detector.bestChecks == ShakeCheck.all.subtracting(.inPlace))
    }

    @Test func verticalShakeDoesNotFire() {
        #expect(fires(Trace.verticalShake(leg: 100)) == 0)
    }

    @Test func diagonalWithTallTurnsDoesNotFire() {   // vertical extent 0.8 x the mean leg
        let result = detector(feeding: Trace.shake(hz: 5, leg: 80, strokes: 8, verticalDrift: 0.8))
        #expect(result.fires == 0)
        #expect(result.detector.bestChecks == ShakeCheck.all.subtracting(.horizontal))
    }

    @Test func stallResetsTheSequence() {
        // Long fast legs: the hold slows one leg but not below the speed floor, so only the stall rule can stop it.
        for rate in [60.0, 1000] {
            let whole = Trace.shake(hz: 3.75, leg: 200, strokes: 4, rate: rate)
            #expect(fires(whole) == 1, "rate \(rate)")
            #expect(fires(Trace.withStall(whole, at: 0.4, seconds: 0.2, rate: rate)) == 0, "rate \(rate)")
        }

        let before = Trace.withStall(Trace.shake(hz: 3.75, leg: 200, strokes: 2), at: .infinity, seconds: 0.2)
        let end = before[before.count - 1]
        let restart = TracePoint(t: end.t + 1.0 / 60, x: end.x, y: end.y)
        #expect(fires(before + Trace.shake(hz: 3.75, leg: 200, strokes: 4, start: restart)) == 1)
        let twoMore = detector(feeding: before + Trace.shake(hz: 3.75, leg: 200, strokes: 2, start: restart))
        #expect(twoMore.fires == 0)
        #expect(twoMore.detector.bestChecks.isEmpty)   // no window of four legs ever formed after the hold
    }

    @Test func longSlowLegsDoNotFire() {   // window, and nothing else
        let result = detector(feeding: Trace.shake(hz: 0.75, leg: 300, strokes: 6))
        #expect(result.fires == 0)
        #expect(result.detector.bestChecks == ShakeCheck.all.subtracting(.rhythm))
    }

    @Test func theApproachIsNotAStroke() {
        let three = Trace.shake(hz: 5, leg: 100, strokes: 3)
        #expect(fires(three) == 0)
        #expect(fires(Trace.mirrored(three)) == 0)
        #expect(fires(Trace.mirrored(Trace.shake(hz: 5, leg: 100, strokes: 4))) == 1)
    }

    @Test func timeShiftDoesNotMatter() {
        let points = Trace.shake(hz: 5, leg: 80, strokes: 6, rate: 120, jitter: 0.2, seed: 3)
        #expect(fires(Trace.shifted(points, by: 10_000)) == 1)
    }

    @Test func dropping30PercentKeepsAClearShake() {
        let points = Trace.shake(hz: 5, leg: 100, strokes: 8, rate: 120)
        for seed in 1...20 {
            #expect(fires(Trace.dropping(points, fraction: 0.3, seed: UInt64(seed))) == 1, "seed \(seed)")
        }
    }

    @Test func easyFiresWhereNormalDoesNot() {
        let points = Trace.shake(hz: 7, leg: 32, strokes: 6, rate: 120)
        #expect(fires(points, .normal) == 0)
        #expect(fires(points, .easy) == 1)
    }

    @Test func carefulNeedsFiveStrokes() {
        let four = Trace.shake(hz: 5, leg: 100, strokes: 4)
        #expect(fires(four, .normal) == 1)
        #expect(fires(four, .careful) == 0)
        let five = Trace.shake(hz: 5, leg: 100, strokes: 5)
        #expect(fires(five, .normal) == 1)
        #expect(fires(five, .careful) == 1)
    }

    @Test func carefulAcceptsJitteredShakesWithAnOddNumberOfLegs() {
        for seed in 1...20 {
            let points = Trace.shake(hz: 5, leg: 100, strokes: 5, jitter: 0.2, seed: UInt64(seed))
            #expect(fires(points, .careful) == 1, "seed \(seed)")
        }
    }

    @Test func bestChecksReportsTheNearMiss() {
        let result = detector(feeding: Trace.shake(hz: 3, leg: 60, strokes: 8))
        #expect(!result.detector.bestChecks.contains(.speed))
        #expect(result.detector.bestChecks.contains(.amplitude))
        #expect(result.detector.bestChecks == ShakeCheck.all.subtracting(.speed))
    }

    @Test func offHasNoParameters() {
        #expect(ShakeSensitivity.off.parameters == nil)
        #expect(ShakeSensitivity.careful.parameters == .careful)
        #expect(ShakeSensitivity.normal.parameters == .normal)
        #expect(ShakeSensitivity.easy.parameters == .easy)
        #expect(ShakeSensitivity.allCases.map(\.title) == ["Off", "Careful", "Normal", "Easy"])
    }

    @Test func sensitivityCodesAsItsRawValue() throws {
        for s in ShakeSensitivity.allCases {
            let data = try JSONEncoder().encode(s)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(s.rawValue)\"")
            #expect(try JSONDecoder().decode(ShakeSensitivity.self, from: data) == s)
        }
    }
}
