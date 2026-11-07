import Foundation
import os
import Testing
import PomeloTestSupport
@testable import PomeloCore

private func makeRunner(
    engines: [any ConversionEngine],
    downloads: URL = FileManager.default.temporaryDirectory,
    writable: @escaping @Sendable (URL) -> Bool = { _ in true },
    trashItem: @escaping @Sendable (URL) throws -> Void = { _ in throw TrashRefused() }
) -> JobRunner {
    let registry = EngineRegistry(engines: engines, priority: engines.map(\.id))
    return JobRunner(
        registry: registry, destinations: DestinationResolver(downloadsFolder: downloads, isWritable: writable),
        trashItem: trashItem
    )
}

private struct TrashRefused: Error {}

private func edge(_ from: FormatID, _ to: FormatID, _ engine: EngineID) -> ConversionEdge {
    ConversionEdge(from: from, to: to, engineID: engine, cost: 10, flags: [])
}

@discardableResult
private func write(_ name: String, in dir: URL) -> URL {
    let url = dir.appending(path: name, directoryHint: .notDirectory)
    FileManager.default.createFile(atPath: url.path, contents: Data("data of \(name)".utf8))
    return url
}

private func contents(of dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// Reads its input as a package directory (FakeEngine copies bytes, which a directory cannot give): writes the
/// content of the package's `TXT.rtf` into a text file, so the test proves the package reached the engine intact.
private struct PackageEngine: ConversionEngine {
    struct Failure: Error {}

    let id: EngineID = "pkg"
    let displayName = "pkg"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: "rtfd", to: "txt", engineID: id, cost: 10, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: step.input.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure()
        }
        let inner = try Data(contentsOf: step.input.appending(path: "TXT.rtf", directoryHint: .notDirectory))
        try inner.write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

/// Throws a fixed `ConversionError`, as `CommandEngine` does.
private struct ThrowingEngine: ConversionEngine {
    let error: ConversionError
    let id: EngineID = "x"
    let displayName = "x"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: "png", to: "jpg", engineID: id, cost: 10, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw error
    }
}

/// Returns its input instead of something it made in its staging folder.
private struct OutsideStagingEngine: ConversionEngine {
    let id: EngineID = "outside"
    let displayName = "outside"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: "png", to: "jpg", engineID: id, cost: 10, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        step.input
    }
}

/// Copies its input, then cancels the task it runs in and returns normally: the cancel lands once the engine's work
/// is done, just before publishing.
private struct LateCancellingEngine: ConversionEngine {
    var from: FormatID = "png"
    var to: FormatID = "jpg"
    let id: EngineID = "late"
    let displayName = "late"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: from, to: to, engineID: id, cost: 10, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Data(contentsOf: step.input).write(to: step.suggestedOutput)
        withUnsafeCurrentTask { $0?.cancel() }
        return step.suggestedOutput
    }
}

/// Produces an item with a name of its own (an extracted folder or file), as an extract tool does.
private struct NamedOutputEngine: ConversionEngine {
    let name: String
    let isFolder: Bool
    let id: EngineID = "named"
    let displayName = "named"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] {
        ["zip", "pdf"].map { ConversionEdge(from: $0, to: $0, engineID: id, cost: 10, flags: [], operation: "extract") }
    }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if isFolder {
            let folder = step.stagingDirectory.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("inside".utf8).write(to: folder.appending(path: "1.jpg", directoryHint: .notDirectory))
            return folder
        }
        let file = step.stagingDirectory.appending(path: name, directoryHint: .notDirectory)
        try Data("produced".utf8).write(to: file)
        return file
    }
}

/// A stand-in for the Trash (P16): moves each item into its own folder and records it, then runs `after`.
private final class TestTrash: Sendable {
    let folder: URL
    private let after: @Sendable (URL) throws -> Void
    private let trashed = OSAllocatedUnfairLock(initialState: [URL]())

    init(folder: URL, after: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.folder = folder
        self.after = after
    }

    var items: [URL] { trashed.withLock { $0 } }

    func trash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
        trashed.withLock { $0.append(url) }
        try after(url)
    }
}

/// What `ObservedEngine` saw: the staging folder of its step and whether its conversion ended in cancellation.
private final class ConvertLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (stagingDirectory: URL?, cancelled: Bool)(nil, false))

    var stagingDirectory: URL? { state.withLock { $0.stagingDirectory } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func started(in directory: URL) { state.withLock { $0.stagingDirectory = directory } }
    func markCancelled() { state.withLock { $0.cancelled = true } }
}

/// Wraps a `FakeEngine`: reports progress 0 as soon as it starts, then records whether the wrapped conversion was
/// cancelled.
private struct ObservedEngine: ConversionEngine {
    let inner: FakeEngine
    let log: ConvertLog

    var id: EngineID { inner.id }
    var displayName: String { inner.displayName }
    var maxConcurrentJobs: Int { inner.maxConcurrentJobs }

