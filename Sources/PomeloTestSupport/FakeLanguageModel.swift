import Foundation
import os
import PomeloCore
import PomeloEngines

/// A `LanguageModeling` for tests: answers through `summarizer` and `extractor`, counts a token per `bytesPerToken`
/// bytes, and remembers every call in order.
public final class FakeLanguageModel: LanguageModeling, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public enum Kind: Sendable { case summarize, extractData }
        public let kind: Kind
        public let text: String
        public let instructions: String
    }

    public let contextSize: Int
    public let fixedCost: Int
    public let bytesPerToken: Double
    /// The text and the call's index among all calls; throw `LanguageModelFailure` to fail it.
    public let summarizer: @Sendable (String, Int) throws -> DocumentSummary
    public let extractor: @Sendable (String, Int) throws -> ExtractedData
    private let state: OSAllocatedUnfairLock<(status: LanguageModelStatus, calls: [Call])>

    public init(
        status: LanguageModelStatus = .available, contextSize: Int = 4096, fixedCost: Int = 100, bytesPerToken: Double = 4,
        summarizer: @escaping @Sendable (String, Int) throws -> DocumentSummary = { text, index in
            DocumentSummary(title: "Title \(index)", points: ["Point of \(text.prefix(12))"])
        },
        extractor: @escaping @Sendable (String, Int) throws -> ExtractedData = { _, _ in ExtractedData() }
    ) {
        self.contextSize = contextSize
        self.fixedCost = fixedCost
        self.bytesPerToken = bytesPerToken
        self.summarizer = summarizer
        self.extractor = extractor
        state = OSAllocatedUnfairLock(initialState: (status, []))
    }

    public var calls: [Call] { state.withLock { $0.calls } }

    public func setStatus(_ status: LanguageModelStatus) {
        state.withLock { $0.status = status }
    }

    public func status() -> LanguageModelStatus { state.withLock { $0.status } }

    public func measure(_ sample: String, instructions: String, for task: LanguageModelTask) async -> TokenMeasure {
        TokenMeasure(fixedCost: fixedCost, bytesPerToken: bytesPerToken)
    }

    public func summarize(_ text: String, instructions: String) async throws -> DocumentSummary {
        try summarizer(text, record(.summarize, text, instructions))
    }

    public func extractData(from text: String, instructions: String) async throws -> ExtractedData {
        try extractor(text, record(.extractData, text, instructions))
    }

    private func record(_ kind: Call.Kind, _ text: String, _ instructions: String) -> Int {
        state.withLock {
            $0.calls.append(Call(kind: kind, text: text, instructions: instructions))
            return $0.calls.count - 1
        }
    }
}
