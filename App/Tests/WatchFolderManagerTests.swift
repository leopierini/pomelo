import Foundation
import os
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Marks `url` as Pomelo's output, as `OutputPublisher` does.
private func mark(_ url: URL) {
    let value = Array("1".utf8)
    _ = setxattr(url.path, OutputMark.attributeName, value, value.count, 0, XATTR_NOFOLLOW)
}

/// Stands in for `JobCoordinator.runUnattended`: records each request and answers with `answer` (by default a success
/// with no outputs).
@MainActor
private final class RecordingRun {
    var requests: [(request: ConversionRequest, verb: String)] = []
    var answer: (ConversionRequest) -> [FileResult] = { request in
        request.inputs.map { .succeeded(source: $0, outputs: [], note: nil) }
    }
    /// When set, a run hands its results back only once the gate opens (after `answer`, which may publish outputs).
    var gate: Gate?

    var inputs: [String] { requests.flatMap { $0.request.inputs.map(\.lastPathComponent) } }

    func run(_ request: ConversionRequest, _ verb: String) async -> [FileResult] {
        requests.append((request, verb))
        let results = answer(request)
        if let gate { _ = await eventually(within: .seconds(10)) { gate.isOpen } }
        return results
    }
}

@MainActor
private final class Gate {
    private(set) var isOpen = false
    func open() { isOpen = true }
}

/// The settle poll's clock (P134): virtual time that moves only by the sleeps the manager asks for, so no test waits
/// real seconds for a file to settle. Running, each sleep passes after 2 ms of real time (files and their events keep
/// up); held, a sleep passes only when the test steps it.
private final class TestClock: Sendable {
    private struct State {
        var elapsed: Duration = .zero
        var requested: [Duration] = []
        var isHeld = false
        var steps = 0
    }

    private let start = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: ContinuousClock.Instant { start + elapsed }
    var elapsed: Duration { state.withLock { $0.elapsed } }
    /// Every sleep the manager asked for, in order.
    var requested: [Duration] { state.withLock { $0.requested } }

    func hold() { state.withLock { $0.isHeld = true } }

    func sleep(_ duration: Duration) async throws {
        state.withLock { $0.requested.append(duration) }
        while true {
            try await Task.sleep(for: .milliseconds(2))
            let passes = state.withLock { state -> Bool in
                if state.isHeld {
                    guard state.steps > 0 else { return false }
                    state.steps -= 1
                }
                state.elapsed += duration
                return true
            }
            if passes { return }
        }
    }

    /// Held: lets one sleep pass, and waits until the poll has looked and asked for its next sleep (or, when the look
    /// should end the poll, until the sleep has passed).
    @MainActor
    func step(thenAnotherSleep: Bool = true) async -> Bool {
        let count = requested.count
        state.withLock { $0.steps += 1 }
        guard thenAnotherSleep else { return await eventually { self.state.withLock { $0.steps == 0 } } }
        return await eventually { self.requested.count > count }
    }

    /// Waits until the poll's time has moved on by `duration`.
    @MainActor
    func advanced(by duration: Duration) async -> Bool {
        let mark = elapsed
        return await eventually(within: .seconds(10)) { self.elapsed - mark >= duration }
    }
}

/// A probe the tests steer: whether content is local, and how often that was asked.
private final class SteeredProbe: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (isLocal: true, asked: 0))

    var asked: Int { state.withLock { $0.asked } }

    func setLocal(_ isLocal: Bool) { state.withLock { $0.isLocal = isLocal } }

    func probe(isMarked: @escaping @Sendable (URL) -> Bool = { _ in false }) -> WatchFolderManager.FileProbe {
        WatchFolderManager.FileProbe(
            isLocal: { [state] _ in state.withLock { $0.asked += 1; return $0.isLocal } }, isMarked: isMarked
        )
    }
}