    func availability() async -> EngineAvailability { await inner.availability() }
    func edges() -> [ConversionEdge] { inner.edges() }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        log.started(in: step.stagingDirectory)
        progress(0)
        do {
            return try await inner.convert(step, progress: progress)
        } catch is CancellationError {
            log.markCancelled()
            throw CancellationError()
        }
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes; returns whether it held.
private func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Runs `request` through `run(_:emit:)` and returns what it emitted, in order, with its results.
private func runCollecting(_ runner: JobRunner, _ request: ConversionRequest) async -> ([JobEvent], [FileResult]) {
    let events = OSAllocatedUnfairLock(initialState: [JobEvent]())
    let results = await runner.run(request, emit: { event in events.withLock { $0.append(event) } })
    return (events.withLock { $0 }, results)
}

/// A minimal RTFD package: a directory named `<stem>.rtfd` holding `TXT.rtf`.
private func makeRTFDPackage(_ stem: String, in dir: URL) throws -> URL {
    let package = dir.appending(path: "\(stem).rtfd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    try Data("{\\rtf1 package body}".utf8).write(to: package.appending(path: "TXT.rtf", directoryHint: .notDirectory))
    return package
}

@Suite struct JobRunnerTests {
    @Test func convertsNextToSource() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])
        let res = await r.run(.init(inputs: [src], target: "jpg"))
        guard case .succeeded(_, let outs, nil) = res.first else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["a.jpg"])
        #expect(outs.first?.deletingLastPathComponent().path == d.path)
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(try String(contentsOf: src, encoding: .utf8) == "data of a.png")
    }

    @Test func runsMultiHopRoute() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.heic", in: d)
        let r = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("heic", "png", "x")]),
            FakeEngine(id: "y", edges: [edge("png", "webp", "y")]),
        ])
        let res = await r.run(.init(inputs: [src], target: "webp"))
        guard case .succeeded(_, let outs, nil) = res.first, let out = outs.first else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["a.webp"])
        #expect(try String(contentsOf: out, encoding: .utf8).hasSuffix("->png\n->webp"))
    }

    @Test func failureIsIsolated() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let good = write("good.png", in: d)
        let bad = write("bad.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], failOnStem: "bad")])
        let res = await r.run(.init(inputs: [good, bad], target: "jpg"))
        #expect(res.count == 2)
        guard case .succeeded(good, let outs, nil) = res[0] else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["good.jpg"])
        guard case .failed(bad, .engineFailed(let engine, let message)) = res[1] else { Issue.record("\(res)"); return }
        #expect(engine == "x")
        #expect(message == String(describing: FakeEngine.Failure()))
        #expect(try contents(of: d) == ["bad.png", "good.jpg", "good.png"])
    }

    @Test func engineThrownConversionErrorPassesThroughUnwrapped() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [ThrowingEngine(error: .engineFailed(engine: "x", message: "exited with code 183"))])
        let res = await r.run(.init(inputs: [src], target: "jpg"))
        // Not re-wrapped: the message would otherwise read "x: x: exited with code 183".
        #expect(res == [.failed(source: src, error: .engineFailed(engine: "x", message: "exited with code 183"))])
        guard case .failed(_, let error) = res.first else { return }
        #expect(error.description == "x: exited with code 183")
    }

    @Test func engineOutsideStagingIsAConverterFault() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let res = await makeRunner(engines: [OutsideStagingEngine()]).run(.init(inputs: [src], target: "jpg"))
        guard case .failed(src, .converterFault(let engine, let message)) = res.first else {
            Issue.record("\(res)")
            return
        }
        #expect(engine == "outside")
        #expect(message.hasPrefix("returned ") && message.hasSuffix(", outside its staging directory"))
        #expect(try contents(of: d) == ["a.png"])
    }

    /// The CLI prints `description`, so the typed cases keep the text the messages had.
    @Test func cliTextIsUnchangedForTypedErrors() {
        #expect(ConversionError.converterTimedOut(engine: "ffmpeg").description == "ffmpeg: timed out")
        #expect(ConversionError.converterUnavailable(engine: "cwebp", message: "executable not found").description
                == "cwebp: executable not found")
        #expect(ConversionError.converterFault(engine: "x", message: "produced no output").description
                == "x: produced no output")
        #expect(ConversionError.notApplicable(reason: "No code found").description == "No code found")
        #expect(ConversionError.notApplicable(reason: "Pomelo can't translate from Japanese to Klingon.").description
                == "Pomelo can't translate from Japanese to Klingon.")
        #expect(ConversionError.engineFailed(engine: "x", message: "exited with code 1").description
                == "x: exited with code 1")
    }

    @Test func publishFailureReadsAsASentence() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])
        // The output folder does not exist, so the final rename fails.
        let missing = d.appending(path: "missing", directoryHint: .isDirectory)
        let res = await r.run(.init(inputs: [src], target: "jpg", outputFolder: missing))
        guard case .failed(src, .publishFailed(let message)) = res.first else { Issue.record("\(res)"); return }
        #expect(message == CocoaError(.fileWriteUnknown).localizedDescription)
        #expect(!message.contains("Domain="))
    }

    @Test func directoryInputFailsAlone() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let folder = d.appending(path: "folder.png", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])
        let res = await r.run(.init(inputs: [folder, src], target: "jpg"))
        #expect(res.count == 2)
        #expect(res.first == .failed(source: folder, error: .isDirectory))
        guard case .succeeded(src, let outs, nil) = res[1] else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["a.jpg"])
    }

    /// A FIFO named like a file would block the first engine that opens it, forever.
    @Test func aFIFOIsRefusedBeforeAnyEngineOpensIt() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let fifo = d.appending(path: "pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let link = d.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        let src = write("a.png", in: d)
        let linkToFile = d.appending(path: "alias.png")
        try FileManager.default.createSymbolicLink(at: linkToFile, withDestinationURL: src)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])

        let res = await r.run(.init(inputs: [fifo, link, linkToFile], target: "jpg"))

        #expect(res[0] == .failed(source: fifo, error: .notARegularFile))
        #expect(res[1] == .failed(source: link, error: .notARegularFile))
        guard case .succeeded = res[2] else { Issue.record("\(res)"); return }
    }

    @Test func knownPackageIsAcceptedAsAFile() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let package = try makeRTFDPackage("note", in: d)
        #expect(try package.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
        let r = makeRunner(engines: [PackageEngine()])
        let res = await r.run(.init(inputs: [package], target: "txt"))
        guard case .succeeded(_, let outs, nil) = res.first else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["note.txt"])
        #expect(try String(contentsOf: outs[0], encoding: .utf8) == "{\\rtf1 package body}")
        #expect(try contents(of: package) == ["TXT.rtf"])
    }

    @Test func packageWithUnknownExtensionAndPlainFolderStillFail() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let bundle = d.appending(path: "thing.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        #expect(try bundle.resourceValues(forKeys: [.isPackageKey]).isPackage == true)
        let folder = d.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let r = makeRunner(engines: [PackageEngine()])
        let res = await r.run(.init(inputs: [bundle, folder], target: "txt"))
        #expect(res == [.failed(source: bundle, error: .isDirectory), .failed(source: folder, error: .isDirectory)])
    }

    @Test func unknownFormatAndNoRoute() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let zzz = write("a.zzz", in: d)
        let png = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])
        let res = await r.run(.init(inputs: [zzz, png], target: "mp3"))
        #expect(res == [
            .failed(source: zzz, error: .unknownFormat(ext: "zzz")),
            .failed(source: png, error: .noRoute(from: "png", to: "mp3")),
        ])
        #expect(try contents(of: d) == ["a.png", "a.zzz"])
    }

    @Test func batchCollisionReservesNames() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let jpg = write("a.jpg", in: d)
        let png = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "webp", "x"), edge("png", "webp", "x")])])
        let res = await r.run(.init(inputs: [jpg, png], target: "webp"))
        let outs = res.compactMap { result -> URL? in
            guard case .succeeded(_, let outs, nil) = result else { return nil }
            return outs.first
        }
        #expect(outs.count == 2, "\(res)")
        #expect(outs.map(\.lastPathComponent).sorted() == ["a 2.webp", "a.webp"])
        let texts = try Set(outs.map { try String(contentsOf: $0, encoding: .utf8) })
        #expect(texts == ["data of a.jpg\n->webp", "data of a.png\n->webp"])
    }

    @Test func fallsBackToDownloadsWhenUnwritable() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let downloads = try makeTempDir(); defer { try? FileManager.default.removeItem(at: downloads) }
        let src = write("a.png", in: d)
        let sourceDir = d.path
        let r = makeRunner(
            engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])],
            downloads: downloads,
            writable: { $0.path != sourceDir }
        )
        let res = await r.run(.init(inputs: [src], target: "jpg"))
        guard case .succeeded(_, let outs, let note) = res.first else { Issue.record("\(res)"); return }
        #expect(note == .fellBackToDownloads)
        #expect(outs.map(\.lastPathComponent) == ["a.jpg"])
        #expect(outs.first?.deletingLastPathComponent().path == downloads.path)
        #expect(try contents(of: d) == ["a.png"])
    }

    @Test func sameFormatPresetUsesSuffix() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "png", "x")])])
        let res = await r.run(ConversionRequest(inputs: [src], target: nil, nameSuffix: "half"))
        guard case .succeeded(_, let outs, nil) = res.first else { Issue.record("\(res)"); return }
        #expect(outs.map(\.lastPathComponent) == ["a-half.png"])
        #expect(try String(contentsOf: src, encoding: .utf8) == "data of a.png")
    }

    @Test func cancellationLeavesNoPartialOutput() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], delay: .seconds(5))])
        let req = ConversionRequest(inputs: [src], target: "jpg")
        let started = ContinuousClock.now
        let task = Task { await runner.run(req) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let res = await task.value
        #expect(res == [.cancelled(source: src)])
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(try contents(of: d) == ["a.png"])
    }

    @Test func respectsEngineConcurrency() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let inputs = ["a.png", "b.png", "c.png"].map { write($0, in: d) }
        let r = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], delay: .milliseconds(200), maxConcurrentJobs: 1),
        ])
        let started = ContinuousClock.now
        let res = await r.run(.init(inputs: inputs, target: "jpg"))
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(550))
        #expect(res.count == 3)
        for (input, result) in zip(inputs, res) {
            guard case .succeeded(input, _, nil) = result else { Issue.record("\(res)"); return }
        }
    }

    @Test func aFileReportsStartedProgressAndFinished() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])
        let (events, results) = await runCollecting(r, .init(inputs: [src], target: "jpg"))
        guard case .fileStarted(index: 0) = events.first else { Issue.record("\(events)"); return }
        guard case .fileFinished(0, .succeeded) = events.last else { Issue.record("\(events)"); return }
        #expect(results.count == 1)
        guard case .succeeded(src, _, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(events.contains { if case .progress(0, 1.0) = $0 { true } else { false } })
        #expect(events.contains { if case .fileFinished(0, .succeeded) = $0 { true } else { false } })
    }

    /// A file queued behind its engine's limit hasn't started: the app times its indicator from `.fileStarted` (P24).
    @Test func aFileStartsOnlyOnceItHoldsItsEnginesSlot() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let inputs = [write("a.png", in: d), write("b.png", in: d)]
        let r = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], delay: .milliseconds(100), maxConcurrentJobs: 1),
        ])
        let starts = OSAllocatedUnfairLock(initialState: [ContinuousClock.Instant]())
        _ = await r.run(.init(inputs: inputs, target: "jpg"), emit: { event in
            if case .fileStarted = event { starts.withLock { $0.append(.now) } }
        })
        let times = starts.withLock { $0 }
        #expect(times.count == 2)
        // The second file waited for the first one's 100 ms conversion before starting.
        #expect(times[1] - times[0] >= .milliseconds(80))
    }

    @Test func cancellingTheRunStopsTheEngineAndRemovesItsStaging() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let log = ConvertLog()
        let slow = FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], delay: .seconds(30))
        let r = makeRunner(engines: [ObservedEngine(inner: slow, log: log)])
        let started = ContinuousClock.now

        // Cancelled at the first progress event, which the engine sends once its conversion is under way.
        let (progressed, progress) = AsyncStream.makeStream(of: Void.self)
        let running = Task {
            await r.run(.init(inputs: [src], target: "jpg"), emit: { if case .progress = $0 { progress.yield() } })
        }
        for await _ in progressed { break }
        running.cancel()
        #expect(await running.value == [.cancelled(source: src)])

        let staging = try #require(log.stagingDirectory).deletingLastPathComponent()
        #expect(await eventually { log.cancelled }, "the engine never saw the cancellation")
        #expect(await eventually { !FileManager.default.fileExists(atPath: staging.path) }, "staging was left behind")
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(try contents(of: d) == ["a.png"])
    }

    @Test func aFileCancelledAsItsEngineReturnsIsNeverPublished() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [LateCancellingEngine()])
        #expect(await r.run(.init(inputs: [src], target: "jpg")) == [.cancelled(source: src)])
        #expect(try contents(of: d) == ["a.png"])
    }

    /// A job cancelled while its file waits for the engine's slot never starts it (the app would otherwise show
    /// progress for it, P24): it reports only `.fileFinished(.cancelled)`.
    @Test func aFileCancelledWhileQueuedNeverReportsStarted() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let first = write("a.png", in: d)
        let queued = write("b.png", in: d)
        let r = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("png", "jpg", "x")], delay: .milliseconds(300), maxConcurrentJobs: 1),
        ])
        let events = OSAllocatedUnfairLock(initialState: [JobEvent]())
        let running = Task { await r.run(.init(inputs: [first], target: "jpg")) }
        try await Task.sleep(for: .milliseconds(50))
        let waiting = Task {
            await r.run(.init(inputs: [queued], target: "jpg"), emit: { event in events.withLock { $0.append(event) } })
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()

        #expect(await waiting.value == [.cancelled(source: queued)])
        _ = await running.value
        let seen = events.withLock { $0 }
        #expect(!seen.contains { if case .fileStarted = $0 { true } else { false } }, "\(seen)")
        #expect(seen.contains { if case .fileFinished(0, .cancelled) = $0 { true } else { false } }, "\(seen)")
        #expect(try contents(of: d) == ["a.jpg", "a.png", "b.png"])
    }
}

