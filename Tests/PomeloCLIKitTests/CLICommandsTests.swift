import Foundation
import Testing
import os
import PomeloCore
import PomeloEngines
import PomeloTestSupport
@testable import PomeloCLIKit

private func edge(_ from: FormatID, _ to: FormatID, _ engine: EngineID, flags: EdgeFlags = []) -> ConversionEdge {
    ConversionEdge(from: from, to: to, engineID: engine, cost: 10, flags: flags)
}

/// png→jpg (lossy, fails on stem "bad"), jpg→webp, png→png (the "half-size" preset's same-format edge), and a
/// missing engine "ghost" that offers png→mp3 and so must never make mp3 reachable.
private func makeRegistry() -> EngineRegistry {
    let engines: [any ConversionEngine] = [
        FakeEngine(id: "pngjpg", edges: [edge("png", "jpg", "pngjpg", flags: .lossy)], failOnStem: "bad"),
        FakeEngine(id: "jpgwebp", edges: [edge("jpg", "webp", "jpgwebp")]),
        FakeEngine(id: "resize", edges: [edge("png", "png", "resize")]),
        FakeEngine(id: "ghost", edges: [edge("png", "mp3", "ghost")], available: false),
    ]
    return EngineRegistry(engines: engines, priority: engines.map(\.id))
}

private func write(_ name: String, in dir: URL) throws -> URL {
    let url = dir.appending(path: name, directoryHint: .notDirectory)
    try Data("data of \(name)".utf8).write(to: url)
    return url
}

private func convert(
    _ files: [URL], to target: String? = nil, preset: String? = nil, options: String? = nil, outputDir: URL? = nil,
    json: Bool = false, registry: EngineRegistry = makeRegistry(), downloads: URL
) async -> CLIOutput {
    await CLICommands.convert(
        files: files, to: target, preset: preset, options: options, outputDir: outputDir, registry: registry,
        downloads: downloads, json: json
    )
}

/// An engine for operation edges that remembers the options it was handed.
private struct OptionsSpyEngine: ConversionEngine {
    let id: EngineID = "spy"
    let displayName = "spy"
    let maxConcurrentJobs = 1
    let operation: String
    let seen = OSAllocatedUnfairLock(initialState: [PresetOptions]())

    func availability() async -> EngineAvailability { .available(version: nil) }
    func edges() -> [ConversionEdge] {
        [ConversionEdge(from: "png", to: "png", engineID: id, cost: 10, flags: [], operation: operation)]
    }
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        seen.withLock { $0.append(step.options) }
        try Data("out".utf8).write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}

private func spyRegistry(_ spy: OptionsSpyEngine) -> EngineRegistry {
    EngineRegistry(engines: [spy], priority: [spy.id])
}

private func rawJSON(_ output: CLIOutput) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
}

@Test func convertJSONAndExitCodes() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let bad = try write("bad.png", in: dir)

    let output = await convert([good, bad], to: "jpg", json: true, downloads: dir)
    let decoded = try JSONDecoder().decode(CLIConvertJSON.self, from: Data(output.stdout.utf8))

    #expect(decoded.results.count == 2)
    #expect(decoded.results[0].status == .succeeded)
    #expect(decoded.results[0].source == good.path)
    #expect(decoded.results[0].outputs == [dir.appending(path: "good.jpg").path])
    #expect(decoded.results[1].status == .failed)
    #expect(decoded.results[1].outputs.isEmpty)
    #expect(decoded.results[1].error?.hasPrefix("pngjpg: ") == true)
    #expect(output.exitCode == 1)
}

@Test func convertAllSucceededExitsZero() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "jpeg", downloads: dir)

    #expect(output.exitCode == 0)
    #expect(output.stdout.contains("✓ good.png → good.jpg"))
}

@Test func unknownTargetIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "zzz", downloads: dir)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("Unknown format: zzz"))
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "good.zzz").path))
}

@Test func usageErrorsInJSONModeUseTheErrorShape() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "zzz", json: true, downloads: dir)

    #expect(output.exitCode == 2)
    #expect(try rawJSON(output) as? [String: String] == ["error": "Unknown format: zzz"])
}

