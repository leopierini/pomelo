import Foundation

/// Markdown cut into the spans a translator may change and the spans it must not touch, so the structure survives
/// translation. `join(split(x)) == x` byte for byte; the translatable spans have no leading or trailing whitespace and
/// always contain a letter.
public enum MarkdownSegments {
    public enum Segment: Equatable, Sendable {
        case translate(String)
        case keep(String)
    }

    public static func split(_ markdown: String) -> [Segment] {
        let lines = linesWithTerminators(markdown)
        var parser = Parser()
        var output = Builder()
        let frontMatter = frontMatterLineCount(lines)
        for line in lines.prefix(frontMatter) { output.keep(line.content + line.terminator) }
        var pendingTerminator = ""
        var previousPlain = false
        for index in frontMatter..<lines.count {
            let line = lines[index]
            let next = index + 1 < lines.count ? Array(lines[index + 1].content) : []
            let result = parser.parse(Array(line.content), next: next)
            // Lines of one paragraph go to the translator together: hard-wrapped prose loses its sentences otherwise.
            if previousPlain, result.plain, output.endsWithTranslation, case .translate? = result.segments.first {
                output.translate(pendingTerminator)
            } else {
                output.keep(pendingTerminator)
            }
            for segment in result.segments { output.add(segment) }
            pendingTerminator = line.terminator
            previousPlain = result.plain
        }
        output.keep(pendingTerminator)
        return output.normalized()
    }

    /// A YAML (`---` to `---` or `...`) or TOML (`+++`) block opening the file is the page's data, not prose: its
    /// keys and values stay as written. The number of its lines, the closing one included; 0 when there is none.
    static func frontMatterLineCount(_ lines: [(content: String, terminator: String)]) -> Int {
        guard var opening = lines.first?.content[...] else { return 0 }
        if opening.first == "\u{FEFF}" { opening = opening.dropFirst() }
        let closers: Set<String> = switch trimmedTrailing(opening) {
        case "---": ["---", "..."]
        case "+++": ["+++"]
        default: []
        }
        // Pandoc's rule: a blank line right after the opening `---` makes it a horizontal rule, not front matter.
        if opening.starts(with: "---"), lines.count > 1, lines[1].content.allSatisfy(\.isWhitespace) { return 0 }
        guard !closers.isEmpty,
              let close = lines.dropFirst().firstIndex(where: { closers.contains(trimmedTrailing($0.content[...])) })
        else { return 0 }
        return close + 1
    }

    private static func trimmedTrailing(_ text: Substring) -> String {
        String(text.reversed().drop(while: \.isWhitespace).reversed())
    }

    public static func join(_ segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case let .translate(text), let .keep(text): text
            }
        }.joined()
    }
}

/// Lines without their terminator ("\n" or "\r\n"), which comes separately. Cuts on scalars: "\r\n" is one Character.
func linesWithTerminators(_ text: String) -> [(content: String, terminator: String)] {
    var lines: [(content: String, terminator: String)] = []
    var current = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if scalar == "\n" {
            var terminator = "\n"
            if current.last == "\r" {
                current.removeLast()
                terminator = "\r\n"
            }
            lines.append((String(current), terminator))
            current = String.UnicodeScalarView()
        } else {
            current.append(scalar)
        }
    }
    if !current.isEmpty { lines.append((String(current), "")) }
    return lines
}

struct Builder {
    var segments: [MarkdownSegments.Segment] = []

    var endsWithTranslation: Bool {
        if case .translate? = segments.last { true } else { false }
    }

    mutating func translate(_ text: String) { add(.translate(text)) }
    mutating func keep(_ text: String) { add(.keep(text)) }
    mutating func keep(_ characters: some Collection<Character>) { keep(String(characters)) }

    mutating func add(_ segment: MarkdownSegments.Segment) {
        switch segment {
        case .translate(""), .keep(""): return
        default: break
        }
        switch (segments.last, segment) {
        case let (.translate(old)?, .translate(new)): segments[segments.count - 1] = .translate(old + new)
        case let (.keep(old)?, .keep(new)): segments[segments.count - 1] = .keep(old + new)
        default: segments.append(segment)
        }
    }

