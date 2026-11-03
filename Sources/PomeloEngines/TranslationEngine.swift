import Foundation
import NaturalLanguage
import PomeloCore

public enum TranslationPairStatus: Sendable, Equatable {
    case installed, supported, unsupported
}

/// Why a translation could not run. Never carries the text.
public enum TranslationFailure: Error, Sendable, Equatable {
    case notInstalled
    case unsupportedPair
    case other
}

/// Translation for one job (one source, one target); batches go through it in order.
public protocol TranslatingSession: Sendable {
    /// One answer per text, in the same order. Throws `TranslationFailure` or `CancellationError`.
    func translate(_ texts: [String]) async throws -> [String]
}

/// What the engine needs from a translation service: which language pairs it has and a session for one pair. The
/// real one is Apple's Translation (`SystemTranslation`); tests inject a fake.
public protocol Translating: Sendable {
    func status(from source: Locale.Language, to target: Locale.Language) async -> TranslationPairStatus
    func startSession(from source: Locale.Language, to target: Locale.Language) throws -> any TranslatingSession
}

/// Translates subtitles (srt, vtt), text and Markdown on the device with Apple's Translation framework. The source
/// language is detected from the file itself, the target is `options.language` (P158). Only installed languages are
/// used, and the person installs them in System Settings (P154).
public struct TranslationEngine: ConversionEngine {
    static let operation = "translate"
    static let needsMacOS26 = "Needs macOS 26."
    static let formats: [FormatID] = ["srt", "vtt", "txt", "md"]
    private static let edgeCost = 10
    private static let batchSize = 50

    private let translating: (any Translating)?
    private let preferredLanguages: [String]

    /// The system's translation where there is one (macOS 26), else an engine that reports itself unsupported.
    public init() {
        self.init(translating: Self.systemTranslation(), preferredLanguages: Locale.preferredLanguages)
    }

    /// `translating` nil is a Mac without Translation; `preferredLanguages` is what a nil target resolves against.
    public init(translating: (any Translating)?, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.translating = translating
        self.preferredLanguages = preferredLanguages
    }

    private static func systemTranslation() -> (any Translating)? {
        if #available(macOS 26, *) { SystemTranslation() } else { nil }
    }

    static let engineID: EngineID = "translation"
    public var id: EngineID { Self.engineID }
    public var displayName: String { "Translation" }
    public var maxConcurrentJobs: Int { 1 }

    public func availability() async -> EngineAvailability {
        translating == nil ? .unsupported(reason: Self.needsMacOS26) : .available(version: nil)
    }

    public func edges() -> [ConversionEdge] {
        Self.formats.map {
            ConversionEdge(
                from: $0, to: $0, engineID: id, cost: Self.edgeCost, flags: [.lossy], operation: Self.operation)
        }
    }

    // MARK: Messages (P154, P158)
    // A language that isn't there, an unsupported pair or an unknown language fails the file (`engineUnsupported`, as
    // P164), so Shortcuts and watch folders see it; "already in" and "no text" are work that doesn't apply.

    /// "Italian", "Chinese (Taiwan)": the language in the user's own, named as the wheel names Translate's target, so
    /// two Chinese read apart. A language the locale can't name is its identifier, and an empty one "this language".
    static func name(of language: Locale.Language) -> String {
        let minimal = language.minimalIdentifier
        guard !minimal.isEmpty else { return "this language" }
        return Locale.current.localizedString(forIdentifier: minimal) ?? minimal
    }

    static func notInstalledMessage(_ language: Locale.Language) -> String {
        "Download \(name(of: language)) for translation in System Settings, General, Language & Region."
    }

    static func unsupportedMessage(from source: Locale.Language, to target: Locale.Language) -> String {
        "Pomelo can't translate from \(name(of: source)) to \(name(of: target))."
    }

    static func alreadyMessage(_ language: Locale.Language) -> String {
        "It's already in \(name(of: language))."
    }

    static let undeterminedMessage = "Pomelo can't tell which language this is in."