@Test func presetById() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], preset: "half-size", downloads: dir)

    #expect(output.exitCode == 0)
    #expect(output.stdout.contains("→ good-half.png"))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "good-half.png").path))
}

@Test func unknownPresetListsAvailableIDs() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], preset: "nope", downloads: dir)

    #expect(output.exitCode == 2)
    let ids = Preset.builtIns.map(\.id).joined(separator: ", ")
    #expect(output.stdout.contains("Unknown preset: nope (available: \(ids))"))
}

@Test func cliListsTheNewPresets() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], preset: "nope", downloads: dir)

    let listed = try #require(output.stdout.components(separatedBy: "(available: ").last)
    let ids = listed.trimmingCharacters(in: CharacterSet(charactersIn: ")\n")).components(separatedBy: ", ")
    #expect(ids.starts(with: ["jpg-80", "png", "heic", "webp-80", "compress"]))
    #expect(ids.contains("extract-archive") && ids.contains("merge-pdfs"))
    #expect(!ids.contains("make-zip") && !ids.contains("copy-paths") && !ids.contains("compress-video"))
}

@Test func presetAndTargetTogetherIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "jpg", preset: "half-size", downloads: dir)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("Pass either --to or --preset, not both"))
}

@Test func neitherTargetNorPresetIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], downloads: dir)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("Pass --to <format> or --preset <id>"))
}

@Test func noFilesIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let output = await convert([], to: "jpg", downloads: dir)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("No files given"))
}

@Test func missingInputFileFailsThatFileOnly() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = dir.appending(path: "absent.png")

    let output = await convert([missing], to: "jpg", json: true, downloads: dir)
    let decoded = try JSONDecoder().decode(CLIConvertJSON.self, from: Data(output.stdout.utf8))

    #expect(output.exitCode == 1)
    #expect(decoded.results[0].status == .failed)
    #expect(decoded.results[0].error == "file not found")
}

@Test func convertNotesFallbackToDownloads() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: source) }
    let good = try write("good.png", in: source)
    // A read-only source folder sends the output to the downloads folder.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }

    let output = await convert([good], to: "jpg", json: true, downloads: dir)
    let results = try #require(try rawJSON(output)["results"] as? [[String: Any]])

    #expect(output.exitCode == 0)
    #expect(results[0]["note"] as? String == "fellBackToDownloads")
    #expect(results[0]["outputs"] as? [String] == [dir.appending(path: "good.jpg").path])

    // The first run took the name, so the human run gets "good 2.jpg"; only the note is under test here.
    let human = await convert([good], to: "jpg", downloads: dir)
    #expect(human.stdout.contains("(saved to Downloads — source folder not writable)"))
}

@Test func optionalJSONFieldsEncodeAsExplicitNull() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let converted = try rawJSON(await convert([good], to: "jpg", json: true, downloads: dir))
    let result = try #require((converted["results"] as? [[String: Any]])?.first)
    #expect(result["note"] is NSNull)
    #expect(result["error"] is NSNull)

    let engines = try rawJSON(await CLICommands.engines(registry: makeRegistry(), json: true))
    let engine = try #require((engines["engines"] as? [[String: Any]])?.first)
    #expect(engine["version"] is NSNull)
    #expect(engine["install"] is NSNull)

    let routes = try rawJSON(await CLICommands.routes(from: "png", to: "mp3", registry: makeRegistry(), json: true))
    #expect(routes["cost"] is NSNull)
}

@Test func jsonIsPrettyPrintedWithSortedKeysAndUnescapedSlashes() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "jpg", json: true, downloads: dir)

    #expect(output.stdout.contains("\n"))
    #expect(!output.stdout.contains("\\/"))
    let error = try #require(output.stdout.range(of: "\"error\""))
    let note = try #require(output.stdout.range(of: "\"note\""))
    let outputs = try #require(output.stdout.range(of: "\"outputs\""))
    let source = try #require(output.stdout.range(of: "\"source\""))
    #expect(error.lowerBound < note.lowerBound && note.lowerBound < outputs.lowerBound && outputs.lowerBound < source.lowerBound)
}