@MainActor
@Suite struct WatchFolderManagerTests {
    /// Converts png and heic to jpg and jpg to png, and compresses jpg (an operation edge).
    private let registry = EngineRegistry(
        engines: [
            FakeEngine(id: "fake", edges: [
                ConversionEdge(from: "png", to: "jpg", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "heic", to: "jpg", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "jpg", to: "png", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "jpg", to: "jpg", engineID: "fake", cost: 1, flags: [], operation: "compress"),
            ])
        ],
        priority: ["fake"]
    )

    private struct Setup {
        let manager: WatchFolderManager
        let store: SettingsStore
        let run: RecordingRun
        let clock: TestClock
        let id: UUID
        /// Every rule's id, `id` first.
        let ids: [UUID]
    }

    /// `also` adds more rules on the same folder.
    private func makeManager(
        watching folder: URL, action: WatchAction = .convert("jpg"), also: [WatchAction] = [],
        bookmarked: Bool = false, probe: WatchFolderManager.FileProbe = .live
    ) -> Setup {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let watched = WatchFolder(
            path: folder.path, bookmark: bookmarked ? try? folder.bookmarkData() : nil, action: action
        )
        let others = also.map { WatchFolder(path: folder.path, action: $0) }
        store.settings.watchFolders = [watched] + others
        let run = RecordingRun()
        let clock = TestClock()
        let manager = WatchFolderManager(
            settings: store, registry: registry, run: { await run.run($0, $1) }, probe: probe,
            now: { clock.now }, sleep: { try await clock.sleep($0) }
        )
        return Setup(
            manager: manager, store: store, run: run, clock: clock, id: watched.id,
            ids: [watched.id] + others.map(\.id)
        )
    }

    /// Starts watching and waits until every rule's baseline is taken.
    private func started(_ setup: Setup) async throws {
        setup.manager.start()
        try #require(await eventually { setup.ids.allSatisfy { setup.manager.states[$0] == .watching } })
    }

    private func write(_ name: String, in folder: URL, _ text: String = "content") throws {
        try Data(text.utf8).write(to: folder.appending(path: name), options: .atomic)
    }

    /// Writes `name` elsewhere, lets `prepare` mark it, then moves it in: the watch never sees it unmarked.
    private func arrive(_ name: String, in folder: URL, _ prepare: (URL) throws -> Void) throws -> URL {
        let staging = folder.deletingLastPathComponent()
            .appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appending(path: name)
        try Data("partly copied".utf8).write(to: staged)
        try prepare(staged)
        let arrived = folder.appending(path: name)
        try FileManager.default.moveItem(at: staged, to: arrived)
        return arrived
    }

    /// True once the watch has followed the folder to `renamed` (a condition, not a fixed wait).
    private func isFollowed(_ setup: Setup, to renamed: URL) async -> Bool {
        let target = renamed.resolvingSymlinksInPath().path
        return await eventually(within: .seconds(10)) {
            setup.manager.watchedURL(setup.id)?.resolvingSymlinksInPath().path == target
        }
    }

