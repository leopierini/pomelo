import Foundation
import Testing
import PomeloTestSupport
@testable import PomeloCore

private func sampleManifest(
    id: String = "sample", displayName: String = "Sample",
    from: [String] = ["txt"], to: [String] = ["md"], cost: Int? = nil, defaultCost: Int? = nil, flags: [String]? = nil,
    names: [String] = ["sample"], searchPaths: [String] = [], arguments: [String] = ["{input}", "{output}"]
) -> PluginManifest {
    PluginManifest(
        id: id, displayName: displayName,
        executable: .init(names: names, searchPaths: searchPaths, versionArguments: nil),
        install: .init(homebrew: "sample"), defaultCost: defaultCost,
        edges: [.init(from: from, to: to, flags: flags, cost: cost, arguments: arguments)]
    )
}

private func format(_ id: String) -> FileFormat {
    FileFormat(id: FormatID(id), displayName: id, category: .text, extensions: [id], utTypeIdentifier: nil)
}

private func step(input: URL, staging: URL, from: String = "txt", to: String = "md") -> ConversionStep {
    ConversionStep(input: input, stagingDirectory: staging, from: format(from), to: format(to), options: .init())
}

@Suite struct PluginTests {
    @Test func expandsPlaceholdersWithoutSplitting() throws {
        let out = try ArgumentTemplate.expand(["-i", "{input}", "-q:v", "{quality:5}", "-b:a", "{audioBitrate:128k}", "{output}"],
            values: ["input": "/a b/in put.mov", "output": "/o/out.mp4"], options: PresetOptions(quality: 0.9))
        #expect(out == ["-i", "/a b/in put.mov", "-q:v", "90", "-b:a", "192k", "/o/out.mp4"])
    }