@Test func targetsListsMultiHop() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await CLICommands.targets(file: good, registry: makeRegistry(), json: true)
    let decoded = try JSONDecoder().decode(CLITargetsJSON.self, from: Data(output.stdout.utf8))

    #expect(output.exitCode == 0)
    #expect(decoded.source == good.path)
    #expect(decoded.targets.map(\.format) == ["jpg", "webp"])
    let jpg = try #require(decoded.targets.first { $0.format == "jpg" })
    #expect(jpg.hops == 1 && jpg.engines == ["pngjpg"] && jpg.flags == ["lossy"] && jpg.category == "image")
    let webp = try #require(decoded.targets.first { $0.format == "webp" })
    #expect(webp.hops == 2 && webp.engines == ["pngjpg", "jpgwebp"] && webp.flags == ["lossy"])

    let human = await CLICommands.targets(file: good, registry: makeRegistry(), json: false)
    #expect(human.stdout.contains("webp  (2 hops via pngjpg → jpgwebp) [lossy]"))
    #expect(human.stdout.contains("jpg  (1 hop via pngjpg) [lossy]"))
}

@Test func targetsOnUnknownFormatIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = try write("mystery.qqq", in: dir)

    let output = await CLICommands.targets(file: file, registry: makeRegistry(), json: false)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("Unknown format: qqq"))
}

@Test func enginesShowsMissingWithInstallHint() async throws {
    let output = await CLICommands.engines(registry: makeRegistry(), json: true)
    let decoded = try JSONDecoder().decode(CLIEnginesJSON.self, from: Data(output.stdout.utf8))

    #expect(output.exitCode == 0)
    let ghost = try #require(decoded.engines.first { $0.id == "ghost" })
    #expect(ghost.status == .missing)
    #expect(ghost.install == "fake")
    #expect(ghost.version == nil)
    let available = try #require(decoded.engines.first { $0.id == "pngjpg" })
    #expect(available.status == .available)
    #expect(decoded.pluginErrors.isEmpty)

    let human = await CLICommands.engines(registry: makeRegistry(), json: false)
    #expect(human.stdout.contains("ghost  ghost  missing — fake"))
    #expect(human.stdout.contains("pngjpg  pngjpg  available"))
}

@Test func enginesReportsPluginFailures() async throws {
    let broken = URL(fileURLWithPath: "/plugins/broken.pomelo-plugin.json")

    let json = await CLICommands.engines(registry: makeRegistry(), json: true, pluginFailures: [broken])
    #expect(try rawJSON(json)["pluginErrors"] as? [String] == [broken.path])

    let human = await CLICommands.engines(registry: makeRegistry(), json: false, pluginFailures: [broken])
    #expect(human.stdout.contains("⚠︎ Could not load plugin: /plugins/broken.pomelo-plugin.json"))
}

@Test func routesNullWhenUnreachable() async throws {
    let output = await CLICommands.routes(from: "png", to: "mp3", registry: makeRegistry(), json: true)
    let decoded = try JSONDecoder().decode(CLIRoutesJSON.self, from: Data(output.stdout.utf8))

    #expect(decoded.steps.isEmpty)
    #expect(decoded.cost == nil)
    #expect(output.exitCode == 1)

    let human = await CLICommands.routes(from: "png", to: "mp3", registry: makeRegistry(), json: false)
    #expect(human.stdout == "No route from png to mp3")
}

@Test func routesReportsStepsAndCost() async throws {
    let output = await CLICommands.routes(from: "png", to: "webp", registry: makeRegistry(), json: true)
    let decoded = try JSONDecoder().decode(CLIRoutesJSON.self, from: Data(output.stdout.utf8))

    #expect(output.exitCode == 0)
    #expect(decoded.cost == 30)
    #expect(decoded.steps == [
        CLIRouteStepJSON(from: "png", to: "jpg", engine: "pngjpg"),
        CLIRouteStepJSON(from: "jpg", to: "webp", engine: "jpgwebp"),
    ])

    let human = await CLICommands.routes(from: "png", to: "webp", registry: makeRegistry(), json: false)
    #expect(human.stdout == "png → webp via pngjpg → jpgwebp (cost 30)")
}

