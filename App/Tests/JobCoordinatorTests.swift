import AppKit
import Foundation
import ImageIO
import PomeloCore
import PomeloEngines
import PomeloUIModel
import Testing
import UniformTypeIdentifiers
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Writes a small solid-colour PNG.
private func writePNG(to url: URL) throws {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

/// Records the file progresses a coordinator publishes, instead of showing them in Finder (P16).
@MainActor
final class RecordingProgressPublisher: FileProgressPublishing {
    private(set) var published: [Progress] = []
    private(set) var unpublished: [Progress] = []

    /// Published and not yet unpublished.
    var live: [Progress] { published.filter { progress in !unpublished.contains { $0 === progress } } }

    func publish(_ progress: Progress) { published.append(progress) }
    func unpublish(_ progress: Progress) { unpublished.append(progress) }
}

/// A coordinator over the real engines, with sounds on and recorded instead of played.
@MainActor
private func makeCoordinator(
    pasteboard: NSPasteboard = NSPasteboard.withUniqueName(),
    publisher: RecordingProgressPublisher = RecordingProgressPublisher(),
    destinations: DestinationResolver = .nextToSource, clock: TimerClock = .live,
    sounds: @escaping @MainActor (NSSound.Name) -> Void = { _ in }
) async -> JobCoordinator {
    let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
    let settings = SettingsStore(defaults: EphemeralDefaults())
    settings.settings.soundsEnabled = true
    let coordinator = JobCoordinator(
        registry: registry, settings: settings, destinations: destinations, pasteboard: pasteboard, playSound: sounds,
        progressPublisher: publisher, trashItem: { _ in }, clock: clock
    )
    let available = await registry.planner()
    let all = await registry.planner(includingMissing: true)
    coordinator.contentBuilder = WheelContentBuilder(
        formats: .builtIn, available: available, all: all, installHints: [:], tools: Preset.builtIns
    )
    return coordinator
}

/// Lets a test decide when each gated conversion finishes. A cancelled wait ends at once, like a real engine's.
actor Gates {
    private var opened: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// The staging folder of each gated conversion, by stem.
    private(set) var staging: [String: URL] = [:]

    func open(_ name: String) {
        opened.insert(name)
        for continuation in waiting.removeValue(forKey: name) ?? [] { continuation.resume() }
    }

    func wait(for name: String) async {
        guard !opened.contains(name) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiting[name, default: []].append(continuation) }
            }
        } onCancel: {
            Task { await self.release(name) }
        }
    }

    func record(staging url: URL, for name: String) {
        staging[name] = url
    }

    private func release(_ name: String) {
        for continuation in waiting.removeValue(forKey: name) ?? [] { continuation.resume() }
    }
}

/// Converts PNG (or `from`) to JPG by copying. A file whose stem starts with `slow` waits for the gate of that stem
/// (after reporting half its work when the stem contains `half`); a stem containing `fail` then fails.
struct GatedEngine: ConversionEngine {
    struct Failure: LocalizedError { var errorDescription: String? { "The gated conversion failed." } }

    let gates: Gates
    var maxConcurrentJobs = 8
    var from: FormatID = "png"
    var id: EngineID { "gated" }
    var displayName: String { "Gated" }

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: from, to: "jpg", engineID: "gated", cost: 1, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let stem = OutputNamer.stem(of: step.input)
        await gates.record(staging: step.stagingDirectory, for: stem)
        if stem.contains("half") { progress(0.5) }
        if stem.hasPrefix("slow") { await gates.wait(for: stem) }
        try Task.checkCancellation()
        if stem.contains("fail") { throw Failure() }
        try Data(contentsOf: step.input).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

/// The first step of a two-step route: PNG to TIFF by copying, at once.
private struct CopyEngine: ConversionEngine {
    var id: EngineID { "copy" }
    var displayName: String { "Copy" }
    var maxConcurrentJobs: Int { 8 }

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] { [ConversionEdge(from: "png", to: "tiff", engineID: "copy", cost: 1, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Data(contentsOf: step.input).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

/// A coordinator over `engines` alone, with sounds on and recorded instead of played.
@MainActor
func makeCoordinator(
    engines: [any ConversionEngine], publisher: RecordingProgressPublisher = RecordingProgressPublisher(),
    progressDelay: Duration = FileProgressIndicator.standardDelay, destinations: DestinationResolver = .nextToSource,
    noteStay: Duration = PillTiming.noteStay, clock: TimerClock = .live,
    sounds: @escaping @MainActor (NSSound.Name) -> Void = { _ in }
) -> JobCoordinator {
    let settings = SettingsStore(defaults: EphemeralDefaults())
    settings.settings.soundsEnabled = true
    return JobCoordinator(
        registry: EngineRegistry(engines: engines, priority: engines.map(\.id)), settings: settings,
        destinations: destinations, pasteboard: NSPasteboard.withUniqueName(), playSound: sounds,
        progressPublisher: publisher, trashItem: { _ in }, progressDelay: progressDelay, noteStay: noteStay,
        clock: clock
    )
}

/// A coordinator over the gated engine alone.
@MainActor
private func makeGatedCoordinator(
    gates: Gates, publisher: RecordingProgressPublisher = RecordingProgressPublisher(),
    progressDelay: Duration = FileProgressIndicator.standardDelay, clock: TimerClock = .live,
    sounds: @escaping @MainActor (NSSound.Name) -> Void = { _ in }
) -> JobCoordinator {
    makeCoordinator(engines: [GatedEngine(gates: gates)], publisher: publisher, progressDelay: progressDelay,
                    clock: clock, sounds: sounds)
}

/// True once no process with `pid` runs `command` any more. Checking the command line too means a pid the
/// system has since reused never reads as still running.
private func processIsGone(_ pid: pid_t, running command: String) async -> Bool {
    guard kill(pid, 0) == 0 else { return true }
    let ps = try? await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/ps"),
                                            arguments: ["-p", "\(pid)", "-o", "command="])
    return !(ps?.stdout.contains(command) ?? false)
}

/// A plugin engine whose process sleeps for 30 s, after writing its pid and its staging folder into `dir`.
private func sleeperEngine(in dir: URL) -> CommandEngine {
    // `exec` makes the shell's pid the sleeping process's; $1 is the output, inside the step's staging folder.
    let script = "echo $$ > '\(dir.appending(path: "pid").path)'; "
        + "dirname \"$(dirname \"$1\")\" > '\(dir.appending(path: "staging").path)'; exec /bin/sleep 30"
    let manifest = PluginManifest(
        id: "sleeper", displayName: "Sleeper",
        executable: .init(names: ["/bin/sh"], searchPaths: [], versionArguments: nil), install: .init(),
        edges: [.init(from: ["png"], to: ["jpg"], arguments: ["-c", script, "{input}", "{output}"])]
    )
    return CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: dir))
}

private func readLine(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Polls `condition` every 20 ms until it holds or `timeout` passes; returns whether it held.
@MainActor
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

extension JobCoordinator {
    /// A job no wheel holds, as a file tool's is: its outcome settles in `jobs` at once.
    @discardableResult
    func perform(_ slice: WheelSlice, on files: [URL]) -> Task<JobOutcome, Never> {
        perform(slice, on: files, anchor: .zero, isHeld: false).outcome
    }
}

func jpgSlice() -> WheelSlice {
    WheelSlice(id: "convert.jpg", title: "JPG", symbol: "photo", kind: .convert("jpg"))
}

extension JobOutcome {
    var summary: ResultSummary? {
        switch self {
        case .succeeded: nil
        case .noted(let summary), .failed(let summary): summary
        }
    }
}

/// The names of a result's outputs, nil for a failure or a cancel.
private func outputNames(_ result: FileResult) -> [String]? {
    if case .succeeded(_, let outputs, _) = result { outputs.map(\.lastPathComponent) } else { nil }
}

private func failureTitle(_ outcome: JobOutcome) -> String? {
    if case .failed(let summary) = outcome { summary.title } else { nil }
}

/// Counts the sets of its additional description.
private final class DescriptionCountingProgress: Progress, @unchecked Sendable {
    private(set) var descriptionSets = 0

    override var localizedAdditionalDescription: String! {
        get { super.localizedAdditionalDescription }
        set {
            descriptionSets += 1
            super.localizedAdditionalDescription = newValue
        }
    }
}

@MainActor
@Suite struct JobCoordinatorTests {
    @Test func convertingAPNGPublishesAJPGNextToItAndSucceeds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)
        var sounds: [NSSound.Name] = []
        let coordinator = await makeCoordinator { sounds.append($0) }

        let outcome = await coordinator.perform(jpgSlice(), on: [png]).value

        #expect(outcome == .succeeded)
        #expect(sounds == ["Glass"])
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "a.jpg").path))
        #expect(FileManager.default.fileExists(atPath: png.path))
    }

    @Test func aConvertSliceSkipsFilesAlreadyInTheTargetFormat() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)
        let jpg = dir.appending(path: "b.jpg")
        try Data("not converted".utf8).write(to: jpg)
        let coordinator = await makeCoordinator()

        let outcome = await coordinator.perform(jpgSlice(), on: [png, jpg]).value

        #expect(outcome == .succeeded)
        #expect(try String(contentsOf: jpg, encoding: .utf8) == "not converted")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "a.jpg").path))
    }

    @Test func nothingToConvertSucceedsSilently() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appending(path: "b.jpg")
        try Data("x".utf8).write(to: jpg)
        var sounds: [NSSound.Name] = []
        let coordinator = await makeCoordinator { sounds.append($0) }

        let outcome = await coordinator.perform(jpgSlice(), on: [jpg]).value

        #expect(outcome == .succeeded)
        #expect(sounds.isEmpty)
    }

    @Test func aCorruptFileFailsAloneAndTheOutcomeSaysWhich() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "a.png")
        try writePNG(to: good)
        let bad = dir.appending(path: "bad.png")
        try Data("x\n".utf8).write(to: bad)
        var sounds: [NSSound.Name] = []
        let coordinator = await makeCoordinator { sounds.append($0) }

        let outcome = await coordinator.perform(jpgSlice(), on: [good, bad]).value

        guard case .failed(let summary) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(summary.title == "1 of 2 converted")
        // A short reason, never the engine's raw message (P23).
        #expect(summary.detail == "bad.png may be damaged")
        #expect(sounds == ["Basso"])
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "a.jpg").path))
    }

    @Test func anUnknownToolFails() async {
        let coordinator = await makeCoordinator()
        let slice = WheelSlice(id: "preset.nope", title: "Nope", symbol: "x", kind: .preset(id: "nope"))
        let outcome = await coordinator.perform(slice, on: [URL(fileURLWithPath: "/tmp/a.png")]).value
        #expect(outcome == .failed(ResultSummary(title: "Couldn't run Nope", detail: "Unknown tool", isFailure: true)))
    }

    @Test func aCopyActionFillsThePasteboardWithoutASound() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var sounds: [NSSound.Name] = []
        let coordinator = await makeCoordinator(pasteboard: pasteboard) { sounds.append($0) }
        let slice = WheelSlice(id: "action.copyPaths", title: "Copy Paths", symbol: "x", kind: .action(.copyPaths))

        let outcome = await coordinator.perform(slice, on: [URL(fileURLWithPath: "/tmp/a.txt"),
                                                             URL(fileURLWithPath: "/tmp/b.txt")]).value

        #expect(outcome == .succeeded)
        #expect(pasteboard.string(forType: .string) == "/tmp/a.txt\n/tmp/b.txt")
        #expect(sounds.isEmpty)
    }

    /// A job is listed while it runs and removed when it ends.
    @Test func aRunningJobIsListedUntilItEnds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "slow.png")
        try writePNG(to: png)
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)

        let job = coordinator.perform(jpgSlice(), on: [png])
        #expect(coordinator.jobs.map(\.verb) == ["Converting"])
        #expect(coordinator.jobs.first?.files.map(\.name) == ["slow.png"])
        #expect(coordinator.jobs.first?.fraction == nil)
        await gates.open("slow")
        _ = await job.value
        #expect(coordinator.jobs.isEmpty)
    }

    // MARK: Results for the Shelf (S18, S37)

    /// Each file's result reaches `onResult` as it finishes, in the order they finish.
    @Test func onResultPerFileForAConversion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = dir.appending(path: "slow-a.png")
        let quick = dir.appending(path: "b.png")
        for file in [slow, quick] { try Data("png".utf8).write(to: file) }
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)
        var results: [FileResult] = []

        let job = coordinator.perform(jpgSlice(), on: [slow, quick], anchor: .zero, isHeld: false) {
            results.append($0)
        }
        #expect(await eventually { results.count == 1 })
        #expect(results.map(\.source) == [quick])
        await gates.open("slow-a")
        #expect(await job.outcome.value == .succeeded)

        #expect(results.map(\.source) == [quick, slow])
        #expect(results.map(outputNames) == [["b.jpg"], ["slow-a.jpg"]])
    }

    /// The same job with and without a callback: the outcome, the pill and the sounds are the same.
    @Test func withoutOnResultNothingChanges() async throws {
        func run(reporting: Bool) async throws -> (JobOutcome, [PillFile], PillPhase?, [NSSound.Name], Int) {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let files = [dir.appending(path: "a.png"), dir.appending(path: "fail-b.png")]
            for file in files { try Data("png".utf8).write(to: file) }
            var sounds: [NSSound.Name] = []
            let coordinator = makeGatedCoordinator(gates: Gates()) { sounds.append($0) }
            var results: [FileResult] = []
            let job = reporting
                ? coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false,
                                      onResult: { results.append($0) })
                : coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
            let outcome = await job.outcome.value
            let pill = coordinator.jobs.first
            return (outcome, pill?.files ?? [], pill?.phase, sounds, results.count)
        }
        let with = try await run(reporting: true)
        let without = try await run(reporting: false)
        #expect(failureTitle(with.0) == "1 of 2 converted")
        #expect(with.0 == without.0)
        #expect(with.1 == without.1)
        #expect(with.2 == without.2)
        #expect(with.3 == ["Basso"] && without.3 == ["Basso"])
        // Both files reported, the failure included: only the Shelf decides what a failure changes (nothing).
        #expect(with.4 == 2 && without.4 == 0)
    }

    @Test func onResultForMakeZip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [dir.appending(path: "a.txt"), dir.appending(path: "b.txt")]
        for file in files { try Data("hello".utf8).write(to: file) }
        let coordinator = await makeCoordinator()
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))
        var results: [FileResult] = []

        let outcome = await coordinator.perform(slice, on: files, anchor: .zero, isHeld: false) {
            results.append($0)
        }.outcome.value

        #expect(outcome == .succeeded)
        // Every source, mapped to the one zip.
        #expect(results.map(\.source) == files)
        let zips = results.compactMap(outputNames)
        #expect(zips.count == 2 && zips[0] == zips[1] && zips[0].count == 1)
        #expect(zips.first?.first?.hasSuffix(".zip") == true)
        let zip = try #require(zips.first?.first)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: zip).path))
    }

    @Test func noResultForCopyPaths() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = [dir.appending(path: "a.txt"), dir.appending(path: "b.txt")]
        for file in files { try Data("hello".utf8).write(to: file) }
        let coordinator = await makeCoordinator(pasteboard: pasteboard)
        var results: [FileResult] = []
        for kind in [FileActionKind.copyPaths, .copyFiles] {
            let slice = WheelSlice(id: "action.\(kind)", title: "Copy", symbol: "x", kind: .action(kind))
            let outcome = await coordinator.perform(slice, on: files, anchor: .zero, isHeld: false) {
                results.append($0)
            }.outcome.value
            #expect(outcome == .succeeded)
        }
        #expect(results.isEmpty)
    }
}

