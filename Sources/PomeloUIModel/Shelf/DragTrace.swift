// One recorded file drag (S34): the fixtures' format. It holds no file names, paths or app names.
import CoreGraphics
import Foundation

public struct DragTrace: Codable, Sendable, Equatable {
    /// What the person was doing, chosen in the recorder's menu before the drag.
    public enum Label: String, Codable, Sendable, CaseIterable {
        case ordinary, shakeMouse, shakeTrackpad

        public var isShake: Bool { self != .ordinary }
    }

    public var label: Label
    /// The drag monitor's 60 Hz poll while the button is down (S36): seconds and points relative to the mouse-down
    /// snapshot, y up.
    public var poll: [TracePoint]
    /// A global `.leftMouseDragged` monitor's points (location and timestamp), in the same coordinates.
    public var events: [TracePoint]
    /// When the drag pasteboard first held files (`DragSession`'s rule); nil for a drag that never did.
    public var filesSeenAt: Double?
    public var fileCount: Int
    /// The frame of the screen the drag started on, in the same coordinates.
    public var screen: CGRect
    /// The shadow run: whether each preset would have fired on the poll, keyed by `ShakeSensitivity.rawValue`.
    public var wouldFire: [String: Bool]

    public init(label: Label, poll: [TracePoint], events: [TracePoint], filesSeenAt: Double?, fileCount: Int,
                screen: CGRect, wouldFire: [String: Bool]) {
        self.label = label
        self.poll = poll
        self.events = events
        self.filesSeenAt = filesSeenAt
        self.fileCount = fileCount
        self.screen = screen
        self.wouldFire = wouldFire
    }

    /// To 0.1 pt and 1 ms: far finer than the detector's own scales (a 20 pt hysteresis, a 0.5 pt stall), and it
    /// keeps the fixtures small.
    public func rounded() -> DragTrace {
        func pt(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func point(_ p: TracePoint) -> TracePoint { TracePoint(t: ms(p.t), x: pt(p.x), y: pt(p.y)) }
        var copy = self
        copy.poll = poll.map(point)
        copy.events = events.map(point)
        copy.filesSeenAt = filesSeenAt.map(ms)
        copy.screen = CGRect(x: pt(screen.origin.x), y: pt(screen.origin.y), width: pt(screen.width),
                             height: pt(screen.height))
        return copy
    }
}