@Test func routesWithUnknownFormatIsUsageError() async throws {
    let output = await CLICommands.routes(from: "png", to: "zzz", registry: makeRegistry(), json: false)

    #expect(output.exitCode == 2)
    #expect(output.stdout.contains("Unknown format: zzz"))
}

@Test func missingOutputFolderIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let folder = dir.appending(path: "absent", directoryHint: .isDirectory)

    let human = await convert([good], to: "jpg", outputDir: folder, downloads: dir)
    #expect(human.exitCode == 2)
    #expect(human.stdout == "Output folder not found: \(folder.path)")

    let json = await convert([good], to: "jpg", outputDir: folder, json: true, downloads: dir)
    #expect(json.exitCode == 2)
    #expect(try rawJSON(json) as? [String: String] == ["error": "Output folder not found: \(folder.path)"])
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "good.jpg").path))
}

@Test func outputFolderThatIsAFileIsUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let file = try write("notes.txt", in: dir)

    let human = await convert([good], preset: "half-size", outputDir: file, downloads: dir)
    #expect(human.exitCode == 2)
    #expect(human.stdout == "Not a folder: \(file.path)")

    let json = await convert([good], preset: "half-size", outputDir: file, json: true, downloads: dir)
    #expect(json.exitCode == 2)
    #expect(try rawJSON(json) as? [String: String] == ["error": "Not a folder: \(file.path)"])
}

@Test(arguments: [(target: "jpg", preset: nil, name: "good.jpg"), (target: nil, preset: "half-size", name: "good-half.png")]
      as [(target: String?, preset: String?, name: String)])
func outputFolderReceivesTheOutput(target: String?, preset: String?, name: String) async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let folder = dir.appending(path: "out", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    let output = await convert([good], to: target, preset: preset, outputDir: folder, json: true, downloads: dir)
    let result = try #require((try rawJSON(output)["results"] as? [[String: Any]])?.first)

    #expect(output.exitCode == 0)
    #expect(result["outputs"] as? [String] == [folder.appending(path: name).path])
    #expect(result["note"] is NSNull)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path))
}

@Test func cliRunsACombinePresetAndListsTheOutputForEachInput() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try write("b.pdf", in: dir)
    let a = try write("a.pdf", in: dir)
    let engine = FakeCombiningEngine(id: "pdfkit", edges: [
        ConversionEdge(from: "pdf", to: "pdf", engineID: "pdfkit", cost: 10, flags: [], operation: "combine"),
    ])

    let output = await CLICommands.convert(
        files: [b, a], to: nil, preset: "merge-pdfs", outputDir: nil,
        registry: EngineRegistry(engines: [engine], priority: ["pdfkit"]), downloads: dir, json: true
    )
    let decoded = try JSONDecoder().decode(CLIConvertJSON.self, from: Data(output.stdout.utf8))

    let merged = dir.appending(path: "b-merged.pdf").path
    #expect(output.exitCode == 0)
    #expect(decoded.results.map(\.source) == [b.path, a.path])
    #expect(decoded.results.map(\.status) == [.succeeded, .succeeded])
    #expect(decoded.results.map(\.outputs) == [[merged], [merged]])
}

@Test func optionsOverrideOnlyTheKeysGiven() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let spy = OptionsSpyEngine(operation: "compress")

    let output = await convert(
        [good], preset: "compress", options: #"{"targetBytes":5}"#, registry: spyRegistry(spy), downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    let options = try #require(spy.seen.withLock { $0.first })
    #expect(options.quality == 0.7)
    #expect(options.videoMaxHeight == 1080)
    #expect(options.targetBytes == 5)
}

