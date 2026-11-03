import Foundation
import Testing
@testable import PomeloCore

@Suite struct PlainTextSegmentsTests {
    private typealias Segment = MarkdownSegments.Segment

    private func spans(_ text: String) -> [String] {
        PlainTextSegments.split(text).compactMap { if case let .translate(value) = $0 { value } else { nil } }
    }

    @Test func everyTextComesBackByteForByte() {
        let fixtures = [
            "", "\n", "\n\n\n", "One line", "One line\n", "a\nb\n\nc\n", "a\r\nb\r\n\r\nc", "  indented\n\t\n  more  \n\n\n",
            "last has no break\n\nsecond", "\u{FEFF}bom\n", "1. 2. 3.\n---\n\nreal words here\n",
        ]
        for text in fixtures {
            #expect(MarkdownSegments.join(PlainTextSegments.split(text)) == text, "\(text.debugDescription)")
        }
    }

    @Test func aParagraphIsARunOfNonBlankLines() {
        #expect(spans("first line\nsecond line\n\nnext one\n") == ["first line\nsecond line", "next one"])
        #expect(spans("first\r\nsecond\r\n\r\nthird\r\n") == ["first\r\nsecond", "third"])
    }

    @Test func blankLinesAndIndentationStayOutsideTheSpans() {
        #expect(PlainTextSegments.split("  Hello there  \n \t \nBye now\n") == [
            Segment.keep("  "), .translate("Hello there"), .keep("  \n \t \n"), .translate("Bye now"), .keep("\n"),
        ])
    }

    @Test func linesWithoutLettersAreNotTranslated() {
        #expect(spans("-----\n\n12 34\n\nwords\n") == ["words"])
    }
}
