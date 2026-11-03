import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct SlidesEngineTests {
    private let registry = FormatRegistry.builtIn

    /// A `ConversionEngine` standing in for LibreOffice: "converts" any step by copying a fixture PDF to
    /// `<staging>/<stem>.pdf`, as the `soffice` manifest edge does.
    fileprivate static func pdfEdges(from sources: [FormatID] = ["doc", "docx", "ppt", "pptx", "odp"]) -> [ConversionEdge] {
        sources.map { ConversionEdge(from: $0, to: "pdf", engineID: "libreoffice", cost: 60, flags: []) }
    }

    private struct StandInOffice: ConversionEngine {
        let pdf: URL
        var pdfEdges: [ConversionEdge] = SlidesEngineTests.pdfEdges()
        var id: EngineID { "libreoffice" }
        var displayName: String { "LibreOffice" }
        var maxConcurrentJobs: Int { 1 }
        func availability() async -> EngineAvailability { .available(version: nil) }
        func edges() -> [ConversionEdge] { pdfEdges }
        func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            #expect(step.to.id == "pdf")
            let output = step.suggestedOutput
            try FileManager.default.copyItem(at: pdf, to: output)
            return output
        }
    }

    private func step(_ input: URL, to target: FormatID, in staging: URL) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target))
        return ConversionStep(input: input, stagingDirectory: staging, from: from, to: to, options: PresetOptions())
    }

    private func makeStaging(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func deck(named name: String = "deck.pptx", in dir: URL) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("PK".utf8).write(to: url)
        return url
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func edgesAreSingleHopsOnThePresentationFormats() {
        let edges = SlidesEngine(office: nil).edges()
        #expect(Set(edges.map(\.from.rawValue)) == ["pptx", "ppt", "odp"])
        #expect(Set(edges.map(\.to.rawValue)) == ["png", "jpg"])
        #expect(edges.count == 6)
        #expect(edges.allSatisfy { $0.engineID == "slides" && $0.cost == 70 && $0.operation == nil })
        #expect(edges.filter { $0.to == "png" }.allSatisfy { $0.flags == [.layoutRisk, .directOnly] })
        #expect(edges.filter { $0.to == "jpg" }.allSatisfy { $0.flags == [.lossy, .layoutRisk, .directOnly] })
        #expect(SlidesEngine(office: nil).id == "slides")
        #expect(SlidesEngine(office: nil).displayName == "Slides (LibreOffice)")
    }

    @Test func deckBecomesOneImagePerSlide() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let engine = SlidesEngine(office: StandInOffice(pdf: try Fixtures.pdf(pages: 3, in: dir)))

        let conversion = try step(try deck(in: dir), to: "png", in: staging)
        let output = try await engine.convert(conversion) { _ in }

        #expect(output == conversion.suggestedFolder)
        #expect(try names(in: output) == ["deck-1.png", "deck-2.png", "deck-3.png"])
        for name in try names(in: output) {
            #expect(Fixtures.imageUTType(output.appending(path: name)) == "public.png")
        }
    }

    @Test func jpgSlidesAreJPEGs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let engine = SlidesEngine(office: StandInOffice(pdf: try Fixtures.pdf(pages: 2, in: dir)))

        let output = try await engine.convert(try step(try deck(named: "talk.odp", in: dir), to: "jpg", in: staging)) { _ in }

        #expect(try names(in: output) == ["talk-1.jpg", "talk-2.jpg"])
        #expect(Fixtures.imageUTType(output.appending(path: "talk-1.jpg")) == "public.jpeg")
    }

    @Test func oneSlideDeckIsOneImage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let engine = SlidesEngine(office: StandInOffice(pdf: try Fixtures.pdf(pages: 1, in: dir)))

        let conversion = try step(try deck(in: dir), to: "png", in: staging)
        let output = try await engine.convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(output.lastPathComponent == "deck.png")
        #expect(Fixtures.imageUTType(output) == "public.png")
        #expect(try names(in: staging) == ["deck.png"])
    }

    @Test func intermediatePdfIsRemoved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let engine = SlidesEngine(office: StandInOffice(pdf: try Fixtures.pdf(pages: 3, in: dir)))

        let output = try await engine.convert(try step(try deck(in: dir), to: "png", in: staging)) { _ in }

        #expect(try names(in: staging) == [output.lastPathComponent])
    }

    @Test func staysCleanWhenTheOfficeStepFails() async throws {
        struct Broken: ConversionEngine {
            var id: EngineID { "libreoffice" }
            var displayName: String { "LibreOffice" }
            var maxConcurrentJobs: Int { 1 }
            func availability() async -> EngineAvailability { .available(version: nil) }
            func edges() -> [ConversionEdge] { SlidesEngineTests.pdfEdges() }
            func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
                try Data("half".utf8).write(to: step.suggestedOutput)
                throw ConversionError.engineFailed(engine: "libreoffice", message: "exited with code 81")
            }
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.engineFailed(engine: "libreoffice", message: "exited with code 81")) {
            _ = try await SlidesEngine(office: Broken()).convert(try step(try deck(in: dir), to: "png", in: staging)) { _ in }
        }
        #expect(try names(in: staging).isEmpty)
    }

    @Test func staysCleanWhenThePdfCannotBeRendered() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let notAPDF = dir.appending(path: "garbage.pdf")
        try Data("not a pdf".utf8).write(to: notAPDF)

        await #expect(throws: PDFKitEngine.Failure.self) {
            _ = try await SlidesEngine(office: StandInOffice(pdf: notAPDF)).convert(
                try step(try deck(in: dir), to: "png", in: staging)
            ) { _ in }
        }
        #expect(try names(in: staging).isEmpty)
    }

    @Test func missingOfficeDisablesSlides() async throws {
        let engine = SlidesEngine(office: nil)
        let hint = "brew install --cask libreoffice"
        #expect(await engine.availability() == .missing(installHint: hint))

        // The same sentence CommandEngine gives for the bundled manifest.
        let bundled = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder]).manifests
        var manifest = try #require(bundled.first { $0.id == "libreoffice" })
        manifest.executable = .init(names: ["pomelo-no-such-soffice"], searchPaths: [], versionArguments: nil)
        let office = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: URL(filePath: "/nonexistent")))
        #expect(await office.availability() == .missing(installHint: hint))

        let registry = EngineRegistry(engines: [engine], priority: ["slides"])
        #expect(await registry.planner().route(from: "pptx", to: "png") == nil)
        #expect(await registry.planner(includingMissing: true).route(from: "pptx", to: "png")?.edges.map(\.engineID) == ["slides"])

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        await #expect(throws: ConversionError.self) {
            _ = try await engine.convert(try step(try deck(in: dir), to: "png", in: staging)) { _ in }
        }
    }

    /// Registry with the real `CommandEngine` for LibreOffice (its executable not installed) and the composite on it.
    private func registryWithLibreOfficeMissing() throws -> EngineRegistry {
        let bundled = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder]).manifests
        var manifest = try #require(bundled.first { $0.id == "libreoffice" })
        manifest.executable = .init(names: ["pomelo-no-such-soffice"], searchPaths: [], versionArguments: ["--version"])
        let office = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: URL(filePath: "/nonexistent")))
        return EngineRegistry(engines: [office, SlidesEngine(office: office)], priority: ["libreoffice", "slides"])
    }

    @Test func theMissingSliceSaysLibreOfficeNotSlides() async throws {
        let registry = try registryWithLibreOfficeMissing()

        // The wheel builds "Needs <name>. Install it with <hint>." from this value: LibreOffice's, for either engine.
        let hints = await registry.installHints()
        #expect(hints["libreoffice"] == "LibreOffice|brew install --cask libreoffice")
        #expect(hints["slides"] == hints["libreoffice"])
        #expect(await registry.planner().route(from: "pptx", to: "png") == nil)
        #expect(await registry.planner(includingMissing: true).route(from: "pptx", to: "png")?.edges.map(\.engineID) == ["slides"])

        // Only LibreOffice is listed, with no second row for the composite.
        let statuses = await registry.statuses()
        #expect(statuses.map(\.id) == ["libreoffice"])
        #expect(statuses.allSatisfy { !$0.displayName.contains("Slides") })
    }

    @Test func theCompositeIsNeverProbedForAVersion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appending(path: "probes")
        let office = try scriptedOffice(in: dir, body: "true", versionScript: "echo probe >> '\(marker.path)'; echo 'LibreOffice 25.8'")
        let registry = EngineRegistry(engines: [office, SlidesEngine(office: office)], priority: ["libreoffice", "slides"])

        let statuses = await registry.statuses()
        #expect(statuses.map(\.id) == ["libreoffice"])
        #expect(statuses.first?.availability == .available(version: "LibreOffice 25.8"))
        let probes = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        #expect(probes.count == 1)
        #expect(await registry.planner().route(from: "pptx", to: "png")?.edges.map(\.engineID) == ["slides"])
    }

    @Test func aManifestWithoutAPptxEdgeDropsThatSlidesEdge() {
        let office = StandInOffice(pdf: URL(filePath: "/nonexistent.pdf"), pdfEdges: Self.pdfEdges(from: ["docx", "odp"]))
        let edges = SlidesEngine(office: office).edges()
        #expect(Set(edges.map(\.from.rawValue)) == ["odp"])
        #expect(edges.count == 2)
        #expect(SlidesEngine(office: StandInOffice(pdf: URL(filePath: "/nonexistent.pdf"), pdfEdges: [])).edges().isEmpty)
    }

    @Test func availabilityIsTheOfficeEngines() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SlidesEngine(office: StandInOffice(pdf: try Fixtures.pdf(pages: 1, in: dir)))
        #expect(await engine.availability() == .available(version: nil))
        #expect(engine.maxConcurrentJobs == 1)
    }

    // MARK: Through the real CommandEngine and the bundled manifest

    /// The libreoffice manifest with its executable replaced by a shell script that reads `--outdir` and the input
    /// the way `soffice` is called, then writes `<outdir>/<stem>.pdf` by running `body`.
    private func scriptedOffice(in dir: URL, body: String, versionScript: String? = nil) throws -> CommandEngine {
        let script = dir.appending(path: "fake-soffice", directoryHint: .notDirectory)
        try """
            #!/bin/sh
            outdir=""
            while [ $# -gt 1 ]; do
              if [ "$1" = "--outdir" ]; then outdir="$2"; fi
              shift
            done
            if [ "$1" = "--version" ]; then
              \(versionScript ?? "echo fake")
              exit 0
            fi
            input="$1"
            stem=$(basename "$input")
            stem="${stem%.*}"
            \(body)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let bundled = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder]).manifests
        var manifest = try #require(bundled.first { $0.id == "libreoffice" })
        manifest.executable = .init(names: [script.path], searchPaths: [], versionArguments: ["--version"])
        // The version probe stops a silent command after its timeout (5 s by default): a shell script starved by
        // hundreds of parallel tests can stay silent that long, so these stand-ins get a generous one.
        return CommandEngine(
            manifest: manifest, locator: ExecutableLocator(enginesFolder: dir.appending(path: "engines")),
            versionProbeTimeout: .seconds(120))
    }

    @Test func realCommandEngineOnAManifestWithAScriptForSoffice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let pdf = try Fixtures.pdf(pages: 3, in: dir)
        let office = try scriptedOffice(in: dir, body: "cp '\(pdf.path)' \"$outdir/$stem.pdf\"")

        let output = try await SlidesEngine(office: office).convert(try step(try deck(in: dir), to: "png", in: staging)) { _ in }

        #expect(try names(in: output) == ["deck-1.png", "deck-2.png", "deck-3.png"])
        #expect(try names(in: staging) == ["deck"])
    }

    @Test func anOfficeThatWritesNothingFailsCleanly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let engine = SlidesEngine(office: try scriptedOffice(in: dir, body: "true"))

        await #expect(throws: ConversionError.self) {
            _ = try await engine.convert(try step(try deck(in: dir), to: "png", in: staging)) { _ in }
        }
        #expect(try names(in: staging).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancelKillsOffice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let started = dir.appending(path: "started")
        let office = try scriptedOffice(in: dir, body: "echo $$ > '\(started.path)'\nsleep 30")
        let input = try deck(in: dir)
        let conversion = try step(input, to: "png", in: staging)
        let engine = SlidesEngine(office: office)

        let task = Task { try await engine.convert(conversion) { _ in } }
        while !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(try names(in: staging).isEmpty)
        let pid = try #require(Int32(String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }
}