/// Jobs never wait for each other, and each one's outcome and sound belong to it (P19, kept by P23).
@MainActor
@Suite struct OverlappingJobsTests {
    private func pngs(_ names: String...) throws -> (dir: URL, files: [URL]) {
        let dir = try makeTempDir()
        let files = try names.map { name in
            let url = dir.appending(path: "\(name).png")
            try writePNG(to: url)
            return url
        }
        return (dir, files)
    }

    @Test func anOlderJobKeepsItsOwnOutcomeAfterANewerOneFinishes() async throws {
        let (dir, files) = try pngs("slow-fail", "fast")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: gates) { sounds.append($0) }

        let older = coordinator.perform(jpgSlice(), on: [files[0]])
        let newer = coordinator.perform(jpgSlice(), on: [files[1]])
        #expect(coordinator.jobs.count == 2)
        #expect(await newer.value == .succeeded)
        #expect(sounds == ["Glass"])
        await gates.open("slow-fail")

        #expect(failureTitle(await older.value) == "Couldn't convert slow-fail.png")
        // A late failure still sounds (and is logged).
        #expect(sounds == ["Glass", "Basso"])
        // Nothing held the older job, so its failure stays as a red pill; the newer one's success left none.
        let summary = try #require(await older.value.summary)
        #expect(coordinator.jobs.map(\.phase) == [.failed(summary)])
    }
}

/// Long jobs show each source's progress in Finder, and Finder's cancel stops that file (P24). The publisher is a
/// recorder, so nothing shows in the real Finder (P16).
@MainActor
@Suite struct FinderProgressTests {
    private func pngs(_ names: String...) throws -> (dir: URL, files: [URL]) {
        let dir = try makeTempDir()
        let files = try names.map { name in
            let url = dir.appending(path: "\(name).png")
            try writePNG(to: url)
            return url
        }
        return (dir, files)
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// True once the gated conversion of `stem` has removed its staging folder.
    private func stagingIsRemoved(_ stem: String, gates: Gates) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let staging = await gates.staging[stem], !FileManager.default.fileExists(atPath: staging.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Lets the delay of the `count` files now running pass on the virtual clock (no real wait).
    private func passTheDelay(_ clock: ManualClock, of count: Int = 1,
                              _ delay: Duration = FileProgressIndicator.standardDelay) async {
        #expect(await eventually { clock.waiting >= count })
        await clock.advance(by: delay)
    }

    @Test func aJobShorterThanTheDelayNeverPublishesAProgress() async throws {
        let (dir, files) = try pngs("fast", "slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, progressDelay: .seconds(2),
                                               clock: clock.timerClock)

        #expect(await coordinator.perform(jpgSlice(), on: [files[0]]).value == .succeeded)
        let slow = coordinator.perform(jpgSlice(), on: [files[1]])
        #expect(await eventually { clock.waiting >= 1 })
        await clock.advance(by: .milliseconds(200))
        await gates.open("slow")
        #expect(await slow.value == .succeeded)
        // Well past the delay: the pending publishes were called off.
        await clock.advance(by: .seconds(3))
        #expect(publisher.published.isEmpty)
    }

    /// A file queued behind its engine's limit isn't timed until it starts, so a quick one never flashes.
    @Test func aQueuedQuickFileNeverPublishesAProgress() async throws {
        let (dir, files) = try pngs("slow", "fast")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeCoordinator(
            engines: [GatedEngine(gates: gates, maxConcurrentJobs: 1)], publisher: publisher, progressDelay: .seconds(2),
            clock: clock.timerClock
        )

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock, .seconds(2))
        #expect(await eventually { !publisher.published.isEmpty })
        await gates.open("slow")
        #expect(await job.value == .succeeded)
        await clock.advance(by: .seconds(3))
        #expect(publisher.published.map(\.fileURL) == [files[0]])
    }

    @Test func aLongJobPublishesItsSourcesFileProgressAfterHalfASecond() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock)