@Test func optionsCanOverrideAPresetKeyAndCarryAnEdit() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let spy = OptionsSpyEngine(operation: "crop")
    let json = #"{"quality":0.5,"edit":{"kind":"crop","x":0,"y":0,"width":0.5,"height":0.5}}"#

    let output = await convert([good], preset: "crop", options: json, registry: spyRegistry(spy), downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    let options = try #require(spy.seen.withLock { $0.first })
    #expect(options.quality == 0.5)
    #expect(options.edit == .crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)))
}

/// P266: Smart crop's Shape reaches the engine from `--options`, as the evals' square case passes it.
@Test func optionsCarrySmartCropsShape() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let spy = OptionsSpyEngine(operation: "smart-crop")

    let output = await convert(
        [good], preset: "smart-crop", options: #"{"aspect":"1:1"}"#, registry: spyRegistry(spy), downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    let options = try #require(spy.seen.withLock { $0.first })
    #expect(options.aspect == "1:1" && options.quality == 0.92)
}

@Test func optionsWorkWithATargetFormatToo() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], to: "jpg", options: #"{"quality":0.4}"#, downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
}

@Test func badOptionsAreAUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    for bad in ["{", "[1]", #"{"edit":{"kind":"blur"}}"#, #"{"edit":{"kind":"trim","start":1}}"#, #"{"quality":"high"}"#] {
        let output = await convert([good], preset: "compress", options: bad, downloads: dir)
        #expect(output.exitCode == 2, "\(bad)")
        #expect(output.stdout.hasPrefix("invalid --options: "), "\(bad): \(output.stdout)")
        #expect(!output.stdout.contains("\n"), "\(bad): \(output.stdout)")
    }
    let unknownKind = await convert([good], preset: "compress", options: #"{"edit":{"kind":"blur"}}"#, downloads: dir)
    #expect(unknownKind.stdout.contains("blur"))
    #expect(try contentsNames(of: dir) == ["good.png"])
}

@Test func theResizeAndRotatePresetsTakeTheirEditsFromOptions() async throws {
    let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
    for (preset, json, name, size) in [
        ("resize", #"{"edit":{"kind":"resize","mode":"width","width":200}}"#, "photo-200x150.png", (200, 150)),
        ("rotate", #"{"edit":{"kind":"rotate","quarterTurns":1,"flipHorizontal":false}}"#, "photo-rotated.png", (300, 400)),
    ] {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appending(path: "photo.png")
        try FileManager.default.moveItem(at: try Fixtures.png(width: 400, height: 300, in: dir), to: photo)
        let bare = dir.appending(path: "bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: false)
        let unedited = try Fixtures.png(width: 40, height: 30, in: bare)

        let missing = await convert([unedited], preset: preset, registry: registry, downloads: dir)
        #expect(missing.exitCode == 2, "\(preset)")
        #expect(missing.stdout == #"the \#(preset) preset needs --options with "edit" or "targetBytes" (see docs/cli-json.md)"#)

        let output = await convert([photo], preset: preset, options: json, registry: registry, downloads: dir)

        #expect(output.exitCode == 0, "\(output.stdout)")
        let written = dir.appending(path: name)
        #expect(Fixtures.imageSize(written) == CGSize(width: size.0, height: size.1), "\(preset)")
    }
}

@Test func badOptionsInJSONModeUseTheErrorShape() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    let output = await convert([good], preset: "compress", options: "{", json: true, downloads: dir)

    #expect(output.exitCode == 2)
    let error = try #require(try rawJSON(output)["error"] as? String)
    #expect(error.hasPrefix("invalid --options: "))
}

@Test func anEditorPresetWithoutOptionsIsAUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let message = #"the trim preset needs --options with "edit" or "targetBytes" (see docs/cli-json.md)"#

    let bare = await convert([good], preset: "trim", downloads: dir)
    #expect(bare.exitCode == 2)
    #expect(bare.stdout == message)

    let unrelated = await convert([good], preset: "trim", options: #"{"quality":0.5}"#, downloads: dir)
    #expect(unrelated.exitCode == 2)
    #expect(unrelated.stdout == message)
}

@Test func anEditorPresetWithAnEditPassesTheCheck() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let spy = OptionsSpyEngine(operation: "target-size")

    let output = await convert(
        [good], preset: "compress-to-size", options: #"{"targetBytes":1000000}"#, registry: spyRegistry(spy),
        downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    #expect(spy.seen.withLock { $0.first?.targetBytes } == 1_000_000)
}

@Test func aTargetSizeThatIsNotPositiveIsAUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)

    for bad in [#"{"targetBytes":0}"#, #"{"targetBytes":-5}"#] {
        let output = await convert([good], preset: "compress-to-size", options: bad, downloads: dir)
        #expect(output.exitCode == 2, "\(bad)")
        #expect(output.stdout == "invalid --options: targetBytes must be more than 0", "\(bad)")
    }
    #expect(try contentsNames(of: dir) == ["good.png"])
}

