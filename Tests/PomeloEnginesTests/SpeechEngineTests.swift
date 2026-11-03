import AVFoundation
import CoreMedia
import Foundation
import os
import Speech
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// A `SpeechTranscribing` for tests: it has the locales and asset status it is given, takes the audio the engine
/// feeds it (recording how much and in which format) and answers with `words`. With `holds`, it stops after the
/// first buffer until its task is cancelled, then records what it saw.
private final class FakeSpeech: SpeechTranscribing, @unchecked Sendable {
    /// `hangs`: a download that, like the system's, ignores cancellation and runs until `releaseDownload()`.
    enum Install { case nothingToDo, downloads, fails, hangs }

    struct State {
        var installs: [String] = []
        var transcribed: [String] = []
        var buffers = 0
        var frames: AVAudioFrameCount = 0
        var formats: Set<String> = []
        var cancelled = false
        var buffersAfterCancel = 0
        var streamEnded = false
        var waiting: CheckedContinuation<Void, Never>?
        var downloadCancelled = false
        var downloadFinished = false
        var download: CheckedContinuation<Void, Never>?
        var downloadReleased = false
    }

    let isAvailable: Bool
    let locales: [Locale]
    let status: SpeechAssetStatus
    let install: Install
    let words: [TimedWord]
    let seconds: [Double]
    let holds: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started: AsyncStream<Void>.Continuation
    let firstBuffer: AsyncStream<Void>

    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    init(
        isAvailable: Bool = true, locales: [String] = ["en_US", "en_GB", "it_IT"], status: SpeechAssetStatus = .installed,
        install: Install = .nothingToDo, words: [TimedWord] = FakeSpeech.hello, seconds: [Double] = [],
        holds: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.locales = locales.map { Locale(identifier: $0) }
        self.status = status
        self.install = install
        self.words = words
        self.seconds = seconds
        self.holds = holds
        (firstBuffer, started) = AsyncStream<Void>.makeStream()
    }

    static let hello = [
        TimedWord(text: "Hello", start: 0, end: 0.4), TimedWord(text: " there.", start: 0.4, end: 0.9),
        TimedWord(text: " Second", start: 3.5, end: 4), TimedWord(text: " part.", start: 4, end: 4.6),
    ]

    var recorded: State { state.withLock { $0 } }

    func supportedLocales() async -> [Locale] { locales }

    func assetStatus(for locale: Locale) async -> SpeechAssetStatus { status }

    func installAssets(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
        state.withLock { $0.installs.append(locale.identifier) }
        switch install {
        case .nothingToDo: return false
        case .fails: throw SpeechFailure.downloadFailed
        case .hangs:
            started.yield()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let released = state.withLock { state in
                        state.download = continuation
                        return state.downloadReleased
                    }
                    if released { releaseDownload() }
                }
            } onCancel: {
                state.withLock { $0.downloadCancelled = true }
            }
            state.withLock { $0.downloadFinished = true }
            return true
        case .downloads:
            progress(0.5)
            progress(1)
            return true
        }
    }

    func audioFormat(for locale: Locale) async -> SpeechAudioFormat? { SpeechAudioFormat(Self.format) }

    func transcribe(
        _ audio: AsyncStream<SpeechAudio>, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        state.withLock { $0.transcribed.append(locale.identifier) }
        if holds {
            // Read from a task of its own, as the system analyzer does: cancelling the job doesn't cancel it, so
            // only the engine can stop the feed.
            let reader = Task.detached { [self] in
                var iterator = audio.makeAsyncIterator()
                guard let first = await iterator.next() else { return }
                record(first)
                started.yield()
                await withCheckedContinuation { continuation in
                    let cancelled = state.withLock { state in
                        state.waiting = continuation
                        return state.cancelled
                    }
                    if cancelled { resume() }
                }
                while await iterator.next() != nil { state.withLock { $0.buffersAfterCancel += 1 } }
                state.withLock { $0.streamEnded = true }
            }
            await withTaskCancellationHandler {
                await reader.value
            } onCancel: {
                state.withLock { $0.cancelled = true }
                resume()
            }
            throw CancellationError()
        }
        for await piece in audio { record(piece) }
        seconds.forEach(progress)
        return words
    }

    private func record(_ piece: SpeechAudio) {
        state.withLock {
            $0.buffers += 1
            $0.frames += piece.buffer.frameLength
            $0.formats.insert("\(piece.buffer.format.commonFormat.rawValue)/\(piece.buffer.format.sampleRate)/\(piece.buffer.format.channelCount)")
        }
    }

    func releaseDownload() {
        let download = state.withLock { state in
            state.downloadReleased = true
            defer { state.download = nil }
            return state.download
        }
        download?.resume()
    }

    private func resume() {
        let waiting = state.withLock { state in
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }
}