        let job = coordinator.perform(jpgSlice(), on: files)
        #expect(await eventually { clock.waiting == 1 })
        await clock.advance(by: .milliseconds(499))
        #expect(publisher.published.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { !publisher.published.isEmpty })

        let progress = try #require(publisher.published.first)
        #expect(publisher.published.count == 1)
        // On the source: the output doesn't exist until it is published.
        #expect(progress.fileURL == files[0])
        #expect(progress.kind == .file)
        #expect(progress.fileOperationKind == .copying)
        #expect(progress.isCancellable)
        #expect(progress.isIndeterminate)
        // The verb alone (P51): Finder draws it on the file.
        #expect(progress.localizedDescription == "Converting\u{2026}")

        await gates.open("slow")
        #expect(await job.value == .succeeded)
        #expect(publisher.live.isEmpty)
        #expect(publisher.unpublished.count == 1)
    }

    @Test func theProgressFollowsTheFilesFraction() async throws {
        let (dir, files) = try pngs("slow-half")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock)

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock)
        #expect(await eventually { !publisher.published.isEmpty })
        let progress = try #require(publisher.published.first)
        #expect(!progress.isIndeterminate)
        #expect(abs(progress.fractionCompleted - 0.5) < 0.01)

        await gates.open("slow-half")
        _ = await job.value
        #expect(publisher.live.isEmpty)
    }

    @Test func aFailedFileUnpublishesItsProgress() async throws {
        let (dir, files) = try pngs("slow-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock)

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock)
        #expect(await eventually { publisher.published.count == 1 })
        await gates.open("slow-fail")
        #expect(failureTitle(await job.value) == "Couldn't convert slow-fail.png")
        #expect(publisher.live.isEmpty)
    }

    @Test func cancellingFromFinderStopsThatFileAloneAndLeavesNothingOfIt() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock) {
            sounds.append($0)
        }

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock, of: 2)
        #expect(await eventually { publisher.published.count == 2 })
        let first = try #require(publisher.published.first { $0.fileURL == files[0] })
        first.cancel()   // what Finder's cancel button does

        #expect(await eventually { publisher.live.map(\.fileURL) == [files[1]] })
        #expect(await stagingIsRemoved("slow-a", gates: gates))
        await gates.open("slow-b")
        #expect(await job.value == .succeeded)
        #expect(sounds == ["Glass"])
        #expect(publisher.live.isEmpty)
        // No output for the cancelled file; the sources are untouched.
        #expect(try contents(of: dir) == ["slow-a.png", "slow-b.jpg", "slow-b.png"])
        #expect(try Data(contentsOf: files[0]) == Data(contentsOf: files[1]))
    }

    @Test func cancellingAOneFileJobEndsItSilentlyWithNoOutput() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock) {
            sounds.append($0)
        }

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock)
        #expect(await eventually { publisher.published.count == 1 })
        publisher.published[0].cancel()

        // A user cancel is not a failure: no Basso, and no Glass either.
        #expect(await job.value == .succeeded)
        #expect(sounds.isEmpty)
        #expect(publisher.live.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        #expect(await stagingIsRemoved("slow", gates: gates))
        #expect(try contents(of: dir) == ["slow.png"])
    }

    /// The real path to a plugin's process: Finder's cancel sends SIGTERM to the tool's process group.
    @Test func cancellingStopsTheEnginesProcess() async throws {
        let (dir, files) = try pngs("long")
        defer { try? FileManager.default.removeItem(at: dir) }
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeCoordinator(engines: [sleeperEngine(in: dir)], publisher: publisher, clock: clock.timerClock)

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock)
        let stagingFile = dir.appending(path: "staging")
        #expect(await eventually { !publisher.published.isEmpty && FileManager.default.fileExists(atPath: stagingFile.path) })
        let pid = try #require(pid_t(try readLine(dir.appending(path: "pid"))))
        #expect(!(await processIsGone(pid, running: "sleep 30")))
        publisher.published[0].cancel()

        // The job ends only once the engine has stopped: its process is gone and its staging removed.
        #expect(await job.value == .succeeded)
        #expect(await processIsGone(pid, running: "sleep 30"))
        #expect(!FileManager.default.fileExists(atPath: try readLine(stagingFile)))
        #expect(try contents(of: dir) == ["long.png", "pid", "staging"])
    }

    /// A zip runs as long as `ditto` takes (8 GB sparse files take several seconds); a cancel from any source stops
    /// it, and every source's indicator goes at once, not when `ditto` has exited.
    @Test func aLongZipShowsItsSourcesAndCancellingOneStopsIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bigs = try ["big-a.bin", "big-b.bin"].map { name in
            let big = dir.appending(path: name)
            #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: 8 << 30)
            try handle.close()
            return big
        }
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let clock = ManualClock()
        let coordinator = await makeCoordinator(publisher: publisher, clock: clock.timerClock) { sounds.append($0) }
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))

        let job = coordinator.perform(slice, on: bigs)
        await passTheDelay(clock, of: 2)
        #expect(await eventually { publisher.published.count == 2 })
        let progress = try #require(publisher.published.first { $0.fileURL == bigs[0] })
        #expect(progress.isIndeterminate)
        let cancelled = ContinuousClock.now
        progress.cancel()

        #expect(await eventually(within: .milliseconds(500)) { publisher.live.isEmpty })
        #expect(await job.value == .succeeded)
        // Awaiting the job awaits `ditto`'s exit, so a quick end means it was stopped, not left to finish.
        #expect(ContinuousClock.now - cancelled < .seconds(4))
        #expect(sounds.isEmpty)
        #expect(try contents(of: dir) == ["big-a.bin", "big-b.bin"])
    }

    @Test func endingAllProgressUnpublishesWhatIsUp() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let clock = ManualClock()
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, clock: clock.timerClock)

        let job = coordinator.perform(jpgSlice(), on: files)
        await passTheDelay(clock)
        #expect(await eventually { publisher.published.count == 1 })
        coordinator.endAllProgress()   // what quitting does
        #expect(publisher.live.isEmpty)

        await gates.open("slow")
        _ = await job.value
        #expect(publisher.unpublished.count == 1)
    }

    /// Abstract units, and an explicit additional description: Finder would read units as bytes and describe them
    /// as the output's size.
    @Test func anIndicatorCountsPerMilleAndStaysIndeterminateAtZero() throws {
        let indicator = FileProgressIndicator(
            file: URL(fileURLWithPath: "/tmp/a.mov"), description: "x", publisher: RecordingProgressPublisher(),
            onCancel: {}
        )
        defer { indicator.end() }

        indicator.update(fraction: 0)
        #expect(indicator.progress.isIndeterminate)
        #expect(indicator.progress.localizedAdditionalDescription == "")
        indicator.update(fraction: 0.25)
        #expect(indicator.progress.totalUnitCount == 1000)
        #expect(indicator.progress.completedUnitCount == 250)
        #expect(indicator.progress.localizedAdditionalDescription == 0.25.formatted(.percent.precision(.fractionLength(0))))
    }

    /// A cancel that lands as the file finishes: whichever wins, the outcome and the sound match what is on disk
    /// (an output means it succeeded, with Glass; none means it was cancelled, silently). Repeated, since the
    /// order is up to the scheduler.
    @Test func aCancelAsTheFileFinishesAgreesWithWhatIsOnDisk() async throws {
        for _ in 0..<5 {
            let (dir, files) = try pngs("slow")
            defer { try? FileManager.default.removeItem(at: dir) }
            let gates = Gates()
            let publisher = RecordingProgressPublisher()
            var sounds: [NSSound.Name] = []
            let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, progressDelay: .milliseconds(20)) {
                sounds.append($0)
            }

            let job = coordinator.perform(jpgSlice(), on: files)
            #expect(await eventually { publisher.published.count == 1 })
            async let opened: Void = gates.open("slow")
            publisher.published[0].cancel()
            await opened

            #expect(await job.value == .succeeded)
            let published = FileManager.default.fileExists(atPath: dir.appending(path: "slow.jpg").path)
            #expect(sounds == (published ? ["Glass"] : []), "output: \(published)")
            #expect(publisher.live.isEmpty)
            #expect(await stagingIsRemoved("slow", gates: gates))
        }
    }

    /// One file cancelled, one failed, one converted: Basso, and the cancelled file counts in the total.
    @Test func aPartialCancelWithAFailureStillFails() async throws {
        let (dir, files) = try pngs("slow-ok", "slow-a", "slow-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, progressDelay: .milliseconds(20)) {
            sounds.append($0)
        }

        let job = coordinator.perform(jpgSlice(), on: files)
        #expect(await eventually { publisher.published.count == 3 })
        try #require(publisher.published.first { $0.fileURL == files[1] }).cancel()
        #expect(await stagingIsRemoved("slow-a", gates: gates))
        await gates.open("slow-ok")
        await gates.open("slow-fail")

        let outcome = await job.value
        #expect(outcome == .failed(ResultSummary(title: "1 of 3 converted", detail: "slow-fail.png may be damaged",
                                                 isFailure: true)))
        #expect(sounds == ["Basso"])
        #expect(try contents(of: dir) == ["slow-a.png", "slow-fail.png", "slow-ok.jpg", "slow-ok.png"])
    }

    /// A cancel during the second step of a route: its staging goes and its engine's slot is free again.
    @Test(.timeLimit(.minutes(1))) func cancellingDuringALaterStepRemovesStagingAndFreesTheSlot() async throws {
        let (dir, files) = try pngs("slow", "next")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let coordinator = makeCoordinator(
            engines: [CopyEngine(), GatedEngine(gates: gates, maxConcurrentJobs: 1, from: "tiff")],
            publisher: publisher, progressDelay: .milliseconds(20)
        )

        let job = coordinator.perform(jpgSlice(), on: [files[0]])
        #expect(await eventually { publisher.published.count == 1 })
        var staging: URL?
        for _ in 0..<250 where staging == nil {
            staging = await gates.staging["slow"]
            if staging == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let stepTwo = try #require(staging)
        #expect(stepTwo.lastPathComponent == "step-1")
        publisher.published[0].cancel()
        #expect(await job.value == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: stepTwo.deletingLastPathComponent().path))

        // The gated engine allows one job at a time: this one runs only if the cancelled file gave its slot back.
        let next = coordinator.perform(jpgSlice(), on: [files[1]])
        #expect(await next.value == .succeeded)
        #expect(try contents(of: dir) == ["next.jpg", "next.png", "slow.png"])
    }

    /// M1: once quitting has begun nothing new starts, so nothing can be published after the wait.
    @Test func noNewJobStartsOnceQuittingBegan() async throws {
        let (dir, files) = try pngs("slow", "late")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: gates, publisher: publisher, progressDelay: .milliseconds(20)) {
            sounds.append($0)
        }
        let running = coordinator.perform(jpgSlice(), on: [files[0]])
        #expect(await eventually { publisher.published.count == 1 })

        await coordinator.cancelAll(waitingAtMost: .seconds(3))
        #expect(await running.value == .succeeded)
        let refused = coordinator.perform(jpgSlice(), on: [files[1]])
        #expect(!coordinator.hasRunningWork)
        #expect(coordinator.jobs.isEmpty)
        #expect(await refused.value == .succeeded)
        try await Task.sleep(for: .milliseconds(100))
        #expect(publisher.published.count == 1)
        #expect(await gates.staging["late"] == nil)
        #expect(sounds.isEmpty)
        #expect(try contents(of: dir) == ["late.png", "slow.png"])
    }

    /// M2: a quit that is called off gives the app back: jobs start again and sound as usual.
    @Test func soundsReturnAfterAQuitIsCancelled() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: Gates()) { sounds.append($0) }
        await coordinator.cancelAll(waitingAtMost: .seconds(1))
        coordinator.quitWasCancelled()

        #expect(await coordinator.perform(jpgSlice(), on: files).value == .succeeded)
        #expect(sounds == ["Glass"])
        #expect(try contents(of: dir) == ["a.jpg", "a.png"])
    }

    /// M4: each new description is sent to Finder, which redraws: it changes only with the whole percent. Counted
    /// on the setter: Progress's own KVO for the description also fires whenever its unit counts change.
    @Test func theAdditionalDescriptionChangesOnlyWithTheWholePercent() {
        let progress = DescriptionCountingProgress(parent: nil)
        let indicator = FileProgressIndicator(
            file: URL(fileURLWithPath: "/tmp/a.mov"), description: "x", publisher: RecordingProgressPublisher(),
            progress: progress, onCancel: {}
        )
        defer { indicator.end() }
        let initial = progress.descriptionSets

        indicator.update(fraction: 0.501)
        indicator.update(fraction: 0.502)
        indicator.update(fraction: 0.504)
        #expect(progress.descriptionSets - initial == 1)
        #expect(progress.localizedAdditionalDescription == 0.5.formatted(.percent.precision(.fractionLength(0))))
        #expect(progress.completedUnitCount == 504)
        indicator.update(fraction: 0.51)
        #expect(progress.descriptionSets - initial == 2)
    }

    /// Quitting cancels every job and waits for its work to stop: the plugin's process is killed, its staging is
    /// removed, nothing is published and nothing sounds.
    @Test func cancellingAllStopsTheWorkBeforeQuitting() async throws {
        let (dir, files) = try pngs("long")
        defer { try? FileManager.default.removeItem(at: dir) }
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = makeCoordinator(engines: [sleeperEngine(in: dir)], publisher: publisher) { sounds.append($0) }

        let job = coordinator.perform(jpgSlice(), on: files)
        let stagingFile = dir.appending(path: "staging")
        #expect(await eventually { FileManager.default.fileExists(atPath: stagingFile.path) })
        let pid = try #require(pid_t(try readLine(dir.appending(path: "pid"))))
        #expect(coordinator.hasRunningWork)

        let started = ContinuousClock.now
        await coordinator.cancelAll(waitingAtMost: .seconds(3))
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(!coordinator.hasRunningWork)
        #expect(await processIsGone(pid, running: "sleep 30"))
        #expect(!FileManager.default.fileExists(atPath: try readLine(stagingFile)))
        #expect(await job.value == .succeeded)
        #expect(sounds.isEmpty)
        #expect(publisher.live.isEmpty)
        #expect(try contents(of: dir) == ["long.png", "pid", "staging"])
    }
}

