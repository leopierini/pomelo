import AVFoundation
import Foundation
import PomeloCore

/// What the system says about a spoken language's model on this Mac (`AssetInventory.Status`).
public enum SpeechAssetStatus: Sendable, Equatable {
    case installed, downloading, supported, unsupported
}

/// Why a transcription could not run. Never carries the text.
public enum SpeechFailure: Error, Sendable, Equatable {
    case downloadFailed
    case other
}

/// Audio for the recognizer, already in the format it asked for. The feed hands each buffer over once and never
/// touches it again, which is what makes passing it between tasks safe.
public struct SpeechAudio: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// The audio format a recognizer wants. `AVAudioFormat` is immutable once made.
public struct SpeechAudioFormat: @unchecked Sendable {
    public let format: AVAudioFormat

    public init(_ format: AVAudioFormat) {
        self.format = format
    }
}

/// What `SpeechEngine` needs from a speech recognizer. The real one is Apple's `SpeechAnalyzer` (`SystemSpeech`);
/// tests inject a fake. Every call throws `SpeechFailure` or `CancellationError`.
public protocol SpeechTranscribing: Sendable {
    var isAvailable: Bool { get }
    func supportedLocales() async -> [Locale]
    func assetStatus(for locale: Locale) async -> SpeechAssetStatus
    /// Has the system download the language's model when it needs one, `progress` 0…1 meanwhile. False when there
    /// was nothing to download.
    func installAssets(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool
    func audioFormat(for locale: Locale) async -> SpeechAudioFormat?
    /// The words of the final results, read from `audio` until it ends. `progress` gets the end, in seconds, of each
    /// final result. Cancelling the task stops the analysis.
    func transcribe(
        _ audio: AsyncStream<SpeechAudio>, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord]
}

/// Transcribe (audio and video to txt) and Make subtitles (to srt or vtt) with Apple's on-device speech recognizer
/// (P157). The spoken language is `options.language`, else the system's (P158); a language whose model this Mac lacks
/// is downloaded by the system first (P155).
public struct SpeechEngine: ConversionEngine {
    static let transcribe = "transcribe"
    static let subtitles = "subtitles"
    static let sources: [FormatID] = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "caf", "flac"]
    private static let edgeCost = 10
    /// The share of the progress a model download takes, when there is one (P155).
    static let assetShare = 0.5

    static let needsMacOS26 = "Needs macOS 26."
    static let notOnThisMac = "Transcription isn't available on this Mac."
    static let noSound = "It has no sound"
    static let noSpeech = "No speech found"

    static func cantTranscribe(_ language: Locale.Language) -> String {
        "Pomelo can't transcribe \(TranslationEngine.name(of: language)) yet."
    }

    static func downloadFailed(_ language: Locale.Language) -> String {
        "Pomelo couldn't download \(TranslationEngine.name(of: language)) for transcription. Try again when this Mac is online."
    }

    private let transcriber: (any SpeechTranscribing)?
    private let systemLocale: Locale

    /// Apple's recognizer where there is one (macOS 26), else an engine that reports itself unsupported.
    public init() {
        self.init(transcriber: Self.systemTranscriber())
    }

    /// `transcriber` nil is a Mac below macOS 26; `systemLocale` is what a nil language resolves against.
    public init(transcriber: (any SpeechTranscribing)?, systemLocale: Locale = .current) {
        self.transcriber = transcriber
        self.systemLocale = systemLocale
    }

    private static func systemTranscriber() -> (any SpeechTranscribing)? {
        if #available(macOS 26, *) { SystemSpeech() } else { nil }
    }

    public var id: EngineID { "speech" }
    public var displayName: String { "Speech" }
    /// One recognizer model at a time keeps the memory of a batch flat.
    public var maxConcurrentJobs: Int { 1 }

    public func availability() async -> EngineAvailability {
        guard let transcriber else { return .unsupported(reason: Self.needsMacOS26) }
        return transcriber.isAvailable ? .available(version: nil) : .unsupported(reason: Self.notOnThisMac)
    }

    public func edges() -> [ConversionEdge] {
        Self.sources.flatMap { source in
            [("txt", Self.transcribe), ("srt", Self.subtitles), ("vtt", Self.subtitles)].map { target, operation in
                ConversionEdge(
                    from: source, to: FormatID(target), engineID: id, cost: Self.edgeCost, flags: [],
                    operation: operation)
            }
        }
    }

    // MARK: Convert

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard Self.sources.contains(step.from.id), let operation = step.operation,
            (operation == Self.transcribe && step.to.id == "txt")
                || (operation == Self.subtitles && ["srt", "vtt"].contains(step.to.id))
        else {
            throw ConversionError.engineFailed(
                engine: id, message: "can't \(step.operation ?? "convert") \(step.from.displayName) into \(step.to.displayName)")
        }
        guard let transcriber else { throw ConversionError.engineUnsupported(engine: id, reason: Self.needsMacOS26) }
        guard transcriber.isAvailable else { throw ConversionError.engineUnsupported(engine: id, reason: Self.notOnThisMac) }
        progress(0)

