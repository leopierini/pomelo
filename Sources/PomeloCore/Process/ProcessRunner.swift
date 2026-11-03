import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    /// The whole of stdout, decoded as UTF-8 (invalid sequences are replaced).
    public let stdout: String
    /// The last `ProcessRunner.stderrTailBytes` of stderr, decoded as UTF-8 (invalid sequences are replaced).
    public let stderrTail: String

    public init(exitCode: Int32, stdout: String, stderrTail: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderrTail = stderrTail
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    /// `posix_spawn` failed; `errno` is the error it returned (for example `ENOENT` for a missing executable).
    case launchFailed(errno: Int32)
    case timedOut
    /// The process exited with a non-zero status. A process killed by a signal it did not get from us reports
    /// `128 + signal`, as shells do.
    case nonZeroExit(code: Int32, stderrTail: String)
}

/// Runs an external tool directly with `posix_spawn`: no shell, argv passed as given, stdin from `/dev/null`.
///
/// The child leads its own process group, so cancelling the calling task or hitting the timeout sends SIGTERM to
/// the whole group (the tool and anything it started), then SIGKILL after a grace period. Cancellation throws
/// `CancellationError`; the timeout throws `ProcessRunnerError.timedOut`.
///
/// The timeout measures inactivity, not total run time: it restarts whenever the child writes anything to stdout or
/// stderr, so a long transcode that keeps reporting progress runs to completion while a silent, hung tool is
/// stopped.
public struct ProcessRunner: Sendable {
    public static let stderrTailBytes = 4096
    static let terminationGracePeriod: DispatchTimeInterval = .seconds(2)

    /// How long the child may go without writing to stdout or stderr before it is stopped.
    public let timeout: Duration

    public init(timeout: Duration = .seconds(600)) {
        self.timeout = timeout
    }

    /// Sends `signal` to the process group of every child still running, from any runner in this process. A safety
    /// net for quitting: a child leads its own group, so nothing else would stop it when this process exits.
    public static func signalAllChildren(_ signal: Int32) {
        LiveProcessGroups.shared.signalAll(signal)
    }

    /// The process groups of the children not yet reaped (each child's pid), for tests.
    static var liveProcessGroups: Set<pid_t> { LiveProcessGroups.shared.all }

    /// Runs `executable` to completion and returns its output. `environment == nil` inherits this process's
    /// environment; otherwise the child gets exactly `environment`. Throws `nonZeroExit` for a non-zero status.
    public func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil, currentDirectory: URL? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let child = try SpawnedChild.launch(
            path: executable.path,
            argv: [executable.path] + arguments,
            env: (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" },
            currentDirectory: currentDirectory?.path
        )

        let timer = Task { [timeout] in
            // Sleep until the latest output plus `timeout`; output that arrived meanwhile moves the deadline on.
            while true {
                let deadline = child.lastActivity + timeout
                if ContinuousClock.now >= deadline { break }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
            child.stop(.timedOut)
        }
        await withTaskCancellationHandler {
            await child.waitUntilFinished()
        } onCancel: {
            child.stop(.cancelled)
        }
        timer.cancel()

        let ending = child.reap()
        switch ending.stopReason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ProcessRunnerError.timedOut
        case nil: break
        }
        let stdout = String(decoding: ending.stdout, as: UTF8.self)
        let stderrTail = String(decoding: ending.stderrTail, as: UTF8.self)
        guard ending.exitCode == 0 else {
            throw ProcessRunnerError.nonZeroExit(code: ending.exitCode, stderrTail: stderrTail)
        }
        return ProcessResult(exitCode: ending.exitCode, stdout: stdout, stderrTail: stderrTail)
    }
}

/// One spawned child: drains its stdout and stderr, notices its exit, and signals its process group.
///
/// The child is left a zombie (exit observed with `waitid(WNOWAIT)`) until `reap()`, so its pid, which is also the
/// process group id, cannot be reused while we might still send `kill(-pid, …)`. All mutable state is behind `lock`.
private final class SpawnedChild: @unchecked Sendable {
    enum StopReason { case cancelled, timedOut }
    enum Stream { case stdout, stderr }

    struct Ending {
        let exitCode: Int32
        let stdout: Data
        let stderrTail: Data
        let stopReason: StopReason?
    }

    let pid: pid_t
    private let lock = NSLock()
    private var stdout = Data()
    private var stderrTail = Data()
    private var openStreams = 2
    private var channels: [DispatchIO] = []
    private var exited = false
    private var reaped = false
    private var stopReason: StopReason?
    private var continuation: CheckedContinuation<Void, Never>?
    private var lastOutput = ContinuousClock.now

    private init(pid: pid_t) {
        self.pid = pid
    }