/// Records what a tool engine was asked to do. A class behind a lock: the engine is `Sendable`.
private final class ToolCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOptions: [PresetOptions] = []
    private var recordedCombines: [[String]] = []

    var options: [PresetOptions] { lock.withLock { recordedOptions } }
    var combines: [[String]] { lock.withLock { recordedCombines } }

    func record(_ options: PresetOptions) { lock.withLock { recordedOptions.append(options) } }
    func record(combine names: [String]) { lock.withLock { recordedCombines.append(names) } }
}

/// A PNG tool engine for `operations`: it writes a single byte (so a compression is always smaller) and records the
/// options it was given. It also combines PNGs into a PDF for the `combine` operation.
private struct ToolEngine: CombiningEngine {
    let operations: [String]
    let calls: ToolCalls
    var id: EngineID { "tool" }
    var displayName: String { "Tool" }
    var maxConcurrentJobs: Int { 4 }

    func availability() async -> EngineAvailability { .available(version: nil) }

    func edges() -> [ConversionEdge] {
        operations.map { operation in
            ConversionEdge(
                from: "png", to: Self.target(of: operation), engineID: "tool", cost: 1, flags: [],
                operation: operation
            )
        }
    }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.record(step.options)
        try Data("x".utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }

    func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.record(combine: step.inputs.map(\.lastPathComponent))
        if step.operation == "find-duplicates" { throw ConversionError.notApplicable(reason: "No duplicates found") }
        try Data("pdf".utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }

    private static func target(of operation: String) -> FormatID {
        switch operation {
        case "combine": "pdf"
        case "find-duplicates": "txt"
        default: "png"
        }
    }
}

/// Moves a trashed file into `folder` instead of the real Trash (P16), and remembers it.
private final class FakeTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var trashed: [URL] = []
    let folder: URL

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var items: [URL] { lock.withLock { trashed } }

    func trash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
        lock.withLock { trashed.append(url) }
    }
}

/// A coordinator over `ToolEngine`, with the wheel content built from `settings` as the app builds it.
@MainActor
private func makeToolCoordinator(
    operations: [String], calls: ToolCalls, settings configure: (inout AppSettings) -> Void = { _ in },
    trash: FakeTrash, publisher: RecordingProgressPublisher = RecordingProgressPublisher(),
    engine: (any ConversionEngine)? = nil, pasteboard: NSPasteboard = NSPasteboard.withUniqueName(),
    sounds: @escaping @MainActor (NSSound.Name) -> Void = { _ in }
) async -> JobCoordinator {
    let store = SettingsStore(defaults: EphemeralDefaults())
    store.settings.soundsEnabled = true
    configure(&store.settings)
    let engines: [any ConversionEngine] = [engine ?? ToolEngine(operations: operations, calls: calls)]
    let registry = EngineRegistry(engines: engines, priority: ["tool"])
    let coordinator = JobCoordinator(
        registry: registry, settings: store, pasteboard: pasteboard, playSound: sounds,
        progressPublisher: publisher, trashItem: { try trash.trash($0) }, progressDelay: .zero
    )
    coordinator.contentBuilder = WheelContentBuilder(
        formats: .builtIn, available: await registry.planner(), all: await registry.planner(includingMissing: true),
        installHints: [:], tools: ToolCatalog.presets(settings: store.settings),
        visibility: ToolVisibility(overrides: store.settings.toolVisibility),
        replacesOriginals: store.settings.replaceOriginal
    )
    return coordinator
}

/// Combines PNGs into a PDF once the test opens the gate named "combine". A cancelled wait ends at once.
private struct GatedCombiner: CombiningEngine {
    let gates: Gates
    var id: EngineID { "tool" }
    var displayName: String { "Tool" }
    var maxConcurrentJobs: Int { 1 }

    func availability() async -> EngineAvailability { .available(version: nil) }