/// The progress values an engine reported, in order.
private final class ProgressLog: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Double]())
    var all: [Double] { values.withLock { $0 } }
    func add(_ value: Double) { values.withLock { $0.append(value) } }
}

/// Serialized: run in parallel, its movie writers held every hardware encoder client, and `ImageIOToolTests`' 4:4:4 HEIC
/// write, which the software encoder refuses, failed in most full runs.
@Suite(.serialized) struct SpeechEngineTests {
    private let formats = FormatRegistry.builtIn
    private static let englishUS = Locale(identifier: "en_US")

    private func step(_ source: URL, to target: FormatID, operation: String, language: String? = nil) throws -> ConversionStep {
        let staging = source.deletingLastPathComponent()
            .appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return ConversionStep(
            input: source, stagingDirectory: staging, from: try #require(formats.format(for: source)),
            to: try #require(formats.format(id: target)), options: PresetOptions(language: language),
            operation: operation)
    }

    private func engine(_ fake: FakeSpeech?) -> SpeechEngine {
        SpeechEngine(transcriber: fake, systemLocale: Locale(identifier: "en_US@rg=itzzzz"))
    }

    private func convert(
        _ source: URL, to target: FormatID = "txt", operation: String = "transcribe", language: String? = nil,
        with fake: FakeSpeech, progress: ProgressLog = ProgressLog()
    ) async throws -> String {
        let output = try await engine(fake).convert(try step(source, to: target, operation: operation, language: language)) {
            progress.add($0)
        }
        return try String(contentsOf: output, encoding: .utf8)
    }

    private func failure(
        _ source: URL, to target: FormatID = "txt", operation: String = "transcribe", language: String? = nil,
        with fake: FakeSpeech?
    ) async -> ConversionError? {
        do {
            _ = try await engine(fake).convert(try step(source, to: target, operation: operation, language: language)) { _ in }
            return nil
        } catch {
            return error as? ConversionError
        }
    }

    private func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // MARK: Edges and availability

