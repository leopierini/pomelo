import Foundation
import NaturalLanguage
import PomeloCore

/// Whether this Mac's language model can run now.
public enum LanguageModelStatus: Sendable, Equatable {
    case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady
}

/// Why a model call failed. Never carries the text.
public enum LanguageModelFailure: Error, Sendable, Equatable {
    case contextExceeded
    /// A guardrail or the model itself declined the text.
    case refused
    case unsupportedLanguage
    case notReady
    case other
}

/// A summary as the model wrote it: a title and its points.
public struct DocumentSummary: Sendable, Equatable {
    public var title: String
    public var points: [String]

    public init(title: String, points: [String]) {
        self.title = title
        self.points = points
    }
}

/// What a call takes of the model's context, in tokens.
public struct TokenMeasure: Sendable, Equatable {
    /// The instructions and the answer's schema.
    public var fixedCost: Int
    /// UTF-8 bytes per token, erring low so a count errs high.
    public var bytesPerToken: Double

    public init(fixedCost: Int, bytesPerToken: Double) {
        self.fixedCost = fixedCost
        self.bytesPerToken = max(bytesPerToken, 0.5)
    }

    /// Without the model's own count (below macOS 26.4): three bytes a token is fewer than the model's tokens hold in
    /// English (about 4.6), Italian (3.2) or Japanese (6.2), so counts err high; the schema gets a generous allowance.
    public static func estimated(instructions: String) -> TokenMeasure {
        var measure = TokenMeasure(fixedCost: 0, bytesPerToken: 3)
        measure.fixedCost = measure.count(instructions) + 500
        return measure
    }

    public func count(_ text: String) -> Int {
        Int((Double(text.utf8.count) / bytesPerToken).rounded(.up))
    }
}

public enum LanguageModelTask: Sendable {
    case summary, documentData
}

/// What `IntelligenceEngine` needs from a language model. The real one is Apple's on-device model
/// (`SystemLanguageModeling`, greedy sampling); tests inject a fake. Every call is a new session, so no history grows
/// past the window, and throws `LanguageModelFailure` or `CancellationError`.
public protocol LanguageModeling: Sendable {
    func status() -> LanguageModelStatus
    /// Tokens shared by the instructions, the prompt and the answer.
    var contextSize: Int { get }
    /// How to count the tokens of texts like `sample` sent with `instructions` for `task`.
    func measure(_ sample: String, instructions: String, for task: LanguageModelTask) async -> TokenMeasure
    func summarize(_ text: String, instructions: String) async throws -> DocumentSummary
    func extractData(from text: String, instructions: String) async throws -> ExtractedData
}

/// Summarize (documents and text to Markdown) and Extract data (receipts, invoices and the like to JSON or CSV) with
/// Apple's on-device model (P161). Optional: a Mac without Apple Intelligence reports it unsupported, with the reason.
public struct IntelligenceEngine: ConversionEngine {
    static let summarize = "summarize"
    static let extractData = "extract-data"
    static let summarySources: [FormatID] = ["pdf", "docx", "doc", "odt", "rtf", "html", "txt", "md"]
    static let dataSources: [FormatID] = ["png", "jpg", "heic", "tiff", "pdf"]
    /// Room left in the context for the answer.
    static let answerTokens = 1_000
    /// The model's count of a sample this long sets the measure for the whole text.
    static let sampleLength = 20_000
    /// Rounds of summaries of summaries before giving up: each round shrinks the text many times over.
    static let maxRounds = 6
    private static let edgeCost = 10

    static let needsMacOS26 = "Needs macOS 26."
    static let needsEligibleMac = "Needs a Mac with Apple Intelligence."
    static let needsAppleIntelligence = "Needs Apple Intelligence. Turn it on in System Settings."
    static let notReady = "Apple Intelligence is still getting ready. Try again in a few minutes."
    static let refused = "Apple Intelligence can't work with this document."
    static let couldNotFinish = "Apple Intelligence couldn't finish."
    static let noData = "No data found"

    static func cantRead(_ language: NLLanguage?) -> String {
        guard let language, language != .undetermined else { return "Apple Intelligence can't read this language yet." }
        return "Apple Intelligence can't read \(englishName(of: language)) yet."
    }

    private let model: (any LanguageModeling)?

    /// Apple's model where there is one (macOS 26), else an engine that reports itself unsupported.
    public init() {
        self.init(model: Self.systemModel())
    }

    /// `model` nil is a Mac below macOS 26.
    public init(model: (any LanguageModeling)?) {
        self.model = model
    }

    private static func systemModel() -> (any LanguageModeling)? {
        if #available(macOS 26, *) { SystemLanguageModeling() } else { nil }
    }

    public var id: EngineID { "intelligence" }
    public var displayName: String { "Apple Intelligence" }
    /// The model is one per Mac.
    public var maxConcurrentJobs: Int { 1 }

