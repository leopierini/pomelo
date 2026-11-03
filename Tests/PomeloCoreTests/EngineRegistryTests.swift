import Foundation
import os
import Testing
import PomeloTestSupport
@testable import PomeloCore

@Test func plannerUsesOnlyAvailableEngines() async {
    let reg = EngineRegistry(engines: [
        FakeEngine(id: "on", edges: [.init(from: "png", to: "jpg", engineID: "on", cost: 10, flags: [])]),
        FakeEngine(id: "off", edges: [.init(from: "png", to: "webp", engineID: "off", cost: 10, flags: [])], available: false),
    ], priority: ["on", "off"])
    let p = await reg.planner()
    #expect(p.route(from: "png", to: "jpg") != nil)
    #expect(p.route(from: "png", to: "webp") == nil)
}

@Test func statusesReportMissing() async {
    let reg = EngineRegistry(engines: [FakeEngine(id: "off", edges: [], available: false)], priority: [])
    #expect(await reg.statuses().first?.availability == .missing(installHint: "fake"))
}

@Test func plannerIncludingMissing() async {
    let reg = EngineRegistry(engines: [FakeEngine(id: "off", edges: [.init(from: "png", to: "webp", engineID: "off", cost: 10, flags: [])], available: false)], priority: [])
    #expect(await reg.planner().route(from: "png", to: "webp") == nil)
    #expect(await reg.planner(includingMissing: true).route(from: "png", to: "webp") != nil)
    #expect(await reg.installHints()["off"] == "off|fake")
}

@Test func installHintsOmitAvailableEngines() async {
    let reg = EngineRegistry(engines: [
        FakeEngine(id: "on", edges: []),
        FakeEngine(id: "off", edges: [], available: false),
    ], priority: [])
    let hints = await reg.installHints()
    #expect(hints["on"] == nil)
    #expect(hints.count == 1)
}

@Test func templateValues() {
    let o = PresetOptions(quality: 0.8)
    #expect(o.templateValue(for: "quality") == "80")
    #expect(o.templateValue(for: "audioBitrate") == "192k")
    #expect(o.templateValue(for: "nope") == nil)
}

@Test func builtInPresetsHaveUniqueIDs() {
    #expect(Set(Preset.builtIns.map(\.id)).count == Preset.builtIns.count)
}

@Test func presetJSONWithoutCategoriesDecodes() throws {
    let json = Data(#"{"id":"x","name":"X","target":"png","options":{"quality":0.5,"stripMetadata":false,"videoCodec":"h264","audioBitrate":"192k","pdfRenderDPI":150}}"#.utf8)
    let preset = try JSONDecoder().decode(Preset.self, from: json)
    #expect(preset.categories == nil)
    #expect(preset.id == "x")
    #expect(Preset.builtIns.first { $0.id == "half-size" }?.categories == [.image])
    #expect(Preset.builtIns.first { $0.id == "compress" }?.categories == [.image, .pdf, .video])
}

@Test func templateValuesRenderNumbersAndNil() {
    let o = PresetOptions(scale: 0.5, maxPixelSize: 100, videoMaxHeight: 1080)
    #expect(o.templateValue(for: "scale") == "0.5")
    #expect(o.templateValue(for: "maxPixelSize") == "100")
    #expect(o.templateValue(for: "videoMaxHeight") == "1080")
    #expect(o.templateValue(for: "pdfRenderDPI") == "150")
    #expect(PresetOptions(scale: 2).templateValue(for: "scale") == "2")
    #expect(PresetOptions().templateValue(for: "scale") == nil)
    #expect(PresetOptions().templateValue(for: "maxPixelSize") == nil)
}

private let fakePNG = FileFormat(id: "png", displayName: "PNG", category: .image, extensions: ["png"], utTypeIdentifier: nil)
private let fakeJPG = FileFormat(id: "jpg", displayName: "JPG", category: .image, extensions: ["jpg", "jpeg"], utTypeIdentifier: nil)

@Test func fakeEngineWritesSuggestedOutput() async throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appending(path: "a.b.PNG")
    try Data("hi".utf8).write(to: input)
    let step = ConversionStep(input: input, stagingDirectory: dir, from: fakePNG, to: fakeJPG, options: PresetOptions())
    #expect(step.suggestedOutput.lastPathComponent == "a.b.jpg")
    let out = try await FakeEngine(id: "f", edges: []).convert(step) { _ in }
    #expect(out == step.suggestedOutput)
    #expect(try String(contentsOf: out, encoding: .utf8) == "hi\n->jpg")
    let failing = FakeEngine(id: "f", edges: [], failOnStem: "a.b")
    await #expect(throws: FakeEngine.Failure.self) { try await failing.convert(step) { _ in } }
}