    func edges() -> [ConversionEdge] {
        [ConversionEdge(from: "png", to: "pdf", engineID: "tool", cost: 1, flags: [], operation: "combine")]
    }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw CancellationError()
    }

    func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        await gates.record(staging: step.stagingDirectory, for: "combine")
        await gates.wait(for: "combine")
        try Task.checkCancellation()
        try Data("pdf".utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

private func toolSlice(_ id: String) -> WheelSlice {
    WheelSlice(id: "preset.\(id)", title: id, symbol: "wrench", kind: .preset(id: id))
}

@MainActor
@Suite struct ToolJobTests {
    private func png(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try writePNG(to: url)
        return url
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func performUsesTheConfiguredPreset() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let calls = ToolCalls()
        let coordinator = await makeToolCoordinator(
            operations: ["compress"], calls: calls,
            settings: { var model = ToolsPaneModel(settings: $0); model.setQuality(0.4, for: "compress"); $0 = model.settings },
            trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )

        let outcome = await coordinator.perform(toolSlice("compress"), on: [source]).value

        #expect(outcome == .succeeded)
        #expect(calls.options.map(\.quality) == [0.4])
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "a-compressed.png").path))
    }

    @Test func anUnknownToolFailsWithAReason() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let coordinator = await makeToolCoordinator(
            operations: ["compress"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        let outcome = await coordinator.perform(toolSlice("no-such-tool"), on: [source]).value
        #expect(failureTitle(outcome) == "Couldn't run no-such-tool")
    }

    @Test func replaceOriginalSettingReachesTheRunner() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let trash = try FakeTrash(folder: dir.appending(path: "trash"))
        let coordinator = await makeToolCoordinator(
            operations: ["compress"], calls: ToolCalls(), settings: { $0.replaceOriginal = true }, trash: trash
        )

        let outcome = await coordinator.perform(toolSlice("compress"), on: [source]).value

        #expect(outcome == .succeeded)
        #expect(trash.items == [source])
        #expect(try contents(of: dir) == ["a.png", "trash"])
        #expect(try Data(contentsOf: source) == Data("x".utf8))
    }

    @Test func withoutTheSettingTheOriginalStays() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let trash = try FakeTrash(folder: dir.appending(path: "trash"))
        let coordinator = await makeToolCoordinator(operations: ["compress"], calls: ToolCalls(), trash: trash)

        _ = await coordinator.perform(toolSlice("compress"), on: [source]).value

        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a-compressed.png", "a.png", "trash"])
    }

    @Test func aToolThatCannotReplaceKeepsTheOriginal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let trash = try FakeTrash(folder: dir.appending(path: "trash"))
        let coordinator = await makeToolCoordinator(
            operations: ["remove-background"], calls: ToolCalls(), settings: { $0.replaceOriginal = true }, trash: trash
        )

        let outcome = await coordinator.perform(toolSlice("remove-background"), on: [source]).value

        #expect(outcome == .succeeded)
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a-cutout.png", "a.png", "trash"])
    }

    // A replace publishes the source's own URL as the output: nothing may treat that as a failure, and the
    // Finder progress on the source still ends.
    @Test func aReplacedOriginalIsAnOrdinarySuccessAndItsProgressEnds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = await makeToolCoordinator(
            operations: ["compress"], calls: ToolCalls(), settings: { $0.replaceOriginal = true },
            trash: try FakeTrash(folder: dir.appending(path: "trash")), publisher: publisher
        ) { sounds.append($0) }

        let outcome = await coordinator.perform(toolSlice("compress"), on: [source]).value

        #expect(outcome == .succeeded)
        #expect(sounds == ["Glass"])
        #expect(publisher.published.count == 1)
        #expect(publisher.live.isEmpty)
        #expect(coordinator.jobs.isEmpty)
    }

    // MARK: Editors (P27, P31)

    private func editorPreset(_ id: String, edit: EditSpec? = nil, targetBytes: Int64? = nil) throws -> Preset {
        var preset = try #require(Preset.builtIns.first { $0.id == id })
        preset.options.edit = edit
        preset.options.targetBytes = targetBytes
        return preset
    }

    private func fakeEngine(_ operation: String, format: FormatID) -> FakeEngine {
        FakeEngine(id: "tool", edges: [ConversionEdge(from: format, to: format, engineID: "tool", cost: 1, flags: [],
                                                      operation: operation)])
    }

    @Test func performWithAPresetCarriesItsEdit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "clip.mov")
        try Data("movie".utf8).write(to: source)
        let range = TimeRange(start: 1.5, end: 4)
        let coordinator = await makeToolCoordinator(
            operations: [], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash")),
            engine: fakeEngine("trim", format: "mov")
        )

        let job = coordinator.perform(preset: try editorPreset("trim", edit: .trim(range)), on: [source],
                                      anchor: CGPoint(x: 10, y: 20), isHeld: false)
        let outcome = await job.outcome.value

        #expect(outcome == .succeeded)
        let output = try String(contentsOf: dir.appending(path: "clip-trimmed.mov"), encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(EditSpec.trim(range)), as: UTF8.self)
        #expect(output == "movie\n->mov [trim]\nedit: \(json)")
        #expect(try contents(of: dir) == ["clip-trimmed.mov", "clip.mov", "trash"])
    }

    @Test func aTargetSizeTravelsWithThePreset() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let calls = ToolCalls()
        let coordinator = await makeToolCoordinator(
            operations: ["target-size"], calls: calls, trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        let preset = try editorPreset("compress-to-size", targetBytes: 500_000)

        let outcome = await coordinator.perform(preset: preset, on: [source], anchor: .zero, isHeld: false).outcome.value

        #expect(outcome == .succeeded)
        #expect(calls.options.map(\.targetBytes) == [500_000])
    }

    @Test func aHeldPresetJobStaysOutOfSightUntilReleased() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let coordinator = await makeToolCoordinator(
            operations: ["crop"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        let crop = EditSpec.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))

        let job = coordinator.perform(preset: try editorPreset("crop", edit: crop), on: [source],
                                      anchor: CGPoint(x: 5, y: 6), isHeld: true)
        _ = await job.outcome.value

        let held = try #require(coordinator.jobs.first { $0.id == job.id })
        #expect(held.isHeld && held.anchor == CGPoint(x: 5, y: 6) && held.verb == "Cropping" && held.symbol == "crop")
        coordinator.release(job.id, outcomeShown: true)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func editorJobsNeverReplaceTheOriginal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let trash = try FakeTrash(folder: dir.appending(path: "trash"))
        let coordinator = await makeToolCoordinator(
            operations: ["crop"], calls: ToolCalls(), settings: { $0.replaceOriginal = true }, trash: trash
        )
        let crop = EditSpec.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))

        let outcome = await coordinator.perform(preset: try editorPreset("crop", edit: crop), on: [source],
                                                anchor: .zero, isHeld: false).outcome.value

        #expect(outcome == .succeeded)
        #expect(trash.items.isEmpty)
        #expect(try contents(of: dir) == ["a-cropped.png", "a.png", "trash"])
    }

    /// A tool doesn't convert: its failure names the tool (an editor's without its "…").
    @Test func aToolsFailureNamesTheTool() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = await makeToolCoordinator(
            operations: ["crop"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        let crop = EditSpec.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))

        let outcome = await coordinator.perform(preset: try editorPreset("crop", edit: crop),
                                                on: [dir.appending(path: "gone.png")], anchor: .zero,
                                                isHeld: false).outcome.value

        #expect(failureTitle(outcome) == "Couldn't run Crop")
    }

    @Test func anEditorSliceIsNeverRunByTheCoordinator() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let calls = ToolCalls()
        let coordinator = await makeToolCoordinator(
            operations: ["crop"], calls: calls, trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        let slice = WheelSlice(id: "editor.crop", title: "Crop\u{2026}", symbol: "crop", kind: .editor(id: "crop"))

        let job = coordinator.perform(slice, on: [source], anchor: .zero, isHeld: true)
        let outcome = await job.outcome.value

        #expect(outcome == .succeeded)
        #expect(calls.options.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        #expect(try contents(of: dir) == ["a.png", "trash"])
    }

    @Test func noPresetJobStartsOnceQuittingBegan() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try png("a.png", in: dir)
        let calls = ToolCalls()
        let coordinator = await makeToolCoordinator(
            operations: ["crop"], calls: calls, trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        await coordinator.cancelAll(waitingAtMost: .milliseconds(50))

        let crop = EditSpec.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let outcome = await coordinator.perform(preset: try editorPreset("crop", edit: crop), on: [source],
                                                anchor: .zero, isHeld: false).outcome.value

        #expect(outcome == .succeeded && calls.options.isEmpty && coordinator.jobs.isEmpty)
    }

    @Test func combineInputsAreSortedByName() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ten = try png("IMG_10.png", in: dir)
        let two = try png("IMG_2.png", in: dir)
        let calls = ToolCalls()
        let coordinator = await makeToolCoordinator(
            operations: ["combine"], calls: calls, trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )

        let outcome = await coordinator.perform(toolSlice("images-to-pdf"), on: [ten, two]).value

        #expect(outcome == .succeeded)
        #expect(calls.combines == [["IMG_2.png", "IMG_10.png"]])
        #expect(try contents(of: dir) == ["IMG_10.png", "IMG_2-combined.pdf", "IMG_2.png", "trash"])
    }

    /// A combine's one output reaches every source, in the combine's order.
    @Test func onResultForACombineGivesEverySourceTheOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ten = try png("IMG_10.png", in: dir)
        let two = try png("IMG_2.png", in: dir)
        let coordinator = await makeToolCoordinator(
            operations: ["combine"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )
        var results: [FileResult] = []

        let outcome = await coordinator.perform(toolSlice("images-to-pdf"), on: [ten, two], anchor: .zero,
                                                isHeld: false) { results.append($0) }.outcome.value

        #expect(outcome == .succeeded)
        #expect(results.map(\.source) == [two, ten])
        #expect(results.map(outputNames) == [["IMG_2-combined.pdf"], ["IMG_2-combined.pdf"]])
    }

    @Test func aCombineFailureNamesTheCombine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try png("a.png", in: dir)
        let missing = dir.appending(path: "b.png")
        let coordinator = await makeToolCoordinator(
            operations: ["combine"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )

        let outcome = await coordinator.perform(toolSlice("images-to-pdf"), on: [a, missing]).value

        #expect(outcome == .failed(ResultSummary(
            title: "Couldn't combine 2 files", detail: "b.png was moved or deleted", isFailure: true
        )))
    }

    /// Final review: "No duplicates found" is about every image, and Find duplicates combines nothing. It stays a
    /// failure's outcome, as every reason a tool doesn't apply is.
    @Test func findingNoDuplicatesSaysSoWithoutBlamingAFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.png", "b.png", "c.png"].map { try png($0, in: dir) }
        let coordinator = await makeToolCoordinator(
            operations: ["find-duplicates"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash"))
        )

        let outcome = await coordinator.perform(toolSlice("find-duplicates"), on: files).value

        #expect(outcome == .failed(ResultSummary(
            title: "Couldn't run Find duplicates", detail: "No duplicates found", isFailure: true
        )))
        #expect(try contents(of: dir) == ["a.png", "b.png", "c.png", "trash"])
    }

    // A combine is one runner job (P24): each source shows an indicator, and Finder's cancel on any of them stops it.
    @Test func aCombineShowsOneIndicatorPerSourceAndEndsThemAll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = try ["b.png", "a.png", "c.png"].map { try png($0, in: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = await makeToolCoordinator(
            operations: ["combine"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash")),
            publisher: publisher, engine: GatedCombiner(gates: gates)
        ) { sounds.append($0) }

        let job = coordinator.perform(toolSlice("images-to-pdf"), on: sources)
        #expect(await eventually { publisher.published.count == 3 })
        #expect(Set(publisher.published.map(\.fileURL)) == Set(sources))
        #expect(publisher.published.allSatisfy { $0.localizedDescription == "Making a PDF\u{2026}" })
        #expect(publisher.live.count == 3)
        await gates.open("combine")

        #expect(await job.value == .succeeded)
        #expect(publisher.live.isEmpty)
        #expect(sounds == ["Glass"])
        #expect(coordinator.jobs.isEmpty)
        #expect(try contents(of: dir) == ["a-combined.pdf", "a.png", "b.png", "c.png", "trash"])
    }

    @Test func cancellingOneSourceCancelsTheWholeCombineSilently() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = try ["a.png", "b.png"].map { try png($0, in: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = await makeToolCoordinator(
            operations: ["combine"], calls: ToolCalls(), trash: try FakeTrash(folder: dir.appending(path: "trash")),
            publisher: publisher, engine: GatedCombiner(gates: gates)
        ) { sounds.append($0) }

        let job = coordinator.perform(toolSlice("images-to-pdf"), on: sources)
        #expect(await eventually { publisher.published.count == 2 })
        try #require(publisher.published.first { $0.fileURL == sources[1] }).cancel()

        #expect(await job.value == .succeeded)
        #expect(sounds.isEmpty)
        #expect(publisher.live.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        let staging = try #require(await gates.staging["combine"])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try contents(of: dir) == ["a.png", "b.png", "trash"])
    }
}

/// Reads the codes of `read-codes`: a file's payloads are `codes[stem]`, separated by a blank line (P53); a file
/// without any is "No code found", as Vision reports it.
private struct CodeEngine: ConversionEngine {
    let codes: [String: [String]]
    var id: EngineID { "tool" }
    var displayName: String { "Codes" }
    var maxConcurrentJobs: Int { 4 }

    func availability() async -> EngineAvailability { .available(version: nil) }

    func edges() -> [ConversionEdge] {
        [ConversionEdge(from: "png", to: "txt", engineID: "tool", cost: 1, flags: [], operation: "read-codes")]
    }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let lines = codes[OutputNamer.stem(of: step.input)] else {
            throw ConversionError.notApplicable(reason: "No code found")
        }
        try Data(lines.joined(separator: "\n\n").utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

func pngs(_ names: String...) throws -> (dir: URL, files: [URL]) {
    let dir = try makeTempDir()
    let files = try names.map { name in
        let url = dir.appending(path: "\(name).png")
        try writePNG(to: url)
        return url
    }
    return (dir, files)
}

/// Well past `PillTiming.showAfter`, so only holding or the phase decide.
private func isVisibleLater(_ job: PillJob?) -> Bool {
    job.map { PillTiming.isVisible($0, now: .now + .seconds(1)) } ?? false
}

/// The pill's model (P25): which jobs `jobs` lists, and how the wheel's hold and release decide where an outcome
/// shows.
@MainActor
@Suite struct PillJobsTests {
    @Test func aJobHeldByTheWheelIsHiddenUntilReleased() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)

        let job = coordinator.perform(jpgSlice(), on: files, anchor: CGPoint(x: 300, y: 200), isHeld: true)
        let held = try #require(coordinator.jobs.first)
        #expect(held.id == job.id)
        #expect(held.isHeld)
        #expect(held.anchor == CGPoint(x: 300, y: 200))
        #expect(!isVisibleLater(held))

        coordinator.release(job.id, outcomeShown: false)
        #expect(coordinator.jobs.first?.phase == .running)
        #expect(isVisibleLater(coordinator.jobs.first))
        await gates.open("slow")
        #expect(await job.outcome.value == .succeeded)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func aHeldSuccessLeavesOnRelease() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = makeGatedCoordinator(gates: Gates())

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: true)
        #expect(await job.outcome.value == .succeeded)
        #expect(coordinator.jobs.map(\.id) == [job.id])
        #expect(!isVisibleLater(coordinator.jobs.first))
        coordinator.release(job.id, outcomeShown: false)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func aFailureTheHubShowedLeavesNoPill() async throws {
        let (dir, files) = try pngs("fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = makeGatedCoordinator(gates: Gates())

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: true)
        let outcome = await job.outcome.value
        #expect(failureTitle(outcome) == "Couldn't convert fail.png")
        // Ended, but held: its final phase is there, out of sight.
        #expect(coordinator.jobs.first?.phase == .failed(try #require(outcome.summary)))
        #expect(!isVisibleLater(coordinator.jobs.first))

        coordinator.release(job.id, outcomeShown: true)
        #expect(coordinator.jobs.isEmpty)
    }

    /// The wheel stops waiting just after the job failed, before its hub could show it.
    @Test func aFailureEndingAsTheWheelLetsGoShowsInThePill() async throws {
        let (dir, files) = try pngs("fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = makeGatedCoordinator(gates: Gates())

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: true)
        let summary = try #require(await job.outcome.value.summary)
        coordinator.release(job.id, outcomeShown: false)

        let pill = try #require(coordinator.jobs.first)
        #expect(pill.phase == .failed(summary))
        #expect(PillTiming.isVisible(pill, now: .now))
        #expect(pill.detail == "The file may be damaged")
        coordinator.dismiss(job: job.id)
        #expect(coordinator.jobs.isEmpty)
    }

    /// The other order: the wheel lets go while the job runs, and the failure arrives later.
    @Test func aFailureAfterTheWheelLetGoShowsInThePill() async throws {
        let (dir, files) = try pngs("slow-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: true)
        coordinator.release(job.id, outcomeShown: false)
        await gates.open("slow-fail")
        let summary = try #require(await job.outcome.value.summary)

        let pill = try #require(coordinator.jobs.first)
        #expect(pill.phase == .failed(summary))
        #expect(PillTiming.isVisible(pill, now: .now))
        // A running job can't be dismissed, an ended one can.
        coordinator.dismiss(job: job.id)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func aRunningJobIsNotDismissed() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        coordinator.dismiss(job: job.id)
        #expect(coordinator.jobs.map(\.id) == [job.id])
        await gates.open("slow")
        _ = await job.outcome.value
    }

    @Test func aQuickFileToolFailureShowsARedPill() async throws {
        var sounds: [NSSound.Name] = []
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = await makeCoordinator(pasteboard: pasteboard) { sounds.append($0) }
        let missing = URL(fileURLWithPath: "/tmp/pomelo-test-\(UUID().uuidString)/a.txt")
        let slice = WheelSlice(id: "action.copyFiles", title: "Copy Files", symbol: "x", kind: .action(.copyFiles))

        let job = coordinator.perform(slice, on: [missing], anchor: .zero, isHeld: false)
        let outcome = await job.outcome.value

        let summary = ResultSummary(title: "Couldn't copy the files", detail: "a.txt was moved or deleted",
                                    isFailure: true)
        #expect(outcome == .failed(summary))
        let pill = try #require(coordinator.jobs.first)
        #expect(pill.phase == .failed(summary))
        #expect(pill.verb == "Copying files")
        #expect(PillTiming.isVisible(pill, now: .now))
        #expect(sounds == ["Basso"])
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func aQuickFileToolSuccessLeavesNoPill() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = await makeCoordinator(pasteboard: pasteboard)
        let slice = WheelSlice(id: "action.copyPaths", title: "Copy Paths", symbol: "x", kind: .action(.copyPaths))

        let job = coordinator.perform(slice, on: [URL(fileURLWithPath: "/tmp/a.txt")], anchor: .zero, isHeld: false)
        #expect(coordinator.jobs.first?.isCombined == true)
        #expect(await job.outcome.value == .succeeded)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func cancellingOneFileStopsOnlyThatFile() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b", "slow-c")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: gates) { sounds.append($0) }

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        #expect(coordinator.jobs.first?.canExpand == true)
        #expect(await eventually {
            coordinator.jobs.first?.files.allSatisfy { $0.state == .running(fraction: nil) } == true
        })
        coordinator.cancel(job: job.id, file: 1)
        #expect(await eventually { coordinator.jobs.first?.files[1].state == .cancelled })
        #expect(coordinator.jobs.first?.files[0].state == .running(fraction: nil))
        #expect(coordinator.jobs.first?.detail == "1 of 3")
        await gates.open("slow-a")
        #expect(await eventually { coordinator.jobs.first?.files[0].state == .done })
        await gates.open("slow-c")

        #expect(await job.outcome.value == .succeeded)
        #expect(coordinator.jobs.isEmpty)
        #expect(sounds == ["Glass"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["slow-a.jpg", "slow-a.png", "slow-b.png", "slow-c.jpg", "slow-c.png"])
    }

    @Test func cancellingAJobStopsAllItsFiles() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        var sounds: [NSSound.Name] = []
        let coordinator = makeGatedCoordinator(gates: gates) { sounds.append($0) }

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        #expect(await eventually {
            coordinator.jobs.first?.files.allSatisfy { $0.state == .running(fraction: nil) } == true
        })
        coordinator.cancel(job: job.id)

        #expect(await job.outcome.value == .succeeded)
        #expect(coordinator.jobs.isEmpty)
        #expect(sounds.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["slow-a.png", "slow-b.png"])
    }

    @Test func aFileReportsItsFraction() async throws {
        let (dir, files) = try pngs("slow-half")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeGatedCoordinator(gates: gates)

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        #expect(await eventually { coordinator.jobs.first?.fraction == 0.5 })
        #expect(coordinator.jobs.first?.percentText == "50%")
        await gates.open("slow-half")
        _ = await job.outcome.value
    }

    @Test func aDownloadsFallbackIsNoted() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let readOnly = DestinationResolver(downloadsFolder: downloads, isWritable: { _ in false })
        var sounds: [NSSound.Name] = []
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: Gates())], destinations: readOnly,
                                          noteStay: .milliseconds(100)) { sounds.append($0) }

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        let outcome = await job.outcome.value

        let note = ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")
        #expect(outcome == .noted(note))
        #expect(sounds == ["Glass"])
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "a.jpg").path))
        let pill = try #require(coordinator.jobs.first)
        #expect(pill.phase == .noted(note))
        #expect(PillTiming.isVisible(pill, now: .now))
        // A note leaves on its own.
        #expect(await eventually(within: .seconds(2)) { coordinator.jobs.isEmpty })
    }

    @Test func aFailureWinsOverTheDownloadsNote() async throws {
        let (dir, files) = try pngs("a", "fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let readOnly = DestinationResolver(downloadsFolder: downloads, isWritable: { _ in false })
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: Gates())], destinations: readOnly)

        let outcome = await coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false).outcome.value
        #expect(failureTitle(outcome) == "1 of 2 converted")
    }

    @Test func aZipSavedToDownloadsIsNoted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        let downloads = dir.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let readOnly = DestinationResolver(downloadsFolder: downloads, isWritable: { _ in false })
        let coordinator = await makeCoordinator(destinations: readOnly)
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))

        let outcome = await coordinator.perform(slice, on: [file], anchor: .zero, isHeld: false).outcome.value

        #expect(outcome == .noted(ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")))
        #expect(FileManager.default.fileExists(atPath: downloads.appending(path: "notes.zip").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "notes.zip").path))
    }

    /// P52: the note comes from the resolver's fallback, so a source reached through a symlinked folder is not "elsewhere".
    @Test func aZipBesideASymlinkedFolderIsNotNoted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: real.appending(path: "notes.txt"))
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let coordinator = await makeCoordinator()
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))

        let outcome = await coordinator.perform(slice, on: [link.appending(path: "notes.txt")], anchor: .zero,
                                                isHeld: false).outcome.value

        #expect(outcome == .succeeded)
        #expect(FileManager.default.fileExists(atPath: real.appending(path: "notes.zip").path))
        #expect(coordinator.jobs.isEmpty)
    }

    /// The hub and pill get a short reason, never `ditto`'s stderr or the title again.
    @Test func aZipFailureHasAShortReason() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = await makeCoordinator()
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))

        let outcome = await coordinator.perform(slice, on: [dir.appending(path: "gone.txt")], anchor: .zero,
                                                isHeld: false).outcome.value

        let summary = try #require(outcome.summary)
        #expect(outcome.isFailure)
        #expect(summary.title == "Couldn't make the zip")
        #expect(summary.detail == "The zip couldn't be made")
        #expect((summary.detail?.count ?? 0) <= ResultSummary.maxDetailLength)
        #expect(coordinator.jobs.first?.files.first?.state == .failed(reason: "The zip couldn't be made"))
    }

    @Test func fileToolReasonsAreShortAndHuman() {
        #expect(JobCoordinator.reason(for: FileActionError.terminalNotFound) == "Terminal wasn't found")
        #expect(JobCoordinator.reason(for: FileActionError.zipFailed(String(repeating: "x", count: 500)))
                == "The zip couldn't be made")
        #expect(JobCoordinator.reason(for: FileActionError.missing(name: "a.txt")) == "a.txt was moved or deleted")
        let long = JobCoordinator.reason(for: FileActionError.missing(name: String(repeating: "n", count: 80) + ".txt"))
        #expect(long.count <= ResultSummary.maxDetailLength)
        #expect(JobCoordinator.reason(for: CocoaError(.fileWriteOutOfSpace)) == "Something went wrong")
    }

    @Test func aZipNextToItsSourceIsAPlainSuccess() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: file)
        let coordinator = await makeCoordinator()
        let slice = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))

        let outcome = await coordinator.perform(slice, on: [file], anchor: .zero, isHeld: false).outcome.value
        #expect(outcome == .succeeded)
        #expect(coordinator.jobs.isEmpty)
    }

    @Test func eachJobHasItsVerbAndSymbol() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let coordinator = await makeCoordinator()
        let txt = WheelSlice(id: "convert.txt", title: "Text", symbol: "doc", kind: .convert("txt"))
        let zip = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))
        let cases: [(slice: WheelSlice, verb: String, symbol: String)] = [
            (toolSlice("compress"), "Compressing", "rectangle.compress.vertical"),
            (txt, "Recognizing text", "doc"),
            (jpgSlice(), "Converting", "photo"),
            (zip, "Zipping", "doc.zipper"),
        ]
        for (slice, verb, symbol) in cases {
            let job = coordinator.perform(slice, on: files, anchor: .zero, isHeld: true)
            let pill = try #require(coordinator.jobs.first { $0.id == job.id }, "\(slice.id)")
            #expect(pill.verb == verb, "\(slice.id)")
            #expect(pill.symbol == symbol, "\(slice.id)")
            _ = await job.outcome.value
            coordinator.release(job.id, outcomeShown: true)
        }
        #expect(coordinator.jobs.isEmpty)
    }
}

