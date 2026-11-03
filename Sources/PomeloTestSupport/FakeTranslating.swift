import Foundation
import os
import PomeloEngines

/// A `Translating` for tests: every text comes back upper-cased (or through `transform`), and the languages it "has"
/// are whatever `statuses` says. Remembers the sessions it started and the batches it was handed.
public final class FakeTranslating: Translating, TranslatingSession, @unchecked Sendable {
    public struct Pair: Hashable, Sendable {
        public let source: String
        public let target: String

        public init(_ source: String, _ target: String) {
            self.source = source
            self.target = target
        }
    }

    private struct State {
        var sessions: [Pair] = []
        var batches: [[String]] = []
    }

    /// Pairs not listed read `.installed`. Keys use the languages' minimal identifiers ("en", "it").
    public let statuses: [Pair: TranslationPairStatus]
    public let transform: @Sendable (String) -> String
    /// Thrown by `startSession` when set.
    public let startFailure: (any Error)?
    /// Thrown by `translate` when set.
    public let failure: (any Error)?
    /// Called with every batch before it is answered.
    public let onBatch: @Sendable ([String]) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        statuses: [Pair: TranslationPairStatus] = [:], transform: @escaping @Sendable (String) -> String = { $0.uppercased() },
        startFailure: (any Error)? = nil, failure: (any Error)? = nil, onBatch: @escaping @Sendable ([String]) -> Void = { _ in }
    ) {
        self.statuses = statuses
        self.transform = transform
        self.startFailure = startFailure
        self.failure = failure
        self.onBatch = onBatch
    }

    public var sessions: [Pair] { state.withLock { $0.sessions } }
    public var batches: [[String]] { state.withLock { $0.batches } }

    public func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus {
        statuses[Pair(source.minimalIdentifier, target.minimalIdentifier)] ?? .installed
    }

    public func startSession(from source: Locale.Language, to target: Locale.Language) throws -> any TranslatingSession {
        if let startFailure { throw startFailure }
        state.withLock { $0.sessions.append(Pair(source.minimalIdentifier, target.minimalIdentifier)) }
        return self
    }

    public func translate(_ texts: [String]) async throws -> [String] {
        state.withLock { $0.batches.append(texts) }
        onBatch(texts)
        if let failure { throw failure }
        return texts.map(transform)
    }
}
