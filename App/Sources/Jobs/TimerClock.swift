import Foundation

/// The time the coordinator's, the pill's and the wheel's timers run on. The app uses the real clock; tests pass a
/// virtual one, so no test waits real seconds for a timer to fire (P134).
struct TimerClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = TimerClock(now: { .now }, sleep: { try await Task.sleep(for: $0) })

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await sleep(max(.zero, deadline - now()))
    }
}
