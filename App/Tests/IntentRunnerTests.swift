import AppIntents
import Foundation
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

/// Stands in for `JobCoordinator.runUnattended`: records each request and answers with `answer`, which by default
/// "converts" every input to a file of the request's target (or the source's own extension) next to it.
@MainActor
private final class FakeJobs {
    var requests: [(request: ConversionRequest, verb: String)] = []
    var answer: (ConversionRequest) -> [FileResult] = { request in
        request.inputs.map { source in
            let ext = request.target?.rawValue ?? source.pathExtension
            let output = source.deletingPathExtension().appendingPathExtension(ext)
            return .succeeded(source: source, outputs: [output], note: nil)
        }
    }

    func run(_ request: ConversionRequest, _ verb: String) async -> [FileResult] {
        requests.append((request, verb))
        return answer(request)
    }
}

@MainActor
@Suite struct IntentRunnerTests {
    private let dir = URL(fileURLWithPath: "/tmp/pomelo-intents-test", isDirectory: true)

    private func file(_ name: String) -> URL { dir.appending(path: name, directoryHint: .notDirectory) }

    private func jpg(of source: URL) -> URL { source.deletingPathExtension().appendingPathExtension("jpg") }

    private func compressed(_ source: URL) -> URL {
        file("\(source.deletingPathExtension().lastPathComponent)-compressed.\(source.pathExtension)")
    }