    static func launch(path: String, argv: [String], env: [String], currentDirectory: String?) throws -> SpawnedChild {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessRunnerError.launchFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            outPipe.forEach { close($0) }
            throw ProcessRunnerError.launchFailed(errno: code)
        }
        // Keep our read ends out of children that other code may spawn concurrently. Our own child is covered by
        // POSIX_SPAWN_CLOEXEC_DEFAULT below.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group led by the child; only fds 0/1/2 survive; default signal dispositions and an empty
        // signal mask, whatever this process has set.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var pid: pid_t = 0
        let status = withCStringArray(argv) { argvPointer in
            withCStringArray(env) { envPointer in
                posix_spawn(&pid, path, &actions, &attributes, argvPointer, envPointer)
            }
        }
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ProcessRunnerError.launchFailed(errno: status)
        }

        let child = SpawnedChild(pid: pid)
        LiveProcessGroups.shared.insert(pid)
        child.drain(fd: outPipe[0], as: .stdout)
        child.drain(fd: errPipe[0], as: .stderr)
        Thread.detachNewThread { child.awaitExit() }
        return child
    }

    /// When the child was launched or last wrote to stdout or stderr.
    var lastActivity: ContinuousClock.Instant {
        lock.withLock { lastOutput }
    }

    /// Returns once the child has exited and both pipes have reached end of file.
    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finishedAlready = lock.withLock {
                if isFinished { return true }
                self.continuation = continuation
                return false
            }
            if finishedAlready { continuation.resume() }
        }
    }

    /// Records why we are stopping, sends SIGTERM to the group, and after the grace period SIGKILL plus a forced
    /// close of both pipes. Only the first call has any effect, and none once the child has finished.
    ///
    /// The forced close bounds the stop even when a descendant left the group (`setsid`/`setpgid`) while still
    /// holding the pipes: no group signal reaches it, but its output is discarded on stop anyway.
    func stop(_ reason: StopReason) {
        let first = lock.withLock {
            guard stopReason == nil, !isFinished else { return false }
            stopReason = reason
            return true
        }
        guard first else { return }
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.terminationGracePeriod) {
            self.signalGroup(SIGKILL)
            self.forceCloseStreams()
        }
    }

    /// Collects the exit status (the child must have finished) and returns everything it produced.
    func reap() -> Ending {
        // Forgotten before `waitpid`: until then the zombie holds the pid, so `signalAll` never reaches a reused one.
        LiveProcessGroups.shared.remove(pid)
        return lock.withLock {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            reaped = true
            let exitCode = result == pid ? Self.exitCode(fromWaitStatus: status) : -1
            return Ending(exitCode: exitCode, stdout: stdout, stderrTail: stderrTail, stopReason: stopReason)
        }
    }

    // MARK: - Internals

    /// Must be called with `lock` held.
    private var isFinished: Bool { exited && openStreams == 0 }

    private func signalGroup(_ signal: Int32) {
        lock.withLock {
            guard !reaped else { return }
            _ = kill(-pid, signal)
        }
    }

    /// Blocks a detached thread until the child exits, without reaping it.
    private func awaitExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        update { $0.exited = true }
    }

    /// Stops any pipe read still pending; its handler then completes with `done`, so the stream counts as closed.
    private func forceCloseStreams() {
        let open = lock.withLock { reaped ? [] : channels }
        open.forEach { $0.close(flags: .stop) }
    }

    private func drain(fd: Int32, as stream: Stream) {
        let queue = DispatchQueue(label: "pomelo.process-runner.drain")
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        channel.setLimit(lowWater: 1)
        lock.withLock { channels.append(channel) }
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty { self.append(data, to: stream) }
            if done {
                channel.close()
                self.update { $0.openStreams -= 1 }
            }
        }
    }

    private func append(_ data: DispatchData, to stream: Stream) {
        lock.withLock {
            lastOutput = .now
            switch stream {
            case .stdout:
                data.enumerateBytes { bytes, _, _ in stdout.append(bytes) }
            case .stderr:
                data.enumerateBytes { bytes, _, _ in stderrTail.append(bytes) }
                if stderrTail.count > ProcessRunner.stderrTailBytes {
                    stderrTail = Data(stderrTail.suffix(ProcessRunner.stderrTailBytes))
                }
            }
        }
    }

    /// Applies `change` under the lock, then resumes the waiter if the child is now finished.
    private func update(_ change: (SpawnedChild) -> Void) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            change(self)
            guard isFinished else { return nil }
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume()
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

/// The pids (and so process group ids) of every spawned child not yet reaped. Signalling happens under the lock,
/// and a child leaves the set before it is reaped, so a signal never reaches a pid the system has reused.
private final class LiveProcessGroups: @unchecked Sendable {
    static let shared = LiveProcessGroups()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    var all: Set<pid_t> { lock.withLock { pids } }

    func insert(_ pid: pid_t) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = pids.remove(pid) } }

    func signalAll(_ signal: Int32) {
        lock.withLock { for pid in pids { _ = kill(-pid, signal) } }
    }
}

/// Calls `body` with a NULL-terminated array of C strings that lives for the duration of the call.
private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