@Suite struct OperationJobTests {
    @Test func runnerRunsTheOperationEdge() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("clip.mp4", in: dir)
        let engine = FakeEngine(id: "fake", edges: [
            ConversionEdge(from: "mp4", to: "mp4", engineID: "fake", cost: 10, flags: [], operation: "remove-audio")])
        let runner = makeRunner(engines: [engine])
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "silent")
        request.operation = "remove-audio"

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, _) = results[0] else { Issue.record("expected success: \(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["clip-silent.mp4"])
        #expect(try String(contentsOf: outputs[0], encoding: .utf8).contains("remove-audio"))
    }

    @Test func runnerFailsWithNoRouteForAMissingOperation() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("clip.mp4", in: dir)
        let engine = FakeEngine(id: "fake", edges: [edge("mp4", "mp4", "fake")])
        var request = ConversionRequest(inputs: [source], target: nil)
        request.operation = "remove-audio"

        let results = await makeRunner(engines: [engine]).run(request)
        #expect(results == [.failed(source: source, error: .noRoute(from: "mp4", to: "mp4"))])
        #expect(try contents(of: dir) == ["clip.mp4"])
    }

    @Test func runnerHandsTheEditToTheEngine() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("clip.mov", in: dir)
        let engine = FakeEngine(id: "fake", edges: [
            ConversionEdge(from: "mov", to: "mov", engineID: "fake", cost: 10, flags: [], operation: "trim")])
        let request = ConversionRequest(
            inputs: [source], target: nil,
            options: PresetOptions(edit: .trim(TimeRange(start: 1, end: 3)), targetBytes: 4096),
            nameSuffix: "trimmed", operation: "trim")

        let results = await makeRunner(engines: [engine]).run(request)
        guard case .succeeded(_, let outputs, _) = results[0] else { Issue.record("expected success: \(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["clip-trimmed.mov"])
        let text = try String(contentsOf: outputs[0], encoding: .utf8)
        #expect(text.contains("\"kind\":\"trim\""), "\(text)")
        #expect(text.contains("\"start\":1"), "\(text)")
        #expect(text.contains("4096"), "\(text)")
    }

    @Test func aPresetCarriesItsOperationIntoTheRequest() {
        let preset = Preset(id: "t", name: "T", target: nil, operation: "speed")
        #expect(ConversionRequest.from(preset, inputs: []).operation == "speed")
    }

    @Test func fakeEngineWritesExactBytesAndFolders() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "s", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = write("a.png", in: dir)
        let png = FileFormat(id: "png", displayName: "png", category: .image, extensions: ["png"], utTypeIdentifier: nil)
        let step = ConversionStep(input: input, stagingDirectory: staging, from: png, to: png, options: .init())

        let sized = try await FakeEngine(id: "f", edges: [], outputBytes: 1234).convert(step, progress: { _ in })
        #expect(try Data(contentsOf: sized).count == 1234)
        let folder = try await FakeEngine(id: "f", edges: [], folderItems: ["x.txt", "y.txt"]).convert(step, progress: { _ in })
        #expect(folder == step.suggestedFolder)
        #expect(try contents(of: folder) == ["x.txt", "y.txt"])
        #expect(step.suggestedFolder.lastPathComponent == "a")
    }
}

