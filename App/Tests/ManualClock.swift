import Foundation
import Testing
@testable import Pomelo

/// Virtual time for the timers behind `TimerClock` (P134): it stands still until a test advances it, and then wakes
/// each sleep that ends meanwhile, earliest first, so a test steps through half a second without waiting for it.
final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let requested: Duration
        let order: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    /// Sleeps cancelled before they were registered, so they never wait.
    private var cancelled: Set<UUID> = []
    private var registered = 0

    var now: ContinuousClock.Instant { start + lock.withLock { elapsed } }
    /// How many sleeps are waiting for the clock.
    var waiting: Int { lock.withLock { sleepers.count } }

    /// Whether a sleep of exactly `duration` is waiting, so a test can tell its timer from others on the clock.
    func isWaiting(for duration: Duration) -> Bool {
        lock.withLock { sleepers.values.contains { $0.requested == duration } }
    }

    var timerClock: TimerClock {
        TimerClock(now: { [self] in now }, sleep: { [self] in try await sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let wasCancelled = lock.withLock { () -> Bool in
                    if cancelled.remove(id) != nil { return true }
                    registered += 1
                    sleepers[id] = Sleeper(
                        deadline: elapsed + duration, requested: duration, order: registered, continuation: continuation
                    )
                    return false
                }
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return nil
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on by `duration`, waking every sleep that ends meanwhile in deadline order, and lets what each one
    /// starts run (including sleeps it begins, which wake too if they end within `duration`).
    @MainActor
    func advance(by duration: Duration) async {
        // A timer whose task has not reached its sleep yet must still count, or it would never fire.
        await settle()
        let target = lock.withLock { elapsed } + duration
        while true {
            let next = lock.withLock { () -> Sleeper? in
                guard let (id, sleeper) = sleepers
                    .filter({ $0.value.deadline <= target })
                    .min(by: { ($0.value.deadline, $0.value.order) < ($1.value.deadline, $1.value.order) })
                else { return nil }
                sleepers[id] = nil
                elapsed = max(elapsed, sleeper.deadline)
                return sleeper
            }
            guard let next else { break }
            next.continuation.resume()
            await settle()
        }
        lock.withLock { elapsed = max(elapsed, target) }
        await settle()
    }

    /// A few turns of the main actor, for the tasks a wake-up resumed (they hop back to it).
    @MainActor
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
@Suite struct ManualClockTests {
    /// The negative checks that replaced real waits depend on this: a timer started just before `advance`, whose task
    /// has not reached its sleep yet, still fires within the advance.
    @Test func aTimerWhoseTaskHasNotSleptYetStillFires() async {
        let clock = ManualClock()
        var fired = false
        Task { @MainActor in
            try? await clock.sleep(.seconds(1))
            fired = true
        }
        await clock.advance(by: .seconds(1))
        #expect(fired)
    }

    @Test func sleepsWakeInDeadlineOrderAndOnlyWhenDue() async {
        let clock = ManualClock()
        var woken: [Int] = []
        for (index, delay) in [(2, 300), (1, 100), (3, 900)] {
            Task { @MainActor in
                try? await clock.sleep(.milliseconds(delay))
                woken.append(index)
            }
        }
        await clock.advance(by: .milliseconds(500))
        #expect(woken == [1, 2])
        #expect(clock.isWaiting(for: .milliseconds(900)))
        await clock.advance(by: .milliseconds(400))
        #expect(woken == [1, 2, 3])
    }
}
