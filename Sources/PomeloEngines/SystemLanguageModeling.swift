import Foundation
@_weakLinked import FoundationModels
import PomeloCore

/// Apple's on-device model behind the `LanguageModeling` seam (macOS 26), always with greedy sampling so the same text
/// gives the same answer on the same system. `PrivateCloudComputeLanguageModel` is never used: nothing leaves the Mac.
@available(macOS 26, *)
struct SystemLanguageModeling: LanguageModeling {
    func status() -> LanguageModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        // Any reason a later system adds reads as the device's.
        case .unavailable: .deviceNotEligible
        }
    }

    var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// The model's own count where it has one (macOS 26.4): of the instructions and the answer's schema, and of
    /// `sample` to find how many bytes a token takes in this text, less 10 % to err on the safe side.
    func measure(_ sample: String, instructions: String, for task: LanguageModelTask) async -> TokenMeasure {
        let estimate = TokenMeasure.estimated(instructions: instructions)
        guard #available(macOS 26.4, *) else { return estimate }
        let model = SystemLanguageModel.default
        do {
            let schema = task == .summary ? SummaryAnswer.generationSchema : DocumentData.generationSchema
            let fixed = try await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: schema)
            let tokens = sample.isEmpty ? 0 : try await model.tokenCount(for: sample)
            guard tokens > 0 else { return TokenMeasure(fixedCost: fixed, bytesPerToken: estimate.bytesPerToken) }
            return TokenMeasure(fixedCost: fixed, bytesPerToken: Double(sample.utf8.count) / Double(tokens) * 0.9)
        } catch {
            return estimate
        }
    }

    func summarize(_ text: String, instructions: String) async throws -> DocumentSummary {
        let answer = try await respond(to: text, instructions: instructions, generating: SummaryAnswer.self)
        return DocumentSummary(title: answer.title, points: answer.points)
    }

    func extractData(from text: String, instructions: String) async throws -> ExtractedData {
        let answer = try await respond(to: text, instructions: instructions, generating: DocumentData.self)
        return ExtractedData(
            kind: answer.kind, issuer: answer.issuer, date: answer.date, total: answer.total, currency: answer.currency,
            tax: answer.tax,
            lineItems: answer.lineItems.map { $0.map { .init(name: $0.name, quantity: $0.quantity, amount: $0.amount) } }
        )
    }

    private func respond<Answer: Generable>(
        to text: String, instructions: String, generating type: Answer.Type
    ) async throws -> Answer {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            return try await session.respond(to: text, generating: type, options: GenerationOptions(samplingMode: .greedy)).content
        } catch {
            throw Self.failure(for: error)
        }
    }

    /// What the framework throws, as the seam's failures. macOS 27 throws `LanguageModelError`; macOS 26 the
    /// `GenerationError` it deprecates. Never carries the text.
    static func failure(for error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        // The macOS 27 SDK (Xcode 27, Swift 6.4) declares these types: an older Xcode still builds, with only the
        // macOS 26 errors below.
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return LanguageModelFailure.contextExceeded
                case .guardrailViolation, .refusal: return LanguageModelFailure.refused
                case .unsupportedLanguageOrLocale: return LanguageModelFailure.unsupportedLanguage
                default: return LanguageModelFailure.other
                }
            }
            if error is SystemLanguageModel.Error { return LanguageModelFailure.notReady }
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return LanguageModelFailure.contextExceeded
            case .guardrailViolation, .refusal: return LanguageModelFailure.refused
            case .unsupportedLanguageOrLocale: return LanguageModelFailure.unsupportedLanguage
            case .assetsUnavailable: return LanguageModelFailure.notReady
            default: return LanguageModelFailure.other
            }
        }
        return LanguageModelFailure.other
    }
}

@available(macOS 26, *)
@Generable(description: "A summary of a text")
struct SummaryAnswer {
    @Guide(description: "A short title for the whole text, at most ten words")
    var title: String
    @Guide(description: "The points that matter most, one sentence each, in the order the text gives them", .count(3...7))
    var points: [String]
}

/// P161: kind, issuer, date, total, currency, tax and line items, each left out when the document doesn't print it.
@available(macOS 26, *)
@Generable(description: "The data printed on a receipt, an invoice or a similar document. Leave out anything not printed on it.")
struct DocumentData {
    @Guide(description: "What the document is, in one or two words in the document's language: receipt, invoice, bill, ticket")
    var kind: String?
    @Guide(description: "The name of the shop, company or person that issued the document, as printed; not a greeting or a slogan")
    var issuer: String?
    // As printed: `ExtractedData.grounded(in:)` reads it, so the order of day and month is a rule, not a guess.
    @Guide(description: "The date printed on the document, copied exactly as it is printed, for example 12.10.2026, 10/12/26 or 3 Nov 2026")
    var date: String?
    @Guide(description: "The total amount to pay, as printed")
    var total: Double?
    @Guide(description: "The currency as an ISO 4217 code (EUR, USD, CHF), only when a currency code, name or symbol is printed")
    var currency: String?
    @Guide(description: "The tax or VAT amount, only when printed")
    var tax: Double?
    @Guide(description: "The items listed, in order, only those printed")
    var lineItems: [DocumentLineItem]?
}

@available(macOS 26, *)
@Generable
struct DocumentLineItem {
    @Guide(description: "The item as printed")
    var name: String
    @Guide(description: "How many, only when printed")
    var quantity: Double?
    @Guide(description: "The line's amount, as printed")
    var amount: Double?
}