/// Read codes go to the clipboard (P25), through a folder of Pomelo's own that is removed afterwards. Serialized:
/// each test checks that folder's contents.
@MainActor
@Suite(.serialized) struct CodesToClipboardTests {
    private var codesRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "Pomelo Codes", directoryHint: .isDirectory)
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: codesRoot.path)) ?? []
    }

    private func coordinator(codes: [String: [String]], pasteboard: NSPasteboard, in dir: URL,
                             sounds: @escaping @MainActor (NSSound.Name) -> Void = { _ in }) async throws
        -> JobCoordinator {
        await makeToolCoordinator(operations: [], calls: ToolCalls(),
                                  trash: try FakeTrash(folder: dir.appending(path: "trash")),
                                  engine: CodeEngine(codes: codes), pasteboard: pasteboard, sounds: sounds)
    }

    @Test func codesAreCopiedToTheInjectedPasteboardSilently() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var sounds: [NSSound.Name] = []
        let before = leftovers()
        let coordinator = try await coordinator(codes: ["a": ["https://example.com"]], pasteboard: pasteboard,
                                                in: dir) { sounds.append($0) }

        let job = coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero, isHeld: false)
        #expect(coordinator.jobs.first?.verb == "Reading codes")
        let outcome = await job.outcome.value

        #expect(outcome == .succeeded)
        #expect(pasteboard.string(forType: .string) == "https://example.com")
        #expect(coordinator.jobs.isEmpty)
        #expect(sounds == ["Glass"])
        #expect(leftovers() == before)
        // Nothing next to the source.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["a.png", "trash"])
    }

    /// Read codes deliver to the clipboard: nothing for the Shelf to take (S18).
    @Test func onResultNeverForClipboardDelivery() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = try await coordinator(codes: ["a": ["https://example.com"]], pasteboard: pasteboard, in: dir)
        var results: [FileResult] = []

        let outcome = await coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero, isHeld: false) {
            results.append($0)
        }.outcome.value

        #expect(outcome == .succeeded)
        #expect(pasteboard.string(forType: .string) == "https://example.com")
        #expect(results.isEmpty)
    }

    @Test func severalFilesCopyEveryCodeOnceInOrder() async throws {
        let (dir, files) = try pngs("a", "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let long = "https://example.com/" + String(repeating: "x", count: 60)
        let coordinator = try await coordinator(
            codes: ["a": [long, "SHARED"], "b": ["SHARED", "b-only"]], pasteboard: pasteboard, in: dir
        )

        let outcome = await coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero,
                                                isHeld: false).outcome.value

        #expect(pasteboard.string(forType: .string) == "\(long)\n\nSHARED\n\nb-only")
        #expect(outcome == .succeeded)
    }

    @Test func noCodeIsAFailure() async throws {
        let (dir, files) = try pngs("blank", "empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var sounds: [NSSound.Name] = []
        let before = leftovers()
        let coordinator = try await coordinator(codes: [:], pasteboard: pasteboard, in: dir) { sounds.append($0) }

        let one = await coordinator.perform(toolSlice("read-codes"), on: [files[0]], anchor: .zero,
                                            isHeld: true).outcome.value
        #expect(one == .failed(ResultSummary(title: "No code found", detail: "blank.png", isFailure: true)))
        let two = await coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero,
                                            isHeld: true).outcome.value
        #expect(two == .failed(ResultSummary(title: "No code found", detail: "In 2 files", isFailure: true)))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(sounds == ["Basso", "Basso"])
        #expect(leftovers() == before)
    }

    /// P53: a payload may span lines; it is one code, kept whole and counted once across files.
    @Test func aMultilinePayloadIsOneCode() async throws {
        let (dir, files) = try pngs("a", "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let wifi = "WIFI:S:home;\nT:WPA;P:secret;;"
        let coordinator = try await coordinator(codes: ["a": [wifi], "b": [wifi, "https://example.com"]],
                                                pasteboard: pasteboard, in: dir)

        let outcome = await coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero,
                                                isHeld: false).outcome.value

        #expect(outcome == .succeeded)
        #expect(pasteboard.string(forType: .string) == "\(wifi)\n\nhttps://example.com")
    }

    @Test func aFileWithoutCodesFailsTheRead() async throws {
        let (dir, files) = try pngs("a", "blank")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = try await coordinator(codes: ["a": ["CODE"]], pasteboard: pasteboard, in: dir)

        let outcome = await coordinator.perform(toolSlice("read-codes"), on: files, anchor: .zero,
                                                isHeld: false).outcome.value

        // The codes found are still copied.
        #expect(pasteboard.string(forType: .string) == "CODE")
        #expect(outcome.isFailure)
        #expect(outcome.summary?.detail == "blank.png: No code found")
    }
}