    private func makeRunner(
        _ jobs: FakeJobs, settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()), workFolder: URL? = nil
    ) -> IntentRunner {
        IntentRunner(
            registry: EngineRegistry(engines: [], priority: []), settings: settings,
            run: { await jobs.run($0, $1) },
            workFolder: workFolder ?? dir.appending(path: "work", directoryHint: .isDirectory)
        )
    }

    @Test func convertRunsOneRequestForTheFilesToConvert() async throws {
        let jobs = FakeJobs()
        let outputs = try await makeRunner(jobs).convert([file("a.png"), file("b.heic")], to: "jpg")
        #expect(jobs.requests.count == 1)
        let request = try #require(jobs.requests.first)
        #expect(request.request.inputs == [file("a.png"), file("b.heic")])
        #expect(request.request.target == "jpg")
        #expect(request.request.operation == nil)
        #expect(request.request.replaceOriginal == false)
        #expect(request.verb == "Converting")
        #expect(outputs == [file("a.jpg"), file("b.jpg")])
    }

    /// P105 (P14): a file already in the target is passed on as it is, never converted or copied.
    @Test func aFileAlreadyInTheTargetIsReturnedAsIs() async throws {
        let jobs = FakeJobs()
        let outputs = try await makeRunner(jobs).convert([file("a.jpg"), file("b.png")], to: "jpg")
        #expect(jobs.requests.map(\.request.inputs) == [[file("b.png")]])
        #expect(outputs == [file("a.jpg"), file("b.jpg")])
    }

    @Test func onlyFilesAlreadyInTheTargetRunNothing() async throws {
        let jobs = FakeJobs()
        let outputs = try await makeRunner(jobs).convert([file("a.jpeg"), file("b.JPG")], to: "jpg")
        #expect(jobs.requests.isEmpty)
        #expect(outputs == [file("a.jpeg"), file("b.JPG")])
    }

    @Test func outputsComeBackInInputOrder() async throws {
        let jobs = FakeJobs()
        // One file made two outputs, one is passed through between converted ones.
        jobs.answer = { request in
            request.inputs.map { source in
                let stem = source.deletingPathExtension().lastPathComponent
                let outputs = stem == "b" ? [file("b-1.jpg"), file("b-2.jpg")] : [file("\(stem).jpg")]
                return .succeeded(source: source, outputs: outputs, note: nil)
            }
        }
        let outputs = try await makeRunner(jobs).convert(
            [file("c.png"), file("a.jpg"), file("b.tiff"), file("d.heic")], to: "jpg"
        )
        #expect(outputs == [file("c.jpg"), file("a.jpg"), file("b-1.jpg"), file("b-2.jpg"), file("d.jpg")])
    }

    @Test func aFailureThrowsAHumanSentence() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { source in
                source.lastPathComponent == "bad.png"
                    ? .failed(source: source, error: .engineFailed(engine: "imageio", message: "CGImageSource failed"))
                    : .succeeded(source: source, outputs: [jpg(of: source)], note: nil)
            }
        }
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.failed("2 of 3 converted. bad.png may be damaged.")) {
            try await runner.convert([file("a.png"), file("bad.png"), file("c.png")], to: "jpg")
        }
        await #expect(throws: IntentRunError.failed("Couldn't convert bad.png. The file may be damaged.")) {
            try await runner.convert([file("bad.png")], to: "jpg")
        }
    }

    @Test func cancelledFilesReturnNothingAndDoNotThrow() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { source in
                source.lastPathComponent == "b.png"
                    ? .cancelled(source: source)
                    : .succeeded(source: source, outputs: [jpg(of: source)], note: nil)
            }
        }
        let outputs = try await makeRunner(jobs).convert([file("a.png"), file("b.png")], to: "jpg")
        #expect(outputs == [file("a.jpg")])
    }

    @Test func noFilesIsAnError() async throws {
        let jobs = FakeJobs()
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.noFiles) { try await runner.convert([], to: "jpg") }
        await #expect(throws: IntentRunError.noFiles) { try await runner.run(toolID: "compress", on: []) }
        #expect(jobs.requests.isEmpty)
    }

    @Test func anUnknownFormatIsAnError() async throws {
        let jobs = FakeJobs()
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.unknownFormat("XYZ")) {
            try await runner.convert([file("a.png")], to: "xyz")
        }
        #expect(jobs.requests.isEmpty)
    }

    @Test func anEditorIsNotATool() async throws {
        let jobs = FakeJobs()
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.unknownTool("Trim")) {
            try await runner.run(toolID: "trim", on: [file("a.mov")])
        }
        await #expect(throws: IntentRunError.unknownTool("Read codes")) {
            try await runner.run(toolID: "read-codes", on: [file("a.png")])
        }
        await #expect(throws: IntentRunError.unknownTool("nope")) {
            try await runner.run(toolID: "nope", on: [file("a.png")])
        }
        #expect(jobs.requests.isEmpty)
    }

    @Test func toolsRunWithTheUsersOptionsAndNeverReplace() async throws {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.replaceOriginal = true
        settings.settings.toolOptions["compress"] = PresetOptions(quality: 0.4)
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { .succeeded(source: $0, outputs: [file("a-compressed.jpg")], note: nil) }
        }
        let outputs = try await makeRunner(jobs, settings: settings).run(toolID: "compress", on: [file("a.jpg")])
        let request = try #require(jobs.requests.first)
        #expect(request.request.operation == "compress")
        #expect(request.request.options.quality == 0.4)
        #expect(request.request.nameSuffix == "compressed")
        #expect(request.request.onlyIfSmaller)
        #expect(request.request.replaceOriginal == false)
        #expect(request.verb == "Compressing")
        #expect(outputs == [file("a-compressed.jpg")])
    }

    /// P120: a file the tool doesn't apply to is handed back as it is, at its place, and is no failure.
    @Test func aFileTheToolDoesNotApplyToIsReturnedAsIs() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { source in
                source.lastPathComponent == "b.jpg"
                    ? .failed(source: source, error: .notApplicable(reason: "Already compressed"))
                    : .succeeded(source: source, outputs: [compressed(source)], note: nil)
            }
        }
        let outputs = try await makeRunner(jobs).run(
            toolID: "compress", on: [file("a.jpg"), file("b.jpg"), file("c.jpg")]
        )
        #expect(outputs == [file("a-compressed.jpg"), file("b.jpg"), file("c-compressed.jpg")])
    }

    @Test func aConversionThatDoesNotApplyReturnsTheSource() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { source in
                source.lastPathComponent == "a.pdf"
                    ? .failed(source: source, error: .notApplicable(reason: "No text found"))
                    : .succeeded(source: source, outputs: [file("b.txt")], note: nil)
            }
        }
        let outputs = try await makeRunner(jobs).convert([file("a.pdf"), file("b.pdf")], to: "txt")
        #expect(outputs == [file("a.pdf"), file("b.txt")])
    }

    @Test func aRealFailureNextToOneThatDoesNotApplyStillThrows() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { source in
                switch source.lastPathComponent {
                case "b.jpg": .failed(source: source, error: .notApplicable(reason: "Already compressed"))
                case "bad.jpg": .failed(source: source, error: .engineFailed(engine: "imageio", message: "bad"))
                default: .succeeded(source: source, outputs: [file("a-compressed.jpg")], note: nil)
                }
            }
        }
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.failed("2 of 3 finished. bad.jpg may be damaged.")) {
            try await runner.run(toolID: "compress", on: [file("a.jpg"), file("b.jpg"), file("bad.jpg")])
        }
    }

    /// The model failing is a failure, not work that doesn't apply: a Shortcut never gets the PDF back as its summary.
    /// The error is the one `IntelligenceEngine` reports for it.
    @Test func aModelThatCouldNotFinishFailsTheIntentWithItsSentence() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map {
                .failed(source: $0, error: .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence couldn't finish."))
            }
        }
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.failed("Couldn't run Compress. Apple Intelligence couldn't finish.")) {
            try await runner.run(toolID: "compress", on: [file("a.jpg")])
        }
    }

    /// P154 with P164: a language that isn't installed, a pair Translation lacks and a language it can't tell fail
    /// the Shortcut with the engine's sentence. Run through the real unattended job path and `TranslationEngine`,
    /// so a Shortcut never gets the untranslated subtitles back as the translation.
    @Test func aTranslationThatCannotRunFailsTheIntentWithItsSentence() async throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let subtitles = folder.appending(path: "movie.srt")
        try Data("1\n00:00:01,000 --> 00:00:03,000\nHello there, my friend. Welcome to the show.\n".utf8).write(to: subtitles)
        let symbols = folder.appending(path: "symbols.srt")
        try Data("1\n00:00:01,000 --> 00:00:03,000\n\u{2135} \u{2136}\n".utf8).write(to: symbols)
        let italian = Locale.current.localizedString(forIdentifier: "it") ?? "it"
        let english = Locale.current.localizedString(forIdentifier: "en") ?? "en"
        let cases: [(FakeTranslating, URL, String)] = [
            (FakeTranslating(statuses: [.init("en", "it"): .supported, .init("it", "en"): .supported]), subtitles,
             "Download \(italian) for translation in System Settings, General, Language & Region."),
            (FakeTranslating(statuses: [.init("en", "it"): .unsupported]), subtitles,
             "Pomelo can't translate from \(english) to \(italian)."),
            (FakeTranslating(), symbols, "Pomelo can't tell which language this is in."),
        ]
        for (translating, source, reason) in cases {
            let coordinator = makeCoordinator(engines: [TranslationEngine(translating: translating, preferredLanguages: ["it"])])
            let settings = SettingsStore(defaults: EphemeralDefaults())
            settings.settings.toolOptions["translate"] = PresetOptions(language: "it")
            let runner = IntentRunner(
                registry: EngineRegistry(engines: [], priority: []), settings: settings,
                run: { await coordinator.runUnattended($0, verb: $1) },
                workFolder: folder.appending(path: "work", directoryHint: .isDirectory)
            )

            await #expect(throws: IntentRunError.failed("Couldn't run Translate. \(reason)")) {
                try await runner.run(toolID: "translate", on: [source])
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["movie.srt", "symbols.srt"])
    }

    @Test func aCombineThatDoesNotApplyReturnsItsInputsInOrder() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { .failed(source: $0, error: .notApplicable(reason: "Nothing to combine")) }
        }
        let outputs = try await makeRunner(jobs).run(toolID: "merge-pdfs", on: [file("b.pdf"), file("a.pdf")])
        #expect(outputs == [file("b.pdf"), file("a.pdf")])
    }

    @Test func aCombineTakesTheFilesInTheOrderGivenAndReturnsOneOutput() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { .succeeded(source: $0, outputs: [file("b-combined.pdf")], note: nil) }
        }
        let outputs = try await makeRunner(jobs).run(toolID: "images-to-pdf", on: [file("b.png"), file("a.png")])
        let request = try #require(jobs.requests.first)
        #expect(request.request.combinesInputs)
        #expect(request.request.inputs == [file("b.png"), file("a.png")])
        #expect(outputs == [file("b-combined.pdf")])
    }

    @Test func aFailedCombineThrowsItsSummary() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            request.inputs.map { .failed(source: $0, error: .engineFailed(engine: "pdfkit", message: "bad")) }
        }
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.failed("Couldn't combine 2 files. a.pdf may be damaged.")) {
            try await runner.run(toolID: "merge-pdfs", on: [file("a.pdf"), file("b.pdf")])
        }
    }

    /// Final review: Find duplicates combines nothing, so its failure says which tool could not run.
    @Test func aFailedFindDuplicatesNamesTheTool() async throws {
        let jobs = FakeJobs()
        jobs.answer = { request in
            [.failed(source: request.inputs[0], error: .engineFailed(engine: "vision", message: "bad"))]
                + request.inputs.dropFirst().map { .cancelled(source: $0) }
        }
        let runner = makeRunner(jobs)
        await #expect(throws: IntentRunError.failed("Couldn't run Find duplicates. a.jpg may be damaged.")) {
            try await runner.run(toolID: "find-duplicates", on: [file("a.jpg"), file("b.jpg")])
        }
    }

    @Test func errorsReadAsSentences() {
        #expect(IntentRunError.noFiles.message == "Choose at least one file.")
        #expect(IntentRunError.unknownFormat("XYZ").message == "Pomelo can't make XYZ files.")
        #expect(IntentRunError.unknownTool("Trim").message == "Pomelo has no tool called Trim.")
        #expect(IntentRunError.failed("2 of 3 converted.").message == "2 of 3 converted.")
        #expect(String(localized: IntentRunError.noFiles.localizedStringResource) == "Choose at least one file.")
    }

    @Test func dataOnlyFilesAreWrittenToPomelosFolder() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let onDisk = file("kept.png")
        let inputs = try IntentRunner.inputs(
            from: [
                IntentFile(data: Data("pixels".utf8), filename: "x.png"),
                IntentFile(fileURL: onDisk),
                IntentFile(data: Data("sneaky".utf8), filename: "../../evil.png"),
            ],
            workFolder: work
        )
        try #require(inputs.count == 3)
        let written = inputs[0]
        #expect(written.lastPathComponent == "x.png")
        #expect(written.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == work.standardizedFileURL)
        #expect(UUID(uuidString: written.deletingLastPathComponent().lastPathComponent) != nil)
        #expect(try Data(contentsOf: written) == Data("pixels".utf8))
        #expect(inputs[1] == onDisk)
        // A name never reaches outside its fresh folder.
        let sneaky = inputs[2]
        #expect(sneaky.lastPathComponent == "evil.png")
        #expect(sneaky.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == work.standardizedFileURL)
        #expect(written.deletingLastPathComponent() != sneaky.deletingLastPathComponent())
    }

    @Test func aDataOnlyFileWithNoNameStillGetsOne() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let inputs = try IntentRunner.inputs(from: [IntentFile(data: Data("x".utf8), filename: "")], workFolder: work)
        #expect(inputs.first?.lastPathComponent == "File")
    }

    /// A file another action made may come with a type and no extension: the job finds its format by extension.
    @Test func aDataOnlyFileWithNoExtensionTakesItsTypes() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let inputs = try IntentRunner.inputs(
            from: [
                IntentFile(data: Data("x".utf8), filename: "Photo", type: .png),
                IntentFile(data: Data("x".utf8), filename: "", type: .heic),
                IntentFile(data: Data("x".utf8), filename: "kept.jpeg", type: .png),
                IntentFile(data: Data("x".utf8), filename: "plain"),
            ],
            workFolder: work
        )
        #expect(inputs.map(\.lastPathComponent) == ["Photo.png", "File.heic", "kept.jpeg", "plain"])
    }

    @Test func performHandsTheOutputsBackAsFiles() async throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let jobs = FakeJobs()
        let runner = makeRunner(jobs, workFolder: work)
        let files = try await runner.perform(on: [IntentFile(data: Data("x".utf8), filename: "x.png")]) {
            try await runner.convert($0, to: "jpg")
        }
        let input = try #require(jobs.requests.first?.request.inputs.first)
        #expect(input.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == work.standardizedFileURL)
        #expect(files.map(\.fileURL) == [input.deletingPathExtension().appendingPathExtension("jpg")])
        #expect(files.map(\.filename) == ["x.jpg"])
    }

    @Test func appIntentsMetadataIsInTheBundle() throws {
        let metadata = Bundle.main.bundleURL.appending(path: "Contents/Resources/Metadata.appintents")
        let actions = metadata.appending(path: "extract.actionsdata")
        let text = try String(contentsOf: actions, encoding: .utf8)
        #expect(text.contains("ConvertFilesIntent"))
        #expect(text.contains("RunPresetIntent"))
    }
}