        let feed = try await SpeechAudioFeed(url: step.input, engine: id)
        let locale = try await resolvedLocale(step.options.language, in: transcriber)
        let share = try await prepareAssets(for: locale, in: transcriber, progress: progress)
        guard let format = await transcriber.audioFormat(for: locale) else {
            throw ConversionError.engineFailed(engine: id, message: "the speech recognizer has no audio format")
        }
        let words = try await transcribe(feed, as: format, locale: locale, in: transcriber) { seconds in
            guard feed.duration > 0 else { return }
            progress(share + (1 - share) * min(1, max(0, seconds / feed.duration)))
        }
        guard words.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) else {
            throw ConversionError.notApplicable(reason: Self.noSpeech)
        }

        let text: String
        switch step.to.id {
        case "txt": text = SubtitleSegmenter.paragraphs(from: words).joined(separator: "\n\n") + "\n"
        case "vtt": text = SubtitleEngine.webVTT(from: SubtitleSegmenter.cues(from: words))
        default: text = SubtitleEngine.subRip(from: SubtitleSegmenter.cues(from: words))
        }
        let url = try SubtitleEngine.write(text, for: step, engine: id)
        progress(1)
        return url
    }

    // MARK: Language (P158)

    private func resolvedLocale(_ requested: String?, in transcriber: any SpeechTranscribing) async throws -> Locale {
        let supported = await transcriber.supportedLocales()
        guard let locale = Self.locale(for: requested, system: systemLocale, supported: supported) else {
            let wanted = requested.map { Locale.Language(identifier: $0) } ?? systemLocale.language
            throw ConversionError.engineUnsupported(engine: id, reason: Self.cantTranscribe(wanted))
        }
        return locale
    }

    /// The supported locale that speaks `requested` (a BCP-47 identifier; nil is the system's language), preferring
    /// in turn the region it names, the system's own region for the system's language, the user's region and the
    /// language's most likely region, each only when its usual script is one the request allows. `supportedLocale(equivalentTo:)` is not used: it maps a bare "en" to New
    /// Zealand or South Africa, differently from one run to the next. Nil when no supported locale speaks it.
    static func locale(for requested: String?, system: Locale, supported: [Locale]) -> Locale? {
        let wanted = requested.map { Locale.Language(identifier: $0) } ?? system.language
        guard let code = wanted.languageCode else { return nil }
        let speaking = supported.filter { $0.language.languageCode == code }
            .sorted { $0.identifier < $1.identifier }
        guard !speaking.isEmpty else { return nil }
        var regions: [Locale.Region] = []
        if let region = wanted.region { regions.append(region) }
        if system.language.languageCode == code, let region = system.language.region { regions.append(region) }
        if let region = system.region { regions.append(region) }
        if let region = Locale.Language(identifier: wanted.maximalIdentifier).region { regions.append(region) }
        // A script the request names (zh-Hans) rules out a region that writes the language otherwise (Taiwan).
        // `Locale.Language.script` infers one (Hans for a bare zh); only the components keep what was written.
        let named = requested.flatMap { Locale.Language.Components(identifier: $0).script }
        let fitting = regions.filter { region in
            guard let script = named else { return true }
            let usual = Locale.Language(languageCode: code, script: nil, region: region).maximalIdentifier
            return Locale.Language(identifier: usual).script == script
        }
        for region in fitting {
            if let match = speaking.first(where: { $0.language.region == region }) { return match }
        }
        return speaking[0]
    }

    // MARK: Assets (P155)

    /// The share of the progress the download took: 0 when there was nothing to download.
    private func prepareAssets(
        for locale: Locale, in transcriber: any SpeechTranscribing, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        switch await transcriber.assetStatus(for: locale) {
        case .installed:
            return 0
        case .unsupported:
            throw ConversionError.engineUnsupported(engine: id, reason: Self.cantTranscribe(locale.language))
        case .supported, .downloading:
            // `supported` is also how the system describes a model that is already here: the request says which.
            let downloaded: Bool
            do {
                downloaded = try await Self.abandonedOnCancel {
                    try await transcriber.installAssets(for: locale) { progress(Self.assetShare * $0) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ConversionError.engineUnsupported(engine: id, reason: Self.downloadFailed(locale.language))
            }
            try Task.checkCancellation()
            return downloaded ? Self.assetShare : 0
        }
    }

    /// `work`'s answer, or `CancellationError` as soon as the job is cancelled, without waiting for `work`, which is
    /// cancelled too. `AssetInstallationRequest.downloadAndInstall()` ignores cancellation (a cancelled download ran
    /// on to its end, 9 s later): the system may still finish installing that model (P173).
    static func abandonedOnCancel<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = FirstOutcome<T>()
        let task = Task {
            do {
                outcome.settle(.success(try await work()))
            } catch {
                outcome.settle(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { outcome.wait(with: $0) }
        } onCancel: {
            task.cancel()
            outcome.settle(.failure(CancellationError()))
        }
    }

    // MARK: Transcribing

    private func transcribe(
        _ feed: SpeechAudioFeed, as format: SpeechAudioFormat, locale: Locale, in transcriber: any SpeechTranscribing,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        let audio = try feed.stream(as: format.format)
        do {
            let words = try await withTaskCancellationHandler {
                try await transcriber.transcribe(audio, locale: locale, progress: progress)
            } onCancel: {
                feed.cancel()
            }
            try Task.checkCancellation()
            if let failure = feed.failure { throw failure }
            return words
        } catch let error as ConversionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ConversionError.engineFailed(engine: id, message: "the speech recognizer failed")
        }
    }
}

/// The first of a work's result and a cancellation, handed to whoever waits; the later one is dropped.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    func settle(_ result: Result<T, any Error>) {
        let waiter: CheckedContinuation<T, any Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func wait(with continuation: CheckedContinuation<T, any Error>) {
        let settled: Result<T, any Error>? = lock.withLock {
            if outcome == nil { waiter = continuation }
            return outcome
        }
        if let settled { continuation.resume(with: settled) }
    }
}
