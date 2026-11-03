import Foundation
import Testing
@testable import PomeloCore

@Suite struct TextChunkerTests {
    private let characters: (String) -> Int = { $0.count }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private let sample = """
    First paragraph has two sentences. Here is the second one.

    Second paragraph is a single longer sentence that goes on for a while without a stop

    Third one. Short.
    """

    @Test func textThatFitsIsOneChunk() {
        #expect(TextChunker.chunks(of: "Hello there.", budget: 100, measure: characters) == ["Hello there."])
    }

    @Test func emptyAndBlankTextGiveNoChunks() {
        #expect(TextChunker.chunks(of: "", budget: 10, measure: characters).isEmpty)
        #expect(TextChunker.chunks(of: " \n\n ", budget: 10, measure: characters).isEmpty)
    }

    @Test func everyChunkFitsTheBudgetAndTheWordsComeBackInOrder() {
        for budget in [15, 30, 60, 120] {
            let chunks = TextChunker.chunks(of: sample, budget: budget, measure: characters)
            #expect(chunks.allSatisfy { characters($0) <= budget }, "budget \(budget)")
            #expect(words(chunks.joined(separator: " ")) == words(sample), "budget \(budget)")
        }
    }

    @Test func chunksPreferParagraphThenSentenceBoundaries() {
        let chunks = TextChunker.chunks(of: sample, budget: 70, measure: characters)
        #expect(chunks.first == "First paragraph has two sentences. Here is the second one.")
        #expect(chunks.contains("Third one. Short."))

        let sentences = TextChunker.chunks(of: "One two three. Four five six. Seven eight nine.", budget: 17, measure: characters)
        #expect(sentences == ["One two three.", "Four five six.", "Seven eight nine."])
    }

    @Test func chunkTextInsideACutIsKeptExactly() {
        let text = "Line one\nline two\n\nPara two   with  gaps"
        let chunks = TextChunker.chunks(of: text, budget: 100, measure: characters)
        #expect(chunks == [text])
        let split = TextChunker.chunks(of: text, budget: 21, measure: characters)
        #expect(split == ["Line one\nline two", "Para two   with  gaps"])
    }

    @Test func aWordOverTheBudgetIsItsOwnChunk() {
        let long = String(repeating: "x", count: 50)
        let chunks = TextChunker.chunks(of: "before \(long) after", budget: 12, measure: characters)
        #expect(chunks == ["before", long, "after"])
    }

    @Test func theInjectedMeasureDecidesWhatFits() {
        let chunks = TextChunker.chunks(of: "a b c d e f g", budget: 3) { words($0).count }
        #expect(chunks == ["a b c", "d e f", "g"])
        let thirds = TextChunker.chunks(of: String(repeating: "abc ", count: 10), budget: 4) { Int((Double($0.count) / 3).rounded(.up)) }
        #expect(thirds.allSatisfy { Int((Double($0.count) / 3).rounded(.up)) <= 4 })
        #expect(thirds.count > 1)
    }

    @Test func aNonPositiveBudgetStillMakesProgress() {
        #expect(TextChunker.chunks(of: "a b", budget: 0, measure: characters) == ["a", "b"])
    }

    @Test func textStartingWithBlankLinesIsChunked() {
        let chunks = TextChunker.chunks(of: "\n\nHello there world this is long text", budget: 20, measure: characters)
        #expect(chunks == ["Hello there world", "this is long text"])
    }

    @Test func textStartingWithIndentationIsChunked() {
        let text = "    Indented first paragraph with many words and no stop at all here"
        let chunks = TextChunker.chunks(of: text, budget: 20, measure: characters)
        #expect(chunks.allSatisfy { characters($0) <= 20 })
        #expect(words(chunks.joined(separator: " ")) == words(text))
    }

    @Test func anIndentedOverBudgetParagraphAfterAShortOneIsChunked() {
        let text = "Short.\n\n   Then an indented paragraph with many words and no sentence stop at all"
        let chunks = TextChunker.chunks(of: text, budget: 20, measure: characters)
        #expect(chunks.first == "Short.")
        #expect(chunks.allSatisfy { characters($0) <= 20 })
        #expect(words(chunks.joined(separator: " ")) == words(text))
    }
}
