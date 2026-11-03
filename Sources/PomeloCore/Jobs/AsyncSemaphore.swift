import Foundation

/// A counting semaphore for async code. Waiters are resumed in FIFO order. Waiting is not cancellable: a cancelled
/// waiter still gets its slot and must `signal()` it back.
public actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore needs a non-negative value")
        self.value = value
    }

    public func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
