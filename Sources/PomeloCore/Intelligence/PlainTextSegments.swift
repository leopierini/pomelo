import Foundation

/// Plain text cut into paragraphs to translate and the line breaks and blank lines to keep, the way
/// `MarkdownSegments` does for Markdown: `MarkdownSegments.join(split(x)) == x` byte for byte. A paragraph is a run of
/// non-blank lines; its inner line breaks stay inside the span.
public enum PlainTextSegments {
    public static func split(_ text: String) -> [MarkdownSegments.Segment] {
        var builder = Builder()
        var paragraph = ""
        var pendingBreak = ""
        func endParagraph() {
            builder.translate(paragraph)
            paragraph = ""
        }
        for line in linesWithTerminators(text) {
            if line.content.allSatisfy(\.isWhitespace) {
                endParagraph()
                builder.keep(pendingBreak)
                builder.keep(line.content)
                pendingBreak = line.terminator
                continue
            }
            if paragraph.isEmpty {
                builder.keep(pendingBreak)
            } else {
                paragraph += pendingBreak
            }
            paragraph += line.content
            pendingBreak = line.terminator
        }
        endParagraph()
        builder.keep(pendingBreak)
        return builder.normalized()
    }
}