@Suite struct ToolRuleJobTests {
    private func writeBytes(_ count: Int, named name: String, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: count))
        return url
    }

    private func compressRequest(_ source: URL) -> ConversionRequest {
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "compressed")
        request.replaceOriginal = true
        return request
    }

    @Test func onlyIfSmallerRefusesAResultThatIsNotSmaller() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = writeBytes(100, named: "photo.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")], outputBytes: 100)])
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "compressed")
        request.onlyIfSmaller = true

        let results = await runner.run(request)
        #expect(results == [.failed(source: source, error: .notApplicable(reason: "Already compressed"))])
        #expect(try contents(of: dir) == ["photo.jpg"])
    }

    @Test func onlyIfSmallerPublishesASmallerResult() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = writeBytes(100, named: "photo.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")], outputBytes: 40)])
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "compressed")
        request.onlyIfSmaller = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["photo-compressed.jpg"])
        #expect(try Data(contentsOf: outputs[0]).count == 40)
    }

    @Test func onlyIfSmallerNeverRefusesAFolder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = writeBytes(1, named: "photo.jpg", in: dir)
        let runner = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")], folderItems: ["a.txt", "b.txt"]),
        ])
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "pages")
        request.onlyIfSmaller = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["photo-pages"])
    }

    /// The size is the link target's: a symlink's own size (its target path's length, about 100 bytes in a temp
    /// folder) would refuse almost every result, so the result here is larger than the link but smaller than its target.
    @Test func onlyIfSmallerComparesASymlinkedSourcesTarget() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = writeBytes(5000, named: "real.jpg", in: dir)
        let link = dir.appending(path: "link.jpg", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")], outputBytes: 1000)])
        var request = ConversionRequest(inputs: [link], target: nil, nameSuffix: "compressed")
        request.onlyIfSmaller = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["link-compressed.jpg"])
    }

    @Test func aFileCancelledAsItsEngineReturnsIsCancelledEvenIfNotSmaller() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("a.jpg", in: dir)
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "compressed")
        request.onlyIfSmaller = true
        let results = await makeRunner(engines: [LateCancellingEngine(from: "jpg", to: "jpg")]).run(request)
        #expect(results == [.cancelled(source: source)])
        #expect(try contents(of: dir) == ["a.jpg"])
    }

    @Test func aPresetCarriesItsSizeAndNamingRules() {
        let preset = Preset(id: "t", name: "T", target: nil, onlyIfSmaller: true, outputNaming: .fromOutput)
        let request = ConversionRequest.from(preset, inputs: [])
        #expect(request.onlyIfSmaller)
        #expect(request.outputNaming == .fromOutput)
        #expect(!request.replaceOriginal)
    }

    @Test func outputNamingFromOutputKeepsTheProducedName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("x.zip", in: dir)
        for (engine, expected) in [
            (NamedOutputEngine(name: "Holiday Pics", isFolder: true), "Holiday Pics"),
            (NamedOutputEngine(name: "report.pdf", isFolder: false), "report.pdf"),
        ] {
            var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "extracted", operation: "extract")
            request.outputNaming = .fromOutput
            let results = await makeRunner(engines: [engine]).run(request)
            guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
            #expect(outputs.map(\.lastPathComponent) == [expected])
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Holiday Pics").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try contents(of: dir.appending(path: "Holiday Pics")) == ["1.jpg"])
        #expect(try contents(of: dir) == ["Holiday Pics", "report.pdf", "x.zip"])
    }

    @Test func outputNamingFromOutputNumbersATakenName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("x.zip", in: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "Holiday Pics"), withIntermediateDirectories: false)
        var request = ConversionRequest(inputs: [source], target: nil, operation: "extract")
        request.outputNaming = .fromOutput
        let results = await makeRunner(engines: [NamedOutputEngine(name: "Holiday Pics", isFolder: true)]).run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["Holiday Pics 2"])
    }

    @Test func replacePutsTheResultUnderTheOriginalsName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: trash.trash)

        let results = await runner.run(compressRequest(source))
        #expect(results == [.succeeded(source: source, outputs: [source], note: .replacedOriginal)])
        #expect(try contents(of: dir) == ["a.jpg"])
        #expect(try String(contentsOf: source, encoding: .utf8) == "data of a.jpg\n->jpg")
        #expect(trash.items == [source])
        #expect(try String(contentsOf: trashFolder.appending(path: "a.jpg"), encoding: .utf8) == "data of a.jpg")
    }

    @Test func replaceKeepsBothWhenTheTrashFails() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(
            engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: { _ in throw TrashRefused() }
        )

        let results = await runner.run(compressRequest(source))
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["a-compressed.jpg"])
        #expect(try contents(of: dir) == ["a-compressed.jpg", "a.jpg"])
        #expect(try String(contentsOf: source, encoding: .utf8) == "data of a.jpg")
    }

    @Test func replaceKeepsTheSuffixedNameWhenTheNameIsTakenAgain() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder, after: { url in try Data("newcomer".utf8).write(to: url) })
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: trash.trash)

        let results = await runner.run(compressRequest(source))
        guard case .succeeded(_, let outputs, .replacedOriginal) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["a-compressed.jpg"])
        #expect(try String(contentsOf: outputs[0], encoding: .utf8) == "data of a.jpg\n->jpg")
        #expect(try String(contentsOf: source, encoding: .utf8) == "newcomer")
        #expect(try String(contentsOf: trashFolder.appending(path: "a.jpg"), encoding: .utf8) == "data of a.jpg")
    }

    /// P273: a result of the source's kind in another format takes the source's name with its own extension.
    @Test func replaceAcrossFormatsOfOneKindKeepsTheSourcesName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("Lake.heic", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("heic", "jpg", "x")])], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: "jpg")
        request.replaceOriginal = true

        let results = await runner.run(request)
        let expected = dir.appending(path: "Lake.jpg", directoryHint: .notDirectory)
        #expect(results == [.succeeded(source: source, outputs: [expected], note: .replacedOriginal)])
        #expect(trash.items == [source])
        #expect(try contents(of: dir) == ["Lake.jpg"])
    }

    /// A suffixed tool result in another format (a cutout PNG of a JPEG) drops its suffix when it replaces.
    @Test func replaceDropsTheSuffixAcrossFormats() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("Puppy.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "png", "x")])], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: "png", nameSuffix: "cutout")
        request.replaceOriginal = true

        let results = await runner.run(request)
        let expected = dir.appending(path: "Puppy.png", directoryHint: .notDirectory)
        #expect(results == [.succeeded(source: source, outputs: [expected], note: .replacedOriginal)])
        #expect(try contents(of: dir) == ["Puppy.png"])
    }

    /// The source's name in the new format is already taken: the result keeps the name it was published under.
    @Test func replaceAcrossFormatsKeepsItsNameWhenTheTargetNameIsTaken() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("Puppy.jpg", in: dir)
        let existing = write("Puppy.png", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "png", "x")])], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: "png", nameSuffix: "cutout")
        request.replaceOriginal = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, .replacedOriginal) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["Puppy-cutout.png"])
        #expect(trash.items == [source])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "data of Puppy.png")
        #expect(try contents(of: dir) == ["Puppy-cutout.png", "Puppy.png"])
    }

    /// A video's audio is another kind of file: the video stays (P273).
    @Test func replaceNeverAppliesAcrossKinds() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("clip.mov", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("mov", "m4a", "x")])], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: "m4a")
        request.replaceOriginal = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["clip.m4a"])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["clip.m4a", "clip.mov"])
    }

    @Test func replaceNeverAppliesToFolders() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(
            engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")], folderItems: ["1.jpg"])],
            trashItem: trash.trash
        )

        let results = await runner.run(compressRequest(source))
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["a-compressed"])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a-compressed", "a.jpg"])
    }

    @Test func replaceNeverAppliesAfterADownloadsFallback() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = try makeTempDir(); defer { try? FileManager.default.removeItem(at: downloads) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let sourceFolder = dir.path
        let runner = makeRunner(
            engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], downloads: downloads,
            writable: { $0.path != sourceFolder }, trashItem: trash.trash
        )

        let results = await runner.run(compressRequest(source))
        guard case .succeeded(_, let outputs, .fellBackToDownloads) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.first?.deletingLastPathComponent().path == downloads.path)
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a.jpg"])
    }

    /// An explicit output folder is not where the source lives, so the result never moves next to it.
    @Test func replaceNeverAppliesInAnotherFolder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let elsewhere = try makeTempDir(); defer { try? FileManager.default.removeItem(at: elsewhere) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: trash.trash)
        var request = compressRequest(source)
        request.outputFolder = elsewhere

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["a-compressed.jpg"])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a.jpg"])
    }

    /// Trashing a link would leave its target where it was, so both files keep their names (P47).
    @Test func replaceNeverAppliesToASymlinkedSource() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let real = write("real.jpg", in: dir)
        let link = dir.appending(path: "link.jpg", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: trash.trash)

        let results = await runner.run(compressRequest(link))
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["link-compressed.jpg"])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["link-compressed.jpg", "link.jpg", "real.jpg"])
    }

    /// A produced name is not a version of the source, so it never takes the source's place (P48).
    @Test func replaceNeverAppliesToAProducedName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("x.pdf", in: dir)
        let runner = makeRunner(engines: [NamedOutputEngine(name: "report.pdf", isFolder: false)], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: nil, operation: "extract")
        request.outputNaming = .fromOutput
        request.replaceOriginal = true

        let results = await runner.run(request)
        guard case .succeeded(_, let outputs, nil) = results.first else { Issue.record("\(results)"); return }
        #expect(outputs.map(\.lastPathComponent) == ["report.pdf"])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["report.pdf", "x.pdf"])
    }

    @Test func aCancelledFileIsNeverReplaced() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(engines: [LateCancellingEngine(from: "jpg", to: "jpg")], trashItem: trash.trash)

        #expect(await runner.run(compressRequest(source)) == [.cancelled(source: source)])
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a.jpg"])
        #expect(try String(contentsOf: source, encoding: .utf8) == "data of a.jpg")
    }
}

