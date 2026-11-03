import Foundation
import NaturalLanguage
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct TranslationEngineTests {
    private let formats = FormatRegistry.builtIn

    private typealias Pair = FakeTranslating.Pair

    private let sampleSRT = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello, <i>Pomelo</i>. Welcome to the show today.

        2
        00:00:04,000 --> 00:00:06,250
        The arrow a --> b is plain text here.
        And this is a second line of the same cue.

        7
        00:01:00,000 --> 00:01:02,000 X1:100 X2:200
        We will see you again very soon, my friend.

        """

    private func step(_ source: URL, in dir: URL, language: String? = nil) throws -> ConversionStep {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let format = try #require(formats.format(for: source))
        return ConversionStep(
            input: source, stagingDirectory: staging, from: format, to: format, options: PresetOptions(language: language),
            operation: "translate"
        )
    }

    /// Italian by default, as a Mac set to Italian would resolve a nil target.
    private func translate(
        _ source: URL, in dir: URL, language: String? = nil, with fake: FakeTranslating = FakeTranslating(),
        preferred: [String] = ["it-IT"]
    ) async throws -> String {
        let engine = TranslationEngine(translating: fake, preferredLanguages: preferred)
        let output = try await engine.convert(try step(source, in: dir, language: language)) { _ in }
        return try String(contentsOf: output, encoding: .utf8)
    }

    private func failure(
        _ source: URL, in dir: URL, language: String? = nil, with fake: FakeTranslating = FakeTranslating(),
        preferred: [String] = ["it-IT"]
    ) async -> ConversionError? {
        do {
            _ = try await translate(source, in: dir, language: language, with: fake, preferred: preferred)
            return nil
        } catch {
            return error as? ConversionError
        }
    }

    private func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    // MARK: Structure

    @Test func anSRTKeepsItsIDsTimingsAndCoordinates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.srt(sampleSRT, in: dir), in: dir, with: fake)

        #expect(output == """
            1
            00:00:01,000 --> 00:00:03,500
            HELLO, <I>POMELO</I>. WELCOME TO THE SHOW
            TODAY.

            2
            00:00:04,000 --> 00:00:06,250
            THE ARROW A --> B IS PLAIN TEXT HERE. AND
            THIS IS A SECOND LINE OF THE SAME CUE.

            7
            00:01:00,000 --> 00:01:02,000 X1:100 X2:200
            WE WILL SEE YOU AGAIN VERY SOON, MY
            FRIEND.

            """)
        // One text per cue, its lines joined with a space.
        #expect(fake.batches == [[
            "Hello, <i>Pomelo</i>. Welcome to the show today.",
            "The arrow a --> b is plain text here. And this is a second line of the same cue.",
            "We will see you again very soon, my friend.",
        ]])
        #expect(fake.sessions == [Pair("en", "it")])
    }

    @Test func everyLineOfATranslatedCueFitsTheLimit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await translate(try Fixtures.srt(sampleSRT, in: dir), in: dir)

        let textLines = output.components(separatedBy: "\n").filter { !$0.contains("-->") || $0.contains("PLAIN") }
        for line in textLines where line.contains(where: \.isLetter) {
            #expect(line.count <= SubtitleSegmenter.maxLineLength, "\(line)")
        }
    }

    @Test func aVTTKeepsItsSettingsNotesStyleAndIdentifiers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vtt = """
            WEBVTT

            NOTE This is a comment
            that spans two lines

            STYLE
            ::cue { color: red }

            intro
            00:00:01.000 --> 00:00:03.500 align:start position:10%
            <v Ann>Hello, welcome to the show today.</v>

            00:00:04.000 --> 00:00:06.000
            Use a --&gt; b to point at things in this talk.

            """
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.vtt(vtt, in: dir), in: dir, with: fake)

        #expect(output == """
            WEBVTT

            NOTE This is a comment
            that spans two lines

            STYLE
            ::cue { color: red }

            intro
            00:00:01.000 --> 00:00:03.500 align:start position:10%
            <V ANN>HELLO, WELCOME TO THE SHOW
            TODAY.</V>

            00:00:04.000 --> 00:00:06.000
            USE A --&gt; B TO POINT AT THINGS IN THIS
            TALK.

            """)
        // The writer's escape is undone for the translator and redone on the way out.
        #expect(fake.batches.first?.last == "Use a --> b to point at things in this talk.")
    }

    @Test func textKeepsItsParagraphsBlankLinesAndLineEndings() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "First paragraph line one\r\nline two of it.\r\n\r\n   Indented second paragraph here.  \r\n\r\n\r\n"
            + "1. 2. 3.\r\n\r\nLast one without an ending break"
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.textFile(text, ext: "txt", in: dir), in: dir, with: fake)

        #expect(output == "FIRST PARAGRAPH LINE ONE\r\nLINE TWO OF IT.\r\n\r\n   INDENTED SECOND PARAGRAPH HERE.  \r\n\r\n\r\n"
            + "1. 2. 3.\r\n\r\nLAST ONE WITHOUT AN ENDING BREAK")
        // Lines go as lines (CRLF as a plain break), and a span with no letter is not worth sending.
        #expect(fake.batches == [[
            "First paragraph line one\nline two of it.", "Indented second paragraph here.", "Last one without an ending break",
        ]])
    }

    private let listAndAddress = "Shopping list for today:\nMilk and fresh eggs\nBread from the bakery\n\n"
        + "John Smith lives at\n12 Main Street\nSpringfield\n"

    @Test func aParagraphKeepsItsLinesInPlainText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await translate(try Fixtures.textFile(listAndAddress, ext: "txt", in: dir), in: dir)

        #expect(output == listAndAddress.uppercased())
    }

    @Test func linesComeBackToTheirPlacesWhenTheTranslatorDoublesEveryBreak() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // What the real translator does: the line count survives, each break becomes a paragraph break.
        let fake = FakeTranslating(transform: { $0.uppercased().replacingOccurrences(of: "\n", with: "\n\n") })

        let output = try await translate(try Fixtures.textFile(listAndAddress, ext: "txt", in: dir), in: dir, with: fake)

        #expect(output == listAndAddress.uppercased())
    }

    @Test func anAnswerWithADifferentLineCountBecomesOneLine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let merged = FakeTranslating(transform: { $0.uppercased().replacingOccurrences(of: "\n", with: " ") })
        let extra = FakeTranslating(transform: { $0.uppercased() + "\nONE MORE" })
        let source = try Fixtures.textFile("  Milk and eggs for you\n  Bread and butter\n", ext: "txt", in: dir)

        #expect(try await translate(source, in: dir, with: merged) == "  MILK AND EGGS FOR YOU BREAD AND BUTTER\n")
        #expect(try await translate(source, in: dir, with: extra) == "  MILK AND EGGS FOR YOU BREAD AND BUTTER ONE MORE\n")
    }

    @Test func markdownKeepsHardLineBreaksAndWrappedLines() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "First sentence of the poem.  \nSecond sentence of the poem.\\\nThird sentence of the poem.\n"
            + "wrapped on the next line\n"

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir)

        #expect(output == markdown.uppercased())
    }

    @Test func aSoftWrappedMarkdownParagraphIsOneSentenceStream() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "The quick brown fox jumps over the\nlazy dog and then runs away.\n\nSecond paragraph in the file.\n"
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir, with: fake)

        #expect(fake.batches == [[
            "The quick brown fox jumps over the lazy dog and then runs away.", "Second paragraph in the file.",
        ]])
        #expect(output == markdown.uppercased())
    }

    @Test func theAnswerIsRewrappedToTheSameNumberOfLines() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "one short line\na considerably longer second line of prose\nand a third line\n"
        let fake = FakeTranslating(transform: { _ in "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu" })

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir, with: fake)

        let lines = output.components(separatedBy: "\n")
        #expect(lines.count == 4 && lines[3].isEmpty)
        #expect(lines.dropLast().allSatisfy { $0.count > 3 })
        #expect(output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            == "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
        // The longer source line gets the longer share.
        #expect(lines[1].count > lines[0].count)
    }

    @Test func anAnswerWithFewerWordsThanLinesNeverLeavesABlankLine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "first line of the paragraph\nsecond line of the paragraph\nthird line of the paragraph\n\nnext one here\n"
        let fake = FakeTranslating(transform: { $0.hasPrefix("first") ? "ONE TWO" : $0.uppercased() })

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir, with: fake)

        #expect(output == "ONE\nTWO\n\nNEXT ONE HERE\n")
    }

    @Test func hardBreaksSplitAMarkdownParagraphIntoSeparateTexts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "First line of the poem  \nsecond line wraps\nonto a third line\\\nFourth line ends it\n"
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir, with: fake)

        #expect(fake.batches == [["First line of the poem", "second line wraps onto a third line", "Fourth line ends it"]])
        #expect(output == markdown.uppercased())
    }

    @Test func anEvenNumberOfTrailingBackslashesIsNotAHardBreak() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = "A path that ends in a slash C:\\\\\nand then the sentence goes on here.\n"
        let fake = FakeTranslating()

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir, with: fake)

        #expect(fake.batches == [["A path that ends in a slash C:\\\\ and then the sentence goes on here."]])
        #expect(output == markdown.uppercased())
    }

    @Test func markdownIsByteIdenticalOutsideTheTranslatedSpans() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = """
            # Welcome to the project

            This is a paragraph with `inline code` and a [link](https://example.com/page) inside it.
            It continues on the second line of the same paragraph.

            ```swift
            let greeting = "keep this code as it is"
            ```

            | Name | Role |
            |------|------|
            | Ann  | Engineer who writes code |

            - First item in the list
            - Second item with **bold words**

            Visit https://example.com/docs for the details.

            """

        let output = try await translate(try Fixtures.textFile(markdown, ext: "md", in: dir), in: dir)

        func kept(_ text: String) -> [String] {
            MarkdownSegments.split(text).compactMap { if case .keep(let value) = $0 { value } else { nil } }
        }
        #expect(kept(output) == kept(markdown))
        #expect(output != markdown)
        #expect(output.contains("```swift\nlet greeting = \"keep this code as it is\"\n```"))
        #expect(output.contains("[LINK](https://example.com/page)"))
        #expect(output.contains("`inline code`"))
        #expect(output.contains("|------|------|\n"))
        #expect(output.contains("# WELCOME TO THE PROJECT\n"))
        #expect(output.contains("Visit") == false && output.contains("VISIT https://example.com/docs FOR THE DETAILS.\n"))
        #expect(output.hasSuffix("\n") && !output.hasSuffix("\n\n\n"))
    }

    @Test func aBlankAnswerKeepsTheOriginalText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeTranslating(transform: { _ in "  \n " })

        let output = try await translate(try Fixtures.textFile("Hello there my friend.\n", ext: "txt", in: dir), in: dir, with: fake)

        #expect(output == "Hello there my friend.\n")
    }

    // MARK: Languages

    @Test func theTargetIsTheSettingElseTheSystemsFirstLanguage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.textFile("Hello there my friend.\n", ext: "txt", in: dir)

        let system = FakeTranslating()
        _ = try await translate(source, in: dir, with: system, preferred: ["fr-CA", "en"])
        let explicit = FakeTranslating()
        _ = try await translate(source, in: dir, language: "de", with: explicit, preferred: ["fr-CA"])

        #expect(system.sessions == [Pair("en", "fr-CA")])
        #expect(explicit.sessions == [Pair("en", "de")])
    }

    @Test func aFileAlreadyInTheTargetLanguageSaysSo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.textFile("Hello there my friend, how are you today?\n", ext: "txt", in: dir)
        let fake = FakeTranslating()

        let problem = await failure(source, in: dir, with: fake, preferred: ["en-GB"])

        #expect(problem == .notApplicable(reason: "It's already in \(name("en-GB"))."))
        #expect(fake.sessions.isEmpty && fake.batches.isEmpty)
    }

    @Test func aTextWithNoDetectableLanguageSaysSo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let problem = await failure(try Fixtures.textFile("ℵ ℶ\n", ext: "txt", in: dir), in: dir)

        #expect(problem == .engineUnsupported(engine: "translation", reason: "Pomelo can't tell which language this is in."))
    }

    @Test func aFileWithNothingToTranslateSaysSo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let problem = await failure(try Fixtures.textFile("12 34\n\n---\n", ext: "txt", in: dir), in: dir)

        #expect(problem == .notApplicable(reason: "There is no text to translate."))
    }

    @Test func aMissingTargetLanguageIsNamedInSystemSettings() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeTranslating(statuses: [Pair("en", "it"): .supported, Pair("it", "en"): .supported])

        let problem = await failure(try Fixtures.srt(sampleSRT, in: dir), in: dir, with: fake)

        #expect(problem == .engineUnsupported(
            engine: "translation", reason: "Download \(name("it")) for translation in System Settings, General, Language & Region."))
        #expect(fake.batches.isEmpty)
    }

    @Test func aMissingSourceLanguageIsNamedWhenTheTargetIsThere() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let french = try Fixtures.textFile("Bonjour tout le monde, comment allez-vous aujourd'hui ?\n", ext: "txt", in: dir)
        let fake = FakeTranslating(statuses: [Pair("fr", "it"): .supported, Pair("fr", "en"): .supported])

        let problem = await failure(french, in: dir, with: fake)

        #expect(problem == .engineUnsupported(
            engine: "translation", reason: "Download \(name("fr")) for translation in System Settings, General, Language & Region."))
    }

    @Test func whenBothAreMissingTheTargetIsNamed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let french = try Fixtures.textFile("Bonjour tout le monde, comment allez-vous aujourd'hui ?\n", ext: "txt", in: dir)
        let fake = FakeTranslating(statuses: [
            Pair("fr", "it"): .supported, Pair("fr", "en"): .supported, Pair("it", "en"): .supported,
        ])

        let problem = await failure(french, in: dir, with: fake)

        #expect(problem == .engineUnsupported(
            engine: "translation", reason: "Download \(name("it")) for translation in System Settings, General, Language & Region."))
    }

    @Test func anUnsupportedPairSaysWhichTwo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeTranslating(statuses: [Pair("en", "it"): .unsupported])

        let problem = await failure(try Fixtures.srt(sampleSRT, in: dir), in: dir, with: fake)

        #expect(problem == .engineUnsupported(
            engine: "translation", reason: "Pomelo can't translate from \(name("en")) to \(name("it"))."))
    }

    /// Two Chinese keep their names apart, and a target the locale can't name never leaves the sentence empty.
    @Test func languageNamesKeepTheirRegionAndAreNeverEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chinese = try Fixtures.textFile("这是一个简单的测试句子，用于检测语言。我们今天去公园散步。\n", ext: "txt", in: dir)
        let english = try Fixtures.textFile("Hello there my friend, how are you today?\n", ext: "txt", in: dir)

        let traditional = await failure(
            chinese, in: dir, language: "zh-Hant", with: FakeTranslating(statuses: [Pair("zh", "zh-TW"): .unsupported]))
        let hostile = await failure(
            english, in: dir, language: "../../etc", with: FakeTranslating(statuses: [Pair("en", ""): .unsupported]))

        #expect(traditional == .engineUnsupported(
            engine: "translation", reason: "Pomelo can't translate from \(name("zh")) to \(name("zh-TW"))."))
        #expect(name("zh") != name("zh-TW"))
        #expect(hostile == .engineUnsupported(
            engine: "translation", reason: "Pomelo can't translate from \(name("en")) to this language."))
    }

    @Test func theServicesOwnFailuresBecomeTheSameSentences() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.textFile("Hello there my friend.\n", ext: "txt", in: dir)

        let notInstalled = await failure(source, in: dir, with: FakeTranslating(failure: TranslationFailure.notInstalled))
        let unsupported = await failure(source, in: dir, with: FakeTranslating(startFailure: TranslationFailure.unsupportedPair))

        #expect(notInstalled == .engineUnsupported(
            engine: "translation", reason: "Download \(name("it")) for translation in System Settings, General, Language & Region."))
        #expect(unsupported == .engineUnsupported(
            engine: "translation", reason: "Pomelo can't translate from \(name("en")) to \(name("it"))."))
    }

    @Test func anUnknownFailureNeverQuotesTheText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.textFile("Confidential merger terms are attached here.\n", ext: "txt", in: dir)

        let problem = await failure(source, in: dir, with: FakeTranslating(failure: TranslationFailure.other))

        #expect(problem == .engineFailed(engine: "translation", message: "the translation failed"))
    }

    // MARK: Batches and cancelling

    @Test func manyTextsGoInBatchesOfFifty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = (1...120).map { "This is the paragraph number \($0) of the file." }.joined(separator: "\n\n")
        let fake = FakeTranslating()
        let progress = ProgressLog()
        let engine = TranslationEngine(translating: fake, preferredLanguages: ["it"])

        let output = try await engine.convert(
            try step(try Fixtures.textFile(text, ext: "txt", in: dir), in: dir), progress: { progress.add($0) })

        #expect(fake.batches.map(\.count) == [50, 50, 20])
        #expect(try String(contentsOf: output, encoding: .utf8).hasPrefix("THIS IS THE PARAGRAPH NUMBER 1 OF THE FILE.\n\n"))
        let values = progress.values
        #expect(values.first == 0 && values.last == 1)
        #expect(values == values.sorted())
    }

    @Test func cancellingBetweenBatchesStopsAndWritesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = (1...120).map { "This is the paragraph number \($0) of the file." }.joined(separator: "\n\n")
        let fake = FakeTranslating(onBatch: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let engine = TranslationEngine(translating: fake, preferredLanguages: ["it"])
        let conversion = try step(try Fixtures.textFile(text, ext: "txt", in: dir), in: dir)

        await #expect(throws: CancellationError.self) {
            try await engine.convert(conversion) { _ in }
        }

        #expect(fake.batches.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: conversion.stagingDirectory.path).isEmpty)
    }

    // MARK: Availability and edges

    @Test func withoutTheFrameworkTheEngineIsUnsupportedWithItsReason() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = TranslationEngine(translating: nil)

        #expect(await engine.availability() == .unsupported(reason: "Needs macOS 26."))
        let conversion = try step(try Fixtures.textFile("Hello there.\n", ext: "txt", in: dir), in: dir)
        await #expect(throws: ConversionError.engineUnsupported(engine: "translation", reason: "Needs macOS 26.")) {
            try await engine.convert(conversion) { _ in }
        }
        #expect(await TranslationEngine(translating: FakeTranslating()).availability() == .available(version: nil))
    }

    @Test func itTranslatesSubtitlesTextAndMarkdownIntoTheSameFormat() {
        let edges = TranslationEngine(translating: nil).edges()

        #expect(Set(edges.map(\.from)) == ["srt", "vtt", "txt", "md"])
        #expect(edges.allSatisfy { $0.from == $0.to && $0.operation == "translate" && $0.flags.contains(.lossy) })
        #expect(edges.count == 4)
    }

    @Test func theDefaultRegistryOffersTranslateOnItsFormats() async {
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        let planner = await registry.planner(includingMissing: true)

        for format in ["srt", "vtt", "txt", "md"] as [FormatID] {
            #expect(planner.route(from: format, operation: "translate", to: nil) != nil, "\(format)")
        }
    }

    @Test func aStepThatIsNotATranslationIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.textFile("Hello there.\n", ext: "txt", in: dir)
        let conversion = try step(source, in: dir)
        let plain = ConversionStep(
            input: source, stagingDirectory: conversion.stagingDirectory, from: conversion.from, to: conversion.to,
            options: PresetOptions())

        await #expect(throws: ConversionError.self) {
            try await TranslationEngine(translating: FakeTranslating()).convert(plain) { _ in }
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        all.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}