// MARK: - Unattended jobs (intents, watch folders; P106)

@MainActor
@Suite struct UnattendedJobTests {
    private func pngs(_ names: String...) throws -> (dir: URL, files: [URL]) {
        let dir = try makeTempDir()
        let files = try names.map { name in
            let url = dir.appending(path: "\(name).png")
            try writePNG(to: url)
            return url
        }
        return (dir, files)
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// True once the gated conversion of `stem` has reached its engine.
    private func reachedEngine(_ stem: String, gates: Gates) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await gates.staging[stem] != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func toJPG(_ files: [URL]) -> ConversionRequest {
        ConversionRequest(inputs: files, target: "jpg")
    }

    private static func isSuccess(_ result: FileResult) -> Bool {
        if case .succeeded = result { true } else { false }
    }

    @Test func anUnattendedJobNeverShowsInThePill() async throws {
        let (dir, files) = try pngs("slow", "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: gates)])
        var seen: [[PillJob]] = []
        let watching = coordinator.$jobs.sink { seen.append($0) }
        defer { watching.cancel() }

        let job = Task { await coordinator.runUnattended(toJPG(files), verb: "Converting") }
        #expect(await reachedEngine("slow", gates: gates))
        #expect(coordinator.jobs.isEmpty)
        await gates.open("slow")
        let results = await job.value

        // In input order, although the second file finished first.
        #expect(results.map(\.source) == files)
        #expect(results.allSatisfy(Self.isSuccess), "\(results)")
        #expect(coordinator.jobs.isEmpty)
        #expect(seen.allSatisfy { $0.isEmpty }, "\(seen)")
        #expect(try contents(of: dir) == ["b.jpg", "b.png", "slow.jpg", "slow.png"])
    }

    @Test func anUnattendedJobMakesNoSound() async throws {
        let (dir, files) = try pngs("a", "fail", "c")
        defer { try? FileManager.default.removeItem(at: dir) }
        var sounds: [NSSound.Name] = []
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: Gates())]) { sounds.append($0) }

