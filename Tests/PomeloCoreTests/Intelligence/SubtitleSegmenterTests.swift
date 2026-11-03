import Foundation
import Testing
@testable import PomeloCore

@Suite struct SubtitleSegmenterTests {
    /// Words spoken back to back, `each` seconds apart, from `start`.
    private func speech(_ texts: [String], start: Double = 0, each: Double = 0.25) -> [TimedWord] {
        texts.enumerated().map { index, text in
            TimedWord(text: text, start: start + Double(index) * each, end: start + Double(index + 1) * each)
        }
    }

    private func assertWellFormed(_ cues: [Cue], sourceLocation: SourceLocation = #_sourceLocation) {
        var previousEnd = -Double.infinity
        for cue in cues {
            #expect(cue.end >= cue.start, sourceLocation: sourceLocation)
            #expect(cue.start >= previousEnd, sourceLocation: sourceLocation)
            #expect(cue.lines.count >= 1 && cue.lines.count <= 2, sourceLocation: sourceLocation)
            previousEnd = cue.end
        }
    }

    @Test func denseSpeechFillsCuesWithinTheLimits() {
        let texts = (1...60).map { "word\($0)" }
        let cues = SubtitleSegmenter.cues(from: speech(texts, each: 0.4))
        assertWellFormed(cues)
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.lines.allSatisfy { $0.count <= 42 })
            #expect(cue.end - cue.start <= 7)
        }
        let spoken = cues.flatMap(\.lines).joined(separator: " ")
        #expect(spoken == texts.joined(separator: " "))
    }

    @Test func aCueFillsTwoLinesBeforeItBreaks() {
        let texts = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"]
        let cues = SubtitleSegmenter.cues(from: speech(texts))
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["alpha bravo charlie delta echo foxtrot", "golf hotel india juliet"])
    }

    @Test func aLineIsAtMostFortyTwoCharacters() {
        let exactly42 = String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 21)
        #expect(exactly42.count == 42)
        let words = speech(exactly42.split(separator: " ").map(String.init))
        #expect(SubtitleSegmenter.cues(from: words)[0].lines == [exactly42])

        let over = speech([String(repeating: "a", count: 20), String(repeating: "b", count: 22)])
        #expect(SubtitleSegmenter.cues(from: over)[0].lines == [String(repeating: "a", count: 20), String(repeating: "b", count: 22)])
    }

    @Test func aSentenceEndStartsANewCue() {
        let cues = SubtitleSegmenter.cues(from: speech(["Hello", "there.", "How", "are", "you?", "Fine", "thanks!"]))
        #expect(cues.map(\.lines) == [["Hello there."], ["How are you?"], ["Fine thanks!"]])
    }

    @Test func aClosingQuoteAfterThePeriodStillEndsTheSentence() {
        let cues = SubtitleSegmenter.cues(from: speech(["He", "said", "\"go.\"", "Then", "left"]))
        #expect(cues.map(\.lines) == [["He said \"go.\""], ["Then left"]])
    }

    @Test func aPauseOfEightTenthsOfASecondStartsANewCue() {
        let at = { (gap: Double) -> [Cue] in
            SubtitleSegmenter.cues(from: [
                TimedWord(text: "one", start: 0, end: 1),
                TimedWord(text: "two", start: 1 + gap, end: 2 + gap),
            ])
        }
        #expect(at(0.75).count == 1)
        #expect(at(0.8).count == 2)
        #expect(at(3).map(\.lines) == [["one"], ["two"]])
    }

    @Test func aCueIsNeverLongerThanSevenSeconds() {
        let texts = (1...10).map { "w\($0)" }
        let cues = SubtitleSegmenter.cues(from: speech(texts, each: 1))
        assertWellFormed(cues)
        #expect(cues.map { $0.end - $0.start }.allSatisfy { $0 <= 7 })
        #expect(cues.count == 2)
        #expect(cues[0].lines == ["w1 w2 w3 w4 w5 w6 w7"])
    }

    @Test func wordsNestedInsideALongWordCannotStretchACuePastSevenSeconds() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: "A", start: 0, end: 9),
            TimedWord(text: "B", start: 1, end: 2),
            TimedWord(text: "C", start: 2, end: 3),
        ])
        #expect(cues == [Cue(start: 0, end: 9, lines: ["A"]), Cue(start: 9, end: 9.5, lines: ["B C"])])
    }

    @Test func aSingleWordGetsOneCueWithItsTimes() {
        let cues = SubtitleSegmenter.cues(from: [TimedWord(text: "Hi", start: 1.5, end: 2)])
        #expect(cues == [Cue(start: 1.5, end: 2, lines: ["Hi"])])
    }

    @Test func noWordsGiveNoCues() {
        #expect(SubtitleSegmenter.cues(from: []).isEmpty)
        #expect(SubtitleSegmenter.cues(from: [TimedWord(text: "  ", start: 0, end: 1)]).isEmpty)
    }

    @Test func aNinetyCharacterWordGetsItsOwnLine() {
        let long = String(repeating: "x", count: 90)
        #expect(SubtitleSegmenter.cues(from: speech([long], each: 0.6)) == [Cue(start: 0, end: 0.6, lines: [long])])

        let cues = SubtitleSegmenter.cues(from: speech(["hi", long, "bye"]))
        #expect(cues.map(\.lines) == [["hi", long], ["bye"]])
        assertWellFormed(cues)
    }

    @Test func wordsOutOfOrderAreSortedFirst() {
        let ordered = speech(["Good", "morning", "everyone.", "Let's", "begin."])
        let shuffled = [ordered[3], ordered[0], ordered[4], ordered[2], ordered[1]]
        #expect(SubtitleSegmenter.cues(from: shuffled) == SubtitleSegmenter.cues(from: ordered))
        #expect(SubtitleSegmenter.cues(from: shuffled).map(\.lines) == [["Good morning everyone."], ["Let's begin."]])
    }

    @Test func overlappingTimesNeverOverlapCues() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: "One.", start: 0, end: 2),
            TimedWord(text: "Two.", start: 1, end: 1.2),
        ])
        #expect(cues == [Cue(start: 0, end: 2, lines: ["One."]), Cue(start: 2, end: 2.5, lines: ["Two."])])
    }

    @Test func aWordThatEndsBeforeItStartsGetsTheShortestCue() {
        let cues = SubtitleSegmenter.cues(from: [TimedWord(text: "Odd", start: 3, end: 2)])
        #expect(cues == [Cue(start: 3, end: 3.5, lines: ["Odd"])])
    }

    @Test func aShortCueStretchesToHalfASecondButNeverIntoTheNext() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: "Hi.", start: 1, end: 1.1),
            TimedWord(text: "Yes.", start: 1.2, end: 1.2),
            TimedWord(text: "Now", start: 3, end: 3.4),
        ])
        #expect(cues == [
            Cue(start: 1, end: 1.2, lines: ["Hi."]), Cue(start: 1.2, end: 1.7, lines: ["Yes."]),
            Cue(start: 3, end: 3.5, lines: ["Now"]),
        ])
    }

    /// Review M3: back-to-back one-word sentences kept their own times instead of drifting 0.3 s a cue.
    @Test func quickCuesNeverDriftLater() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: "Yes.", start: 0, end: 0.2), TimedWord(text: "No.", start: 0.2, end: 0.4),
            TimedWord(text: "Okay.", start: 0.4, end: 0.6), TimedWord(text: "Fine.", start: 0.6, end: 0.8),
        ])
        #expect(cues.map(\.start) == [0, 0.2, 0.4, 0.6])
        #expect(cues.map(\.end) == [0.2, 0.4, 0.6, 1.1])
    }

    @Test func aCueWithNoLengthStillShowsAndTheNextOneWaits() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: "One.", start: 0, end: 2), TimedWord(text: "Two.", start: 1, end: 1.2),
            TimedWord(text: "Three.", start: 2, end: 3),
        ])
        #expect(cues == [
            Cue(start: 0, end: 2, lines: ["One."]), Cue(start: 2, end: 2.5, lines: ["Two."]),
            Cue(start: 2.5, end: 3, lines: ["Three."]),
        ])
    }

    @Test func punctuationAndSpacesStayAsTheRecognizerGaveThem() {
        let cues = SubtitleSegmenter.cues(from: [
            TimedWord(text: " Hello,", start: 0, end: 0.5),
            TimedWord(text: "world", start: 0.5, end: 1),
            TimedWord(text: " again…", start: 1, end: 1.5),
        ])
        #expect(cues.map(\.lines) == [["Hello, world again…"]])
    }

    @Test func paragraphsBreakAtAPauseOfTwoSeconds() {
        let words = [
            TimedWord(text: "First", start: 0, end: 1),
            TimedWord(text: "part.", start: 1, end: 2),
            TimedWord(text: "Still", start: 3.75, end: 4),
            TimedWord(text: "same.", start: 4, end: 5),
            TimedWord(text: "Second", start: 7, end: 8),
            TimedWord(text: "paragraph.", start: 8, end: 9),
        ]
        #expect(SubtitleSegmenter.paragraphs(from: words) == ["First part. Still same.", "Second paragraph."])
    }

    @Test func paragraphsOfNothingAreEmptyAndOutOfOrderWordsAreSorted() {
        #expect(SubtitleSegmenter.paragraphs(from: []).isEmpty)
        let words = speech(["a", "b", "c"])
        #expect(SubtitleSegmenter.paragraphs(from: [words[2], words[0], words[1]]) == ["a b c"])
    }

    // MARK: wrapped

    @Test func wrappedKeepsShortTextOnOneLine() {
        #expect(SubtitleSegmenter.wrapped("  Hello   there \n friend ") == ["Hello there friend"])
        #expect(SubtitleSegmenter.wrapped("   ").isEmpty)
    }

    @Test func wrappedBreaksAtWordsUnderTheLineLimit() {
        let lines = SubtitleSegmenter.wrapped("The quick brown fox jumps over the lazy dog and keeps going")
        #expect(lines == ["The quick brown fox jumps over the lazy", "dog and keeps going"])
        #expect(lines.allSatisfy { $0.count <= SubtitleSegmenter.maxLineLength })
    }

    @Test func wrappedNeverMakesAThirdLine() {
        let words = Array(repeating: "word", count: 40).joined(separator: " ")
        let lines = SubtitleSegmenter.wrapped(words)
        #expect(lines.count == SubtitleSegmenter.maxLines)
        #expect(lines.joined(separator: " ") == words)
    }

    @Test func wrappedCutsAWordWithNoSpaces() {
        let text = String(repeating: "字", count: 100)
        let lines = SubtitleSegmenter.wrapped(text)
        #expect(lines.count == 2)
        #expect(lines.joined().count == 100)
        #expect(lines[0].count == SubtitleSegmenter.maxLineLength)
    }
}