private func combineEdge(_ from: FormatID, _ engine: EngineID) -> ConversionEdge {
    ConversionEdge(from: from, to: "pdf", engineID: engine, cost: 10, flags: [], operation: "combine")
}

private func combineRequest(_ inputs: [URL], suffix: String = "merged") -> ConversionRequest {
    var request = ConversionRequest(inputs: inputs, target: "pdf", nameSuffix: suffix, operation: "combine")
    request.combinesInputs = true
    return request
}

/// Fails with a plain error that names no input.
private struct UnnamedFailureCombiningEngine: CombiningEngine {
    struct Failure: Error {}

    let id: EngineID = "unnamed"
    let displayName = "unnamed"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [combineEdge("pdf", id)] }
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw Failure()
    }
    func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw Failure()
    }
}

@Suite struct CombineJobTests {
    @Test func combineMakesOneOutputNamedAfterTheFirstInput() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let b = write("b.pdf", in: dir)
        let a = write("a.pdf", in: dir)
        let runner = makeRunner(engines: [FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")])])

        let results = await runner.run(combineRequest([b, a]))
        let output = dir.appending(path: "b-merged.pdf")
        #expect(results == [
            .succeeded(source: b, outputs: [output], note: nil), .succeeded(source: a, outputs: [output], note: nil),
        ])
        #expect(try String(contentsOf: output, encoding: .utf8) == "data of b.pdfdata of a.pdf")
        #expect(try contents(of: dir) == ["a.pdf", "b-merged.pdf", "b.pdf"])
    }

    @Test func combineReportsEveryInputsStartProgressAndEnd() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = [write("a.pdf", in: dir), write("b.pdf", in: dir)]
        let runner = makeRunner(engines: [FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")])])
        let (events, results) = await runCollecting(runner, combineRequest(inputs))

        for index in 0..<2 {
            #expect(events.contains { if case .fileStarted(index) = $0 { true } else { false } }, "\(events)")
            #expect(events.contains { if case .progress(index, 1.0) = $0 { true } else { false } }, "\(events)")
            #expect(events.contains { if case .fileFinished(index, .succeeded) = $0 { true } else { false } })
        }
        #expect(results.count == 2)
    }

    @Test func combineFailsAsAWholeWhenOneInputFails() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let b = write("b.pdf", in: dir)
        let a = write("a.pdf", in: dir)
        let engine = FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")], failOnStem: "a")

        let results = await makeRunner(engines: [engine]).run(combineRequest([b, a]))
        #expect(results.count == 2)
        #expect(results[0] == .cancelled(source: b))
        guard case .failed(a, .engineFailed(engine: "pdfkit", _)) = results[1] else {
            Issue.record("\(results)"); return
        }
        #expect(try contents(of: dir) == ["a.pdf", "b.pdf"])
    }

    @Test func combineFailsTheFirstInputWhenTheErrorNamesNone() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = [write("a.pdf", in: dir), write("b.pdf", in: dir)]

        let results = await makeRunner(engines: [UnnamedFailureCombiningEngine()]).run(combineRequest(inputs))
        guard case .failed(inputs[0], .engineFailed(engine: "unnamed", _)) = results[0] else {
            Issue.record("\(results)"); return
        }
        #expect(results[1] == .cancelled(source: inputs[1]))
        #expect(try contents(of: dir) == ["a.pdf", "b.pdf"])
    }

    @Test func combineFailsAMissingInputAndCancelsTheRest() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = write("a.pdf", in: dir)
        let gone = dir.appending(path: "gone.pdf")
        let runner = makeRunner(engines: [FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")])])

        let results = await runner.run(combineRequest([a, gone]))
        #expect(results == [.cancelled(source: a), .failed(source: gone, error: .sourceMissing)])
        #expect(try contents(of: dir) == ["a.pdf"])
    }

    @Test func combineNeedsOneCombiningEngine() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = write("a.pdf", in: dir)
        let png = write("b.png", in: dir)
        let twoEngines = makeRunner(engines: [
            FakeCombiningEngine(id: "one", edges: [combineEdge("pdf", "one")]),
            FakeCombiningEngine(id: "two", edges: [combineEdge("png", "two")]),
        ])
        let notCombining = makeRunner(engines: [FakeEngine(id: "plain", edges: [combineEdge("pdf", "plain")])])
        let noRoutes: [FileResult] = [
            .failed(source: pdf, error: .noRoute(from: "pdf", to: "pdf")),
            .failed(source: png, error: .noRoute(from: "png", to: "pdf")),
        ]

        #expect(await twoEngines.run(combineRequest([pdf, png])) == noRoutes)
        #expect(await notCombining.run(combineRequest([pdf])) == [noRoutes[0]])
        #expect(try contents(of: dir) == ["a.pdf", "b.png"])
    }

    @Test func combineCancelledPublishesNothing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = [write("a.pdf", in: dir), write("b.pdf", in: dir)]
        let runner = makeRunner(engines: [
            FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")], delay: .seconds(5)),
        ])
        let started = ContinuousClock.now
        let task = Task { await runner.run(combineRequest(inputs)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        #expect(await task.value == inputs.map { .cancelled(source: $0) })
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(try contents(of: dir) == ["a.pdf", "b.pdf"])
    }

    /// A combine is never a version of one source: it replaces nothing and is never refused for its size.
    @Test func combineNeverReplacesAndIgnoresOnlyIfSmaller() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let inputs = [write("a.pdf", in: dir), write("b.pdf", in: dir)]
        let runner = makeRunner(
            engines: [FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")])], trashItem: trash.trash
        )
        var request = combineRequest(inputs)
        request.replaceOriginal = true
        request.onlyIfSmaller = true

        let output = dir.appending(path: "a-merged.pdf")
        #expect(await runner.run(request) == inputs.map { .succeeded(source: $0, outputs: [output], note: nil) })
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a-merged.pdf", "a.pdf", "b.pdf"])
    }

    @Test func aPresetCarriesCombinesInputsIntoTheRequest() {
        let preset = Preset(id: "m", name: "M", target: "pdf", operation: "combine", combinesInputs: true)
        #expect(ConversionRequest.from(preset, inputs: []).combinesInputs)
        #expect(!ConversionRequest(inputs: [], target: "pdf").combinesInputs)
    }
}

