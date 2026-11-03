import Foundation

/// Timed words to subtitle cues and transcript paragraphs.
public enum SubtitleSegmenter {
    public static let maxLineLength = 42
    public static let maxLines = 2
    public static let maxCueDuration = 7.0
    public static let cueBreakPause = 0.8
    /// A short cue is stretched to this, up to the next cue's start; one with no length at all always gets it.
    public static let minimumCueDuration = 0.5
    public static let paragraphBreakPause = 2.0

    /// Seconds are doubles, so a pause of "0.8" can come out a hair under it.
    private static let tolerance = 1e-9

    public static func cues(from words: [TimedWord]) -> [Cue] {
        var cues: [Cue] = []
        var current: [TimedWord] = []
        var currentEnd = 0.0

        func finishCue() {
            guard let first = current.first else { return }
            var start = first.start
            var end = max(currentEnd, start)
            // Overlapping words must not make overlapping cues: players show only one cue at a time.
            if let previous = cues.last, start < previous.end {
                start = previous.end
                end = max(end, start)
            }
            cues.append(Cue(start: start, end: end, lines: wrap(current.map(\.text))))
            current = []
        }

        for word in prepared(words) {
            if let first = current.first, let last = current.last {
                let breaks = endsSentence(last.text)
                    || word.start - currentEnd >= cueBreakPause - tolerance
                    || max(currentEnd, word.end) - first.start > maxCueDuration
                    || wrap(current.map(\.text) + [word.text]).count > maxLines
                if breaks { finishCue() }
            }
            current.append(word)
            currentEnd = current.count == 1 ? word.end : max(currentEnd, word.end)
        }
        finishCue()
        return stretched(cues)
    }

    /// Each cue stretched to `minimumCueDuration`, but only up to where the next one starts, so quick cues never push
    /// the later ones; a cue left with no length at all takes the whole minimum, and the cues after it wait.
    private static func stretched(_ cues: [Cue]) -> [Cue] {
        var result = cues
        for index in result.indices {
            if index > 0, result[index].start < result[index - 1].end {
                result[index].start = result[index - 1].end
                result[index].end = max(result[index].end, result[index].start)
            }
            let wanted = result[index].start + minimumCueDuration
            let next = index + 1 < result.count ? result[index + 1].start : wanted
            result[index].end = max(result[index].end, min(wanted, next))
            if result[index].end <= result[index].start + tolerance { result[index].end = wanted }
        }
        return result
    }

    public static func paragraphs(from words: [TimedWord]) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var end = 0.0
        for word in prepared(words) {
            if !current.isEmpty, word.start - end >= paragraphBreakPause - tolerance {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            end = current.isEmpty ? word.end : max(end, word.end)
            current.append(word.text)
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs
    }

    /// Sorted by time (stable), whitespace trimmed and collapsed, unusable words dropped, and a word that ends before
    /// it starts given a zero length.
    private static func prepared(_ words: [TimedWord]) -> [TimedWord] {
        words.enumerated()
            .compactMap { offset, word -> (Int, TimedWord)? in
                guard word.start.isFinite, word.end.isFinite else { return nil }
                let text = word.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !text.isEmpty else { return nil }
                return (offset, TimedWord(text: text, start: word.start, end: max(word.end, word.start)))
            }
            .sorted { ($0.1.start, $0.1.end, $0.0) < ($1.1.start, $1.1.end, $1.0) }
            .map(\.1)
    }

    /// Text re-wrapped for a cue: at most `maxLines` lines. Text with a word longer than a line (CJK has no spaces)
    /// is cut every `maxLineLength` characters; text that needs more lines keeps the rest on the last one, which then
    /// runs long, because a cue's time is fixed.
    public static func wrapped(_ text: String) -> [String] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String]
        var separator = " "
        if tokens.contains(where: { $0.count > maxLineLength }) {
            let characters = Array(tokens.joined(separator: " "))
            lines = stride(from: 0, to: characters.count, by: maxLineLength).map {
                String(characters[$0..<min($0 + maxLineLength, characters.count)])
            }
            separator = ""
        } else {
            lines = wrap(tokens)
        }
        guard lines.count > maxLines else { return lines }
        return Array(lines.prefix(maxLines - 1)) + [lines.dropFirst(maxLines - 1).joined(separator: separator)]
    }

    /// Greedy wrap; a token longer than a line sits alone on its own line.
    private static func wrap(_ tokens: [String]) -> [String] {
        var lines: [String] = []
        for token in tokens {
            if let last = lines.last, last.count + 1 + token.count <= maxLineLength {
                lines[lines.count - 1] = last + " " + token
            } else {
                lines.append(token)
            }
        }
        return lines
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "»"]
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        guard let last = text.last(where: { !closers.contains($0) }) else { return false }
        return terminators.contains(last)
    }
}