@Test func fakeEngineDelayIsCancellable() async throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appending(path: "a.png")
    try Data("x".utf8).write(to: input)
    let step = ConversionStep(input: input, stagingDirectory: dir, from: fakePNG, to: fakeJPG, options: PresetOptions())
    let engine = FakeEngine(id: "f", edges: [], delay: .seconds(30))
    let task = Task { try await engine.convert(step) { _ in } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

/// Counts its version probes; the version names the probe ("v1", "v2"…).
private struct VersionCountingEngine: ConversionEngine {
    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    let id: EngineID
    let probes = Probes()
    var displayName: String { id.rawValue }
    var maxConcurrentJobs: Int { 1 }
    func availability() async -> EngineAvailability { .available(version: nil) }
    func version() async -> String? { "v\(probes.next())" }
    func edges() -> [ConversionEdge] { [] }
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { step.input }
}

@Test func aVersionIsProbedOnceUntilTheNextRefresh() async {
    let engine = VersionCountingEngine(id: "tool")
    let reg = EngineRegistry(engines: [engine, FakeEngine(id: "off", edges: [], available: false)], priority: [])
    #expect(await reg.statuses().first?.availability == .available(version: "v1"))
    #expect(await reg.statuses().first?.availability == .available(version: "v1"))
    #expect(engine.probes.count == 1)
    await reg.refresh()
    #expect(engine.probes.count == 1)
    #expect(await reg.statuses().first?.availability == .available(version: "v2"))
    #expect(await reg.statuses().last?.availability == .missing(installHint: "fake"))
}

/// Holds every version probe until opened, counting the probes that started.
private actor ProbeGate {
    private(set) var started = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func probe() async {
        started += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

private struct GatedVersionEngine: ConversionEngine {
    let id: EngineID
    let gate: ProbeGate
    var displayName: String { id.rawValue }
    var maxConcurrentJobs: Int { 1 }
    func availability() async -> EngineAvailability { .available(version: nil) }
    func version() async -> String? {
        await gate.probe()
        return "\(id.rawValue) 1.0"
    }
    func edges() -> [ConversionEdge] { [] }
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { step.input }
}

private func startedProbes(_ gate: ProbeGate, reach count: Int) async -> Bool {
    for _ in 0..<200 {
        if await gate.started >= count { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Settings › Engines waits for these: each engine's version command runs at the same time, not one after another.
@Test func versionsAreProbedConcurrently() async {
    let gate = ProbeGate()
    let reg = EngineRegistry(engines: [GatedVersionEngine(id: "a", gate: gate), GatedVersionEngine(id: "b", gate: gate)],
                             priority: [])
    let statuses = Task { await reg.statuses() }
    #expect(await startedProbes(gate, reach: 2))
    await gate.open()
    #expect(await statuses.value.map(\.availability) == [.available(version: "a 1.0"), .available(version: "b 1.0")])
}

/// Two callers at once (the pane and `pomelo engines` never are, but a refresh and a reload can be) share each probe.
@Test func concurrentCallersShareEachProbe() async {
    let gate = ProbeGate()
    let reg = EngineRegistry(engines: [GatedVersionEngine(id: "a", gate: gate), GatedVersionEngine(id: "b", gate: gate)],
                             priority: [])
    let first = Task { await reg.statuses() }
    #expect(await startedProbes(gate, reach: 1))
    let second = Task { await reg.statuses() }
    try? await Task.sleep(for: .milliseconds(100))
    await gate.open()
    let versions = [.available(version: "a 1.0"), .available(version: "b 1.0")] as [EngineAvailability]
    #expect(await first.value.map(\.availability) == versions)
    #expect(await second.value.map(\.availability) == versions)
    #expect(await gate.started == 2)
}

@Test func anUnsupportedEngineIsPlannedOnlyWithTheMissingOnes() async {
    let reg = EngineRegistry(engines: [
        FakeEngine(id: "on", edges: []),
        FakeEngine(id: "off", edges: [], available: false),
        FakeEngine(id: "old", edges: [.init(from: "m4a", to: "txt", engineID: "old", cost: 10, flags: [])],
                   unsupportedReason: "Needs macOS 26."),
    ], priority: [])
    #expect(await reg.planner().route(from: "m4a", to: "txt") == nil)
    #expect(await reg.planner(includingMissing: true).route(from: "m4a", to: "txt") != nil)
    #expect(await reg.unsupportedReasons() == ["old": "Needs macOS 26."])
    #expect(await reg.installHints() == ["off": "off|fake"])
    #expect(await reg.statuses().last?.availability == .unsupported(reason: "Needs macOS 26."))
}

@Test func languageAndOutputFormatDecodeAndDefaultToNil() throws {
    #expect(PresetOptions().language == nil && PresetOptions().outputFormat == nil)
    let old = try JSONDecoder().decode(PresetOptions.self, from: Data(#"{"quality":0.5}"#.utf8))
    #expect(old.language == nil && old.outputFormat == nil)
    let set = try JSONDecoder().decode(PresetOptions.self, from: Data(#"{"language":"it-IT","outputFormat":"VTT"}"#.utf8))
    #expect(set.language == "it-IT" && set.outputFormat == "vtt")
    #expect(try JSONDecoder().decode(PresetOptions.self, from: JSONEncoder().encode(set)) == set)
    // Unset, they stay out of the blob: a Phase 6 blob is written back unchanged.
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PresetOptions())) as? [String: Any]
    #expect(encoded?["language"] == nil && encoded?["outputFormat"] == nil)
}

@Test func optionsAspectCodes() throws {
    #expect(PresetOptions().aspect == nil)
    #expect(try JSONDecoder().decode(PresetOptions.self, from: Data(#"{"quality":0.5}"#.utf8)).aspect == nil)
    let set = PresetOptions(aspect: "4:5")
    #expect(try JSONDecoder().decode(PresetOptions.self, from: JSONEncoder().encode(set)) == set)
    #expect(try JSONDecoder().decode(PresetOptions.self, from: Data(#"{"aspect":"16:9"}"#.utf8)).aspect == "16:9")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PresetOptions())) as? [String: Any]
    #expect(encoded?["aspect"] == nil)
}

/// An engine whose availability is set by the test, standing in for Apple Intelligence getting ready.
private final class ChangingEngine: ConversionEngine, @unchecked Sendable {
    let id: EngineID
    let displayName: String
    let maxConcurrentJobs = 1
    let availabilityIsVolatile: Bool
    private let state: OSAllocatedUnfairLock<(availability: EngineAvailability, asked: Int)>

    init(id: EngineID, availability: EngineAvailability, volatile: Bool = true) {
        self.id = id
        displayName = id.rawValue
        availabilityIsVolatile = volatile
        state = OSAllocatedUnfairLock(initialState: (availability, 0))
    }

    var asked: Int { state.withLock { $0.asked } }

    func set(_ availability: EngineAvailability) { state.withLock { $0.availability = availability } }

    func availability() async -> EngineAvailability {
        state.withLock {
            $0.asked += 1
            return $0.availability
        }
    }

    func edges() -> [ConversionEdge] { [ConversionEdge(from: "txt", to: "md", engineID: id, cost: 10, flags: [], operation: "summarize")] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Data("summary".utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

private let notReady = EngineAvailability.unsupported(reason: "Apple Intelligence is still getting ready. Try again in a few minutes.")

/// A login launch caches "still getting ready"; asking the volatile engines again clears it for every reader of the
/// registry, the wheel's next plan included, and tells the change handler once.
@Test func recheckingVolatileEnginesUpdatesWhatThePlannersSee() async {
    let model = ChangingEngine(id: "model", availability: notReady)
    let fixed = ChangingEngine(id: "fixed", availability: .unsupported(reason: "Needs macOS 26."), volatile: false)
    let registry = EngineRegistry(engines: [model, fixed], priority: ["model", "fixed"])
    let changes = OSAllocatedUnfairLock(initialState: 0)
    await registry.setChangeHandler { changes.withLock { $0 += 1 } }
    #expect(await registry.unsupportedReasons()["model"] != nil)
    #expect(await registry.planner().route(from: "txt", operation: "summarize", to: "md") == nil)

    model.set(.available(version: nil))
    await registry.recheckVolatileEngines()

    #expect(await registry.unsupportedReasons() == ["fixed": "Needs macOS 26."])
    #expect(await registry.planner().route(from: "txt", operation: "summarize", to: "md") != nil)
    #expect(changes.withLock { $0 } == 1)
    #expect(fixed.asked == 1)

    await registry.recheckVolatileEngines()
    #expect(changes.withLock { $0 } == 1, "an unchanged answer tells nobody")
}

@Test func recheckingBeforeTheFirstAnswerAsksNothing() async {
    let model = ChangingEngine(id: "model", availability: notReady)
    let registry = EngineRegistry(engines: [model], priority: ["model"])
    await registry.recheckVolatileEngines()
    #expect(model.asked == 0)
}

/// The job that finds the model ready runs, though the wheel was planned while it was not.
@Test func aJobAsksAVolatileEngineAgainBeforeItRuns() async throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appending(path: "a.txt")
    try Data("text".utf8).write(to: source)
    let model = ChangingEngine(id: "model", availability: notReady)
    let registry = EngineRegistry(engines: [model], priority: ["model"])
    let runner = JobRunner(registry: registry, destinations: DestinationResolver(downloadsFolder: dir, isWritable: { _ in true }))
    let request = ConversionRequest(inputs: [source], target: "md", operation: "summarize")

    let first = await runner.run(request)
    model.set(.available(version: nil))
    let second = await runner.run(request)

    #expect(first == [.failed(source: source, error: .engineUnsupported(engine: "model", reason: "Apple Intelligence is still getting ready. Try again in a few minutes."))])
    #expect(second == [.succeeded(source: source, outputs: [dir.appending(path: "a.md")], note: nil)])
}
