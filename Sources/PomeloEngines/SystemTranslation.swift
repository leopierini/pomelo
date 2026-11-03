import Foundation
@_weakLinked import Translation

/// Apple's Translation framework behind the `Translating` seam (macOS 26: `installedSource` sessions need it). Never
/// drives a language download: those happen in System Settings (P154).
@available(macOS 26, *)
struct SystemTranslation: Translating {
    func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .supported
        default: .unsupported
        }
    }

    func startSession(from source: Locale.Language, to target: Locale.Language) -> any TranslatingSession {
        SystemTranslationSession(TranslationSession(installedSource: source, target: target))
    }
}

@available(macOS 26, *)
final class SystemTranslationSession: TranslatingSession, @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses: [TranslationSession.Response]
        do {
            responses = try await session.translations(from: requests)
        } catch {
            throw Self.failure(for: error)
        }
        // Answers carry the identifier of their request: do not rely on their order.
        var byIndex: [Int: String] = [:]
        for response in responses {
            if let index = response.clientIdentifier.flatMap({ Int($0) }) { byIndex[index] = response.targetText }
        }
        guard byIndex.count == texts.count else { throw TranslationFailure.other }
        return texts.indices.map { byIndex[$0] ?? "" }
    }

    /// What the framework throws, as the seam's own failures. Never carries the text.
    static func failure(for error: any Error) -> any Error {
        if error is CancellationError || TranslationError.alreadyCancelled ~= error { return CancellationError() }
        if TranslationError.notInstalled ~= error { return TranslationFailure.notInstalled }
        if TranslationError.unsupportedSourceLanguage ~= error || TranslationError.unsupportedTargetLanguage ~= error
            || TranslationError.unsupportedLanguagePairing ~= error
        {
            return TranslationFailure.unsupportedPair
        }
        return TranslationFailure.other
    }
}
