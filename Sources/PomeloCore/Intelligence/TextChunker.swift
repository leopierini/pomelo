import Foundation

/// Text cut into pieces that each fit a budget, at paragraph ends where it can, else at sentence ends, else between
/// words. The budget's unit is whatever `measure` counts (characters / 3 below macOS 26.4, the model's tokens above).
public enum TextChunker {
    /// Every chunk measures at most `budget`, except a single word that is over it on its own. Chunks in order give
    /// the text back, except for the whitespace at the cuts.
    public static func chunks(of text: String, budget: Int, measure: (String) -> Int) -> [String] {
        pack(text, level: .paragraphs, budget: max(budget, 1), measure: measure)
    }

    private enum Level: Int {
        case paragraphs, sentences, words
    }

    private static func pack(_ text: String, level: Level, budget: Int, measure: (String) -> Int) -> [String] {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if whole.isEmpty { return [] }
        if measure(whole) <= budget { return [whole] }
        let finer = Level(rawValue: level.rawValue + 1)

        var chunks: [String] = []
        var current = ""
        func flush() {
            let chunk = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            current = ""
        }
        for piece in pieces(of: text, level: level) {
            if measure((current + piece).trimmingCharacters(in: .whitespacesAndNewlines)) <= budget {
                current += piece
                continue
            }
            flush()
            if measure(piece.trimmingCharacters(in: .whitespacesAndNewlines)) <= budget {
                current = piece
            } else if let finer {
                chunks += pack(piece, level: finer, budget: budget, measure: measure)
            } else {
                chunks.append(piece.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        flush()
        return chunks
    }

    /// Consecutive pieces that add up to the text: each keeps the whitespace that follows it.
    private static func pieces(of text: String, level: Level) -> [String] {
        switch level {
        case .paragraphs:
            var pieces: [String] = []
            var previousBlank = false
            for line in linesWithTerminators(text) {
                let blank = line.content.allSatisfy(\.isWhitespace)
                if pieces.isEmpty || (!blank && previousBlank) {
                    pieces.append("")
                }
                pieces[pieces.count - 1] += line.content + line.terminator
                previousBlank = blank
            }
            return pieces
        case .sentences:
            var pieces: [String] = []
            text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, _, enclosing, _ in
                pieces.append(String(text[enclosing]))
            }
            return pieces
        case .words:
            var pieces: [String] = []
            var inWhitespace = false
            for character in text {
                if pieces.isEmpty {
                    pieces.append("")
                } else if character.isWhitespace {
                    inWhitespace = true
                } else if inWhitespace {
                    pieces.append("")
                    inWhitespace = false
                }
                pieces[pieces.count - 1].append(character)
            }
            return pieces
        }
    }
}