        let results = await coordinator.runUnattended(toJPG(Array(files[0...1])), verb: "Converting")
        #expect(Self.isSuccess(results[0]))
        guard case .failed(files[1], _) = results[1] else { Issue.record("\(results)"); return }
        #expect(sounds.isEmpty)

        // The same coordinator does sound for a job the person started, so the silence above is the unattended path's.
        #expect(await coordinator.perform(jpgSlice(), on: [files[2]]).value == .succeeded)
        #expect(sounds == ["Glass"])
    }

    @Test func anUnattendedJobShowsFinderProgressAfterTheDelay() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let coordinator = makeCoordinator(
            engines: [GatedEngine(gates: gates)], publisher: publisher, progressDelay: .milliseconds(50)
        )

        let started = ContinuousClock.now
        let job = Task { await coordinator.runUnattended(toJPG(files), verb: "Compressing") }
        #expect(await eventually { !publisher.published.isEmpty })
        #expect(ContinuousClock.now - started >= .milliseconds(45))
        let progress = try #require(publisher.published.first)
        #expect(publisher.published.count == 1)
        #expect(progress.fileURL == files[0])
        #expect(progress.isCancellable)
        #expect(progress.localizedDescription == "Compressing\u{2026}")

        await gates.open("slow")
        #expect(await job.value.allSatisfy(Self.isSuccess))
        #expect(publisher.live.isEmpty)
    }

    @Test func finderCancelStopsThatFileAlone() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let coordinator = makeCoordinator(
            engines: [GatedEngine(gates: gates)], publisher: publisher, progressDelay: .milliseconds(20)
        )

        let job = Task { await coordinator.runUnattended(toJPG(files), verb: "Converting") }
        #expect(await eventually { publisher.published.count == 2 })
        try #require(publisher.published.first { $0.fileURL == files[0] }).cancel()
        await gates.open("slow-b")
        let results = await job.value

        #expect(results[0] == .cancelled(source: files[0]))
        #expect(Self.isSuccess(results[1]), "\(results)")
        #expect(try contents(of: dir) == ["slow-a.png", "slow-b.jpg", "slow-b.png"])
    }

    @Test func anUnattendedJobNeverReplacesTheOriginal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "a.png")
        try writePNG(to: source)
        let original = try Data(contentsOf: source)
        let trash = try FakeTrash(folder: dir.appending(path: "trash"))
        let coordinator = await makeToolCoordinator(
            operations: ["compress"], calls: ToolCalls(), settings: { $0.replaceOriginal = true }, trash: trash
        )
        var request = ConversionRequest.from(try #require(Preset.builtIns.first { $0.id == "compress" }), inputs: [source])
        request.replaceOriginal = true

        let results = await coordinator.runUnattended(request, verb: "Compressing")

        #expect(results == [.succeeded(source: source, outputs: [dir.appending(path: "a-compressed.png")], note: nil)])
        #expect(trash.items.isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(try contents(of: dir) == ["a-compressed.png", "a.png", "trash"])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerCancelsTheFiles() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        let coordinator = makeCoordinator(
            engines: [GatedEngine(gates: gates)], publisher: publisher, progressDelay: .milliseconds(20)
        )

        let job = Task { await coordinator.runUnattended(toJPG(files), verb: "Converting") }
        #expect(await reachedEngine("slow", gates: gates))
        let staging = try #require(await gates.staging["slow"])
        let cancelled = ContinuousClock.now
        job.cancel()
        // Should the cancel not reach the engine, the gate opens anyway: the test fails instead of hanging.
        Task { try? await Task.sleep(for: .seconds(4)); await gates.open("slow") }
        let results = await job.value

        #expect(ContinuousClock.now - cancelled < .seconds(3))
        #expect(results == [.cancelled(source: files[0])])
        // Gone by the time it returns, not eventually.
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try contents(of: dir) == ["slow.png"])
        #expect(!coordinator.hasRunningWork)
        #expect(await eventually { publisher.live.isEmpty })
    }

    @Test(.timeLimit(.minutes(1))) func quittingCancelsUnattendedJobs() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let publisher = RecordingProgressPublisher()
        var sounds: [NSSound.Name] = []
        let coordinator = makeCoordinator(
            engines: [GatedEngine(gates: gates)], publisher: publisher, progressDelay: .milliseconds(20)
        ) { sounds.append($0) }

        let job = Task { await coordinator.runUnattended(toJPG(files), verb: "Converting") }
        #expect(await reachedEngine("slow", gates: gates))
        #expect(coordinator.hasRunningWork)

        await coordinator.cancelAll(waitingAtMost: .seconds(3))
        // Should the quit not reach the engine, the gate opens anyway: the test fails instead of hanging.
        Task { try? await Task.sleep(for: .seconds(4)); await gates.open("slow") }

        #expect(!coordinator.hasRunningWork)
        #expect(await job.value == [.cancelled(source: files[0])])
        #expect(try contents(of: dir) == ["slow.png"])
        #expect(publisher.live.isEmpty)
        #expect(sounds.isEmpty)
    }

    @Test func noUnattendedJobStartsWhileQuitting() async throws {
        let (dir, files) = try pngs("a", "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gates = Gates()
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: gates)])
        await coordinator.cancelAll(waitingAtMost: .milliseconds(50))

        let refused = await coordinator.runUnattended(toJPG(files), verb: "Converting")

        #expect(refused == files.map { .cancelled(source: $0) })
        #expect(await gates.staging.isEmpty)
        #expect(!coordinator.hasRunningWork)
        #expect(try contents(of: dir) == ["a.png", "b.png"])

        // Once the quit is called off the same request runs, so the refusal above was the quit's.
        coordinator.quitWasCancelled()
        #expect(await coordinator.runUnattended(toJPG(files), verb: "Converting").allSatisfy(Self.isSuccess))
    }
}
