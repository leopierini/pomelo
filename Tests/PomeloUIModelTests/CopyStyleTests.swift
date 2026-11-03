import Foundation
import Testing

/// P32: no UI string joins two facts with "·" or "—". Literals are scanned in the app's sources, its Quick Action and
/// the UI model; comments may keep the glyphs, and the CLI's text output is not app UI.
@Suite struct CopyStyleTests {
    static let glyphs: [Character] = ["\u{00B7}", "\u{2014}"]

    static var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `file:line` for every line whose code, before any `//`, holds a string literal containing a glyph. A line
    /// inside a multi-line string is a literal as a whole.
    static func offendingLines(in folders: [URL]) throws -> [String] {
        var found: [String] = []
        for folder in folders {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files.sorted(by: { $0.path < $1.path }) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                var inMultiLineString = false
                for (index, line) in lines.enumerated() {
                    let strings = inMultiLineString ? [line] : literals(in: line)
                    if line.components(separatedBy: "\"\"\"").count % 2 == 0 { inMultiLineString.toggle() }
                    guard strings.contains(where: hasGlyph) else { continue }
                    found.append("\(file.path.replacingOccurrences(of: repository.path + "/", with: "")):\(index + 1)")
                }
            }
        }
        return found
    }

    /// The glyph itself, or its `\u{…}` escape as written in the source.
    static func hasGlyph(_ text: String) -> Bool {
        text.contains { glyphs.contains($0) } || ["\\u{00B7}", "\\u{B7}", "\\u{2014}"].contains { text.contains($0) }
    }

    /// The string literals on one line of code, up to a `//` that is outside a literal.
    static func literals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        var escaped = false
        var previous: Character?
        for character in line {
            if var literal = current {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    literals.append(literal)
                    current = nil
                    previous = character
                    continue
                }
                literal.append(character)
                current = literal
            } else if character == "\"" {
                current = ""
            } else if character == "/", previous == "/" {
                break
            }
            previous = character
        }
        // Unclosed: the opening of a multi-line string, or a line inside one.
        if let current { literals.append(current) }
        return literals
    }

    @Test func userFacingStringsHaveNoSeparatorGlyphs() throws {
        let folders = ["Sources/PomeloUIModel", "App/Sources", "App/QuickAction"]
            .map { Self.repository.appending(path: $0) }
        for folder in folders { #expect(FileManager.default.fileExists(atPath: folder.path), "\(folder.path)") }
        let offending = try Self.offendingLines(in: folders)
        #expect(offending.isEmpty, "separator glyphs in UI strings: \(offending.joined(separator: ", "))")
    }

    @Test func theScanFindsLiteralsAndSkipsComments() {
        #expect(Self.literals(in: #"Text("\u{00B7}") // a "comment""#) == [#"\u{00B7}"#])
        #expect(Self.hasGlyph(#"\u{2014}"#))
        #expect(Self.literals(in: "let a = \"Needs x \u{00B7} y\" // \u{00B7}").contains(where: Self.hasGlyph))
        #expect(!Self.literals(in: "// Text(\"\u{00B7}\")").contains(where: Self.hasGlyph))
        #expect(!Self.literals(in: "let url = \"https://a.b\" // \u{2014} note").contains(where: Self.hasGlyph))
        #expect(Self.literals(in: #"let s = "a \"q\" \u{2014} b""#).count == 1)
    }

    @Test func theScanReadsTheLinesOfAMultiLineString() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pomelo-copy-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "let a = 1\nlet usage = \"\"\"\n    Convert \u{00B7} Tools\n    \"\"\"\n// \u{00B7} fine\n"
        try source.write(to: folder.appending(path: "A.swift"), atomically: true, encoding: .utf8)
        let found = try Self.offendingLines(in: [folder])
        #expect(found.count == 1 && found[0].hasSuffix("A.swift:3"), "\(found)")
    }
}