    // MARK: Convert

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard step.operation == Self.operation, step.from.id == step.to.id, Self.formats.contains(step.from.id) else {
            throw ConversionError.engineFailed(
                engine: id, message: "can't \(step.operation ?? "convert") \(step.from.displayName) into \(step.to.displayName)")
        }
        guard let translating else { throw ConversionError.engineUnsupported(engine: id, reason: Self.needsMacOS26) }
        progress(0)
        let text: String
        do {
            text = try SubtitleEngine.read(step.input)
        } catch {
            throw ConversionError.engineFailed(engine: id, message: "cannot read \(step.input.lastPathComponent)")
        }
        let plan = try makePlan(for: text, format: step.from.id)

        let source = try Self.sourceLanguage(of: plan.texts)
        let target = Locale.Language(identifier: TranslationTarget.identifier(step.options.language, preferred: preferredLanguages))
        guard !Self.sameLanguage(source, target) else {
            throw ConversionError.notApplicable(reason: Self.alreadyMessage(target))
        }
        try await Self.requireInstalled(source: source, target: target, in: translating)

        let translated = try await run(plan.texts, from: source, to: target, in: translating, progress: progress)
        let url = try SubtitleEngine.write(plan.render(translated), for: step, engine: id)
        progress(1)
        return url
    }

    // MARK: Plans

    /// The pieces of a file that get translated, and how the file is put together again from their translations.
    private struct Plan {
        var texts: [String]
        var render: ([String]) -> String
    }

    private func makePlan(for text: String, format: FormatID) throws -> Plan {
        switch format {
        case "srt", "vtt": try subtitlePlan(text, isVTT: format == "vtt")
        case "md": try segmentPlan(MarkdownSegments.split(text), isMarkdown: true)
        default: try segmentPlan(PlainTextSegments.split(text), isMarkdown: false)
        }
    }

    private func subtitlePlan(_ text: String, isVTT: Bool) throws -> Plan {
        let document = try SubtitleEngine.parse(text, isVTT: isVTT)
        guard !document.cues.isEmpty else { throw ConversionError.engineFailed(engine: id, message: "no subtitles found") }
        // An escaped arrow is the VTT writer's doing, not the speaker's.
        let unescape: (String) -> String = { isVTT ? $0.replacingOccurrences(of: "--&gt;", with: "-->") : $0 }
        var texts: [String] = []
        var positions: [Int] = []
        for (index, block) in document.blocks.enumerated() {
            guard case .cue(let entry) = block else { continue }
            let joined = entry.cue.lines.map(unescape).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            if joined.contains(where: \.isLetter) {
                texts.append(joined)
                positions.append(index)
            }
        }
        guard !texts.isEmpty else { throw ConversionError.notApplicable(reason: "There is no text to translate.") }
        return Plan(texts: texts) { translated in
            var result = document
            for (position, text) in zip(positions, translated) {
                guard case .cue(var entry) = result.blocks[position] else { continue }
                entry.cue.lines = SubtitleSegmenter.wrapped(Self.oneLine(text))
                result.blocks[position] = .cue(entry)
            }
            return isVTT ? SubtitleEngine.webVTT(result) : SubtitleEngine.subRip(result)
        }
    }

    private func segmentPlan(_ segments: [MarkdownSegments.Segment], isMarkdown: Bool) throws -> Plan {
        var shapes: [LineShape] = []
        var positions: [Int] = []
        for (index, segment) in segments.enumerated() {
            if case .translate(let text) = segment {
                shapes.append(LineShape(text, isMarkdown: isMarkdown))
                positions.append(index)
            }
        }
        let texts = shapes.flatMap(\.sendTexts)
        guard !texts.isEmpty else { throw ConversionError.notApplicable(reason: "There is no text to translate.") }
        return Plan(texts: texts) { translated in
            var result = segments
            var answers = translated[...]
            for (position, shape) in zip(positions, shapes) {
                let count = shape.sendTexts.count
                result[position] = .translate(shape.render(Array(answers.prefix(count))))
                answers = answers.dropFirst(count)
            }
            return MarkdownSegments.join(result)
        }
    }

    /// A text on one line: for a heading, a table cell or a cue, where a break would break the structure.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The lines of a span to translate, kept in place.
    /// - Plain text: a line break is content (a list, an address), so the lines go as lines and come back to the same
    ///   places.
    /// - Markdown: a soft-wrapped paragraph is one sentence stream (translated line by line it loses its agreement),
    ///   so each run of lines up to a hard break (two trailing spaces, or an odd number of trailing backslashes) goes
    ///   as one text, and the answer is re-wrapped at word boundaries to the run's line count, in proportion to the
    ///   source lines' lengths.
    /// Indentation, the hard break marker and the line ending (CRLF too) are kept as written.
    private struct LineShape {
        struct Line {
            var leading = ""
            var body = ""
            var trailing = ""
            var terminator = ""
            var isHardBreak = false
        }

        let isMarkdown: Bool
        /// Only the lines with text; each group is one translation.
        private(set) var groups: [[Line]] = []

        init(_ text: String, isMarkdown: Bool) {
            self.isMarkdown = isMarkdown
            var lines: [Line] = []
            var current = ""
            func finish(_ terminator: String) {
                var rest = Substring(current)
                var line = Line(terminator: terminator)
                line.leading = String(rest.prefix { $0 == " " || $0 == "\t" })
                rest = rest.dropFirst(line.leading.count)
                let spaces = rest.reversed().prefix { $0 == " " || $0 == "\t" }.count
                line.trailing = String(rest.suffix(spaces))
                rest = rest.dropLast(spaces)
                if isMarkdown {
                    if spaces >= 2 { line.isHardBreak = true }
                    let slashes = rest.reversed().prefix { $0 == "\\" }.count
                    if spaces == 0, slashes % 2 == 1 {
                        line.trailing = "\\"
                        rest = rest.dropLast()
                        line.isHardBreak = true
                    }
                }
                line.body = String(rest)
                lines.append(line)
                current = ""
            }
            for character in text {
                if character.isNewline { finish(String(character)) } else { current.append(character) }
            }
            finish("")
            let spoken = lines.filter { !$0.body.isEmpty }
            guard isMarkdown else {
                groups = spoken.isEmpty ? [] : [spoken]
                return
            }
            var group: [Line] = []
            for line in spoken {
                group.append(line)
                if line.isHardBreak {
                    groups.append(group)
                    group = []
                }
            }
            if !group.isEmpty { groups.append(group) }
        }

        var sendTexts: [String] {
            groups.map { $0.map(\.body).joined(separator: isMarkdown ? " " : "\n") }
        }

        /// `answers` has one text per group. The translator doubles every break it is given, so blank lines in an
        /// answer are not lines.
        func render(_ answers: [String]) -> String {
            zip(groups, answers).map { isMarkdown ? Self.rewrapped($1, as: $0) : Self.matched($1, to: $0) }.joined()
        }

        /// Line for line when the answer has as many lines as were sent, else one line.
        private static func matched(_ answer: String, to lines: [Line]) -> String {
            let answered = answer.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard answered.count == lines.count else {
                let last = lines[lines.count - 1]
                return lines[0].leading + TranslationEngine.oneLine(answer) + last.trailing + last.terminator
            }
            return zip(lines, answered).map { $0.leading + $1 + $0.trailing + $0.terminator }.joined()
        }

        private static func rewrapped(_ answer: String, as lines: [Line]) -> String {
            let words = answer.split(whereSeparator: \.isWhitespace).map(String.init)
            let count = min(lines.count, words.count)
            guard count > 1 else {
                let last = lines[lines.count - 1]
                return lines[0].leading + words.joined(separator: " ") + last.trailing + last.terminator
            }
            // Where each line should end, in characters of the answer, following the source lines' shares.
            let total = words.reduce(0) { $0 + $1.count } + words.count - 1
            let weights = lines.prefix(count).map(\.body.count)
            var pieces: [String] = []
            var index = 0
            var consumed = 0
            var sourceSoFar = 0
            for k in 0..<count {
                if k == count - 1 {
                    pieces.append(words[index...].joined(separator: " "))
                    break
                }
                sourceSoFar += weights[k]
                let goal = Double(total) * Double(sourceSoFar) / Double(weights.reduce(0, +))
                let room = words.count - index - (count - k - 1)
                var taken = 1
                var length = words[index].count
                while taken < room {
                    let longer = length + 1 + words[index + taken].count
                    if abs(Double(consumed + longer) - goal) >= abs(Double(consumed + length) - goal) { break }
                    length = longer
                    taken += 1
                }
                pieces.append(words[index..<(index + taken)].joined(separator: " "))
                index += taken
                consumed += length + 1
            }
            return pieces.enumerated().map { k, piece in
                let source = k == pieces.count - 1 ? lines[lines.count - 1] : lines[k]
                return lines[k].leading + piece + source.trailing + source.terminator
            }.joined()
        }
    }

    // MARK: Languages

    private static func sourceLanguage(of texts: [String]) throws -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else {
            throw ConversionError.engineUnsupported(engine: engineID, reason: undeterminedMessage)
        }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Chinese scripts are different targets; any other language ignores its region.
    private static func sameLanguage(_ first: Locale.Language, _ second: Locale.Language) -> Bool {
        guard let code = first.languageCode, code == second.languageCode else { return false }
        return code.identifier != "zh" || first.minimalIdentifier == second.minimalIdentifier
    }

    private static func requireInstalled(source: Locale.Language, target: Locale.Language, in service: any Translating) async throws {
        switch await service.status(from: source, to: target) {
        case .installed: return
        case .unsupported:
            throw ConversionError.engineUnsupported(engine: engineID, reason: unsupportedMessage(from: source, to: target))
        case .supported:
            throw ConversionError.engineUnsupported(
                engine: engineID, reason: notInstalledMessage(await missing(source, target, in: service)))
        }
    }

    /// The language a supported pair lacks, found through English, which every other language is installed against;
    /// both lacking, or neither found, is the target.
    private static func missing(_ source: Locale.Language, _ target: Locale.Language, in service: any Translating) async -> Locale.Language {
        let english = Locale.Language(identifier: "en")
        func isInstalled(_ language: Locale.Language) async -> Bool {
            if language.languageCode == english.languageCode { return true }
            return await service.status(from: language, to: english) == .installed
        }
        if await !isInstalled(target) { return target }
        if await !isInstalled(source) { return source }
        return target
    }

    // MARK: Translating

    private func run(
        _ texts: [String], from source: Locale.Language, to target: Locale.Language, in service: any Translating,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [String] {
        let session: any TranslatingSession
        do {
            session = try service.startSession(from: source, to: target)
        } catch {
            throw await Self.conversionError(for: error, source: source, target: target, in: service, engine: id)
        }
        var translated: [String] = []
        translated.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(texts[start..<min(start + Self.batchSize, texts.count)])
            let answers: [String]
            do {
                answers = try await session.translate(batch)
            } catch {
                throw await Self.conversionError(for: error, source: source, target: target, in: service, engine: id)
            }
            guard answers.count == batch.count else {
                throw ConversionError.engineFailed(engine: id, message: "the translation came back incomplete")
            }
            // A blank answer keeps the original.
            translated += zip(batch, answers).map { original, answer in
                answer.allSatisfy(\.isWhitespace) ? original : answer
            }
            progress(Double(translated.count) / Double(texts.count))
        }
        try Task.checkCancellation()
        return translated
    }

    private static func conversionError(
        for error: any Error, source: Locale.Language, target: Locale.Language, in service: any Translating,
        engine: EngineID
    ) async -> any Error {
        switch error {
        case is CancellationError, is ConversionError:
            error
        case TranslationFailure.notInstalled:
            ConversionError.engineUnsupported(engine: engine, reason: notInstalledMessage(await missing(source, target, in: service)))
        case TranslationFailure.unsupportedPair:
            ConversionError.engineUnsupported(engine: engine, reason: unsupportedMessage(from: source, to: target))
        default:
            ConversionError.engineFailed(engine: engine, message: "the translation failed")
        }
    }
}