    /// Whitespace around a translatable span is kept outside it, and a span with no letter is not worth translating.
    func normalized() -> [MarkdownSegments.Segment] {
        var result = Builder()
        for segment in segments {
            switch segment {
            case let .keep(text):
                result.keep(text)
            case let .translate(text):
                let characters = Array(text)
                let first = characters.firstIndex { !$0.isWhitespace }
                let last = characters.lastIndex { !$0.isWhitespace }
                guard let first, let last, characters[first...last].contains(where: \.isLetter) else {
                    result.keep(text)
                    continue
                }
                result.keep(characters[..<first])
                result.translate(String(characters[first...last]))
                result.keep(characters[(last + 1)...])
            }
        }
        return result.segments
    }
}

private struct Parser {
    private var fence: (marker: Character, length: Int)?
    private var inComment = false
    private var listOpen = false
    private var previousBlank = true
    private var previousWasIndentedCode = false
    private var table = TableState.none

    private enum TableState { case none, expectingDelimiter, body }

    /// `plain` marks a line that is only paragraph text, which may join the next plain line in one segment.
    mutating func parse(_ line: [Character], next: [Character]) -> (segments: [MarkdownSegments.Segment], plain: Bool) {
        let keepsAll = (segments: [MarkdownSegments.Segment.keep(String(line))], plain: false)
        let quoteLength = Self.quotePrefixLength(line)
        let body = Array(line[quoteLength...])
        if continuesKeptBlock(line, body: body) { return keepsAll }
        let indent = Self.indentWidth(body)
        let text = Array(body.drop { $0 == " " || $0 == "\t" })
        if opensKeptBlock(text, indent: indent) { return keepsAll }

        var builder = Builder()
        builder.keep(line[..<quoteLength])
        let leading = body[..<(body.count - text.count)]
        if let keptLength = Self.definitionKeptLength(text, indent: indent) {
            builder.keep(leading)
            builder.keep(text[..<keptLength])
            Self.scanInline(Array(text[keptLength...]), into: &builder)
            return (builder.segments, false)
        }
        if scanTable(text, body: body, next: next, into: &builder) { return (builder.segments, false) }

        builder.keep(leading)
        if indent < 4, let markerLength = Self.headingMarkerLength(text) {
            builder.keep(text[..<markerLength])
            Self.scanHeadingText(Array(text[markerLength...]), into: &builder)
            return (builder.segments, false)
        }
        if let markerLength = Self.listMarkerLength(text) {
            listOpen = true
            builder.keep(text[..<markerLength])
            Self.scanInline(Array(text[markerLength...]), into: &builder)
            return (builder.segments, false)
        }
        Self.scanInline(text, into: &builder)
        return (builder.segments, quoteLength == 0 && leading.isEmpty)
    }

    /// A line inside a comment or a fence, or a blank one: kept whole, as the lines before decided.
    private mutating func continuesKeptBlock(_ line: [Character], body: [Character]) -> Bool {
        if inComment {
            if String(line).contains("-->") { inComment = false }
            return true
        }
        if let open = fence {
            if Self.closesFence(body, open) { fence = nil }
            return true
        }
        guard body.allSatisfy(\.isWhitespace) else { return false }
        previousBlank = true
        previousWasIndentedCode = false
        table = .none
        return true
    }

    /// Indented code, a fence or a comment opening on this line, or a rule: kept whole.
    private mutating func opensKeptBlock(_ text: [Character], indent: Int) -> Bool {
        let wasBlank = previousBlank
        let wasIndentedCode = previousWasIndentedCode
        previousBlank = false
        previousWasIndentedCode = false
        if indent == 0 { listOpen = false }

        if indent >= 4, wasBlank || wasIndentedCode, !listOpen {
            previousWasIndentedCode = true
            return true
        }
        if let open = Self.fenceOpening(text) {
            fence = open
            return true
        }
        if text.starts(with: "<!--"), !String(text).contains("-->") {
            inComment = true
            return true
        }
        return Self.isRuleOrSetextUnderline(text)
    }