// MARK: - Quarantine (P58)

private let downloadedMark = Data("0081;65f00000;Safari;F1A2B3C4-0000-4000-8000-000000000000".utf8)

/// Marks a temporary test file as downloaded.
private func quarantine(_ url: URL, _ value: Data = downloadedMark) {
    let result = value.withUnsafeBytes {
        setxattr(url.path, "com.apple.quarantine", $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
    }
    precondition(result == 0, "setxattr failed on \(url.path)")
}

private func quarantineMark(of url: URL) -> Data? {
    let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard getxattr(url.path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
    return Data(bytes)
}

@Suite struct QuarantineTests {
    @Test func theOutputOfAQuarantinedSourceCarriesItsMark() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("a.png", in: dir)
        quarantine(source)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])

        let results = await runner.run(ConversionRequest(inputs: [source], target: "jpg"))

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        #expect(quarantineMark(of: output) == downloadedMark)
        #expect(quarantineMark(of: source) == downloadedMark)
    }

    @Test func anUnquarantinedSourceGivesAnUnquarantinedOutput() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("a.png", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("png", "jpg", "x")])])

        let results = await runner.run(ConversionRequest(inputs: [source], target: "jpg"))

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        #expect(quarantineMark(of: output) == nil)
    }

    @Test func aFolderOutputIsMarkedThroughout() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = write("x.zip", in: dir)
        quarantine(source)
        var request = ConversionRequest(inputs: [source], target: nil, operation: "extract")
        request.outputNaming = .fromOutput

        let results = await makeRunner(engines: [NamedOutputEngine(name: "Pics", isFolder: true)]).run(request)

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        #expect(quarantineMark(of: output) == downloadedMark)
        #expect(quarantineMark(of: output.appending(path: "1.jpg")) == downloadedMark)
    }

    @Test func itemsInsideKeepTheirOwnMarkAndLinksAreNotFollowed() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "out", directoryHint: .isDirectory)
        let sub = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let plain = write("plain.txt", in: sub)
        let marked = write("marked.txt", in: folder)
        let ownMark = Data("0083;65f00001;Mail;".utf8)
        quarantine(marked, ownMark)
        let outsideTarget = write("target.txt", in: dir)
        let link = folder.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)

        Quarantine.apply(downloadedMark, to: folder)

        #expect(quarantineMark(of: folder) == downloadedMark)
        #expect(quarantineMark(of: plain) == downloadedMark)
        #expect(quarantineMark(of: marked) == ownMark)
        #expect(quarantineMark(of: outsideTarget) == nil)
    }

    @Test func aCombineTakesTheFirstQuarantinedInputsMark() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let b = write("b.pdf", in: dir)
        let a = write("a.pdf", in: dir)
        let c = write("c.pdf", in: dir)
        quarantine(a)
        quarantine(c, Data("0083;65f00001;Mail;".utf8))
        let runner = makeRunner(engines: [FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")])])

        let results = await runner.run(combineRequest([b, a, c]))

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        #expect(quarantineMark(of: output) == downloadedMark)
    }
}