private func contentsNames(of dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

@Test func theResultIsNamedAfterTheSize() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let noisy = try Fixtures.noisyImage(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", quality: 0.95, in: dir)
    let photo = dir.appending(path: "photo.jpg")
    try FileManager.default.moveItem(at: noisy, to: photo)
    let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)

    let output = await convert(
        [photo], preset: "compress-to-size", options: #"{"targetBytes":500000}"#, registry: registry, downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    let result = dir.appending(path: "photo-under-500kb.jpg")
    #expect(FileManager.default.fileExists(atPath: result.path))
    let size = try #require(try result.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(size <= 500_000)
}

@Test func theSizeSuffixIsOnlyForTargetSize() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let good = try write("good.png", in: dir)
    let spy = OptionsSpyEngine(operation: "compress")

    let output = await convert(
        [good], preset: "compress", options: #"{"targetBytes":500000}"#, registry: spyRegistry(spy), downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "good-compressed.png").path))
}

// MARK: - Engines this Mac can't run, and a tool's output format

private func toolEdge(_ from: FormatID, _ to: FormatID, _ engine: EngineID, _ operation: String) -> ConversionEdge {
    ConversionEdge(from: from, to: to, engineID: engine, cost: 10, flags: [], operation: operation)
}

/// `subs` makes srt or vtt from m4a; `speech` can't run here.
private let subtitlePreset = Preset(id: "subs", name: "Subs", target: "srt", nameSuffix: nil, operation: "subs")
private let transcribePreset = Preset(id: "transcribe", name: "Transcribe", target: "txt", operation: "transcribe")

private func toolRegistry() -> EngineRegistry {
    let engines: [any ConversionEngine] = [
        FakeEngine(id: "subs", edges: [toolEdge("m4a", "srt", "subs", "subs"), toolEdge("m4a", "vtt", "subs", "subs")]),
        FakeEngine(id: "speech", edges: [toolEdge("m4a", "txt", "speech", "transcribe")],
                   unsupportedReason: "Needs macOS 26."),
    ]
    return EngineRegistry(engines: engines, priority: engines.map(\.id))
}

private func runTool(
    _ files: [URL], preset: String, options: String? = nil, json: Bool = false, downloads: URL
) async -> CLIOutput {
    await CLICommands.convert(
        files: files, to: nil, preset: preset, options: options, outputDir: nil, registry: toolRegistry(),
        downloads: downloads, json: json, presets: [subtitlePreset, transcribePreset]
    )
}

@Test func enginesShowsAnUnsupportedEngineWithItsReason() async throws {
    let engines = try #require(try rawJSON(await CLICommands.engines(registry: toolRegistry(), json: true))["engines"]
        as? [[String: Any]])
    let speech = try #require(engines.first { $0["id"] as? String == "speech" })
    #expect(speech["status"] as? String == "unsupported")
    #expect(speech["reason"] as? String == "Needs macOS 26.")
    #expect(speech["install"] is NSNull && speech["version"] is NSNull)
    let subs = try #require(engines.first { $0["id"] as? String == "subs" })
    #expect(subs["reason"] is NSNull)

    let human = await CLICommands.engines(registry: toolRegistry(), json: false)
    #expect(human.stdout.contains("speech  speech  unsupported: Needs macOS 26."))
}

