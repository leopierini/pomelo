import Foundation
import NaturalLanguage
import Testing
import Translation
import os
import PomeloCore
import PomeloTestSupport
@testable import PomeloEngines

/// Whether this Mac has the English and Italian translation languages installed. Asked once, synchronously, because a
/// test trait cannot wait.
private let englishItalianInstalled: Bool = {
    guard #available(macOS 26, *) else { return false }
    let answer = OSAllocatedUnfairLock(initialState: false)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en"), italian = Locale.Language(identifier: "it")
        let forward = await availability.status(from: english, to: italian)
        let back = await availability.status(from: italian, to: english)
        answer.withLock { $0 = forward == .installed && back == .installed }
        done.signal()
    }
    done.wait()
    return answer.withLock { $0 }
}()

@Suite struct SystemTranslationTests {
    @Test @available(macOS 26, *) func theFrameworksErrorsBecomeTheSeamsFailures() {
        func failure(_ error: any Error) -> TranslationFailure? {
            SystemTranslationSession.failure(for: error) as? TranslationFailure
        }
        #expect(failure(TranslationError.notInstalled) == .notInstalled)
        #expect(failure(TranslationError.unsupportedLanguagePairing) == .unsupportedPair)
        #expect(failure(TranslationError.unsupportedSourceLanguage) == .unsupportedPair)
        #expect(failure(TranslationError.unsupportedTargetLanguage) == .unsupportedPair)
        #expect(failure(TranslationError.internalError) == .other)
        #expect(failure(CocoaError(.fileReadUnknown)) == .other)
        #expect(SystemTranslationSession.failure(for: TranslationError.alreadyCancelled) is CancellationError)
        #expect(SystemTranslationSession.failure(for: CancellationError()) is CancellationError)
    }

    @Test @available(macOS 26, *) func theDefaultEngineOnMacOS26IsAvailable() async {
        #expect(await TranslationEngine().availability() == .available(version: nil))
    }

    @Test(.enabled(if: englishItalianInstalled))
    @available(macOS 26, *) func aRealSubtitleFileTranslatesFromEnglishToItalian() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = """
            1
            00:00:01,000 --> 00:00:03,500
            The file was converted next to the original.

            2
            00:00:04,000 --> 00:00:06,250 X1:10 X2:20
            Thank you for watching, and see you next time.

            """
        let source = try Fixtures.srt(srt, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let format = try #require(FormatRegistry.builtIn.format(for: source))
        let step = ConversionStep(
            input: source, stagingDirectory: staging, from: format, to: format, options: PresetOptions(language: "it"),
            operation: "translate")

        let output = try await TranslationEngine().convert(step) { _ in }

        let text = try String(contentsOf: output, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let original = srt.components(separatedBy: "\n")
        #expect(lines.count >= original.count)
        // Ids, timings and coordinates are untouched.
        #expect(Array(lines.prefix(2)) == Array(original.prefix(2)))
        #expect(lines.contains("00:00:04,000 --> 00:00:06,250 X1:10 X2:20"))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lines.filter { !$0.contains("-->") && Int($0) == nil }.joined(separator: " "))
        #expect(recognizer.dominantLanguage == .italian)
        #expect(!text.contains("converted"))
    }

    @Test(.enabled(if: englishItalianInstalled))
    @available(macOS 26, *) func realMarkdownKeepsItsStructure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = """
            # Getting started

            Run `pomelo engines` to see what this Mac can do. Read the [manual](https://example.com/manual) first.

            ```sh
            pomelo convert photo.heic --to jpg
            ```

            - Drop a file on the wheel
            - Pick a format

            """
        let source = try Fixtures.textFile(markdown, ext: "md", in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let format = try #require(FormatRegistry.builtIn.format(for: source))
        let step = ConversionStep(
            input: source, stagingDirectory: staging, from: format, to: format, options: PresetOptions(language: "it"),
            operation: "translate")

        let output = try await TranslationEngine().convert(step) { _ in }

        let text = try String(contentsOf: output, encoding: .utf8)
        func kept(_ text: String) -> [String] {
            MarkdownSegments.split(text).compactMap { if case .keep(let value) = $0 { value } else { nil } }
        }
        #expect(kept(text) == kept(markdown))
        #expect(text != markdown)
    }

    @Test(.enabled(if: englishItalianInstalled))
    @available(macOS 26, *) func realTextKeepsTheThreeLinesOfAParagraph() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = "Shopping list for today:\nMilk and fresh eggs\nBread from the bakery\n"
        let source = try Fixtures.textFile(original, ext: "txt", in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let format = try #require(FormatRegistry.builtIn.format(for: source))
        let step = ConversionStep(
            input: source, stagingDirectory: staging, from: format, to: format, options: PresetOptions(language: "it"),
            operation: "translate")

        let output = try await TranslationEngine().convert(step) { _ in }

        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.components(separatedBy: "\n").count == 4)
        #expect(text.hasSuffix("\n") && !text.contains("\n\n") && text != original)
    }

    @Test(.enabled(if: englishItalianInstalled))
    @available(macOS 26, *) func realMarkdownTranslatesASoftWrappedParagraphAsOneSentence() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func translate(_ markdown: String) async throws -> String {
            let source = try Fixtures.textFile(markdown, ext: "md", in: dir)
            let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let format = try #require(FormatRegistry.builtIn.format(for: source))
            let step = ConversionStep(
                input: source, stagingDirectory: staging, from: format, to: format,
                options: PresetOptions(language: "it"), operation: "translate")
            return try String(contentsOf: try await TranslationEngine().convert(step) { _ in }, encoding: .utf8)
        }

        let wrapped = try await translate("The quick brown fox jumps over the\nlazy dog and then runs away.\n")
        let oneLine = try await translate("The quick brown fox jumps over the lazy dog and then runs away.\n")

        #expect(wrapped.components(separatedBy: "\n").count == 3)
        #expect(wrapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            == oneLine.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
