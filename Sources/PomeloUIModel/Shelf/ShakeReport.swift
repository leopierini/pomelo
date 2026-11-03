// Replays recorded drags through the shake detector with the drag session's arming delay, and reports false fires,
// recall and each trace's margin (S34).
import Foundation

public enum ShakeReport {
    /// Which recorded points feed the detector (S36).
    public enum Source: String, Sendable {
        case poll, events
    }

    public struct Line: Codable, Sendable, Equatable {
        public var name: String
        public var label: DragTrace.Label
        public var fired: Bool
        /// The checks the nearest-to-firing window passed, in `checkNames` order: the margin report.
        public var checks: [String]

        public init(name: String, label: DragTrace.Label, fired: Bool, checks: [String]) {
            self.name = name
            self.label = label
            self.fired = fired
            self.checks = checks
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var ordinary: Int
        public var shakes: Int
        /// Ordinary traces that fired.
        public var falseFires: Int
        /// Shake traces that fired.
        public var hits: Int
        /// 0 when there are no shakes.
        public var recallPercent: Double
        public var lines: [Line]

        public init(ordinary: Int, shakes: Int, falseFires: Int, hits: Int, recallPercent: Double, lines: [Line]) {
            self.ordinary = ordinary
            self.shakes = shakes
            self.falseFires = falseFires
            self.hits = hits
            self.recallPercent = recallPercent
            self.lines = lines
        }
    }

    public static let checkNames: [(ShakeCheck, String)] = [
        (.amplitude, "amplitude"), (.speed, "speed"), (.rhythm, "rhythm"), (.uniformity, "uniformity"),
        (.inPlace, "inPlace"), (.horizontal, "horizontal"),
    ]

    /// The other gates of S35 (the wheel, a drag out of Pomelo, once per drag) can't happen in a recording, so only
    /// the arming delay applies: points from `filesSeenAt + DragSession.shakeArming` on, none for a drag without files.
    public static func replay(_ trace: DragTrace, sensitivity: ShakeSensitivity,
                              source: Source = .poll) -> (fired: Bool, checks: ShakeCheck) {
        guard let parameters = sensitivity.parameters, let seen = trace.filesSeenAt else { return (false, []) }
        let armedAt = seen + DragSession.shakeArming
        var detector = ShakeDetector(parameters: parameters)
        for point in source == .poll ? trace.poll : trace.events where point.t >= armedAt {
            if detector.feed(point) { return (true, detector.bestChecks) }
        }
        return (false, detector.bestChecks)
    }

    public static func summarize(_ traces: [(name: String, trace: DragTrace)], sensitivity: ShakeSensitivity,
                                 source: Source = .poll) -> Summary {
        var summary = Summary(ordinary: 0, shakes: 0, falseFires: 0, hits: 0, recallPercent: 0, lines: [])
        for (name, trace) in traces {
            let replay = replay(trace, sensitivity: sensitivity, source: source)
            if trace.label.isShake {
                summary.shakes += 1
                if replay.fired { summary.hits += 1 }
            } else {
                summary.ordinary += 1
                if replay.fired { summary.falseFires += 1 }
            }
            let checks = checkNames.filter { replay.checks.contains($0.0) }.map(\.1)
            summary.lines.append(Line(name: name, label: trace.label, fired: replay.fired, checks: checks))
        }
        if summary.shakes > 0 { summary.recallPercent = 100 * Double(summary.hits) / Double(summary.shakes) }
        return summary
    }
}
