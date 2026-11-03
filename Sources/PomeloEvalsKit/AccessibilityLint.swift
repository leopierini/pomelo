import Foundation

/// The static half of the accessibility audit (P146): SwiftUI builds its accessibility tree only for a connected
/// assistive app, so the app's in-process walk sees AppKit views alone, and this reads the SwiftUI source instead.
///
/// It is a heuristic over the text, with no type information. It sees a control or image written out where it is
/// used; it cannot see a label added by a caller of the view that holds it, a custom modifier that labels or hides
/// (`.adjustable`), a label built at run time, an `Image` made through a helper, or a control wrapped in a custom
/// style. It takes any `Text(` in a control's label as its title (even `.help(Text(…))`), and it flags
/// `let icon = Image(…)` where it is assigned, not where it is shown. A finding it gets wrong is silenced on its line
/// with `// a11y: <why>`.
public enum AccessibilityLint {
    public enum Rule: String, Codable, Sendable {
        /// A `Button`, `Toggle`, `Menu` or `Link` whose label is only an image, with no `.accessibilityLabel`.
        case iconOnlyControl
        /// An `Image(systemName:)` or `Image(nsImage:)` neither labeled nor hidden.
        case unlabeledImage
    }

    public struct Finding: Codable, Equatable, Sendable {
        public var file: String
        public var line: Int
        public var rule: Rule
        public var snippet: String
    }

    static let controls: Set<String> = ["Button", "Toggle", "Menu", "Link"]
    /// An image inside one of these is named by it: a `Label`'s title, a `Text` it is part of, or the control (judged
    /// by the first rule).
    static let namingOwners: Set<String> = controls.union(["Label", "Text"])
    /// Modifiers on the image or a view around it that give VoiceOver something to read, or hide it. Matched with the
    /// spaces taken out of the code.
    static let coveringModifiers = [
        ".accessibilityLabel(", ".accessibilityHidden(true)", ".accessibilityElement(children:.ignore)",
        ".accessibilityRepresentation",
    ]

    /// Every Swift file under `sources`, with paths from the repository's `App/` or `Sources/` folder on.
    public static func run(sources: [URL]) throws -> [Finding] {
        var found: [Finding] = []
        for folder in sources {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files.sorted(by: { $0.path < $1.path }) {
                let source = try String(contentsOf: file, encoding: .utf8)
                found += findings(in: source, file: Audit.relativePath(file.standardizedFileURL.path))
            }
        }
        return found
    }

    public static func findings(in source: String, file: String) -> [Finding] {
        let scan = Scan(source)
        var found: [Finding] = []
        func add(_ rule: Rule, at index: Int) {
            let line = scan.line(of: index)
            guard !scan.isSuppressed(line: line) else { return }
            found.append(Finding(file: file, line: line, rule: rule, snippet: scan.lineText(line)))
        }
        for start in scan.identifiers(in: controls) where isIconOnlyAndUnlabeled(control: start, scan) {
            add(.iconOnlyControl, at: start)
        }
        for start in scan.identifiers(in: ["Image"]) where isUnlabeledImage(at: start, scan) {
            add(.unlabeledImage, at: start)
        }
        return found.sorted { ($0.line, $0.rule.rawValue) < ($1.line, $1.rule.rawValue) }
    }

    // MARK: Rules

    private static func isIconOnlyAndUnlabeled(control start: Int, _ scan: Scan) -> Bool {
        guard let call = scan.call(at: start), let label = labelClosure(of: call, scan) else { return false }
        let body = scan.text(label.open + 1, label.close)
        guard body.contains(word: "Image("), !body.contains(word: "Text("), !body.contains(word: "Label(") else {
            return false
        }
        return !body.contains(".accessibilityLabel(") && !scan.chain(after: call.end).contains(".accessibilityLabel(")
    }

    /// The closure that draws a control's label, or nil when the control has a title (or a form this cannot read).
    private static func labelClosure(of call: Scan.Call, _ scan: Scan) -> Scan.Group? {
        if let labeled = call.closures.first(where: { $0.label == "label" }) { return labeled.group }
        guard let arguments = call.arguments else { return nil }
        if let labeled = scan.closureArgument(named: "label", in: arguments) { return labeled }
        let inside = scan.text(arguments.open + 1, arguments.close).trimmingCharacters(in: .whitespacesAndNewlines)
        // A first argument without a label is the title: `Button("Install") {…}`, `Toggle(title, isOn:)`.
        guard inside.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*:"#, options: .regularExpression) != nil,
              call.closures.count == 1 else { return nil }
        switch call.name {
        case "Button": return inside.contains("action:") ? call.closures[0].group : nil
        case "Toggle", "Link": return call.closures[0].group
        default: return nil
        }
    }