@Test func aJobThroughAnUnsupportedEngineFailsWithItsReason() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try write("talk.m4a", in: dir)

    let output = await runTool([audio], preset: "transcribe", json: true, downloads: dir)
    let decoded = try JSONDecoder().decode(CLIConvertJSON.self, from: Data(output.stdout.utf8))
    #expect(output.exitCode == 1)
    // The sentence as written, as the app shows it: no engine id before it.
    #expect(decoded.results.first?.error == "Needs macOS 26.")
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "talk.txt").path))
    let human = await runTool([audio], preset: "transcribe", downloads: dir)
    #expect(human.stdout.hasSuffix("Needs macOS 26.") && !human.stdout.contains("speech:"), "\(human.stdout)")
}

@Test func outputFormatPicksTheToolsTarget() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try write("talk.m4a", in: dir)

    let vtt = await runTool([audio], preset: "subs", options: #"{"outputFormat":"vtt"}"#, downloads: dir)
    #expect(vtt.exitCode == 0)
    #expect(vtt.stdout.contains("✓ talk.m4a → talk.vtt"))
    let plain = await runTool([audio], preset: "subs", downloads: dir)
    #expect(plain.stdout.contains("✓ talk.m4a → talk.srt"))
}

@Test func anOutputFormatTheToolCantMakeIsAUsageError() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try write("talk.m4a", in: dir)

    let output = await runTool([audio], preset: "subs", options: #"{"outputFormat":"pdf"}"#, json: true, downloads: dir)
    #expect(output.exitCode == 2)
    #expect(try rawJSON(output) as? [String: String]
        == ["error": "the subs preset can't make pdf (it makes: srt, vtt)"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["talk.m4a"])
}

@Test func theTranslateResultIsNamedAfterTheTargetLanguage() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let notes = dir.appending(path: "notes.txt")
    try Data("Hello there, my friend. Welcome to the show.\n".utf8).write(to: notes)
    let engine = TranslationEngine(translating: FakeTranslating())
    let registry = EngineRegistry(engines: [engine], priority: [engine.id])

    for (language, name) in [("it", "notes-it.txt"), ("pt-PT", "notes-pt-PT.txt"), ("de-AT", "notes-de-AT.txt")] {
        let output = await convert(
            [notes], preset: "translate", options: #"{"language":"\#(language)"}"#, registry: registry, downloads: dir)

        #expect(output.exitCode == 0, "\(output.stdout)")
        let result = dir.appending(path: name)
        #expect(try String(contentsOf: result, encoding: .utf8) == "HELLO THERE, MY FRIEND. WELCOME TO THE SHOW.\n", "\(name)")
    }
    #expect(try String(contentsOf: notes, encoding: .utf8) == "Hello there, my friend. Welcome to the show.\n")
}

/// The final review's reproduction: a Jekyll post's front matter came back with its keys translated and its words
/// moved across lines. It is the page's data and stays as written; the text after it is translated.
@Test func translatingMarkdownKeepsItsFrontMatterAsWritten() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let frontMatter = """
        ---
        layout: post
        title: "Walking in the mountains"
        date: 2026-10-01
        tags: [travel, hiking]
        ---

        """
    let post = dir.appending(path: "post.md")
    try Data((frontMatter + "\nWe walked for hours in the mountains.\n").utf8).write(to: post)
    let engine = TranslationEngine(translating: FakeTranslating())
    let registry = EngineRegistry(engines: [engine], priority: [engine.id])

    let output = await convert(
        [post], preset: "translate", options: #"{"language":"it"}"#, registry: registry, downloads: dir)

    #expect(output.exitCode == 0, "\(output.stdout)")
    let result = try String(contentsOf: dir.appending(path: "post-it.md"), encoding: .utf8)
    #expect(result == frontMatter + "\nWE WALKED FOR HOURS IN THE MOUNTAINS.\n")
}