    /// Long enough for anything that arrived to settle and be taken, were it to be: the folder's events land, then
    /// the poll runs until nothing is settling (or a minute of its time passes, for a file that can't settle).
    private func quiet(_ setup: Setup) async {
        try? await Task.sleep(for: .milliseconds(300))
        let mark = setup.clock.elapsed
        _ = await eventually(within: .seconds(10)) {
            !setup.manager.isPolling || setup.clock.elapsed - mark >= .seconds(60)
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - Arrivals

    @Test func existingFilesAreNeverProcessed() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("old.png", in: folder)
        try write("older.heic", in: folder)
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try write("new.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["new.png"])
    }

    @Test func aNewFileIsProcessedOnceItSettles() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let arrived = setup.clock.now
        try write("a.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(setup.clock.now - arrived >= SettleTracker.interval)
        let request = try #require(setup.run.requests.first)
        #expect(request.request.inputs == [folder.appending(path: "a.png")])
        #expect(request.request.target == "jpg")
        #expect(request.request.replaceOriginal == false)
        #expect(request.verb == "Converting")
        await quiet(setup)
        #expect(setup.run.requests.count == 1)
    }

    @Test func aToolRuleRunsWithTheToolsVerb() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder, action: .tool("compress"))
        defer { setup.manager.stop() }
        try await started(setup)

        try write("a.jpg", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        let request = try #require(setup.run.requests.first)
        #expect(request.request.operation == "compress")
        #expect(request.verb == ToolCatalog.info("compress")?.verb)
    }

    @Test func aGrowingFileWaitsUntilItSettles() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        // Each second of the poll's time, the file has grown.
        setup.clock.hold()
        let file = folder.appending(path: "big.png")
        try Data("start".utf8).write(to: file)
        try #require(await eventually { setup.clock.requested.count == 1 })
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<3 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x2A, count: 1024))
            #expect(await setup.clock.step())
        }
        try handle.close()
        #expect(setup.run.requests.isEmpty)
        // A second with no change, and it is taken.
        #expect(await setup.clock.step(thenAnotherSleep: false))
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(setup.run.inputs == ["big.png"])
    }

    @Test func aRenamedDownloadIsTakenOnce() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        // A browser's partial name, and a hidden copy renamed when whole (the evals hook's way).
        try write("a.png.crdownload", in: folder)
        try write(".b.png", in: folder)
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)
        try FileManager.default.moveItem(at: folder.appending(path: "a.png.crdownload"),
                                         to: folder.appending(path: "a.png"))
        try FileManager.default.moveItem(at: folder.appending(path: ".b.png"), to: folder.appending(path: "b.png"))
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count >= 2 })
        // Another arrival lists the folder again: the two taken are not taken twice.
        try write("later.txt", in: folder)
        await quiet(setup)
        #expect(setup.run.inputs.sorted() == ["a.png", "b.png"])
    }

    @Test func theSameNameWithNewContentIsANewArrival() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try write("a.png", in: folder, "first")
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 1 })
        try write("a.png", in: folder, "second, longer")
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 2 })
        #expect(setup.run.inputs == ["a.png", "a.png"])
    }

    // MARK: - Loop safety (P109)

    @Test func theRulesOwnOutputIsNeverProcessed() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder, action: .tool("compress"))
        defer { setup.manager.stop() }
        setup.run.answer = { request in
            request.inputs.map { source in
                let output = folder.appending(path: "\(source.deletingPathExtension().lastPathComponent)-compressed.jpg")
                try? Data("smaller".utf8).write(to: output)
                mark(output)
                return .succeeded(source: source, outputs: [output], note: nil)
            }
        }
        try await started(setup)

        try write("x.jpg", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["x.jpg"])
    }

    /// What the wheel converts inside a watched folder is marked too, and no watch takes it.
    @Test func aMarkedFileFromElsewhereIsNeverProcessed() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let staged = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: staged) }
        try write("made.png", in: staged)
        mark(staged.appending(path: "made.png"))
        try FileManager.default.moveItem(at: staged.appending(path: "made.png"), to: folder.appending(path: "made.png"))
        try write("plain.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["plain.png"])
    }

    @Test func anUnmarkedOutputIsSkippedByMemory() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        let setup = makeManager(watching: folder, action: .tool("compress"), probe: probe.probe())
        defer { setup.manager.stop() }
        setup.run.answer = { request in
            request.inputs.map { source in
                let output = folder.appending(path: "\(source.deletingPathExtension().lastPathComponent)-compressed.jpg")
                try? Data("smaller".utf8).write(to: output)
                return .succeeded(source: source, outputs: [output], note: nil)
            }
        }
        try await started(setup)

        try write("x.jpg", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["x.jpg"])
    }

    /// P127: on a volume that drops the mark, one rule's output is still never another rule's arrival.
    @Test func twoRulesOnOneFolderNeverPingPong() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        let setup = makeManager(watching: folder, action: .convert("jpg"), also: [.convert("png")],
                                probe: probe.probe())
        defer { setup.manager.stop() }
        setup.run.answer = { request in
            request.inputs.map { source in
                let stem = source.deletingPathExtension().lastPathComponent
                let target = request.target?.rawValue ?? source.pathExtension
                var output = folder.appending(path: "\(stem).\(target)")
                if FileManager.default.fileExists(atPath: output.path) {
                    output = folder.appending(path: "\(stem) 2.\(target)")
                }
                try? Data("converted".utf8).write(to: output)
                return .succeeded(source: source, outputs: [output], note: nil)
            }
        }
        try await started(setup)

        try write("x.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["x.png"])
    }

    /// P127: an output that settles before its run has returned waits for that run, then is known as an output.
    @Test func anOutputPublishedBeforeItsRunReturnsIsNeverTaken() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        let setup = makeManager(watching: folder, action: .tool("compress"), probe: probe.probe())
        defer { setup.manager.stop() }
        let gate = Gate()
        setup.run.gate = gate
        setup.run.answer = { request in
            request.inputs.map { source in
                let output = folder.appending(path: "\(source.deletingPathExtension().lastPathComponent)-compressed.jpg")
                try? Data("smaller".utf8).write(to: output)
                return .succeeded(source: source, outputs: [output], note: nil)
            }
        }
        try await started(setup)

        try write("x.jpg", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        // The output settles (a second after the source did) while its run is still going on.
        await quiet(setup)
        #expect(setup.clock.elapsed >= SettleTracker.interval * 2)
        gate.open()
        await quiet(setup)
        #expect(setup.run.inputs == ["x.jpg"])
    }

    // MARK: - Copies in progress (P126)

    /// Finder gives a file it is still copying a placeholder creation date (either of two), however long the copy
    /// stalls; it is taken once the date is the real one.
    @Test func aFileWithFindersBusyDateWaits() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let busyDays = [(1946, 2, 14), (1984, 1, 24)]
        var copying: [URL] = []
        for (index, day) in busyDays.enumerated() {
            let busy = try #require(DateComponents(
                calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                year: day.0, month: day.1, day: day.2, hour: 8
            ).date)
            copying.append(try arrive("copy-\(index).png", in: folder) { url in
                try FileManager.default.setAttributes([.creationDate: busy], ofItemAtPath: url.path)
            })
        }
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)
        for url in copying {
            let modified = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)
            try FileManager.default.setAttributes([.creationDate: modified], ofItemAtPath: url.path)
        }
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 2 })
        #expect(setup.run.inputs.sorted() == ["copy-0.png", "copy-1.png"])
    }

    /// The other mark of a Finder copy in progress: the FinderInfo file type 'brok'.
    @Test func aFileFinderMarksAsBrokWaits() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let copying = try arrive("copy.png", in: folder) { url in
            let info = Array("brokMACS".utf8) + [UInt8](repeating: 0, count: 24)
            guard setxattr(url.path, "com.apple.FinderInfo", info, info.count, 0, XATTR_NOFOLLOW) == 0 else {
                throw POSIXError(.EIO)
            }
        }
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)
        #expect(removexattr(copying.path, "com.apple.FinderInfo", XATTR_NOFOLLOW) == 0)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(setup.run.inputs == ["copy.png"])
    }

    // MARK: - Content not on this Mac

    @Test func aDatalessArrivalWaitsWithoutReading() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        probe.setLocal(false)
        let setup = makeManager(watching: folder, probe: probe.probe())
        defer { setup.manager.stop() }
        try await started(setup)

        try write("cloud.png", in: folder)
        // Asked on arrival and on the polls after it, and never taken while remote.
        #expect(await eventually(within: .seconds(10)) { probe.asked >= 3 })
        #expect(setup.run.requests.isEmpty)
        probe.setLocal(true)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(setup.run.inputs == ["cloud.png"])
    }

    /// An iCloud round trip (evicted, then downloaded again with the same size and date) never converts twice.
    @Test func aRoundTripThroughTheCloudNeverReconverts() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        let setup = makeManager(watching: folder, probe: probe.probe())
        defer { setup.manager.stop() }
        try await started(setup)

        try write("a.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 1 })
        probe.setLocal(false)
        try write("b.txt", in: folder)
        #expect(await setup.clock.advanced(by: .seconds(1.5)))
        probe.setLocal(true)
        try write("c.txt", in: folder)
        await quiet(setup)
        #expect(setup.run.inputs == ["a.png"])
    }

    // MARK: - Outcomes

    @Test func aFileTheRuleCantTakeIsIgnoredQuietly() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try write("notes.txt", in: folder)
        try write("photo.jpg", in: folder)
        try await Task.sleep(for: .milliseconds(200))
        try write("a.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        #expect(setup.run.inputs == ["a.png"])
        #expect(setup.manager.problems.isEmpty)
    }

    @Test func aFailureBecomesTheFoldersProblem() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        setup.run.answer = { request in
            request.inputs.map { source in
                source.lastPathComponent == "bad.png"
                    ? .failed(source: source, error: .engineFailed(engine: "fake", message: "CGImageSource failed"))
                    : .succeeded(source: source, outputs: [], note: nil)
            }
        }
        try await started(setup)

        try write("bad.png", in: folder)
        #expect(await eventually(within: .seconds(10)) {
            setup.manager.problems[setup.id] == "Couldn't convert bad.png. The file may be damaged."
        })
        try write("good.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { setup.manager.problems[setup.id] == nil })
        #expect(setup.run.inputs == ["bad.png", "good.png"])
    }

    /// P120: work that doesn't apply ("Already compressed") is no problem, and the file isn't tried again.
    @Test func aFileTheToolDoesNotApplyToIsSkippedQuietly() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder, action: .tool("compress"))
        defer { setup.manager.stop() }
        setup.run.answer = { request in
            request.inputs.map { .failed(source: $0, error: .notApplicable(reason: "Already compressed")) }
        }
        try await started(setup)

        try write("small.jpg", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        try write("later.txt", in: folder)
        await quiet(setup)
        #expect(setup.manager.problems.isEmpty)
        #expect(setup.run.inputs == ["small.jpg"])
    }

    // MARK: - Folder states

    @Test func aMissingFolderShowsItsState() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "later", directoryHint: .isDirectory)
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }

        setup.manager.start()
        #expect(await eventually { setup.manager.states[setup.id] == .missing })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        setup.manager.reconcile()
        #expect(await eventually { setup.manager.states[setup.id] == .watching })
        try FileManager.default.removeItem(at: folder)
        #expect(await eventually { setup.manager.states[setup.id] == .missing })
    }

    /// P130: a renamed or moved folder is found again through its bookmark and keeps its watch state.
    private func rename(_ folder: URL, to name: String) throws -> URL {
        let renamed = folder.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: renamed)
        return renamed
    }

    @Test func aRenamedFolderKeepsBeingWatched() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write("old.png", in: folder)
        let setup = makeManager(watching: folder, bookmarked: true)
        defer { setup.manager.stop() }
        try await started(setup)

        let renamed = try rename(folder, to: "Renamed")
        #expect(await isFollowed(setup, to: renamed))
        try write("new.png", in: renamed)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        // The bookmark may spell the place another way (/private/var for /var).
        let inputs = setup.run.requests.flatMap(\.request.inputs)
        #expect(inputs.map(\.lastPathComponent) == ["new.png"])
        #expect(inputs.first?.deletingLastPathComponent().resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        #expect(setup.manager.states[setup.id] == .watching)
        await quiet(setup)
        #expect(setup.run.requests.count == 1)
    }

    @Test func aFileAddedRightAfterTheRenameIsStillAnArrival() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let setup = makeManager(watching: folder, bookmarked: true)
        defer { setup.manager.stop() }
        try await started(setup)

        let renamed = try rename(folder, to: "Renamed")
        try write("quick.png", in: renamed)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        #expect(setup.run.inputs == ["quick.png"])
    }

    @Test func thePanesPathUpdateAfterARenameDoesNotStartOver() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let setup = makeManager(watching: folder, bookmarked: true)
        defer { setup.manager.stop() }
        try await started(setup)

        let renamed = try rename(folder, to: "Renamed")
        #expect(await isFollowed(setup, to: renamed))
        // Still settling when Settings stores the new path and the manager reconciles.
        try write("pending.png", in: renamed)
        setup.store.settings.watchFolders[0].path = renamed.path
        setup.store.settings.watchFolders[0].bookmark = try renamed.bookmarkData()
        setup.manager.reconcile()
        #expect(setup.manager.states[setup.id] == .watching)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        #expect(setup.run.inputs == ["pending.png"])
    }

    @Test func aRunGoingOnAcrossARenameStillReleasesWhatWaited() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let setup = makeManager(watching: folder, bookmarked: true)
        defer { setup.manager.stop() }
        let gate = Gate()
        setup.run.gate = gate
        try await started(setup)

        try write("first.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        let renamed = try rename(folder, to: "Renamed")
        try write("second.png", in: renamed)
        // It settles while the first run is still going on, so it waits for that run; it is taken once it returns.
        await quiet(setup)
        #expect(setup.clock.elapsed >= SettleTracker.interval * 2)
        #expect(setup.run.requests.count == 1)
        gate.open()
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 2 })
        await quiet(setup)
        #expect(setup.run.inputs == ["first.png", "second.png"])
    }

    @Test func aDeletedFolderWithABookmarkShowsAsMissing() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let setup = makeManager(watching: folder, bookmarked: true)
        defer { setup.manager.stop() }
        try await started(setup)

        try FileManager.default.removeItem(at: folder)
        #expect(await eventually { setup.manager.states[setup.id] == .missing })
        // A folder made again at that path is a new folder: it starts over once the folders are reconciled.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try write("existing.png", in: folder)
        setup.manager.reconcile()
        #expect(await eventually { setup.manager.states[setup.id] == .watching })
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)
    }

    @Test func disablingAFolderStopsWatchingIt() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        setup.store.settings.watchFolders[0].isEnabled = false
        setup.manager.reconcile()
        #expect(setup.manager.states[setup.id] == .off)
        try write("while-off.png", in: folder)
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)

        // Turned on again, what arrived meanwhile is part of the new baseline.
        setup.store.settings.watchFolders[0].isEnabled = true
        setup.manager.reconcile()
        #expect(await eventually { setup.manager.states[setup.id] == .watching })
        try write("after.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        #expect(setup.run.inputs == ["after.png"])
    }

    @Test func removingAFolderFromSettingsForgetsIt() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        setup.store.settings.watchFolders = []
        setup.manager.reconcile()
        #expect(setup.manager.states[setup.id] == nil)
        try write("a.png", in: folder)
        await quiet(setup)
        #expect(setup.run.requests.isEmpty)
    }

    @Test func nothingPollsWhileNothingIsPending() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try await Task.sleep(for: .milliseconds(300))
        #expect(setup.clock.requested.isEmpty)
        try write("a.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        let polls = setup.clock.requested.count
        #expect(polls >= 1)
        #expect(setup.clock.requested.allSatisfy { $0 == SettleTracker.interval })
        await quiet(setup)
        #expect(setup.clock.requested.count == polls)
        #expect(!setup.manager.isPolling)
    }

    // MARK: - Files that can't settle

    /// Waits ten minutes of the poll's time beside `name`, which can't settle, and checks the looks grew to one a
    /// minute instead of one a second.
    private func expectLooksBackOff(_ setup: Setup) async {
        #expect(await setup.clock.advanced(by: .seconds(600)))
        let waits = setup.clock.requested
        #expect(waits.count < 30, "\(waits.count) looks in ten minutes")
        #expect(zip(waits, waits.dropFirst()).allSatisfy { $0 <= $1 }, "\(waits)")
        #expect(waits.suffix(3) == Array(repeating: SettleTracker.longestWait, count: 3), "\(waits.suffix(3))")
        #expect(setup.run.requests.isEmpty)
    }

    @Test func anEmptyFileIsLookedAtLessAndLessOftenAndTakenOnceWritten() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let file = folder.appending(path: "empty.png")
        try Data().write(to: file)
        await expectLooksBackOff(setup)
        // Written in place, which sends no folder event: the next look sees it, and a second later it is taken.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("content".utf8))
        try handle.close()
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(setup.clock.requested.last == SettleTracker.interval)
        #expect(await eventually { !setup.manager.isPolling })
        #expect(setup.run.inputs == ["empty.png"])
    }

    @Test func aFileThatStaysInTheCloudIsLookedAtLessAndLessOften() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SteeredProbe()
        probe.setLocal(false)
        let setup = makeManager(watching: folder, probe: probe.probe())
        defer { setup.manager.stop() }
        try await started(setup)

        try write("cloud.png", in: folder)
        await expectLooksBackOff(setup)
        probe.setLocal(true)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        #expect(await eventually { !setup.manager.isPolling })
        #expect(setup.run.inputs == ["cloud.png"])
    }

    /// A poll asleep for a minute beside a stuck file is started again for a new arrival, which settles in a second.
    @Test func anArrivalBesideAStuckFileIsStillTakenWithinASecond() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try Data().write(to: folder.appending(path: "empty.png"))
        try #require(await eventually(within: .seconds(10)) {
            setup.clock.requested.last == SettleTracker.longestWait
        })
        setup.clock.hold()
        try write("a.png", in: folder)
        #expect(await eventually { setup.clock.requested.last == SettleTracker.interval })
        _ = await setup.clock.step()
        #expect(await eventually { !setup.run.requests.isEmpty })
        #expect(setup.run.inputs == ["a.png"])
    }

    // MARK: - Identity

    @Test func aFileRenamedAfterItWasTakenIsNotTakenAgain() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("old.png", in: folder)
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        try write("IMG_1.png", in: folder)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        await quiet(setup)
        try FileManager.default.moveItem(at: folder.appending(path: "IMG_1.png"), to: folder.appending(path: "Holiday.png"))
        // What was there before the watch began is no arrival under a new name either.
        try FileManager.default.moveItem(at: folder.appending(path: "old.png"), to: folder.appending(path: "Older.png"))
        await quiet(setup)
        #expect(setup.run.inputs == ["IMG_1.png"])
    }

    /// Another file put in its place with the same size and date is new content all the same.
    @Test func aReplacementWithTheSameSizeAndDateIsANewArrival() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = makeManager(watching: folder)
        defer { setup.manager.stop() }
        try await started(setup)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dated: (URL) throws -> Void = { url in
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let first = try arrive("a.png", in: folder, dated)
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 1 })
        await quiet(setup)
        let staging = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: staging) }
        let replacement = staging.appending(path: "a.png")
        try Data("partly copied".utf8).write(to: replacement)
        try dated(replacement)
        try #require(Foundation.rename(replacement.path, first.path) == 0)
        #expect(await eventually(within: .seconds(10)) { setup.run.requests.count == 2 })
        #expect(setup.run.inputs == ["a.png", "a.png"])
    }

    // MARK: - Off the main thread

    /// Finding a folder through its bookmark can block on a share that went away: it never happens on the main thread.
    @Test func foldersAreFoundOffTheMainThread() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
        var probe = WatchFolderManager.FileProbe.live
        probe.place = { folder in
            onMain.withLock { $0.append(Thread.isMainThread) }
            return WatchFolderManager.resolve(folder)
        }
        let setup = makeManager(watching: folder, bookmarked: true, probe: probe)
        defer { setup.manager.stop() }
        try await started(setup)

        let renamed = try rename(folder, to: "Renamed")
        try await Task.sleep(for: .milliseconds(300))
        setup.store.settings.watchFolders[0].path = renamed.path
        setup.manager.reconcile()
        try write("new.png", in: renamed)
        #expect(await eventually(within: .seconds(10)) { !setup.run.requests.isEmpty })
        let calls = onMain.withLock { $0 }
        #expect(calls.count >= 3, "begin, the rename and the reconcile")
        #expect(!calls.contains(true))
    }
}