    private static func isUnlabeledImage(at start: Int, _ scan: Scan) -> Bool {
        guard let call = scan.call(at: start), let arguments = call.arguments else { return false }
        let inside = scan.text(arguments.open + 1, arguments.close).trimmingCharacters(in: .whitespacesAndNewlines)
        guard inside.hasPrefix("systemName:") || inside.hasPrefix("nsImage:") else { return false }
        if covers(scan.chain(after: call.end)) { return false }
        for group in scan.enclosingGroups(of: start) {
            guard let owner = scan.owner(of: group) else { continue }
            if namingOwners.contains(owner.name) { return false }
            if let outer = scan.call(at: owner.start), covers(scan.chain(after: outer.end)) { return false }
        }
        return true
    }

    private static func covers(_ chain: String) -> Bool {
        let compact = chain.filter { !$0.isWhitespace }
        return coveringModifiers.contains { compact.contains($0) }
    }
}

// MARK: The scan

/// Swift source with its comments and string contents blanked out (lines kept), and the brackets matched.
struct Scan {
    struct Group: Equatable {
        var open: Int
        var close: Int
    }

    struct Call {
        var name: String
        var arguments: Group?
        var closures: [(label: String?, group: Group)]
        /// Just past the call's last argument list or trailing closure.
        var end: Int
    }

    private let original: [UInt8]
    private let code: [UInt8]
    private let lineStarts: [Int]
    private let closeOf: [Int: Int]
    private let openOf: [Int: Int]
    private let groups: [Group]

