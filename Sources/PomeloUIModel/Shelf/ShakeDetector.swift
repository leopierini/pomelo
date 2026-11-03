// Pure shake detector (S29, S30). Fed one timestamped cursor point at a time by the drag monitor; only Foundation.
// Everything is times and distances, never sample counts, so 60 Hz polls and 1000 Hz mice read the same.
import Foundation

/// One cursor sample: seconds, AppKit global points (y up).
public struct TracePoint: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct ShakeParameters: Sendable, Equatable {
    public var strokes: Int
    public var hysteresis: Double
    public var minLeg: Double
    public var maxLeg: Double
    public var minSpeed: Double
    public var window: Double
    public var maxGap: Double
    public var uniformity: Double
    public var maxDriftRatio: Double
    public var maxVerticalRatio: Double

    public init(strokes: Int, hysteresis: Double, minLeg: Double, maxLeg: Double, minSpeed: Double, window: Double,
                maxGap: Double, uniformity: Double, maxDriftRatio: Double, maxVerticalRatio: Double) {
        self.strokes = strokes
        self.hysteresis = hysteresis
        self.minLeg = minLeg
        self.maxLeg = maxLeg
        self.minSpeed = minSpeed
        self.window = window
        self.maxGap = maxGap
        self.uniformity = uniformity
        self.maxDriftRatio = maxDriftRatio
        self.maxVerticalRatio = maxVerticalRatio
    }

    private static func preset(strokes: Int, minLeg: Double, minSpeed: Double, window: Double) -> ShakeParameters {
        ShakeParameters(strokes: strokes, hysteresis: 20, minLeg: minLeg, maxLeg: 500, minSpeed: minSpeed,
                        window: window, maxGap: 0.15, uniformity: 0.35, maxDriftRatio: 1.0, maxVerticalRatio: 0.5)
    }

    public static let careful = preset(strokes: 5, minLeg: 60, minSpeed: 500, window: 1.2)
    public static let normal = preset(strokes: 4, minLeg: 40, minSpeed: 400, window: 1.0)
    public static let easy = preset(strokes: 4, minLeg: 28, minSpeed: 300, window: 1.0)
}

public enum ShakeSensitivity: String, Codable, Sendable, CaseIterable {
    case off, careful, normal, easy

    /// nil for Off: the detector isn't fed at all.
    public var parameters: ShakeParameters? {
        switch self {
        case .off: nil
        case .careful: .careful
        case .normal: .normal
        case .easy: .easy
        }
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .careful: "Careful"
        case .normal: "Normal"
        case .easy: "Easy"
        }
    }
}

/// The six conditions a window of legs must meet to count as a shake.
public struct ShakeCheck: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let amplitude = ShakeCheck(rawValue: 1 << 0)
    public static let speed = ShakeCheck(rawValue: 1 << 1)
    public static let rhythm = ShakeCheck(rawValue: 1 << 2)
    public static let uniformity = ShakeCheck(rawValue: 1 << 3)
    public static let inPlace = ShakeCheck(rawValue: 1 << 4)
    public static let horizontal = ShakeCheck(rawValue: 1 << 5)
    public static let all: ShakeCheck = [.amplitude, .speed, .rhythm, .uniformity, .inPlace, .horizontal]
}

public struct ShakeDetector: Sendable {
    private enum Phase { case undecided, rising, falling }

    private let parameters: ShakeParameters
    private var previous: TracePoint?
    private var lastMoveTime = 0.0
    private var anchor = TracePoint(t: 0, x: 0, y: 0)
    private var phase = Phase.undecided
    private var start = TracePoint(t: 0, x: 0, y: 0)
    private var high = TracePoint(t: 0, x: 0, y: 0)
    private var low = TracePoint(t: 0, x: 0, y: 0)
    private var extreme = TracePoint(t: 0, x: 0, y: 0)
    private var turns: [TracePoint] = []
    private var fired = false

    /// The largest set of checks any window of legs passed since `reset`, for the margin report.
    public private(set) var bestChecks: ShakeCheck = []

    public init(parameters: ShakeParameters) {
        self.parameters = parameters
    }

    public mutating func reset() {
        previous = nil
        phase = .undecided
        turns.removeAll(keepingCapacity: true)
        fired = false
        bestChecks = []
    }