// MARK: - The output mark (§3.4 rule 10)

/// Stages its output as a hard link to its input (a user `CommandEngine` running `ln {input} {output}`): the staged
/// item shares the source's inode, so marking it would mark the source.
private struct HardLinkingEngine: CombiningEngine {
    let id: EngineID = "ln"
    let displayName = "ln"
    let maxConcurrentJobs = 1

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [edge("png", "jpg", id), combineEdge("pdf", id)] }
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.linkItem(at: step.input, to: step.suggestedOutput)
        return step.suggestedOutput
    }
    func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let output = step.stagingDirectory.appending(path: "combined.pdf")
        try FileManager.default.linkItem(at: step.inputs[0], to: output)
        return output
    }
}

/// Every extended attribute of `url`, names and values, but `com.apple.macl`: macOS adds that one itself when a
/// process links the file.
private func attributes(of url: URL) -> [String: Data] {
    let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: size)
    _ = listxattr(url.path, &names, size, XATTR_NOFOLLOW)
    var result: [String: Data] = [:]
    for name in names.split(separator: 0).map({ String(decoding: $0.map(UInt8.init), as: UTF8.self) })
    where name != "com.apple.macl" {
        let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        var bytes = [UInt8](repeating: 0, count: max(length, 0))
        _ = getxattr(url.path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        result[name] = Data(bytes)
    }
    return result
}