    init(_ source: String) {
        original = Array(source.utf8)
        code = Self.blank(original)
        var starts = [0]
        for (index, byte) in original.enumerated() where byte == UInt8(ascii: "\n") { starts.append(index + 1) }
        lineStarts = starts
        var stack: [Int] = []
        var closeOf: [Int: Int] = [:]
        var openOf: [Int: Int] = [:]
        for (index, byte) in code.enumerated() {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: "{"), UInt8(ascii: "["): stack.append(index)
            case UInt8(ascii: ")"), UInt8(ascii: "}"), UInt8(ascii: "]"):
                if let open = stack.popLast() {
                    closeOf[open] = index
                    openOf[index] = open
                }
            default: break
            }
        }
        self.closeOf = closeOf
        self.openOf = openOf
        groups = closeOf.map { Group(open: $0.key, close: $0.value) }.sorted { $0.open < $1.open }
    }

    // MARK: Lines

    func line(of index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    func lineText(_ line: Int) -> String {
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] - 1 : original.count
        return String(decoding: original[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// `// a11y: <why>` on the line or the line before, with a reason.
    func isSuppressed(line: Int) -> Bool {
        [line, line - 1].filter { $0 >= 1 }.contains { candidate in
            guard let range = lineText(candidate).range(of: "// a11y:") else { return false }
            return !lineText(candidate)[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Code

    func text(_ start: Int, _ end: Int) -> String {
        String(decoding: code[max(0, start)..<min(end, code.count)], as: UTF8.self)
    }

    /// Where each of `names` starts as a whole identifier that is not a member (`.Button`) or part of a longer name.
    func identifiers(in names: Set<String>) -> [Int] {
        var found: [Int] = []
        var index = 0
        while index < code.count {
            guard Self.isIdentifierStart(code[index]), index == 0 || !Self.isIdentifier(code[index - 1]) else {
                index += 1
                continue
            }
            let start = index
            while index < code.count, Self.isIdentifier(code[index]) { index += 1 }
            let previous = previousNonSpace(before: start)
            let isMember = previous.map { code[$0] == UInt8(ascii: ".") && !follows("SwiftUI", dot: $0) } ?? false
            if names.contains(text(start, index)), !isMember {
                found.append(start)
            }
        }
        return found
    }

    /// Whether the identifier just before the `.` at `dot` is `name` (`SwiftUI.Image`).
    private func follows(_ name: String, dot: Int) -> Bool {
        let bytes = Array(name.utf8)
        let start = dot - bytes.count
        return start >= 0 && Array(code[start..<dot]) == bytes && (start == 0 || !Self.isIdentifier(code[start - 1]))
    }

    /// The closure passed as the argument `name:` at the top level of `arguments`: `Button(action: f, label: {…})`.
    func closureArgument(named name: String, in arguments: Group) -> Group? {
        var index = arguments.open + 1
        while index < arguments.close {
            if let close = closeOf[index] {
                index = close + 1
                continue
            }
            if Self.isIdentifierStart(code[index]), !Self.isIdentifier(code[index - 1]) {
                var end = index
                while end < code.count, Self.isIdentifier(code[end]) { end += 1 }
                if text(index, end) == name, let colon = nextNonSpace(from: end), code[colon] == UInt8(ascii: ":"),
                   let brace = nextNonSpace(from: colon + 1), code[brace] == UInt8(ascii: "{"),
                   let close = closeOf[brace] {
                    return Group(open: brace, close: close)
                }
                index = end
                continue
            }
            index += 1
        }
        return nil
    }

    /// The call that starts with the identifier at `start`: its arguments and trailing closures (`label: {…}` too).
    func call(at start: Int) -> Call? {
        var index = start
        while index < code.count, Self.isIdentifier(code[index]) { index += 1 }
        let name = text(start, index)
        var call = Call(name: name, arguments: nil, closures: [], end: index)
        var next = nextNonSpace(from: index)
        if let open = next, code[open] == UInt8(ascii: "("), let close = closeOf[open] {
            call.arguments = Group(open: open, close: close)
            call.end = close + 1
            next = nextNonSpace(from: close + 1)
        }
        while let position = next {
            var label: String?
            var open = position
            if Self.isIdentifierStart(code[position]) {
                var end = position
                while end < code.count, Self.isIdentifier(code[end]) { end += 1 }
                guard let colon = nextNonSpace(from: end), code[colon] == UInt8(ascii: ":"),
                      let brace = nextNonSpace(from: colon + 1), code[brace] == UInt8(ascii: "{") else { break }
                label = text(position, end)
                open = brace
            }
            guard code[open] == UInt8(ascii: "{"), let close = closeOf[open] else { break }
            call.closures.append((label, Group(open: open, close: close)))
            call.end = close + 1
            next = nextNonSpace(from: close + 1)
        }
        guard call.arguments != nil || !call.closures.isEmpty else { return nil }
        return call
    }

    /// The modifiers that follow `end`: `.font(.title)`, `.onTapGesture {…}` and so on, as one string.
    func chain(after end: Int) -> String {
        var index = end
        var chainEnd = end
        while let dot = nextNonSpace(from: index), code[dot] == UInt8(ascii: "."),
              dot + 1 < code.count, Self.isIdentifierStart(code[dot + 1]) {
            var position = dot + 1
            while position < code.count, Self.isIdentifier(code[position]) { position += 1 }
            while let open = nextNonSpace(from: position),
                  code[open] == UInt8(ascii: "(") || code[open] == UInt8(ascii: "{"), let close = closeOf[open] {
                position = close + 1
            }
            chainEnd = position
            index = position
        }
        return text(end, chainEnd)
    }

    /// The brackets around `index`, innermost first.
    func enclosingGroups(of index: Int) -> [Group] {
        groups.filter { $0.open < index && index < $0.close }.reversed()
    }

    /// The call a bracket group belongs to: `HStack` for `HStack {…}`, `Label` for `Label {…} icon: {…}`,
    /// `overlay` for `.overlay(…)`.
    func owner(of group: Group) -> (name: String, start: Int)? {
        var position = previousNonSpace(before: group.open)
        while let index = position {
            switch code[index] {
            case UInt8(ascii: ")"), UInt8(ascii: "}"):
                guard let open = openOf[index] else { return nil }
                position = previousNonSpace(before: open)
            case UInt8(ascii: ":"):
                // `label:` before a trailing closure: skip the argument's name.
                guard var cursor = previousNonSpace(before: index), Self.isIdentifier(code[cursor]) else { return nil }
                while cursor > 0, Self.isIdentifier(code[cursor - 1]) { cursor -= 1 }
                position = previousNonSpace(before: cursor)
            default:
                guard Self.isIdentifier(code[index]) else { return nil }
                var start = index
                while start > 0, Self.isIdentifier(code[start - 1]) { start -= 1 }
                return (text(start, index + 1), start)
            }
        }
        return nil
    }

    private func nextNonSpace(from index: Int) -> Int? {
        var position = index
        while position < code.count, Self.isSpace(code[position]) { position += 1 }
        return position < code.count ? position : nil
    }

    private func previousNonSpace(before index: Int) -> Int? {
        var position = index - 1
        while position >= 0, Self.isSpace(code[position]) { position -= 1 }
        return position >= 0 ? position : nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "_")
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    // MARK: Blanking

    /// Comments and the insides of string literals (interpolations included) become spaces; newlines and the quotes
    /// stay, so lines and `Button("…")`'s title argument are still seen.
    static func blank(_ source: [UInt8]) -> [UInt8] {
        var out = source
        var index = 0
        func blankRange(_ start: Int, _ end: Int) {
            for position in start..<min(end, out.count) where out[position] != UInt8(ascii: "\n") {
                out[position] = UInt8(ascii: " ")
            }
        }
        while index < source.count {
            let byte = source[index]
            let next = index + 1 < source.count ? source[index + 1] : 0
            if byte == UInt8(ascii: "/"), next == UInt8(ascii: "/") {
                var end = index
                while end < source.count, source[end] != UInt8(ascii: "\n") { end += 1 }
                blankRange(index, end)
                index = end
            } else if byte == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                var depth = 0
                var end = index
                repeat {
                    if end + 1 < source.count, source[end] == UInt8(ascii: "/"), source[end + 1] == UInt8(ascii: "*") {
                        depth += 1
                        end += 2
                    } else if end + 1 < source.count, source[end] == UInt8(ascii: "*"),
                              source[end + 1] == UInt8(ascii: "/") {
                        depth -= 1
                        end += 2
                    } else {
                        end += 1
                    }
                } while depth > 0 && end < source.count
                blankRange(index, end)
                index = end
            } else if byte == UInt8(ascii: "\"") || (byte == UInt8(ascii: "#") && next == UInt8(ascii: "\"")) {
                let end = stringEnd(source, from: index)
                let opening = byte == UInt8(ascii: "#") ? index + 1 : index
                blankRange(opening + 1, max(opening + 1, end - 1))
                index = end
            } else {
                index += 1
            }
        }
        return out
    }

    /// Just past the string literal that opens at `start` (`"…"`, `"""…"""` or `#"…"#`).
    private static func stringEnd(_ source: [UInt8], from start: Int) -> Int {
        var index = start
        var hashes = 0
        while index < source.count, source[index] == UInt8(ascii: "#") {
            hashes += 1
            index += 1
        }
        let quote = UInt8(ascii: "\"")
        let isMultiLine = index + 2 < source.count && source[index + 1] == quote && source[index + 2] == quote
        let delimiter = isMultiLine ? 3 : 1
        index += delimiter
        while index < source.count {
            if source[index] == UInt8(ascii: "\\"), hashes == 0 {
                if index + 1 < source.count, source[index + 1] == UInt8(ascii: "(") {
                    index = interpolationEnd(source, from: index + 1)
                } else {
                    index += 2
                }
                continue
            }
            if !isMultiLine, source[index] == UInt8(ascii: "\n") { return index }
            if source[index] == quote, index + delimiter - 1 < source.count,
               source[index..<(index + delimiter)].allSatisfy({ $0 == quote }) {
                var end = index + delimiter
                var closing = 0
                while closing < hashes, end < source.count, source[end] == UInt8(ascii: "#") {
                    closing += 1
                    end += 1
                }
                if closing == hashes { return end }
            }
            index += 1
        }
        return index
    }

    /// Just past the `)` that closes the interpolation whose `(` is at `open`, stepping over nested strings.
    private static func interpolationEnd(_ source: [UInt8], from open: Int) -> Int {
        var depth = 0
        var index = open
        while index < source.count {
            switch source[index] {
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return index + 1 }
            case UInt8(ascii: "\""):
                index = stringEnd(source, from: index)
                continue
            default: break
            }
            index += 1
        }
        return index
    }
}

private extension String {
    /// `needle` where the character before it is not part of an identifier (`Image(` but not `NSImage(`).
    func contains(word needle: String) -> Bool {
        var searchStart = startIndex
        while let range = range(of: needle, range: searchStart..<endIndex) {
            if range.lowerBound == startIndex { return true }
            let before = self[index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