    /// The model gets ready, or is turned on or off, while Pomelo runs; asking is a property read.
    public var availabilityIsVolatile: Bool { model != nil }

    public func availability() async -> EngineAvailability {
        guard let model else { return .unsupported(reason: Self.needsMacOS26) }
        return Self.unavailableReason(model.status()).map { .unsupported(reason: $0) } ?? .available(version: nil)
    }

    static func unavailableReason(_ status: LanguageModelStatus) -> String? {
        switch status {
        case .available: nil
        case .deviceNotEligible: needsEligibleMac
        case .appleIntelligenceNotEnabled: needsAppleIntelligence
        case .modelNotReady: notReady
        }
    }

    public func edges() -> [ConversionEdge] {
        Self.summarySources.map {
            ConversionEdge(from: $0, to: "md", engineID: id, cost: Self.edgeCost, flags: [.lossy], operation: Self.summarize)
        }
            + Self.dataSources.flatMap { source in
                ["json", "csv"].map {
                    ConversionEdge(
                        from: source, to: FormatID($0), engineID: id, cost: Self.edgeCost, flags: [.lossy],
                        operation: Self.extractData)
                }
            }
    }

    // MARK: Convert

    /// Reading the document (OCR above all) is this share of the progress; the model's calls are the rest.
    private static let readingShare = 0.2

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        let isSummary = step.operation == Self.summarize && step.to.id == "md" && Self.summarySources.contains(step.from.id)
        let isData = step.operation == Self.extractData && ["json", "csv"].contains(step.to.id) && Self.dataSources.contains(step.from.id)
        guard isSummary || isData else {
            throw ConversionError.engineFailed(
                engine: id, message: "can't \(step.operation ?? "convert") \(step.from.displayName) into \(step.to.displayName)")
        }
        guard let model else { throw ConversionError.engineUnsupported(engine: id, reason: Self.needsMacOS26) }
        if let reason = Self.unavailableReason(model.status()) {
            throw ConversionError.engineUnsupported(engine: id, reason: reason)
        }
        progress(0)
        let text = try await DocumentText.read(step.input, as: step.from) { progress($0 * Self.readingShare) }
        let language = Self.dominantLanguage(of: text)
        let modelProgress: @Sendable (Double) -> Void = { progress(Self.readingShare + $0 * (1 - Self.readingShare)) }
        let output: Data
        do {
            if isSummary {
                let summary = try await summarize(text, language: language, with: model, progress: modelProgress)
                output = Data(Self.markdown(summary, fallbackTitle: OutputNamer.stem(of: step.input)).utf8)
            } else {
                let data = try await extract(text, language: language, with: model)
                guard data.hasData else { throw ConversionError.notApplicable(reason: Self.noData) }
                output = step.to.id == "csv" ? data.csv() : try data.json()
            }
        } catch {
            throw conversionError(for: error, language: language)
        }
        try Task.checkCancellation()
        let url = step.suggestedOutput
        do {
            try output.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.engineFailed(engine: id, message: "cannot write \(url.lastPathComponent)")
        }
        progress(1)
        return url
    }

    // MARK: Summarize

    /// Each chunk that fits the context is summarized, then the summaries are summarized together, in rounds, until
    /// one is left.
    private func summarize(
        _ text: String, language: NLLanguage?, with model: any LanguageModeling,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DocumentSummary {
        let instructions = Self.summaryInstructions(language)
        let measure = await model.measure(String(text.prefix(Self.sampleLength)), instructions: instructions, for: .summary)
        let budget = model.contextSize - measure.fixedCost - Self.answerTokens
        guard budget > 0 else { throw LanguageModelFailure.other }

        let chunks = TextChunker.chunks(of: text, budget: budget, measure: measure.count)
        let steps = Double(chunks.count + (chunks.count > 1 ? 1 : 0))
        var summaries: [DocumentSummary] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            summaries += try await summarized(chunk, budget: budget, measure: measure) {
                try await model.summarize($0, instructions: instructions)
            }
            progress(Double(index + 1) / steps)
        }
        var rounds = 0
        while summaries.count > 1 {
            rounds += 1
            guard rounds <= Self.maxRounds else { throw LanguageModelFailure.other }
            let combined = summaries.map(Self.plainText).joined(separator: "\n\n")
            var next: [DocumentSummary] = []
            for group in TextChunker.chunks(of: combined, budget: budget - measure.count(Self.partsHeader), measure: measure.count) {
                try Task.checkCancellation()
                next += try await summarized(group, budget: budget, measure: measure) {
                    try await model.summarize(Self.partsHeader + $0, instructions: instructions)
                }
            }
            summaries = next
        }
        guard let summary = summaries.first, summary.points.contains(where: { !$0.allSatisfy(\.isWhitespace) }) else {
            throw LanguageModelFailure.other
        }
        return summary
    }

    /// One call for `text`; when the model says it doesn't fit after all (the measure is an estimate), one more try
    /// on its halves, each a summary of its own. Halves of the text, not of the budget: the text may be well under it.
    private func summarized(
        _ text: String, budget: Int, measure: TokenMeasure, _ call: (String) async throws -> DocumentSummary
    ) async throws -> [DocumentSummary] {
        do {
            return [try await call(text)]
        } catch LanguageModelFailure.contextExceeded {
            var halves: [DocumentSummary] = []
            for piece in TextChunker.chunks(of: text, budget: Self.half(text, budget, measure), measure: measure.count) {
                try Task.checkCancellation()
                halves.append(try await call(piece))
            }
            return halves
        }
    }

    private static func half(_ text: String, _ budget: Int, _ measure: TokenMeasure) -> Int {
        max(1, min(budget, measure.count(text)) / 2)
    }

    static let partsHeader = "These are summaries of consecutive parts of one document. Summarize the whole document from them.\n\n"

    static func summaryInstructions(_ language: NLLanguage?) -> String {
        """
        You summarize documents. Give a short title for the whole text and between 3 and 7 points, one sentence \
        each, covering what matters most in the order the text gives it. Use only what the text says. \
        \(languageInstruction(language))
        """
    }

    private static func plainText(_ summary: DocumentSummary) -> String {
        ([summary.title] + summary.points.map { "- \($0)" }).joined(separator: "\n")
    }

    /// `# <title>`, a blank line and the points as a list, each on one line. Heading and list markers the model
    /// added itself are dropped.
    static func markdown(_ summary: DocumentSummary, fallbackTitle: String) -> String {
        func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let title = String(oneLine(summary.title).drop { $0 == "#" || $0 == " " })
        let points = summary.points.map { point -> String in
            let line = oneLine(point)
            return ["- ", "* ", "+ ", "\u{2022} "].contains(where: line.hasPrefix) ? String(line.dropFirst(2)) : line
        }.filter { !$0.isEmpty }
        return "# \(title.isEmpty ? fallbackTitle : title)\n\n" + points.map { "- \($0)\n" }.joined()
    }

    // MARK: Extract data

    /// A receipt or an invoice fits the context; of a longer document only the beginning is read.
    private func extract(_ text: String, language: NLLanguage?, with model: any LanguageModeling) async throws -> ExtractedData {
        let instructions = Self.dataInstructions(language)
        let measure = await model.measure(String(text.prefix(Self.sampleLength)), instructions: instructions, for: .documentData)
        let budget = model.contextSize - measure.fixedCost - Self.answerTokens
        guard budget > 0 else { throw LanguageModelFailure.other }
        var read = TextChunker.chunks(of: text, budget: budget, measure: measure.count).first ?? text
        let data: ExtractedData
        do {
            data = try await model.extractData(from: read, instructions: instructions)
        } catch LanguageModelFailure.contextExceeded {
            read = TextChunker.chunks(of: read, budget: Self.half(read, budget, measure), measure: measure.count).first ?? read
            data = try await model.extractData(from: read, instructions: instructions)
        }
        return data.grounded(in: read)
    }

    static func dataInstructions(_ language: NLLanguage?) -> String {
        """
        You read the text of a receipt, an invoice or a similar document and fill in the data printed on it. Copy \
        names and amounts exactly as they are printed. Leave out every field the text does not show: never guess, \
        never compute, never invent a value. \(languageInstruction(language))
        """
    }

    // MARK: Languages

    /// Below this NaturalLanguage is guessing: a receipt's few words read as Romanian at 25 %, and a model told to
    /// write Romanian misspells its answer. Real prose scores above 0.95.
    static let languageConfidence = 0.6

    private static func dominantLanguage(of text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(sampleLength)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
            language != .undetermined, confidence >= languageConfidence
        else { return nil }
        return language
    }

    private static func languageInstruction(_ language: NLLanguage?) -> String {
        guard let language else { return "Write in the language of the document." }
        let name = englishName(of: language)
        return "Write in \(name), the language of the document."
    }

    /// "Japanese": the reasons and the instructions are in English.
    static func englishName(of language: NLLanguage) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    }

    // MARK: Errors

    /// The model's failures are failures (watch folders and Shortcuts count them), shown as written: only
    /// `engineUnsupported` does both, `engineFailed` reads "may be damaged".
    private func conversionError(for error: any Error, language: NLLanguage?) -> any Error {
        let reason: String
        switch error {
        case is CancellationError, is ConversionError: return error
        case LanguageModelFailure.refused: reason = Self.refused
        case LanguageModelFailure.unsupportedLanguage: reason = Self.cantRead(language)
        case LanguageModelFailure.notReady: reason = Self.notReady
        default: reason = Self.couldNotFinish
        }
        return ConversionError.engineUnsupported(engine: id, reason: reason)
    }
}