    @Test func everyAudioAndVideoFormatTranscribesToTextAndSubtitles() {
        let edges = engine(FakeSpeech()).edges()
        let sources: [FormatID] = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "caf", "flac"]
        #expect(Set(edges.map(\.from)) == Set(sources))
        #expect(edges.count == sources.count * 3)
        for source in sources {
            let from = edges.filter { $0.from == source }
            #expect(Set(from.filter { $0.operation == "transcribe" }.map(\.to)) == ["txt"])
            #expect(Set(from.filter { $0.operation == "subtitles" }.map(\.to)) == ["srt", "vtt"])
        }
        #expect(edges.allSatisfy { $0.cost == 10 && $0.flags.isEmpty && $0.engineID == "speech" })
    }

    @Test func belowMacOS26TheEngineIsUnsupportedAndFailsTheFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await engine(nil).availability() == .unsupported(reason: "Needs macOS 26."))
        let error = await failure(try Fixtures.wav(seconds: 1, in: dir), with: nil)
        #expect(error == .engineUnsupported(engine: "speech", reason: "Needs macOS 26."))
    }

    @Test func aMacWithoutTheRecognizerSaysSo() async throws {
        let fake = FakeSpeech(isAvailable: false)
        #expect(await engine(fake).availability() == .unsupported(reason: "Transcription isn't available on this Mac."))
        #expect(await engine(FakeSpeech()).availability() == .available(version: nil))
    }

    @Test func theDefaultRegistryHasTheSpeechEngine() async {
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        #expect(await registry.engine(id: "speech") != nil)
        #expect(DefaultEngines.priority.contains("speech"))
    }

    @Test func aStepThatIsNotTranscriptionIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, in: dir)
        let wrongTarget = await failure(source, to: "srt", operation: "transcribe", with: FakeSpeech())
        let wrongOperation = await failure(source, to: "txt", operation: "translate", with: FakeSpeech())
        for error in [wrongTarget, wrongOperation] {
            guard case .engineFailed(engine: "speech", _)? = error else {
                Issue.record("expected an engine failure, got \(String(describing: error))")
                continue
            }
        }
    }

    // MARK: Outputs

    @Test func transcribeWritesOneParagraphPerStretchOfSpeech() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try await convert(try Fixtures.wav(seconds: 1, in: dir), with: FakeSpeech())
        #expect(text == "Hello there.\n\nSecond part.\n")
    }

    @Test func makeSubtitlesWritesSubRipAndWebVTTCues() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, in: dir)
        let srt = try await convert(source, to: "srt", operation: "subtitles", with: FakeSpeech())
        #expect(srt == """
            1
            00:00:00,000 --> 00:00:00,900
            Hello there.

            2
            00:00:03,500 --> 00:00:04,600
            Second part.

            """)
        let vtt = try await convert(source, to: "vtt", operation: "subtitles", with: FakeSpeech())
        #expect(vtt == """
            WEBVTT

            00:00:00.000 --> 00:00:00.900
            Hello there.

            00:00:03.500 --> 00:00:04.600
            Second part.

            """)
    }

    @Test func theToolsNameTheirOutputsAsPlayersExpect() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, in: dir)
        let stem = source.deletingPathExtension().lastPathComponent
        let runner = JobRunner(
            registry: EngineRegistry(engines: [engine(FakeSpeech())], priority: ["speech"]),
            destinations: DestinationResolver(downloadsFolder: dir, isWritable: { _ in true }))
        var names: [String] = []
        for (presetID, target) in [("transcribe", nil), ("make-subtitles", nil), ("make-subtitles", "vtt")] as [(String, FormatID?)] {
            let preset = try #require(Preset.builtIns.first { $0.id == presetID })
            var request = ConversionRequest.from(preset, inputs: [source])
            if let target { request.target = target }
            let results = await runner.run(request)
            guard case .succeeded(_, let outputs, _)? = results.first else {
                Issue.record("\(presetID): \(results)")
                continue
            }
            names += outputs.map(\.lastPathComponent)
        }
        #expect(names == ["\(stem)-transcript.txt", "\(stem).srt", "\(stem).vtt"])
    }

    @Test func noWordsIsNoSpeechFound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, amplitude: 0, in: dir)
        #expect(await failure(source, with: FakeSpeech(words: [])) == .notApplicable(reason: "No speech found"))
        let blank = FakeSpeech(words: [TimedWord(text: "  ", start: 0, end: 1)])
        #expect(await failure(source, with: blank) == .notApplicable(reason: "No speech found"))
        #expect(await failure(source, to: "srt", operation: "subtitles", with: blank) == .notApplicable(reason: "No speech found"))
    }

    // MARK: The feed

    @Test func aVideoWithoutSoundHasNoSound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech()
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        #expect(await failure(movie, with: fake) == .notApplicable(reason: "It has no sound"))
        #expect(fake.recorded.transcribed.isEmpty)
    }

    @Test func aDamagedFileCannotBeRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let damaged = try Fixtures.textFile(Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7919) }), ext: "mp4", in: dir)
        guard case .engineFailed(engine: "speech", let message)? = await failure(damaged, with: FakeSpeech()) else {
            Issue.record("expected a read failure")
            return
        }
        #expect(message.hasPrefix("cannot read"))
    }

    @Test(arguments: ["wav", "stereo", "m4a", "mov"])
    func theRecognizerGetsTheWholeTrackInItsOwnFormat(_ kind: String) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source: URL = switch kind {
        case "wav": try Fixtures.wav(seconds: 2, in: dir)
        case "stereo": try Fixtures.wav(seconds: 2, channels: 2, in: dir)
        case "m4a": try Fixtures.m4a(seconds: 2, in: dir)
        default: try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        }
        let fake = FakeSpeech()
        _ = try await convert(source, with: fake)
        let recorded = fake.recorded
        #expect(recorded.formats == ["\(AVAudioCommonFormat.pcmFormatInt16.rawValue)/16000.0/1"])
        #expect(abs(Double(recorded.frames) - 32_000) < 32_000 * 0.03, "\(recorded.frames) frames")
        #expect(recorded.buffers > 1)
    }

    @Test func progressIsTheLastFinalResultsEndOverTheDuration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ProgressLog()
        _ = try await convert(try Fixtures.wav(seconds: 2, in: dir), with: FakeSpeech(seconds: [0.5, 1.5, 9]), progress: log)
        #expect(log.all == [0, 0.25, 0.75, 1, 1])
    }

    @Test func cancellingStopsTheFeedAndTheRecognizerAndPublishesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(holds: true)
        let step = try step(try Fixtures.wav(seconds: 30, in: dir), to: "txt", operation: "transcribe")
        let engine = engine(fake)
        let job = Task { try await engine.convert(step) { _ in } }
        for await _ in fake.firstBuffer { break }
        job.cancel()
        let result = await job.result
        #expect(throws: CancellationError.self) { try result.get() }
        let recorded = fake.recorded
        #expect(recorded.cancelled && recorded.streamEnded)
        // The fake wakes its reader as the job is cancelled, so one read may start before the feed has stopped.
        #expect(recorded.buffers == 1 && recorded.buffersAfterCancel <= 1, "\(recorded.buffersAfterCancel) after")
        #expect(try FileManager.default.contentsOfDirectory(atPath: step.stagingDirectory.path).isEmpty)
    }

    // MARK: Language (P158)

    @Test func theSpokenLanguageResolvesThroughItsRegion() {
        let supported = ["en_NZ", "en_US", "en_ZA", "en_GB", "it_IT", "it_CH", "fr_CA", "fr_CH", "fr_FR", "zh_CN", "zh_TW"]
            .map { Locale(identifier: $0) }
        let mac = Locale(identifier: "en_US@rg=itzzzz")
        func resolved(_ requested: String?, system: Locale = mac) -> String? {
            SpeechEngine.locale(for: requested, system: system, supported: supported)?.identifier
        }
        #expect(resolved(nil) == "en_US")
        #expect(resolved("en") == "en_US")
        #expect(resolved("en-GB") == "en_GB")
        #expect(resolved("en-IT") == "en_US")
        #expect(resolved("it") == "it_IT")
        #expect(resolved("it-CH") == "it_CH")
        #expect(resolved("fr") == "fr_FR")
        #expect(resolved("fr", system: Locale(identifier: "de_CH")) == "fr_CH")
        #expect(resolved("zh-Hant") == "zh_TW")
        #expect(resolved("zh-Hans", system: Locale(identifier: "en_TW")) == "zh_CN")
        #expect(resolved("zh-Hant", system: Locale(identifier: "en_CN")) == "zh_TW")
        #expect(resolved("zh", system: Locale(identifier: "en_TW")) == "zh_TW")
        #expect(resolved(nil, system: Locale(identifier: "en_GB")) == "en_GB")
        #expect(resolved("ja") == nil)
        #expect(resolved("") == nil)
    }

    @Test func aLanguageTheRecognizerLacksCantBeTranscribed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, in: dir)
        let fake = FakeSpeech()
        #expect(await failure(source, language: "ja", with: fake)
            == .engineUnsupported(engine: "speech", reason: "Pomelo can't transcribe \(name("ja")) yet."))
        #expect(fake.recorded.transcribed.isEmpty)
        let unsupportedAssets = FakeSpeech(status: .unsupported)
        #expect(await failure(source, language: "it", with: unsupportedAssets)
            == .engineUnsupported(engine: "speech", reason: "Pomelo can't transcribe \(name("it")) yet."))
    }

    @Test func theLanguageOptionPicksTheRecognizersLocale() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.wav(seconds: 1, in: dir)
        let fake = FakeSpeech()
        _ = try await convert(source, with: fake)
        _ = try await convert(source, language: "it", with: fake)
        _ = try await convert(source, language: "en-GB", with: fake)
        #expect(fake.recorded.transcribed == ["en_US", "it_IT", "en_GB"])
    }

    // MARK: Assets (P155)

    @Test func anInstalledModelRunsWithoutAnInstallRequest() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(status: .installed, seconds: [1])
        let log = ProgressLog()
        _ = try await convert(try Fixtures.wav(seconds: 2, in: dir), with: fake, progress: log)
        #expect(fake.recorded.installs.isEmpty)
        #expect(log.all == [0, 0.5, 1])
    }

    @Test(arguments: [SpeechAssetStatus.supported, .downloading])
    func aModelTheSystemMayLackIsRequestedAndRunsWhenNothingDownloads(_ status: SpeechAssetStatus) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(status: status, install: .nothingToDo, seconds: [1])
        let log = ProgressLog()
        _ = try await convert(try Fixtures.wav(seconds: 2, in: dir), with: fake, progress: log)
        #expect(fake.recorded.installs == ["en_US"])
        #expect(log.all == [0, 0.5, 1])
    }

    @Test func aDownloadIsTheFirstHalfOfTheProgress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(status: .supported, install: .downloads, seconds: [1])
        let log = ProgressLog()
        _ = try await convert(try Fixtures.wav(seconds: 2, in: dir), language: "it", with: fake, progress: log)
        #expect(fake.recorded.installs == ["it_IT"])
        #expect(log.all == [0, 0.25, 0.5, 0.75, 1])
    }

    /// The system's download ignores cancellation: the job must not wait for it (I1).
    @Test func cancellingDuringADownloadEndsTheJobAtOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(status: .supported, install: .hangs)
        let step = try step(try Fixtures.wav(seconds: 1, in: dir), to: "txt", operation: "transcribe", language: "it")
        let engine = engine(fake)
        let job = Task { try await engine.convert(step) { _ in } }
        for await _ in fake.firstBuffer { break }
        let cancelled = ContinuousClock.now
        job.cancel()
        // A job that waited for the download would never end here: the deadline turns that into a failure.
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await job.result; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended && ContinuousClock.now - cancelled < .seconds(1))
        // Before reading the outcome, so the recorded state is the job's, and a job still waiting can finish.
        let recorded = fake.recorded
        fake.releaseDownload()
        let result = await job.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(recorded.downloadCancelled && !recorded.downloadFinished)
        #expect(recorded.transcribed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: step.stagingDirectory.path).isEmpty)
    }

    @Test func aFailedDownloadFailsTheFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeSpeech(status: .supported, install: .fails)
        let error = await failure(try Fixtures.wav(seconds: 1, in: dir), language: "it", with: fake)
        #expect(error == .engineUnsupported(
            engine: "speech",
            reason: "Pomelo couldn't download \(name("it")) for transcription. Try again when this Mac is online."))
        #expect(fake.recorded.transcribed.isEmpty)
    }

    // MARK: The system recognizer

    @Test func aResultsWordsAreItsTimedRuns() throws {
        guard #available(macOS 26, *) else { return }
        func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var piece = AttributedString(text)
            piece.audioTimeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
            return piece
        }
        let text = AttributedString("\u{201C}") + timed("Hello", 0, 0.5) + timed(" world", 0.5, 1) + AttributedString(".")
        #expect(SystemSpeech.words(in: text) == [
            TimedWord(text: "\u{201C}Hello", start: 0, end: 0.5), TimedWord(text: " world.", start: 0.5, end: 1),
        ])
    }

    /// A real transcription (Task 2's gate: SpeechAnalyzer asks no permission). Only where the English model is on
    /// this Mac, so nothing downloads.
    @Test(.enabled(if: Installed.has("engine:speech") && Installed.has("speech:en-US")))
    func theSystemRecognizerHearsTheFixture() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.speech(in: dir)
        let engine = SpeechEngine()
        let transcript = try String(
            contentsOf: try await engine.convert(try step(source, to: "txt", operation: "transcribe", language: "en-US")) { _ in },
            encoding: .utf8)
        #expect(transcript.lowercased().contains("hello"))

        let srt = try String(
            contentsOf: try await engine.convert(try step(source, to: "srt", operation: "subtitles", language: "en-US")) { _ in },
            encoding: .utf8)
        let cues = try SubtitleEngine.parse(srt, isVTT: false).cues
        #expect(cues.count >= 2)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start && $0.start < $0.end })
        #expect(cues.flatMap(\.lines).joined(separator: " ").lowercased().contains("hello"))
    }
}
