import AVFoundation
import CoreMedia
import Foundation
import PomeloCore
import Speech

/// Apple's `SpeechAnalyzer` with a `SpeechTranscriber` behind the `SpeechTranscribing` seam (macOS 26). It needs no
/// Speech Recognition permission (checked on this Mac before Task 2, P156), and a missing language model is
/// downloaded by the system through `AssetInventory` (P155).
@available(macOS 26, *)
struct SystemSpeech: SpeechTranscribing {
    var isAvailable: Bool { SpeechTranscriber.isAvailable }

    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// Final results only, each word with its time range.
    private static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    func assetStatus(for locale: Locale) async -> SpeechAssetStatus {
        switch await AssetInventory.status(forModules: [Self.module(for: locale)]) {
        case .installed: .installed
        case .downloading: .downloading
        case .supported: .supported
        default: .unsupported
        }
    }

    func installAssets(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
        do {
            // Nil when the model is already here, which the status alone doesn't tell.
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.module(for: locale)])
            else { return false }
            let observation = request.progress.observe(\.fractionCompleted) { progressed, _ in
                progress(progressed.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
            return true
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpeechFailure.downloadFailed
        }
    }

    func audioFormat(for locale: Locale) async -> SpeechAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [Self.module(for: locale)]).map(SpeechAudioFormat.init)
    }

    func transcribe(
        _ audio: AsyncStream<SpeechAudio>, locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        let module = Self.module(for: locale)
        let collector = Task {
            var words: [TimedWord] = []
            for try await result in module.results where result.isFinal {
                words += Self.words(in: result.text)
                progress(result.range.end.seconds)
            }
            return words
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let pull = Pull(audio)
        let inputs = AsyncStream<AnalyzerInput> { await pull.next().map { AnalyzerInput(buffer: $0.buffer) } }
        do {
            let end = try await withTaskCancellationHandler {
                try await analyzer.analyzeSequence(inputs)
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            guard end != nil else {
                // No audio reached the analyzer: nothing to finalize.
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                return []
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw SpeechFailure.other
        }
    }

    /// The words of a result: each run of its text that carries a time range. Text without one (rare: punctuation
    /// between words) joins the word before it, or the first word when it comes first.
    static func words(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        var untimed = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard let range = run.audioTimeRange else {
                if words.isEmpty { untimed += piece } else { words[words.count - 1].text += piece }
                continue
            }
            words.append(TimedWord(text: untimed + piece, start: range.start.seconds, end: range.end.seconds))
            untimed = ""
        }
        return words
    }
}

/// The audio stream's one iterator, for the analyzer's stream to pull from. `@unchecked Sendable`: only the
/// analyzer's single iteration calls `next()`.
private final class Pull: @unchecked Sendable {
    private var iterator: AsyncStream<SpeechAudio>.Iterator

    init(_ stream: AsyncStream<SpeechAudio>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> SpeechAudio? {
        await iterator.next()
    }
}
