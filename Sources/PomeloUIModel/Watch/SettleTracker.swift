// A file that has just appeared may still be written to (a download, a copy in progress, a cloud file that isn't
// local yet). It is ready once its size and date have stayed the same for `interval` and its content is on disk (P110).
import Foundation

public struct SettleTracker: Sendable {
    public static let interval: Duration = .seconds(1)

    private struct Seen: Sendable {
        var size: Int64
        var modified: Date
        var isReadyToCount: Bool
        /// When this exact state was first seen: a change starts the clock again.
        var since: ContinuousClock.Instant
        var reported = false
    }

    private var seen: [URL: Seen] = [:]

    public init() {}

    /// The files seen and still waiting to settle.
    public var pending: Set<URL> {
        Set(seen.filter { !$0.value.reported }.keys)
    }

    /// True once per state: the content is local, the size is over 0, and the first observation of this same size and
    /// date was at least `interval` ago. A file that reported ready stays quiet until it changes or is forgotten.
    public mutating func observe(_ url: URL, size: Int64, modified: Date, isLocal: Bool, at now: ContinuousClock.Instant) -> Bool {
        let counts = isLocal && size > 0
        if var previous = seen[url], previous.size == size, previous.modified == modified,
           previous.isReadyToCount == counts {
            guard counts, !previous.reported, now - previous.since >= Self.interval else { return false }
            previous.reported = true
            seen[url] = previous
            return true
        }
        seen[url] = Seen(size: size, modified: modified, isReadyToCount: counts, since: now)
        return false
    }

    /// How long a file that can't settle (empty, not local, still being copied) waits between looks at most.
    public static let longestWait: Duration = .seconds(60)

    /// How long until the pending files need another look, nil when none is pending: `interval` while one of them can
    /// settle; a file stuck in a state that can't waits as long as it has been stuck (doubling) up to `longestWait`,
    /// so a file that never settles costs a wakeup a minute, not one a second.
    public func nextLook(at now: ContinuousClock.Instant) -> Duration? {
        seen.values.lazy.filter { !$0.reported }.map { seen in
            seen.isReadyToCount ? Self.interval : min(max(now - seen.since, Self.interval), Self.longestWait)
        }.min()
    }

    public mutating func forget(_ url: URL) {
        seen[url] = nil
    }
}