    /// True exactly once: on the point that completes a shake. Later points return false until `reset`.
    public mutating func feed(_ point: TracePoint) -> Bool {
        guard !fired else { return false }
        defer { previous = point }
        guard let prev = previous else {
            restart(at: point)
            lastMoveTime = point.t
            return false
        }
        if point.t - prev.t > parameters.maxGap {
            restart(at: point)
            lastMoveTime = point.t
            return false
        }
        // A poll keeps sampling a still cursor and an event stream doesn't; this reads both the same way. Movement
        // is measured from an anchor, not the previous sample, so a slow cursor at 1000 Hz is not "still".
        if hypot(point.x - anchor.x, point.y - anchor.y) >= 0.5 {
            lastMoveTime = point.t
            anchor = point
        } else if point.t - lastMoveTime > parameters.maxGap {
            restart(at: point)
            return false
        }
        guard let turn = nextTurn(for: point) else { return false }
        turns.append(turn)
        if turns.count > parameters.strokes + 1 { turns.removeFirst() }
        guard turns.count == parameters.strokes + 1 else { return false }
        let passed = checks(for: turns)
        if passed.rawValue.nonzeroBitCount >= bestChecks.rawValue.nonzeroBitCount { bestChecks = passed }
        fired = passed == .all
        return fired
    }

    private mutating func restart(at point: TracePoint) {
        phase = .undecided
        start = point
        anchor = point
        high = point
        low = point
        turns.removeAll(keepingCapacity: true)
    }

    /// Peak and valley tracking: a turning point is confirmed once the cursor retreats `hysteresis` from it.
    private mutating func nextTurn(for p: TracePoint) -> TracePoint? {
        switch phase {
        case .rising: follow(p, rising: true)
        case .falling: follow(p, rising: false)
        case .undecided: firstTurn(at: p)
        }
    }

    private mutating func follow(_ p: TracePoint, rising: Bool) -> TracePoint? {
        if rising ? p.x > extreme.x : p.x < extreme.x {
            extreme = p
            return nil
        }
        guard (rising ? extreme.x - p.x : p.x - extreme.x) >= parameters.hysteresis else { return nil }
        let turn = extreme
        phase = rising ? .falling : .rising
        extreme = p
        return turn
    }

    private mutating func firstTurn(at p: TracePoint) -> TracePoint? {
        let h = parameters.hysteresis
        if p.x > high.x { high = p }
        if p.x < low.x { low = p }
        // The start is no turning point: only an extreme the cursor really came to (and left) counts. A
        // shake smaller than the hysteresis around its start would otherwise never pick a direction.
        let peak = high.x > start.x && high.x - p.x >= h
        let valley = low.x < start.x && p.x - low.x >= h
        if peak, !valley || high.t >= low.t {
            phase = .falling
            extreme = p
            return high
        } else if valley {
            phase = .rising
            extreme = p
            return low
        } else if p.x - start.x >= h {
            phase = .rising
            extreme = p
        } else if start.x - p.x >= h {
            phase = .falling
            extreme = p
        }
        return nil
    }

    private func checks(for turns: [TracePoint]) -> ShakeCheck {
        let p = parameters
        let legs = turns.count - 1
        var result = ShakeCheck.all
        var shortest = Double.infinity
        var longest = 0.0
        var total = 0.0
        for i in 0..<legs {
            let length = abs(turns[i + 1].x - turns[i].x)
            let duration = turns[i + 1].t - turns[i].t
            if length < p.minLeg || length > p.maxLeg { result.remove(.amplitude) }
            if duration <= 0 || length / duration < p.minSpeed { result.remove(.speed) }
            shortest = min(shortest, length)
            longest = max(longest, length)
            total += length
        }
        let mean = total / Double(legs)
        if turns[legs].t - turns[0].t > p.window { result.remove(.rhythm) }
        if shortest < p.uniformity * longest { result.remove(.uniformity) }
        // With an odd number of legs the ends sit on opposite sides, a whole leg apart even in a perfect shake,
        // so drift is measured between turning points on the same side.
        if abs(turns[legs].x - turns[legs % 2].x) > p.maxDriftRatio * mean { result.remove(.inPlace) }
        let ys = turns.map(\.y)
        if let lo = ys.min(), let hi = ys.max(), hi - lo > p.maxVerticalRatio * mean { result.remove(.horizontal) }
        return result
    }
}