@Suite struct OutputMarkJobTests {
    @Test func everyPublishedOutputCarriesTheMark() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = write("a.png", in: dir)
        let jpg = write("b.jpg", in: dir)
        let pdfs = [write("c.pdf", in: dir), write("d.pdf", in: dir)]
        let runner = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("png", "jpg", "x")]),
            FakeEngine(id: "pages", edges: [
                ConversionEdge(from: "jpg", to: "jpg", engineID: "pages", cost: 10, flags: [], operation: "split"),
            ], folderItems: ["1.jpg", "2.jpg"]),
            FakeCombiningEngine(id: "pdfkit", edges: [combineEdge("pdf", "pdfkit")]),
        ])

        let converted = await runner.run(ConversionRequest(inputs: [png], target: "jpg"))
        let split = await runner.run(ConversionRequest(inputs: [jpg], target: nil, nameSuffix: "pages", operation: "split"))
        let combined = await runner.run(combineRequest(pdfs))

        var outputs: [URL] = []
        for case .succeeded(_, let produced, _) in converted + split + combined { outputs += produced }
        #expect(outputs.map(\.lastPathComponent) == ["a.jpg", "b-pages", "c-merged.pdf", "c-merged.pdf"])
        for output in outputs { #expect(OutputMark.isMarked(output), "\(output.lastPathComponent)") }
        // Only the folder itself: what is inside is not an output of its own.
        #expect(!OutputMark.isMarked(dir.appending(path: "b-pages/1.jpg")))
        for source in [png, jpg] + pdfs { #expect(!OutputMark.isMarked(source), "\(source.lastPathComponent)") }
    }

    /// A staged hard link to a source is refused before anything writes to its inode: the source keeps no mark.
    @Test func aHardLinkToTheSourceIsAConverterFaultAndTheSourceStaysUnmarked() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = write("a.png", in: dir)
        let pdfs = [write("c.pdf", in: dir), write("d.pdf", in: dir)]
        let sources = [png] + pdfs
        let before = try sources.map { (try Data(contentsOf: $0), attributes(of: $0)) }
        let runner = makeRunner(engines: [HardLinkingEngine()])

        let converted = await runner.run(ConversionRequest(inputs: [png], target: "jpg"))
        let combined = await runner.run(combineRequest(pdfs))

        func isFault(_ result: FileResult?, _ source: URL) -> Bool {
            if case .failed(source, .converterFault("ln", _)) = result { true } else { false }
        }
        #expect(isFault(converted.first, png), "\(converted)")
        #expect(isFault(combined.first, pdfs[0]), "\(combined)")
        #expect(try contents(of: dir) == ["a.png", "c.pdf", "d.pdf"])
        for (source, (data, xattrs)) in zip(sources, before) {
            #expect(!OutputMark.isMarked(source), "\(source.lastPathComponent)")
            #expect(try Data(contentsOf: source) == data)
            #expect(attributes(of: source) == xattrs)
        }
    }

    @Test func theMarkSurvivesReplaceOriginal() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let trashFolder = try makeTempDir(); defer { try? FileManager.default.removeItem(at: trashFolder) }
        let trash = TestTrash(folder: trashFolder)
        let source = write("a.jpg", in: dir)
        let runner = makeRunner(engines: [FakeEngine(id: "x", edges: [edge("jpg", "jpg", "x")])], trashItem: trash.trash)
        var request = ConversionRequest(inputs: [source], target: nil, nameSuffix: "compressed")
        request.replaceOriginal = true

        let results = await runner.run(request)

        #expect(results == [.succeeded(source: source, outputs: [source], note: .replacedOriginal)])
        #expect(OutputMark.isMarked(source))
        #expect(!OutputMark.isMarked(trashFolder.appending(path: "a.jpg")))
    }
}

/// A route through an engine this Mac can't run (a CLI request, a stale wheel) fails the file with its reason.
@Suite struct UnsupportedEngineJobTests {
    private let reason = "Needs macOS 26."

    @Test func aConversionThroughAnUnsupportedEngineFailsWithItsReason() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [
            FakeEngine(id: "x", edges: [edge("png", "jpg", "x")]),
            FakeEngine(id: "u", edges: [edge("jpg", "txt", "u")], unsupportedReason: reason),
        ])
        let res = await r.run(.init(inputs: [src], target: "txt"))
        #expect(res == [.failed(source: src, error: .engineUnsupported(engine: "u", reason: reason))])
        #expect(try contents(of: d) == ["a.png"])
    }

    @Test func aToolOnAnUnsupportedEngineFailsWithItsReason() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.m4a", in: d)
        let tool = ConversionEdge(from: "m4a", to: "txt", engineID: "u", cost: 10, flags: [], operation: "transcribe")
        let r = makeRunner(engines: [FakeEngine(id: "u", edges: [tool], unsupportedReason: reason)])
        let res = await r.run(.init(inputs: [src], target: "txt", operation: "transcribe"))
        #expect(res == [.failed(source: src, error: .engineUnsupported(engine: "u", reason: reason))])
        #expect(ConversionError.engineUnsupported(engine: "u", reason: reason).description == "Needs macOS 26.")
    }

    @Test func aRouteThroughAMissingEngineStillHasNoRoute() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let src = write("a.png", in: d)
        let r = makeRunner(engines: [
            FakeEngine(id: "m", edges: [edge("png", "webp", "m")], available: false),
            FakeEngine(id: "u", edges: [edge("png", "txt", "u")], unsupportedReason: reason),
        ])
        let res = await r.run(.init(inputs: [src], target: "webp"))
        #expect(res == [.failed(source: src, error: .noRoute(from: "png", to: "webp"))])
    }
}