    /// A table's delimiter row is kept whole, its other rows cell by cell. True when the line belongs to a table.
    private mutating func scanTable(
        _ text: [Character], body: [Character], next: [Character], into builder: inout Builder
    ) -> Bool {
        switch table {
        case .expectingDelimiter:
            table = .body
            builder.keep(body)
            return true
        case .body where Self.hasPipe(text):
            Self.scanRow(body, into: &builder)
            return true
        default:
            table = .none
        }
        guard Self.hasPipe(text), Self.isDelimiterRow(Array(next.dropFirst(Self.quotePrefixLength(next)))) else {
            return false
        }
        table = .expectingDelimiter
        Self.scanRow(body, into: &builder)
        return true
    }

    // MARK: Block shapes

    /// Length of the run of `>` markers (each with its optional space) at the start of the line.
    private static func quotePrefixLength(_ line: [Character]) -> Int {
        var end = 0
        while true {
            var index = end
            while index < line.count, line[index] == " ", index - end < 3 { index += 1 }
            guard index < line.count, line[index] == ">" else { return end }
            index += 1
            if index < line.count, line[index] == " " || line[index] == "\t" { index += 1 }
            end = index
        }
    }

    private static func indentWidth(_ line: [Character]) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    private static func fenceOpening(_ text: [Character]) -> (marker: Character, length: Int)? {
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let length = text.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        // A backtick fence's info string cannot hold a backtick: that is inline code.
        if marker == "`", text.dropFirst(length).contains("`") { return nil }
        return (marker, length)
    }

    private static func closesFence(_ body: [Character], _ open: (marker: Character, length: Int)) -> Bool {
        let text = body.drop { $0 == " " || $0 == "\t" }
        let length = text.prefix { $0 == open.marker }.count
        return length >= open.length && text.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    private static func isRuleOrSetextUnderline(_ text: [Character]) -> Bool {
        let trimmed = trimTrailingWhitespace(text)
        guard let first = trimmed.first else { return false }
        if trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) { return true }
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        return marks.count >= 3 && "-*_".contains(first) && marks.allSatisfy { $0 == first }
    }

    /// `[label]: ...` is kept whole when it defines a link; a footnote's text after its label is translatable.
    /// Returns how many characters to keep.
    private static func definitionKeptLength(_ text: [Character], indent: Int) -> Int? {
        guard indent < 4, text.first == "[", let close = text.firstIndex(of: "]"), close > 1,
              close + 1 < text.count, text[close + 1] == ":" else { return nil }
        guard text[1] == "^" else { return text.count }
        return close + 2 + text[(close + 2)...].prefix { $0 == " " || $0 == "\t" }.count
    }

