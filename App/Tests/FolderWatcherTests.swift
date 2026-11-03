import Foundation
import os
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Counts a watcher's callbacks, which arrive on its own queue.
private final class Calls: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (changes: 0, gone: 0))

    var changes: Int { counts.withLock { $0.changes } }
    var gone: Int { counts.withLock { $0.gone } }

    func changed() { counts.withLock { $0.changes += 1 } }
    func wentAway() { counts.withLock { $0.gone += 1 } }
}

@MainActor
@Suite struct FolderWatcherTests {
    private func watch(_ folder: URL, _ calls: Calls) throws -> FolderWatcher {
        try FolderWatcher(folder: folder, onChange: { calls.changed() }, onGone: { calls.wentAway() })
    }

    @Test func creatingAFileFiresOnChange() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = Calls()
        let watcher = try watch(folder, calls)
        defer { watcher.cancel() }

        try Data("x".utf8).write(to: folder.appending(path: "a.png"))
        #expect(await eventually(within: .seconds(2)) { calls.changes > 0 })
        #expect(calls.gone == 0)
    }

    @Test func removingTheFolderFiresOnGone() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let removed = parent.appending(path: "removed", directoryHint: .isDirectory)
        let renamed = parent.appending(path: "renamed", directoryHint: .isDirectory)
        for folder in [removed, renamed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let removedCalls = Calls()
        let renamedCalls = Calls()
        let watchers = [try watch(removed, removedCalls), try watch(renamed, renamedCalls)]
        defer { watchers.forEach { $0.cancel() } }

        try FileManager.default.removeItem(at: removed)
        try FileManager.default.moveItem(at: renamed, to: parent.appending(path: "moved", directoryHint: .isDirectory))
        #expect(await eventually(within: .seconds(2)) { removedCalls.gone > 0 && renamedCalls.gone > 0 })
    }

    @Test func cancelStopsEvents() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let calls = Calls()
        let watcher = try watch(folder, calls)
        // A second watcher on the same folder shows the event really happened.
        let witness = Calls()
        let other = try watch(folder, witness)
        defer { other.cancel() }

        watcher.cancel()
        try Data("x".utf8).write(to: folder.appending(path: "a.png"))
        #expect(await eventually(within: .seconds(2)) { witness.changes > 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(calls.changes == 0)
    }

    @Test func aMissingFolderThrows() throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) {
            try FolderWatcher(folder: folder.appending(path: "nowhere"), onChange: {}, onGone: {})
        }
    }
}
