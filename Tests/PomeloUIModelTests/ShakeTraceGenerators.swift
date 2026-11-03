import Foundation
@testable import PomeloUIModel

/// Seeded, so a failing trace can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Synthetic cursor traces. `strokes` counts the legs the detector sees (runs between confirmed turning points);
/// each generator adds the approach and the departure itself.
enum Trace {
    static let origin = TracePoint(t: 0, x: 500, y: 500)

    private static func times(from t0: Double, duration: Double, rate: Double, jitter: Double, seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        var out = [t0]
        var t = 0.0
        while t < duration {
            t += (1 / rate) * (1 + jitter * (2 * rng.unit() - 1))
            out.append(t0 + t)
        }
        return out
    }

    /// A sinusoid on x starting at the centre: the turning points are the sine's peaks, `leg` pt apart.
    static func shake(hz: Double, leg: Double, strokes: Int, rate: Double = 60, jitter: Double = 0,
                      verticalDrift: Double = 0, start: TracePoint = origin, seed: UInt64 = 1) -> [TracePoint] {
        let half = leg / 2
        let duration = Double(2 * strokes + 1) / (4 * hz) + 0.4 / hz
        return times(from: start.t, duration: duration, rate: rate, jitter: jitter, seed: seed).map { t in
            let x = start.x + half * sin(2 * .pi * hz * (t - start.t))
            return TracePoint(t: t, x: x, y: start.y + verticalDrift * (x - start.x))
        }
    }

    /// Legs eased at both ends, so a sampled turning point sits at the vertex however coarse the rate.
    private static func piecewise(xs: [Double], durations: [Double], rate: Double = 120, start: TracePoint = origin) -> [TracePoint] {
        var out = [TracePoint(t: start.t, x: start.x + xs[0], y: start.y)]
        var t0 = start.t
        for i in 0..<durations.count {
            let steps = max(1, Int((durations[i] * rate).rounded()))
            for k in 1...steps {
                let u = Double(k) / Double(steps)
                let eased = (1 - cos(.pi * u)) / 2
                out.append(TracePoint(t: t0 + u * durations[i], x: start.x + xs[i] + (xs[i + 1] - xs[i]) * eased, y: start.y))
            }
            t0 += durations[i]
        }
        return out
    }

    /// A minimum-jerk reach that overshoots its target and corrects back: one reversal.
    static func reach(distance: Double, duration: Double, overshoot: Double, rate: Double = 60, start: TracePoint = origin) -> [TracePoint] {
        func minJerk(_ u: Double) -> Double { 10 * pow(u, 3) - 15 * pow(u, 4) + 6 * pow(u, 5) }
        let far = distance * (1 + overshoot)
        let pause = 0.05
        let correction = duration * 0.35
        let total = duration + pause + correction
        let steps = Int(total * rate)
        return (0...steps).map { k in
            let t = Double(k) / rate
            let x: Double
            if t <= duration {
                x = far * minJerk(t / duration)
            } else if t <= duration + pause {
                x = far
            } else {
                x = far + (distance - far) * minJerk((t - duration - pause) / correction)
            }
            return TracePoint(t: start.t + t, x: start.x + x, y: start.y)
        }
    }

    /// Constant-pace sweeps `width` pt wide, `count` legs, after a half-sweep approach.
    static func sweep(width: Double, speed: Double, count: Int, rate: Double = 120) -> [TracePoint] {
        var xs = [0.0, width / 2]
        var durations = [width / 2 / speed]
        for i in 0..<count {
            xs.append(i.isMultiple(of: 2) ? -width / 2 : width / 2)
            durations.append(width / speed)
        }
        let last = xs[xs.count - 1]
        xs.append(last + (last > 0 ? -60 : 60))
        durations.append(60 / speed)
        return piecewise(xs: xs, durations: durations, rate: rate)
    }

    /// A sinusoid whose peak-to-peak size is `amplitude`, kept up for `duration` seconds.
    static func wiggle(amplitude: Double, hz: Double, duration: Double, rate: Double = 60) -> [TracePoint] {
        times(from: 0, duration: duration, rate: rate, jitter: 0, seed: 1).map { t in
            TracePoint(t: t, x: origin.x + amplitude / 2 * sin(2 * .pi * hz * t), y: origin.y)
        }
    }

    /// Four legs of 200, 320, 200 and 90 pt at 1200 pt/s: one fast big stroke among smaller ones, balanced so the
    /// shake stays in place and only the uniformity check can fail.
    static func flickThenTwitches() -> [TracePoint] {
        let turns: [Double] = [100, -100, 220, 20, 110]
        var xs = [0.0] + turns
        xs.append(turns[4] - 60)
        let durations = (0..<xs.count - 1).map { abs(xs[$0 + 1] - xs[$0]) / 1200 }
        return piecewise(xs: xs, durations: durations)
    }

    /// Legs of `leg + drift` forward and `leg` back, six of them, at about 1000 pt/s: the wiggle advances by
    /// `drift` per back-and-forth, so every other check passes and only the in-place one can fail.
    static func travellingWiggle(leg: Double, drift: Double) -> [TracePoint] {
        var xs = [50.0, 0.0]
        for i in 0..<6 {
            xs.append(xs[xs.count - 1] + (i.isMultiple(of: 2) ? leg + drift : -leg))
        }
        xs.append(xs[xs.count - 1] - 50)
        let durations = (0..<xs.count - 1).map { abs(xs[$0 + 1] - xs[$0]) / 1000 }
        return piecewise(xs: xs, durations: durations)
    }

    /// The same sinusoid as `shake`, on y; x does not move.
    static func verticalShake(leg: Double, hz: Double = 5, strokes: Int = 8, rate: Double = 60) -> [TracePoint] {
        shake(hz: hz, leg: leg, strokes: strokes, rate: rate).map { TracePoint(t: $0.t, x: origin.x, y: origin.y + ($0.x - origin.x)) }
    }

    /// Holds the last point at or before `time` (seconds from the first point) for `seconds`, still sampled at
    /// `rate`, and moves the rest of the trace later by the same amount.
    static func withStall(_ points: [TracePoint], at time: Double, seconds: Double, rate: Double = 60) -> [TracePoint] {
        guard let t0 = points.first?.t, let index = points.lastIndex(where: { $0.t - t0 <= time }) else { return points }
        var out = Array(points[...index])
        let held = points[index]
        var n = 1
        while Double(n) / rate <= seconds {
            out.append(TracePoint(t: held.t + Double(n) / rate, x: held.x, y: held.y))
            n += 1
        }
        out += points[(index + 1)...].map { TracePoint(t: $0.t + seconds, x: $0.x, y: $0.y) }
        return out
    }

    /// Drops each point with probability `fraction`, keeping the first.
    static func dropping(_ points: [TracePoint], fraction: Double, seed: UInt64) -> [TracePoint] {
        var rng = SplitMix64(seed: seed)
        return points.enumerated().filter { $0.offset == 0 || rng.unit() >= fraction }.map(\.element)
    }

    /// The same trace flipped left to right around `origin`.
    static func mirrored(_ points: [TracePoint]) -> [TracePoint] {
        points.map { TracePoint(t: $0.t, x: 2 * origin.x - $0.x, y: $0.y) }
    }

    static func shifted(_ points: [TracePoint], by seconds: Double) -> [TracePoint] {
        points.map { TracePoint(t: $0.t + seconds, x: $0.x, y: $0.y) }
    }
}
