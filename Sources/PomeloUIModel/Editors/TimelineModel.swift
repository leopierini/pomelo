// The Trim and Split editors' timeline (P27): where the handles, the playhead and the split points are, the range
// that plays, and what the footer says. The rules for a range and for points are PomeloCore's `TimeEdit` (P76), the
// same the engines check. No AppKit; the app's sessions wrap it in views.
import Foundation
import PomeloCore

public enum TimeFormat {
    /// Tenths of a second: "0:02.4" under an hour, "1:02:03.0" from an hour.
    public static func clock(_ seconds: Double) -> String {
        let tenths = seconds.isFinite ? max(0, Int((seconds * 10).rounded())) : 0
        let (hours, minutes) = (tenths / 36_000, tenths / 600 % 60)
        let rest = String(format: "%02d.%d", tenths / 10 % 60, tenths % 10)
        return hours > 0 ? String(format: "%d:%02d:", hours, minutes) + rest : "\(minutes):" + rest
    }
}

public enum TimelineHandle: Equatable, Sendable {
    case start, end, playhead, point(Int)
}

public struct TimelineModel: Equatable, Sendable {
    public static let minimumLength = TimeEdit.minimumLength
    /// How many part lengths the split readout lists before "…".
    static let listedParts = 5

    public let duration: Double
    /// One frame, or a hundredth of a second for audio.
    public let step: Double
    public private(set) var start: Double = 0
    public private(set) var end: Double
    public private(set) var playhead: Double = 0
    /// Sorted, each `TimeEdit.pointSpacing` from the ends and from its neighbours.
    public private(set) var points: [Double] = []

    public init(duration: Double, frameRate: Double?) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        end = self.duration
        if let frameRate, frameRate.isFinite, frameRate > 0 { step = 1 / frameRate } else { step = 0.01 }
    }

    public func value(of handle: TimelineHandle) -> Double? {
        switch handle {
        case .start: start
        case .end: end
        case .playhead: playhead
        case .point(let index): points.indices.contains(index) ? points[index] : nil
        }
    }

    /// Moves `handle` to `seconds`, as close as the rules allow: inside the file, the start at least the minimum
    /// length before the end, a point the spacing from the ends and from its neighbours (so the order never changes).
    public mutating func set(_ handle: TimelineHandle, to seconds: Double) {
        guard seconds.isFinite else { return }
        let inFile = min(max(seconds, 0), duration)
        // A file shorter than the minimum length can only be kept whole.
        let room = max(0, duration - Self.minimumLength)
        switch handle {
        case .start:
            start = min(inFile, max(0, end - Self.minimumLength), room)
        case .end:
            end = max(inFile, min(duration, start + Self.minimumLength))
        case .playhead:
            playhead = inFile
        case .point(let index):
            guard points.indices.contains(index) else { return }
            let spacing = TimeEdit.pointSpacing
            let lower = index > 0 ? points[index - 1] + spacing : spacing
            let upper = index < points.count - 1 ? points[index + 1] - spacing : duration - spacing
            guard lower <= upper else { return }
            points[index] = min(max(inFile, lower), upper)
        }
    }

    /// One step (a frame) or one second per `steps`.
    public mutating func nudge(_ handle: TimelineHandle, steps: Int, coarse: Bool) {
        guard let value = value(of: handle) else { return }
        set(handle, to: value + Double(steps) * (coarse ? 1 : step))
    }

    /// Adds a split point at the playhead; false when `TimeEdit` would drop it or a neighbour for crowding (P76).
    @discardableResult
    public mutating func addPoint() -> Bool {
        let usable = TimeEdit.usablePoints(points + [playhead], duration: duration)
        guard usable.count == points.count + 1 else { return false }
        points = usable
        return true
    }

    public mutating func removePoint(_ index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
    }

    /// From the playhead when it lies inside the selection, else from the start, to the end. A playhead stopped at
    /// the end grip (within `TimeEdit.endTolerance`) starts over, or playing again would play nothing.
    public func playRange() -> ClosedRange<Double> {
        let from = playhead >= start && playhead < end - TimeEdit.endTolerance ? playhead : start
        return from...end
    }

    // MARK: Trim

    public var trimSpec: EditSpec? {
        trimBlocker == nil ? .trim(TimeRange(start: start, end: end)) : nil
    }

    public var trimBlocker: String? {
        if start <= TimeEdit.endTolerance, end >= duration - TimeEdit.endTolerance { return TimeEdit.wholeFileReason }
        return TimeEdit.trimProblem(TimeRange(start: start, end: end), duration: duration)
    }

    /// "Keeps 7.6 s of 1:23.0"; a minute or more is a clock: "Keeps 1:15.0 of 1:23.0".
    public var trimReadout: String {
        let kept = (max(0, end - start) * 10).rounded() / 10
        let length = kept < 60 ? String(format: "%.1f s", kept) : TimeFormat.clock(kept)
        return "Keeps \(length) of \(TimeFormat.clock(duration))"
    }

    // MARK: Split

    public var splitSpec: EditSpec? {
        let usable = TimeEdit.usablePoints(points, duration: duration)
        return usable.isEmpty ? nil : .split(usable)
    }

    public var splitBlocker: String? {
        TimeEdit.usablePoints(points, duration: duration).isEmpty ? "Add a split point (S)" : nil
    }

    /// "3 parts: 0:02.0, 0:02.0, 0:02.0", at most five lengths and then "…".
    public var splitReadout: String {
        let bounds = [0] + TimeEdit.usablePoints(points, duration: duration) + [duration]
        let lengths = zip(bounds, bounds.dropFirst()).map { TimeFormat.clock($1 - $0) }
        var listed = Array(lengths.prefix(Self.listedParts))
        if lengths.count > Self.listedParts { listed.append("\u{2026}") }
        let count = lengths.count == 1 ? "1 part" : "\(lengths.count) parts"
        return "\(count): " + listed.joined(separator: ", ")
    }
}