    @Test func embeddedPlaceholder() throws {
        #expect(try ArgumentTemplate.expand(["-env:UserInstallation=file://{tempDir}/lo"], values: ["tempDir": "/t"], options: .init())
                == ["-env:UserInstallation=file:///t/lo"])
        // Several placeholders in one element, a default, and braces that are not placeholders.
        #expect(try ArgumentTemplate.expand(["{inputStem}-{suffix:x}", "a{b", "}{", "{1}", "{a b}", "{c:d"],
                                            values: ["inputStem": "s"], options: .init())
                == ["s-x", "a{b", "}{", "{1}", "{a b}", "{c:d"])
    }

    @Test func unresolvedThrows() {
        #expect(throws: TemplateError.unresolved("mystery")) { try ArgumentTemplate.expand(["{mystery}"], values: [:], options: .init()) }
    }

    @Test func validationRequiresInputAndOutput() throws {
        var m = sampleManifest(); m.edges[0].arguments = ["{input}"]
        #expect(throws: PluginManifestError.missingOutput(edgeIndex: 0)) { try m.validate() }
        m.edges[0].arguments = ["{input}", "--outdir", "{outputDir}"]; try m.validate()  // outputDir satisfies output
        m.edges[0].arguments = ["{output}"]
        #expect(throws: PluginManifestError.missingInput(edgeIndex: 0)) { try m.validate() }
        m.edges[0].arguments = ["{input}", "{output}"]; m.edges[0].flags = ["lossy", "sparkly"]
        #expect(throws: PluginManifestError.unknownFlag("sparkly")) { try m.validate() }
        m.edges[0].flags = nil; m.id = " "
        #expect(throws: PluginManifestError.emptyID) { try m.validate() }
        m.id = "x"; m.executable.names = []
        #expect(throws: PluginManifestError.noExecutableNames) { try m.validate() }
    }

    @Test func edgesAreCartesianWithDefaultCost() {
        let m = sampleManifest(from: ["mov", "mp4"], to: ["mp3"], cost: nil, defaultCost: nil, flags: ["lossy"])
        #expect(Set(m.conversionEdges().map { "\($0.from)>\($0.to)" }) == ["mov>mp3", "mp4>mp3"])
        #expect(m.conversionEdges().allSatisfy { $0.cost == 30 && $0.flags == .lossy })
    }

    @Test func aliasesInManifestBecomeCanonicalFormats() {
        // jpeg/JPG are known (alias / id); "zzz" is unknown to the catalog and stays as written.
        let m = sampleManifest(from: ["jpeg", "JPG", "zzz"], to: ["tif"])
        #expect(Set(m.conversionEdges().map { "\($0.from)>\($0.to)" }) == ["jpg>tiff", "zzz>tiff"])
    }

    @Test func commandEngineMatchesAliasEdgeForCanonicalStep() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.jpg"); try Data("pix".utf8).write(to: input)
        let manifest = sampleManifest(id: "cp", from: ["jpeg"], to: ["tif"], names: ["cp"], searchPaths: ["/bin"])
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let output = try await engine.convert(step(input: input, staging: staging, from: "jpg", to: "tiff"), progress: { _ in })
        #expect(output == staging.appending(path: "a.tiff"))
        #expect(try String(contentsOf: output, encoding: .utf8) == "pix")
    }

    @Test func locatorPrefersEnginesFolder() {
        let loc = ExecutableLocator(enginesFolder: URL(fileURLWithPath: "/eng"),
                                    isExecutable: { ["/eng/tool/bin/tool", "/opt/homebrew/bin/tool"].contains($0) })
        #expect(loc.locate(.init(names: ["tool"], searchPaths: [], versionArguments: nil), pluginID: "tool")?.path == "/eng/tool/bin/tool")
    }

    @Test func commandEngineRunsCopyTool() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("hello \u{1F34A}".utf8).write(to: input)
        let engine = CommandEngine(
            manifest: sampleManifest(id: "cp", names: ["cp"], searchPaths: ["/bin"]),
            locator: ExecutableLocator(enginesFolder: d.appending(path: "engines")))

        let output = try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        #expect(output == staging.appending(path: "a.md"))
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: ".tmp").path))
        guard case .available = await engine.availability() else { Issue.record("expected available"); return }
        #expect(engine.id == "cp" && engine.maxConcurrentJobs == 2)
    }

    /// An engine whose version command leaves `marker` behind, so a test sees whether the probe ran (P143).
    private func probedEngine(in d: URL, marker: URL) -> CommandEngine {
        var manifest = sampleManifest(id: "sh", names: ["/bin/sh"])
        manifest.executable.versionArguments = ["-c", "echo probed > \"$0\"; echo; echo '  tool 9.9  '", marker.path]
        return CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d), versionProbeTimeout: .seconds(120))
    }

    @Test func aSilentVersionCommandPastItsTimeoutGivesNoVersion() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        var manifest = sampleManifest(id: "sh", names: ["/bin/sh"])
        manifest.executable.versionArguments = ["-c", "sleep 30; echo late"]
        let impatient = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d), versionProbeTimeout: .milliseconds(200))
        #expect(await impatient.version() == nil)
        manifest.executable.versionArguments = ["-c", "sleep 1; echo 'tool 1.0'"]
        let patient = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d), versionProbeTimeout: .seconds(120))
        #expect(await patient.version() == "tool 1.0")
    }

    @Test func availabilityOnlyLocatesAndTheVersionIsProbedOnRequest() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let marker = d.appending(path: "probed")
        let engine = probedEngine(in: d, marker: marker)

        #expect(await engine.availability() == .available(version: nil))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await engine.version() == "tool 9.9")
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func planningNeverRunsAVersionCommandButStatusesShowTheVersion() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let marker = d.appending(path: "probed")
        let registry = EngineRegistry(engines: [probedEngine(in: d, marker: marker)], priority: ["sh"])

        #expect(await registry.planner().route(from: "txt", to: "md") != nil)
        _ = await registry.installHints()
        await registry.refresh()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await registry.statuses().first?.availability == .available(version: "tool 9.9"))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func outputDirConventionFindsProducedFile() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(
            id: "sh", names: ["/bin/sh"],
            arguments: ["-c", "cp \"$0\" \"$1/$2.md\"", "{input}", "{outputDir}", "{inputStem}"])
        try manifest.validate()
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let output = try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        #expect(output == staging.appending(path: "a.md"))
        #expect(try String(contentsOf: output, encoding: .utf8) == "x")
    }

    @Test func manifestFolderEdgeGetsAnEmptyOutputFolder() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        var manifest = sampleManifest(id: "touch", names: ["/usr/bin/touch"], arguments: ["{outputFolder}/a.txt"])
        manifest.edges[0].output = "folder"
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let output = try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        #expect(output == staging.appending(path: "a", directoryHint: .isDirectory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["a.txt"])
    }

    @Test func aFolderEdgeThatLeavesTheFolderEmptyIsAConverterFault() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        var manifest = sampleManifest(id: "true", names: ["/usr/bin/true"], arguments: ["{input}", "{outputFolder}"])
        manifest.edges[0].output = "folder"
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        await #expect(throws: ConversionError.converterFault(engine: "true", message: "produced no output")) {
            try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "a").path))
    }

    /// P62: a tool's folder gets ArchiveEngine's walk. Folders without owner access (000, 0555) would block the
    /// publish rename and the staging cleanup; a symlink is kept as a link, never followed.
    @Test func aFolderEdgeGetsItsFoldersOpenedAndKeepsLinksAsLinks() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let script = "cd \"$2\" && mkdir locked && echo x > locked/f && chmod 000 locked && ln -s /etc link && chmod 555 ."
        var manifest = sampleManifest(id: "sh", names: ["/bin/sh"], arguments: ["-c", script, "sh", "{input}", "{outputFolder}"])
        manifest.edges[0].output = "folder"
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let output = try await engine.convert(step(input: input, staging: staging), progress: { _ in })

        func mode(_ url: URL) throws -> Int {
            try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        #expect(try mode(output) & 0o700 == 0o700)
        #expect(try mode(output.appending(path: "locked")) & 0o700 == 0o700)
        #expect(try String(contentsOf: output.appending(path: "locked/f"), encoding: .utf8) == "x\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.appending(path: "link").path) == "/etc")
    }

    @Test func aFolderEdgeWhoseFolderBecomesALinkOutsideIsAConverterFault() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        let outside = d.appending(path: "outside", directoryHint: .isDirectory)
        for folder in [staging, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("mine".utf8).write(to: outside.appending(path: "keep.txt"))
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let script = "rmdir \"$2\" && ln -s \"$3\" \"$2\""
        var manifest = sampleManifest(
            id: "sh", names: ["/bin/sh"], arguments: ["-c", script, "sh", "{input}", "{outputFolder}", outside.path]
        )
        manifest.edges[0].output = "folder"
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        await #expect(throws: ConversionError.converterFault(engine: "sh", message: "an item it made is outside its staging folder")) {
            try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    }

    @Test func folderEdgeWithoutOutputFolderIsInvalid() {
        var m = sampleManifest(); m.edges[0].output = "folder"
        #expect(throws: PluginManifestError.folderOutputNeedsOutputFolder(edgeIndex: 0)) { try m.validate() }
        m.edges[0].arguments = ["{input}", "{outputFolder}"]
        #expect(throws: Never.self) { try m.validate() }
        m.edges[0].output = "file"
        #expect(throws: PluginManifestError.missingOutput(edgeIndex: 0)) { try m.validate() }
        m.edges[0].output = "bundle"
        #expect(throws: PluginManifestError.unknownOutputKind("bundle")) { try m.validate() }
    }

    @Test func manifestOperationSelectsItsEdge() {
        var m = sampleManifest(from: ["png"], to: ["png"], arguments: ["{input}", "{output}", "plain"])
        m.edges.append(.init(from: ["png"], to: ["png"], operation: "compress", arguments: ["{input}", "{output}", "compress"]))
        #expect(m.edge(from: "png", to: "png", operation: nil)?.arguments.last == "plain")
        #expect(m.edge(from: "png", to: "png", operation: "compress")?.arguments.last == "compress")
        #expect(m.edge(from: "png", to: "png", operation: "other") == nil)
        #expect(m.conversionEdges().map(\.operation) == [nil, "compress"])
    }

    @Test func aCommandEngineRunsTheEdgeOfTheStepsOperation() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        var manifest = sampleManifest(id: "sh", from: ["txt"], to: ["txt"], names: ["/bin/sh"],
                                      arguments: ["-c", "echo plain > \"$0\"", "{output}", "{input}"])
        manifest.edges.append(.init(from: ["txt"], to: ["txt"], operation: "shout",
                                    arguments: ["-c", "echo shout > \"$0\"", "{output}", "{input}"]))
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))
        let shout = ConversionStep(input: input, stagingDirectory: staging, from: format("txt"), to: format("txt"),
                                   options: .init(), operation: "shout")

        let output = try await engine.convert(shout, progress: { _ in })
        #expect(try String(contentsOf: output, encoding: .utf8) == "shout\n")
    }

    @Test func speedAndLoudnessExpand() throws {
        let slow = try ArgumentTemplate.expand(["atempo={speed:2}", "I={loudness:-16}"], values: [:], options: PresetOptions(speed: 0.5, loudness: -23))
        #expect(slow == ["atempo=0.5", "I=-23"])
        let defaults = try ArgumentTemplate.expand(["atempo={speed:2}", "I={loudness:-9}"], values: [:], options: .init())
        #expect(defaults == ["atempo=2", "I=-16"])
        #expect(try ArgumentTemplate.expand(["{speed}"], values: [:], options: PresetOptions(speed: 2)) == ["2"])
    }

    @Test func olderPresetOptionsBlobsDecode() throws {
        let old = Data(#"{"quality":0.5,"stripMetadata":true}"#.utf8)
        let decoded = try JSONDecoder().decode(PresetOptions.self, from: old)
        #expect(decoded.quality == 0.5 && decoded.stripMetadata)
        #expect(decoded.speed == nil && decoded.loudness == -16 && decoded.audioBitrate == "192k" && decoded.pdfRenderDPI == 150)
        #expect(try JSONDecoder().decode(PresetOptions.self, from: Data("{}".utf8)) == PresetOptions())
        let roundTrip = PresetOptions(speed: 1.5, loudness: -20)
        #expect(try JSONDecoder().decode(PresetOptions.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }

    @Test func presetWithoutNewKeysDecodes() throws {
        let old = Data(#"{"id":"x","name":"X","target":"jpg","options":{}}"#.utf8)
        let preset = try JSONDecoder().decode(Preset.self, from: old)
        #expect(preset.operation == nil && !preset.combinesInputs && preset.delivery == .file)
        #expect(!preset.onlyIfSmaller && preset.outputNaming == .fromSource)
        let tool = Preset(id: "t", name: "T", target: nil, operation: "speed", combinesInputs: true, delivery: .clipboard,
                          onlyIfSmaller: true, outputNaming: .fromOutput)
        #expect(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(tool)) == tool)
    }

    @Test func tempDirURLIsAPercentEncodedDirectoryURL() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        // Shaped like the staging folders `.itemReplacementDirectory` hands out.
        let staging = d.appending(path: "(A Document Being Saved By Pomelo) caf\u{E9}", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(
            id: "sh", names: ["/bin/sh"],
            arguments: ["-c", "printf '%s' \"$1\" > \"$2\"", "{input}", "-env:UserInstallation={tempDirURL}profile", "{output}"])
        try manifest.validate()
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let output = try await engine.convert(step(input: input, staging: staging), progress: { _ in })

        let argument = try String(contentsOf: output, encoding: .utf8)
        let url = try #require(argument.split(separator: "=", maxSplits: 1).last.map(String.init))
        #expect(url.hasPrefix("file:///"))
        #expect(url.hasSuffix("/.tmp/profile"))
        #expect(url.contains("/(A%20Document%20Being%20Saved%20By%20Pomelo)%20caf"))
        #expect(url.unicodeScalars.allSatisfy { $0.isASCII && $0 != " " })
        #expect(URL(string: url)?.path == staging.appending(path: ".tmp/profile").path)
    }

    @Test func cancelLeavesNoOutput() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(id: "sleepy", names: ["/bin/sh"], arguments: ["-c", "sleep 30", "{input}", "{output}"])
        try manifest.validate()
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let task = Task { try await engine.convert(step(input: input, staging: staging), progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func manifestDecodesOptionalTimeout() throws {
        let json = """
        { "id": "t", "displayName": "T", "executable": { "names": ["t"], "searchPaths": [] }, "install": {},
          %@ "edges": [{ "from": ["txt"], "to": ["md"], "arguments": ["{input}", "{output}"] }] }
        """
        let withTimeout = try JSONDecoder().decode(
            PluginManifest.self, from: Data(json.replacingOccurrences(of: "%@", with: "\"timeoutSeconds\": 3600,").utf8))
        #expect(withTimeout.timeoutSeconds == 3600)
        try withTimeout.validate()
        let without = try JSONDecoder().decode(
            PluginManifest.self, from: Data(json.replacingOccurrences(of: "%@", with: "").utf8))
        #expect(without.timeoutSeconds == nil)
        try without.validate()
    }

    @Test func validationRejectsNonPositiveTimeout() {
        var manifest = sampleManifest()
        manifest.timeoutSeconds = 0
        #expect(throws: PluginManifestError.invalidTimeout(0)) { try manifest.validate() }
    }

    @Test func commandEngineUsesManifestTimeout() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let staging = d.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        var manifest = sampleManifest(id: "silent", names: ["/bin/sh"], arguments: ["-c", "sleep 30", "{input}", "{output}"])
        manifest.timeoutSeconds = 1
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))

        let start = ContinuousClock.now
        await #expect(throws: ConversionError.converterTimedOut(engine: "silent")) {
            try await engine.convert(step(input: input, staging: staging), progress: { _ in })
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // M5: the converter's own trouble is typed, so the hub never has to guess from a message.
    @Test func missingExecutableIsConverterUnavailable() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let engine = CommandEngine(manifest: sampleManifest(),
                                   locator: ExecutableLocator(enginesFolder: d, isExecutable: { _ in false }))
        await #expect(throws: ConversionError.converterUnavailable(engine: "sample", message: "executable not found")) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
    }

    @Test func aToolThatCannotLaunchIsConverterUnavailable() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let tool = d.appending(path: "no-such-tool").path
        let engine = CommandEngine(manifest: sampleManifest(names: [tool]),
                                   locator: ExecutableLocator(enginesFolder: d, isExecutable: { _ in true }))
        await #expect(throws: ConversionError.converterUnavailable(
            engine: "sample", message: "could not launch: \(String(cString: strerror(ENOENT)))"
        )) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
    }

    @Test func unresolvedPlaceholderIsAConverterFault() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(names: ["/bin/sh"], arguments: ["-c", "true", "{input}", "{output}", "{nope}"])
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))
        let fault = ConversionError.converterFault(engine: "sample", message: "unresolved placeholder {nope}")
        await #expect(throws: fault) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
    }

    @Test func noOutputAndNoMatchingEdgeAreConverterFaults() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(names: ["/bin/sh"], arguments: ["-c", "true", "{input}", "{output}"])
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))
        await #expect(throws: ConversionError.converterFault(engine: "sample", message: "produced no output")) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
        let noEdge = ConversionError.converterFault(engine: "sample", message: "no conversion from txt to pdf")
        await #expect(throws: noEdge) {
            try await engine.convert(step(input: input, staging: d, to: "pdf"), progress: { _ in })
        }
    }

    @Test func toolTimeoutIsConverterTimedOut() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(names: ["/bin/sh"], arguments: ["-c", "sleep 30", "{input}", "{output}"])
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d),
                                   runner: ProcessRunner(timeout: .seconds(1)))
        await #expect(throws: ConversionError.converterTimedOut(engine: "sample")) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
    }

    @Test func aToolThatFailsKeepsEngineFailed() async throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appending(path: "a.txt"); try Data("x".utf8).write(to: input)
        let manifest = sampleManifest(names: ["/bin/sh"], arguments: ["-c", "exit 3", "{input}", "{output}"])
        let engine = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: d))
        await #expect(throws: ConversionError.engineFailed(engine: "sample", message: "exited with code 3")) {
            try await engine.convert(step(input: input, staging: d), progress: { _ in })
        }
    }

    @Test func loaderUserFolderOverridesBundled() throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let user = d.appending(path: "user"), bundled = d.appending(path: "bundled"), missing = d.appending(path: "missing")
        for folder in [user, bundled] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let encoder = JSONEncoder()
        try encoder.encode(sampleManifest(displayName: "User Sample")).write(to: user.appending(path: "sample.pomelo-plugin.json"))
        try encoder.encode(sampleManifest(displayName: "Bundled Sample")).write(to: bundled.appending(path: "sample.pomelo-plugin.json"))
        try encoder.encode(sampleManifest(id: "other")).write(to: bundled.appending(path: "other.pomelo-plugin.json"))
        let broken = bundled.appending(path: "broken.pomelo-plugin.json"); try Data("{".utf8).write(to: broken)
        try Data("ignored".utf8).write(to: bundled.appending(path: "notes.txt"))

        let loaded = PluginLoader.load(folders: [user, missing, bundled])
        #expect(loaded.manifests.map(\.id) == ["sample", "other"])
        #expect(loaded.manifests.first?.displayName == "User Sample")
        #expect(loaded.failures.map(\.lastPathComponent) == [broken.lastPathComponent])
    }

    /// P96: a manifest named before the rename still loads from a folder the caller names (the user's), and only there.
    @Test func loaderReadsPreRenameNamesOnlyFromTheNamedFolders() throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let user = d.appending(path: "user"), bundled = d.appending(path: "bundled")
        for folder in [user, bundled] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let encoder = JSONEncoder()
        try encoder.encode(sampleManifest(id: "old")).write(to: user.appending(path: "old.kumquat-plugin.json"))
        try encoder.encode(sampleManifest(id: "new")).write(to: user.appending(path: "new.pomelo-plugin.json"))
        try encoder.encode(sampleManifest(id: "stray")).write(to: bundled.appending(path: "stray.kumquat-plugin.json"))
        let broken = user.appending(path: "broken.kumquat-plugin.json"); try Data("{".utf8).write(to: broken)

        let loaded = PluginLoader.load(folders: [user, bundled], acceptingLegacyNamesIn: [user])
        #expect(loaded.manifests.map(\.id) == ["new", "old"])
        #expect(loaded.failures.map(\.lastPathComponent) == [broken.lastPathComponent])

        #expect(PluginLoader.load(folders: [user, bundled]).manifests.map(\.id) == ["new"])
    }

    @Test func loaderPrefersTheRenamedManifestOverItsPreRenameCopy() throws {
        let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let encoder = JSONEncoder()
        try encoder.encode(sampleManifest(displayName: "Old")).write(to: d.appending(path: "a.kumquat-plugin.json"))
        try encoder.encode(sampleManifest(displayName: "New")).write(to: d.appending(path: "z.pomelo-plugin.json"))

        let loaded = PluginLoader.load(folders: [d], acceptingLegacyNamesIn: [d])
        #expect(loaded.manifests.map(\.displayName) == ["New"])
    }
}