    /// `#`s and the whitespace after them.
    private static func headingMarkerLength(_ text: [Character]) -> Int? {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), hashes == text.count || text[hashes] == " " || text[hashes] == "\t" else { return nil }
        return hashes + text[hashes...].prefix { $0 == " " || $0 == "\t" }.count
    }

    /// The bullet or number, the whitespace after it and a task checkbox.
    private static func listMarkerLength(_ text: [Character]) -> Int? {
        var end: Int
        if let first = text.first, "-*+".contains(first) {
            end = 1
        } else {
            let digits = text.prefix { $0.isASCII && $0.isNumber }.count
            guard (1...9).contains(digits), digits < text.count, text[digits] == "." || text[digits] == ")" else { return nil }
            end = digits + 1
        }
        guard end == text.count || text[end] == " " || text[end] == "\t" else { return nil }
        end += text[end...].prefix { $0 == " " || $0 == "\t" }.count
        if end + 3 <= text.count, text[end] == "[", "xX ".contains(text[end + 1]), text[end + 2] == "]",
           end + 3 == text.count || text[end + 3] == " " || text[end + 3] == "\t" {
            end += 3
            end += text[end...].prefix { $0 == " " || $0 == "\t" }.count
        }
        return end
    }

    private static func trimTrailingWhitespace(_ text: [Character]) -> [Character] {
        var end = text.count
        while end > 0, text[end - 1].isWhitespace { end -= 1 }
        return Array(text[..<end])
    }

    // MARK: Tables

    private static func hasPipe(_ text: [Character]) -> Bool {
        splitCells(text).count > 1
    }

    /// Cells between unescaped pipes (the text before the first and after the last included).
    private static func splitCells(_ text: [Character]) -> [[Character]] {
        var cells: [[Character]] = [[]]
        var index = 0
        while index < text.count {
            let character = text[index]
            if character == "\\", index + 1 < text.count {
                cells[cells.count - 1] += [character, text[index + 1]]
                index += 2
                continue
            }
            if character == "|" { cells.append([]) } else { cells[cells.count - 1].append(character) }
            index += 1
        }
        return cells
    }

    private static func isDelimiterRow(_ line: [Character]) -> Bool {
        var cells = splitCells(line)
        guard cells.count > 1 else { return false }
        if cells.first?.allSatisfy(\.isWhitespace) == true { cells.removeFirst() }
        if cells.last?.allSatisfy(\.isWhitespace) == true { cells.removeLast() }
        return !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.filter { !$0.isWhitespace }
            let dashes = core.drop { $0 == ":" }.prefix { $0 == "-" }.count
            return dashes > 0 && core.count - dashes <= 2 && core.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Every cell is its own span; the pipes and the spaces around the cell text are kept.
    private static func scanRow(_ body: [Character], into builder: inout Builder) {
        for (index, cell) in splitCells(body).enumerated() {
            if index > 0 { builder.keep("|") }
            let first = cell.firstIndex { !$0.isWhitespace }
            let last = cell.lastIndex { !$0.isWhitespace }
            guard let first, let last else {
                builder.keep(cell)
                continue
            }
            builder.keep(cell[..<first])
            scanInline(Array(cell[first...last]), into: &builder)
            builder.keep(cell[(last + 1)...])
        }
    }

    // MARK: Inline

    /// The text of a heading without its optional closing `#`s.
    private static func scanHeadingText(_ text: [Character], into builder: inout Builder) {
        var content = text
        var closing: [Character] = []
        let trailing = text.reversed().prefix { $0.isWhitespace }.count
        let trimmed = Array(text.dropLast(trailing))
        var hashStart = trimmed.count
        while hashStart > 0, trimmed[hashStart - 1] == "#" { hashStart -= 1 }
        if hashStart < trimmed.count, hashStart == 0 || trimmed[hashStart - 1].isWhitespace {
            content = Array(trimmed[..<hashStart])
            closing = Array(text[hashStart...])
            let spaces = content.reversed().prefix { $0.isWhitespace }.count
            closing = Array(content.suffix(spaces)) + closing
            content = Array(content.dropLast(spaces))
        }
        scanInline(content, into: &builder)
        builder.keep(closing)
    }

    private static func scanInline(_ characters: [Character], into builder: inout Builder) {
        var pending = ""
        var index = 0
        let count = characters.count

        func flush() {
            builder.translate(pending)
            pending = ""
        }
        func keep(_ range: Range<Int>) {
            flush()
            builder.keep(characters[range])
        }

        while index < count {
            let character = characters[index]
            if character == "\\" {
                pending.append(character)
                if index + 1 < count { pending.append(characters[index + 1]) }
                index += 2
                continue
            }
            if character == "`" {
                let run = characters[index...].prefix { $0 == "`" }.count
                if let end = closingBackticks(characters, from: index + run, length: run) {
                    keep(index..<end)
                    index = end
                } else {
                    pending += String(repeating: "`", count: run)
                    index += run
                }
                continue
            }
            if character == "<", let end = htmlEnd(characters, from: index) {
                keep(index..<end)
                index = end
                continue
            }
            if character == "[" || (character == "!" && index + 1 < count && characters[index + 1] == "["),
               let end = scanLink(characters, from: index, into: &builder, pending: &pending) {
                index = end
                continue
            }
            if let end = bareURLEnd(characters, from: index) {
                keep(index..<end)
                index = end
                continue
            }
            pending.append(character)
            index += 1
        }
        flush()
    }

    /// Index after the backtick run of exactly `length` that closes a code span.
    private static func closingBackticks(_ characters: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let run = characters[index...].prefix { $0 == "`" }.count
            if run == length { return index + run }
            index += run
        }
        return nil
    }

    /// Index after an HTML tag, comment, declaration or autolink starting at `<`.
    private static func htmlEnd(_ characters: [Character], from start: Int) -> Int? {
        guard start + 1 < characters.count else { return nil }
        let next = characters[start + 1]
        if characters[start...].starts(with: "<!--") {
            return indexAfter("-->", in: characters, from: start + 4)
        }
        let startsLikeTag = next.isASCII && next.isLetter || next == "/" || next == "!" || next == "?"
        guard startsLikeTag else { return nil }
        var quote: Character?
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index + 1
            } else if character == "<" {
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func indexAfter(_ needle: String, in characters: [Character], from start: Int) -> Int? {
        let target = Array(needle)
        guard characters.count - start >= target.count else { return nil }
        for index in start...(characters.count - target.count) where Array(characters[index..<(index + target.count)]) == target {
            return index + target.count
        }
        return nil
    }

    /// Index after `http://…`, `https://…` or `www.…` starting at a word boundary, without the punctuation that
    /// ends a sentence.
    private static func bareURLEnd(_ characters: [Character], from start: Int) -> Int? {
        if start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber { return nil }
        let head = String(characters[start..<min(start + 8, characters.count)]).lowercased()
        guard let prefix = ["https://", "http://", "www."].first(where: head.hasPrefix) else { return nil }
        var end = start
        while end < characters.count, !characters[end].isWhitespace, characters[end] != "<", characters[end] != ">" { end += 1 }
        while end > start + prefix.count {
            let last = characters[end - 1]
            let opens = characters[start..<end].filter { $0 == "(" }.count
            let closes = characters[start..<end].filter { $0 == ")" }.count
            if ".,;:!?'\"*_".contains(last) || (last == ")" && closes > opens) { end -= 1 } else { break }
        }
        return end > start + prefix.count ? end : nil
    }

    /// A link, image, reference link or footnote reference starting at `[` or `![`. The brackets and everything after
    /// the text are kept; the text is scanned on. Returns the index after it, or nil when it is not one.
    private static func scanLink(
        _ characters: [Character], from start: Int, into builder: inout Builder, pending: inout String
    ) -> Int? {
        let open = characters[start] == "!" ? start + 1 : start
        guard let close = matching(characters, from: open, open: "[", close: "]") else { return nil }
        var end: Int?
        if close + 1 < characters.count, characters[close + 1] == "(" {
            end = matching(characters, from: close + 1, open: "(", close: ")").map { $0 + 1 }
        } else if close + 1 < characters.count, characters[close + 1] == "[" {
            end = matching(characters, from: close + 1, open: "[", close: "]").map { $0 + 1 }
        }
        let isFootnote = open + 1 < characters.count && characters[open + 1] == "^"
        if isFootnote, !characters[open...close].contains(where: \.isWhitespace) {
            builder.translate(pending)
            pending = ""
            builder.keep(characters[start...close])
            return close + 1
        }
        guard let end else { return nil }
        builder.translate(pending)
        pending = ""
        builder.keep(characters[start...open])
        scanInline(Array(characters[(open + 1)..<close]), into: &builder)
        builder.keep(characters[close..<end])
        return end
    }

    private static func matching(_ characters: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var index = start
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
