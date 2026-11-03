import Foundation

/// Lines of one Swift file, by what they hold. A line with code and a trailing comment is both.
public struct CommentStats: Equatable, Sendable {
    public var codeLines: Int
    public var commentLines: Int
    /// Comment lines that mention a ruling (`P` or `R` followed by digits).
    public var rulingRefLines: Int

    public init(codeLines: Int = 0, commentLines: Int = 0, rulingRefLines: Int = 0) {
        self.codeLines = codeLines
        self.commentLines = commentLines
        self.rulingRefLines = rulingRefLines
    }

    static func + (lhs: CommentStats, rhs: CommentStats) -> CommentStats {
        CommentStats(codeLines: lhs.codeLines + rhs.codeLines, commentLines: lhs.commentLines + rhs.commentLines,
                     rulingRefLines: lhs.rulingRefLines + rhs.rulingRefLines)
    }
}

/// The code-health audit: dead code (Periphery), duplication (jscpd), complexity (lizard) and comments, turned into
/// metrics. The tools run in `evals/audit.sh`; this reads their reports.
public enum Audit {
    /// Periphery results under these path fragments are not production code or are not ours, so they never count.
    public static let allowedPathFragments = [
        "/Sources/PomeloTestSupport/", "/Tests/", "/checkouts/", "/SourcePackages/", "/.build/",
    ]
    /// Tooling and test support: neither ships, so the comment metrics (which stand for the shipped code) skip them.
    public static let nonProductionModules: Set<String> = ["PomeloTestSupport", "PomeloEvalsKit", "PomeloEvals"]
    public static let ccnLimit = 15

    // MARK: Paths

