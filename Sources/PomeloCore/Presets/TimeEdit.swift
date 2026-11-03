import Foundation

/// The rules for a trim range and for split points, shared by the engines and the editors (P76).
public enum TimeEdit {
    /// The shortest range a trim keeps.
    public static let minimumLength = 0.1
    /// How far past the duration an end may land, and how close to either end counts as "the whole file".
    public static let endTolerance = 0.05
    /// A split point this close to either end, or to the previous point, is dropped.
    public static let pointSpacing = 0.1

    public static let outsideReason = "The range is outside the file"
    public static let wholeFileReason = "Nothing to trim"
    public static let noEditReason = "Nothing was chosen"
    public static let noPointReason = "Add a split point first"

    /// Absorbs the error of seconds that were rounded to milliseconds on their way here.
    private static let slack = 1e-9

    /// Why `range` cannot be trimmed from a file `duration` seconds long, or nil when it can. The minimum length is
    /// measured to the end clamped to the duration (P82), since that is what the cut keeps.
    public static func trimProblem(_ range: TimeRange, duration: Double) -> String? {
        let (start, end) = (range.start, range.end)
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0, start < end,
              end <= duration + endTolerance, min(end, duration) - start >= minimumLength - slack
        else { return outsideReason }
        if start <= endTolerance, end >= duration - endTolerance { return wholeFileReason }
        return nil
    }

    /// The range to cut: the edit's, with an end a hair past the duration pulled back to it.
    public static func trimRange(_ edit: EditSpec?, duration: Double) throws -> TimeRange {
        guard case .trim(let range) = edit else { throw ConversionError.notApplicable(reason: noEditReason) }
        if let problem = trimProblem(range, duration: duration) { throw ConversionError.notApplicable(reason: problem) }
        return TimeRange(start: range.start, end: min(range.end, duration))
    }

    /// The points that cut, sorted: one under `pointSpacing` from either end or from the previous kept point goes.
    public static func usablePoints(_ points: [Double], duration: Double) -> [Double] {
        var kept: [Double] = []
        for point in points.filter(\.isFinite).sorted() {
            guard point >= pointSpacing - slack, point <= duration - pointSpacing + slack else { continue }
            if let last = kept.last, point - last < pointSpacing - slack { continue }
            kept.append(point)
        }
        return kept
    }

    public static func splitPoints(_ edit: EditSpec?, duration: Double) throws -> [Double] {
        guard case .split(let points) = edit else { throw ConversionError.notApplicable(reason: noEditReason) }
        let usable = usablePoints(points, duration: duration)
        guard !usable.isEmpty else { throw ConversionError.notApplicable(reason: noPointReason) }
        return usable
    }
}
