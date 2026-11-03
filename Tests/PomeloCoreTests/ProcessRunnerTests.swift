import Foundation
import Testing
import PomeloTestSupport
@testable import PomeloCore

@Suite struct ProcessRunnerTests {
    @Test func capturesStdout() async throws {
        let r = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi there"])
        #expect(r.stdout == "hi there\n"); #expect(r.exitCode == 0)
    }

    @Test func argumentsAreNotShellSplit() async throws {
        let r = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["$(whoami); rm -rf x"])
        #expect(r.stdout == "$(whoami); rm -rf x\n")
    }

    @Test func nonZeroExitThrowsWithStderr() async {
        await #expect(throws: ProcessRunnerError.nonZeroExit(code: 3, stderrTail: "boom\n")) {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo boom >&2; exit 3"])
        }
    }

    @Test func timesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await ProcessRunner(timeout: .milliseconds(200)).run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func timeoutIsResetByOutput() async throws {
        // Runs ~1 s in total, far past the 400 ms timeout, but never stays silent for that long.
        let script = "i=0; while [ $i -lt 10 ]; do echo tick; sleep 0.1; i=$((i + 1)); done"
        let r = try await ProcessRunner(timeout: .milliseconds(400)).run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                         arguments: ["-c", script])
        #expect(r.stdout.split(separator: "\n").count == 10)
    }

    @Test func timeoutIsResetByStderrOutput() async throws {
        let script = "i=0; while [ $i -lt 10 ]; do echo tick >&2; sleep 0.1; i=$((i + 1)); done"
        let r = try await ProcessRunner(timeout: .milliseconds(400)).run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                         arguments: ["-c", script])
        #expect(r.exitCode == 0)
    }

    @Test func cancelKillsProcessGroup() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let pidFile = d.appending(path: "child.pid")
        let t = Task { try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"]) }
        try await Task.sleep(for: .milliseconds(300)); t.cancel(); _ = try? await t.value
        try await Task.sleep(for: .seconds(3))
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test func cancelReturnsPromptlyWhenGrandchildHoldsPipes() async throws {
        // The backgrounded sleep inherits stdout/stderr; only a group-wide signal lets the pipes close quickly.
        let t = Task { try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                     arguments: ["-c", "sleep 30 & wait"]) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// A descendant that left the process group (setsid) while holding the pipes gets no group signal, so the stop
    /// must still bound `run()` by closing the pipes itself.
    private static let groupEscapingHolder = ["-c", "/usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 8' & sleep 30"]

    @Test func timeoutReturnsWhenPipeHolderLeftTheGroup() async {
        let start = ContinuousClock.now
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await ProcessRunner(timeout: .milliseconds(300)).run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                     arguments: Self.groupEscapingHolder)
        }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func cancelReturnsWhenPipeHolderLeftTheGroup() async throws {
        let t = Task { try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                     arguments: Self.groupEscapingHolder) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func drainsOutputLargerThanPipeBuffer() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2"
        let r = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        #expect(r.stdout.utf8.count == 300_000)
        #expect(r.stdout.utf8.allSatisfy { $0 == UInt8(ascii: "a") })
        #expect(r.stderrTail == String(repeating: "b", count: ProcessRunner.stderrTailBytes))
    }

    @Test func missingExecutableFailsToLaunch() async {
        await #expect(throws: ProcessRunnerError.launchFailed(errno: ENOENT)) {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/nonexistent/pomelo-tool"), arguments: [])
        }
    }

    @Test func usesGivenEnvironmentAndDirectory() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let r = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                              arguments: ["-c", "echo \"$POMELO_X|$HOME\"; /bin/pwd -P"],
                                              environment: ["POMELO_X": "y"], currentDirectory: d)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "y|")
        // `pwd -P` reports /private/var/…; compare with both sides' symlinks resolved.
        #expect(lines.count == 2 && URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath().path == d.resolvingSymlinksInPath().path)
    }

    @Test func alreadyCancelledDoesNotSpawn() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let marker = d.appending(path: "ran")
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path])
        }
        await #expect(throws: CancellationError.self) { try await t.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// The quit safety net can only reach children it knows: each one is listed while it runs and forgotten once
    /// it is reaped.
    @Test func aRunningChildIsListedUntilItIsReaped() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let pidFile = d.appending(path: "pid")
        let t = Task {
            try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 30"])
        }
        var pid: pid_t?
        for _ in 0..<300 where pid == nil {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let child = try #require(pid)
        #expect(ProcessRunner.liveProcessGroups.contains(child))
        t.cancel()
        _ = try? await t.value
        #expect(!ProcessRunner.liveProcessGroups.contains(child))
    }
}