    /// `path` from its `Sources/` or `App/` component on, which is where the repository's layout starts; the path
    /// unchanged when it has neither.
    public static func relativePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (index, part) in parts.enumerated() {
            let next = index + 1 < parts.count ? parts[index + 1] : nil
            if part == "Sources" || (part == "App" && (next == "Sources" || next == "QuickAction")) {
                return parts[index...].joined(separator: "/")
            }
        }
        return path
    }

    /// `Sources/<Module>/…` is that module, `App/Sources/…` is `App` and `App/QuickAction/…` is `QuickAction`.
    public static func moduleName(ofPath path: String) -> String {
        let parts = relativePath(path).split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "App", parts[1] == "Sources" || parts[1] == "QuickAction" {
            return parts[1] == "Sources" ? "App" : "QuickAction"
        }
        if parts.count >= 3, parts[0] == "Sources" { return parts[1] }
        return "other"
    }

    // MARK: Periphery

    public struct Finding: Equatable, Sendable {
        public var path: String
        public var line: Int
        public var kind: String
        public var name: String
        public var hints: [String]
        public var module: String

        var key: String { "\(path):\(line):\(name)" }
    }

    /// The declarations Periphery reports as unused or only ever assigned, minus imports (an unused `import` is not
    /// a declaration), accessibility advice, and anything under `allowedPaths`.
    public static func deadDeclarations(periphery: Data, allowedPaths: [String] = allowedPathFragments) throws -> [Finding] {
        struct Raw: Decodable {
            var kind: String
            var name: String?
            var hints: [String]?
            var location: String
        }
        let raw = try JSONDecoder().decode([Raw].self, from: periphery)
        var seen = Set<String>()
        var findings: [Finding] = []
        for item in raw where item.kind != "module" {
            guard let hints = item.hints, hints.contains("unused") || hints.contains("assignOnlyProperty") else { continue }
            guard !allowedPaths.contains(where: { item.location.contains($0) }) else { continue }
            let parts = item.location.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let line = Int(parts[parts.count - 2]) else { continue }
            let path = relativePath(parts[..<(parts.count - 2)].joined(separator: ":"))
            let finding = Finding(path: path, line: line, kind: item.kind, name: item.name ?? "", hints: hints,
                                  module: moduleName(ofPath: path))
            if seen.insert(finding.key).inserted { findings.append(finding) }
        }
        return findings.sorted { ($0.path, $0.line, $0.name) < ($1.path, $1.line, $1.name) }
    }

    // MARK: jscpd

    public struct Fragment: Equatable, Sendable {
        public var path: String
        public var start: Int
        public var module: String { Audit.moduleName(ofPath: path) }
    }

    public struct Clone: Equatable, Sendable {
        public var lines: Int
        public var first: Fragment
        public var second: Fragment
    }

    public struct Duplication: Equatable, Sendable {
        public var percentage: Double
        public var clones: [Clone]

        /// jscpd counts a clone's lines once however many files hold it, and so does this: once per module the clone
        /// touches, so a clone inside one module counts once there and one across two counts once in each.
        public func duplicatedLines(inModule module: String) -> Int {
            clones.filter { $0.first.module == module || $0.second.module == module }.reduce(0) { $0 + $1.lines }
        }
    }

    public static func duplication(jscpd: Data) throws -> Duplication {
        struct File: Decodable { var name: String; var start: Int }
        struct Raw: Decodable {
            struct Entry: Decodable { var lines: Int; var firstFile: File; var secondFile: File }
            struct Statistics: Decodable {
                struct Total: Decodable { var percentage: Double }
                var total: Total
            }
            var duplicates: [Entry]?
            var statistics: Statistics
        }
        let raw = try JSONDecoder().decode(Raw.self, from: jscpd)
        func fragment(_ file: File) -> Fragment { Fragment(path: relativePath(file.name), start: file.start) }
        let clones = (raw.duplicates ?? []).map { Clone(lines: $0.lines, first: fragment($0.firstFile), second: fragment($0.secondFile)) }
        return Duplication(percentage: raw.statistics.total.percentage, clones: clones)
    }

    // MARK: lizard

    public struct FunctionComplexity: Equatable, Sendable {
        public var ccn: Int
        public var path: String
        public var name: String
        public var line: Int
        public var module: String
    }

    /// Lizard's `--csv` rows: NLOC, CCN, tokens, parameters, length, location, file, name, long name, start, end.
    public static func complexity(lizardCSV: String) -> [FunctionComplexity] {
        lizardCSV.split(whereSeparator: \.isNewline).compactMap { row in
            let fields = csvFields(String(row))
            guard fields.count >= 10, let ccn = Int(fields[1]), let line = Int(fields[9]) else { return nil }
            let path = relativePath(fields[6])
            return FunctionComplexity(ccn: ccn, path: path, name: fields[7], line: line, module: moduleName(ofPath: path))
        }
    }

    public static func functionsOver(_ limit: Int, in functions: [FunctionComplexity]) -> [FunctionComplexity] {
        functions.filter { $0.ccn > limit }
    }

    /// One CSV row; a quoted field may hold commas and `""` for a quote.
    static func csvFields(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var characters = row.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" { current.append("\""); pending = characters.next() } else { quoted = false }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    // MARK: Comments

    public static func commentStats(of url: URL) -> CommentStats {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return CommentStats() }
        return commentStats(in: text)
    }

    /// Counts the lines that hold code and the lines that hold a `//`, `///` or `/* */` comment (block comments nest,
    /// as in Swift). A `//` inside a string literal (plain, raw, multi-line or in an interpolation) is code.
    public static func commentStats(in text: String) -> CommentStats {
        var scanner = CommentScanner(bytes: Array(text.utf8))
        return scanner.scan()
    }

    /// A one-pass lexer that knows just enough Swift to tell a comment from a string: it is not a parser.
    private struct CommentScanner {
        struct Literal {
            var hashes: Int
            var multiline: Bool
            /// Parenthesis depth inside a `\(` interpolation; 0 while in the string's body.
            var interpolation = 0
        }

        static let newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        static let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
        static let open = UInt8(ascii: "("), close = UInt8(ascii: ")")

        let bytes: [UInt8]
        var index = 0
        var stats = CommentStats()
        var hasCode = false
        var hasComment = false
        var commentText: [UInt8] = []
        var blockDepth = 0
        var inLineComment = false
        var literals: [Literal] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        func byte(at position: Int) -> UInt8? { position < bytes.count ? bytes[position] : nil }
        static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D }

        mutating func scan() -> CommentStats {
            while let current = byte(at: index) {
                if current == Self.newline {
                    endLine()
                } else if blockDepth > 0 {
                    inBlockComment(current)
                } else if inLineComment {
                    if !Self.isSpace(current) { hasComment = true }
                    commentText.append(current)
                    index += 1
                } else if let top = literals.last, top.interpolation == 0 {
                    inStringBody(current, top)
                } else {
                    inCode(current)
                }
            }
            countLine()
            return stats
        }

        mutating func countLine() {
            if hasCode { stats.codeLines += 1 }
            if hasComment {
                stats.commentLines += 1
                if Audit.mentionsRuling(commentText) { stats.rulingRefLines += 1 }
            }
            hasCode = false
            hasComment = false
            commentText.removeAll(keepingCapacity: true)
        }

        mutating func endLine() {
            countLine()
            inLineComment = false
            // A plain string ends with its line; only a multi-line one goes on.
            while let top = literals.last, !top.multiline, top.interpolation == 0 { literals.removeLast() }
            index += 1
        }

        mutating func inBlockComment(_ current: UInt8) {
            if !Self.isSpace(current) { hasComment = true }
            commentText.append(current)
            let next = byte(at: index + 1)
            if current == Self.slash, next == Self.star {
                blockDepth += 1
                index += 2
            } else if current == Self.star, next == Self.slash {
                blockDepth -= 1
                index += 2
            } else {
                index += 1
            }
        }

        mutating func inStringBody(_ current: UInt8, _ top: Literal) {
            if !Self.isSpace(current) { hasCode = true }
            if current == Self.backslash {
                escape(in: top)
            } else if current == Self.quote, let end = closing(top) {
                literals.removeLast()
                index = end
            } else {
                index += 1
            }
        }

        /// A backslash plus the literal's `#`s starts an escape: `\(` opens an interpolation, anything else is skipped.
        mutating func escape(in top: Literal) {
            var cursor = index + 1
            var matched = 0
            while matched < top.hashes, byte(at: cursor) == Self.hash { matched += 1; cursor += 1 }
            guard matched == top.hashes, let escaped = byte(at: cursor) else { index += 1; return }
            if escaped == Self.open {
                literals[literals.count - 1].interpolation = 1
                index = cursor + 1
            } else {
                index = escaped == Self.newline ? cursor : cursor + 1
            }
        }

        /// Where the scan resumes if the quote at `index` closes `top`: its quote(s) and `#`s, nil if they do not.
        func closing(_ top: Literal) -> Int? {
            let needed = top.multiline ? 3 : 1
            var cursor = index
            while cursor - index < needed, byte(at: cursor) == Self.quote { cursor += 1 }
            guard cursor - index == needed else { return nil }
            for _ in 0..<top.hashes {
                guard byte(at: cursor) == Self.hash else { return nil }
                cursor += 1
            }
            return cursor
        }

        mutating func inCode(_ current: UInt8) {
            let next = byte(at: index + 1)
            if Self.isSpace(current) {
                index += 1
            } else if current == Self.slash, next == Self.slash {
                inLineComment = true
                startComment()
            } else if current == Self.slash, next == Self.star {
                blockDepth = 1
                startComment()
            } else if !openLiteral() {
                hasCode = true
                if !literals.isEmpty { trackInterpolation(current) }
                index += 1
            }
        }

        mutating func startComment() {
            hasComment = true
            commentText.append(contentsOf: [Self.slash, Self.slash])
            index += 2
        }

        /// A string starts at `index` (after any `#`s of a raw one).
        mutating func openLiteral() -> Bool {
            var cursor = index
            while byte(at: cursor) == Self.hash { cursor += 1 }
            guard byte(at: cursor) == Self.quote else { return false }
            hasCode = true
            let multiline = byte(at: cursor + 1) == Self.quote && byte(at: cursor + 2) == Self.quote
            literals.append(Literal(hashes: cursor - index, multiline: multiline))
            index = cursor + (multiline ? 3 : 1)
            return true
        }

        /// Code inside a `\(` is code until its parenthesis closes.
        mutating func trackInterpolation(_ current: UInt8) {
            let last = literals.count - 1
            guard literals[last].interpolation > 0 else { return }
            if current == Self.open { literals[last].interpolation += 1 }
            if current == Self.close { literals[last].interpolation -= 1 }
        }
    }

    /// `P12` or `R7` as a whole word.
    static func mentionsRuling(_ comment: [UInt8]) -> Bool {
        func isWordByte(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        for index in comment.indices where comment[index] == UInt8(ascii: "P") || comment[index] == UInt8(ascii: "R") {
            if index > 0, isWordByte(comment[index - 1]) { continue }
            var end = index + 1
            while end < comment.count, isDigit(comment[end]) { end += 1 }
            guard end > index + 1 else { continue }
            if end == comment.count || !isWordByte(comment[end]) { return true }
        }
        return false
    }

    // MARK: Assembly

    public struct Inputs: Sendable {
        /// Periphery's JSON with the tests indexed: code a test uses counts as used.
        public var periphery: Data?
        /// Periphery's JSON with the tests left out of the index: what only the tests use shows up as unused.
        public var peripheryWithoutTests: Data?
        public var jscpd: Data?
        public var lizardCSV: String?
        public var sourceDirectories: [URL]

        public init(periphery: Data? = nil, peripheryWithoutTests: Data? = nil, jscpd: Data? = nil,
                    lizardCSV: String? = nil, sourceDirectories: [URL]) {
            self.periphery = periphery
            self.peripheryWithoutTests = peripheryWithoutTests
            self.jscpd = jscpd
            self.lizardCSV = lizardCSV
            self.sourceDirectories = sourceDirectories
        }
    }

    public struct Outcome: Sendable {
        public var results: EvalResults
        /// What to look at, for the tasks that act on the numbers.
        public var report: String
    }

    struct SourceFile {
        var module: String
        var physicalLines: Int
        var stats: CommentStats
    }

    static func swiftFiles(in directories: [URL]) -> [URL] {
        var files: [URL] = []
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func run(_ inputs: Inputs) throws -> Outcome {
        let files: [SourceFile] = swiftFiles(in: inputs.sourceDirectories).map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let newlines = text.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            let unterminated = !text.isEmpty && !text.hasSuffix("\n") ? 1 : 0
            return SourceFile(module: moduleName(ofPath: url.path), physicalLines: newlines + unterminated,
                              stats: commentStats(of: url))
        }
        let modules = Set(files.map(\.module)).sorted()
        var metrics: [String: Double] = [:]
        var skipped: [String] = []
        var report: [String] = []

        let code = files.reduce(CommentStats()) { $0 + $1.stats }
        metrics["code.swift_lines"] = Double(code.codeLines)
        let production = files.filter { !nonProductionModules.contains($0.module) }.reduce(CommentStats()) { $0 + $1.stats }
        metrics["comments.density_percent"] = production.codeLines == 0
            ? 0 : Double(production.commentLines) / Double(production.codeLines) * 100
        metrics["comments.ruling_refs"] = Double(production.rulingRefLines)
        report.append("Comments (production sources): \(production.commentLines) comment lines over \(production.codeLines) code lines, "
            + "\(production.rulingRefLines) mention a ruling")

        func perModule(_ name: String, _ value: (String) -> Double) {
            for module in modules { metrics["code.\(module).\(name)"] = value(module) }
        }

        if let periphery = inputs.periphery {
            let dead = try deadDeclarations(periphery: periphery)
            metrics["code.dead_declarations"] = Double(dead.count)
            perModule("dead_declarations") { module in Double(dead.filter { $0.module == module }.count) }
            report.append("\nDead declarations (\(dead.count)), tests counted as users:")
            report += dead.map(describe)
            if let withoutTests = inputs.peripheryWithoutTests {
                let known = Set(dead.map(\.key))
                let testOnly = try deadDeclarations(periphery: withoutTests).filter { !known.contains($0.key) }
                metrics["code.test_only_declarations"] = Double(testOnly.count)
                report.append("\nDeclarations only tests use, so test-only (\(testOnly.count)): removing one takes its tests with it:")
                report += testOnly.map(describe)
            } else {
                skipped.append("code.test_only_declarations")
            }
        } else {
            skipped += ["code.dead_declarations", "code.test_only_declarations"]
        }

        if let jscpd = inputs.jscpd {
            let summary = try duplication(jscpd: jscpd)
            metrics["code.duplication_percent"] = summary.percentage
            let linesByModule = Dictionary(grouping: files, by: \.module).mapValues { $0.reduce(0) { $0 + $1.physicalLines } }
            perModule("duplication_percent") { module in
                let lines = linesByModule[module] ?? 0
                return lines == 0 ? 0 : Double(summary.duplicatedLines(inModule: module)) / Double(lines) * 100
            }
            report.append("\nDuplication: \(String(format: "%.2f", summary.percentage))% in \(summary.clones.count) clones:")
            report += summary.clones.sorted { $0.lines > $1.lines }.map {
                "  \($0.lines) lines  \($0.first.path):\($0.first.start)  <->  \($0.second.path):\($0.second.start)"
            }
        } else {
            skipped.append("code.duplication_percent")
        }

        if let csv = inputs.lizardCSV {
            let functions = complexity(lizardCSV: csv)
            let over = functionsOver(ccnLimit, in: functions)
            metrics["code.functions_over_ccn15"] = Double(over.count)
            metrics["code.max_ccn"] = Double(functions.map(\.ccn).max() ?? 0)
            perModule("functions_over_ccn15") { module in Double(over.filter { $0.module == module }.count) }
            report.append("\nFunctions over CCN \(ccnLimit) (\(over.count) of \(functions.count)):")
            report += over.sorted { $0.ccn > $1.ccn }.map { "  CCN \($0.ccn)  \($0.path):\($0.line)  \($0.name)" }
        } else {
            skipped += ["code.functions_over_ccn15", "code.max_ccn"]
        }

        let results = EvalResults(date: ISO8601DateFormatter().string(from: Date()), metrics: metrics, skipped: skipped)
        return Outcome(results: results, report: report.joined(separator: "\n") + "\n")
    }

    private static func describe(_ finding: Finding) -> String {
        "  \(finding.path):\(finding.line)  \(finding.kind) \(finding.name)  [\(finding.hints.joined(separator: ", "))]"
    }
}
