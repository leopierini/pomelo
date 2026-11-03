import Foundation
import PomeloCore

/// SRT to WebVTT and back. The text is parsed into cues and written again, so nothing but the cue timing and
/// text survives: a VTT's styling, regions, notes and cue settings are lost. `TranslationEngine` shares the parser
/// (`parse`) and the writers, and keeps what a conversion drops.
public struct SubtitleEngine: ConversionEngine {
    private static let edgeCost = 10
    private static let timingSeparator = "-->"
    private static let keptTags: Set<String> = ["i", "b", "u"]
    private static let unreadableTime = ConversionError.engineFailed(
        engine: "subtitles", message: "a subtitle has a time that can't be read"
    )
    private static let vttOnlyBlocks = ["NOTE", "STYLE", "REGION"]

    public init() {}

    public var id: EngineID { "subtitles" }
    public var displayName: String { "Subtitles" }
    public var maxConcurrentJobs: Int { 4 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        [
            ConversionEdge(from: "srt", to: "vtt", engineID: id, cost: Self.edgeCost, flags: []),
            ConversionEdge(from: "vtt", to: "srt", engineID: id, cost: Self.edgeCost, flags: [.lossy]),
        ]
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let text = try Self.read(step.input)
        let output: String
        switch (step.from.id, step.to.id) {
        case ("srt", "vtt"): output = Self.webVTT(from: try Self.parse(text, isVTT: false).cues)
        case ("vtt", "srt"): output = Self.subRip(from: try Self.parse(text, isVTT: true).cues)
        default:
            throw ConversionError.engineFailed(
                engine: id, message: "can't turn \(step.from.displayName) into \(step.to.displayName)"
            )
        }
        guard !output.isEmpty else {
            throw ConversionError.engineFailed(engine: id, message: "no subtitles found")
        }
        let url = try Self.write(output, for: step, engine: id)
        progress(1)
        return url
    }

    /// Writes `text` as UTF-8 to the step's output, unless the job was cancelled. A partial file is removed.
    static func write(_ text: String, for step: ConversionStep, engine: EngineID) throws -> URL {
        try Task.checkCancellation()
        let url = step.suggestedOutput
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.engineFailed(engine: engine, message: "cannot write \(url.lastPathComponent)")
        }
        return url
    }

    // MARK: Reading

    // Windows-1252 is what most old SRT files are; Notepad's "Unicode" is UTF-16 with a BOM.
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(decoding: data, as: UTF8.self)
        }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func normalisedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// What a subtitle file holds, in file order: its cues, and the VTT blocks a cue list has no place for.
    struct Document {
        struct Entry {
            /// The line before the timing line, as written (SRT numbers, VTT identifiers).
            var id: String?
            var cue: Cue
            /// Whatever follows the end time on the timing line: VTT cue settings, SRT coordinates.
            var settings: String
        }

        enum Block {
            case cue(Entry)
            /// A NOTE, STYLE or REGION block, lines as written.
            case kept([String])
        }

        var blocks: [Block]

        var cues: [Cue] {
            blocks.compactMap { if case .cue(let entry) = $0 { entry.cue } else { nil } }
        }
    }

    static func parse(_ text: String, isVTT: Bool) throws -> Document {
        var result: [Document.Block] = []
        for block in blocks(of: text) {
            if isVTT, isVTTOnly(block) {
                result.append(.kept(block))
            } else {
                result += try entries(in: block).map(Document.Block.cue)
            }
        }
        return Document(blocks: result)
    }

    /// The lines between blank lines.
    private static func blocks(of text: String) -> [[String]] {
        var blocks: [[String]] = [[]]
        for line in normalisedLines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
    }

    private static func isVTTOnly(_ block: [String]) -> Bool {
        guard let first = block.first else { return false }
        return vttOnlyBlocks.contains { first == $0 || first.hasPrefix($0 + " ") || first.hasPrefix($0 + "\t") }
    }

    /// A cue starts at every timing line, even inside one block, so a missing blank line never merges two cues.
    /// Lines before a block's first timing line are dropped except the one right before it (its id); between cues
    /// only an all-digit line is taken as the next cue's id.
    private static func entries(in block: [String]) throws -> [Document.Entry] {
        let timings = block.indices.filter { looksLikeTiming(block[$0]) }
        var entries: [Document.Entry] = []
        for (position, timing) in timings.enumerated() {
            let next = position + 1 < timings.count ? timings[position + 1] : block.count
            // After a timing line only an all-digit line can be the next cue's id: any other line is text.
            let hasNextID = next < block.count && next - 1 > timing && isNumber(block[next - 1])
            let textEnd = hasNextID ? next - 1 : next
            guard let (start, end, settings) = timestamps(in: block[timing]) else { throw unreadableTime }
            // A header glued to the first cue (no blank line) is not an id.
            let id = timing > 0 && (position == 0 || isNumber(block[timing - 1])) && !block[timing - 1].hasPrefix("WEBVTT")
                ? block[timing - 1] : nil
            entries.append(Document.Entry(
                id: id, cue: Cue(start: start, end: end, lines: Array(block[(timing + 1)..<textEnd])), settings: settings))
        }
        return entries
    }

    /// An arrow is legal in cue text, so a timing line is one whose two sides start with something time-shaped
    /// (a digit first, a colon inside); one that then fails to parse is an error, not text.
    private static func looksLikeTiming(_ line: String) -> Bool {
        let sides = line.components(separatedBy: timingSeparator)
        guard sides.count == 2 else { return false }
        return sides.allSatisfy {
            guard let token = $0.split(whereSeparator: \.isWhitespace).first else { return false }
            return token.first?.isASCII == true && token.first?.isNumber == true && token.contains(":")
        }
    }

    private static func isNumber(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The start and end of a timing line in seconds, and the text after the end time; nil if either time is
    /// malformed.
    private static func timestamps(in line: String) -> (Double, Double, String)? {
        let sides = line.components(separatedBy: timingSeparator)
        guard sides.count == 2,
            let start = sides[0].split(whereSeparator: \.isWhitespace).first,
            let endToken = sides[1].split(whereSeparator: \.isWhitespace).first,
            let from = milliseconds(String(start)), let to = milliseconds(String(endToken))
        else { return nil }
        let settings = sides[1].drop { $0.isWhitespace }.dropFirst(endToken.count)
        return (Double(from) / 1000, Double(to) / 1000, settings.trimmingCharacters(in: .whitespaces))
    }

    /// A fraction of one or two digits is padded (`,5` is half a second), as players read it.
    private static func milliseconds(_ text: String) -> Int? {
        let clock = text.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard clock.count == 2, (1...3).contains(clock[1].count) else { return nil }
        let fields = clock[0].split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        let digits = fields + [clock[1]]
        guard digits.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == fields.count, let fraction = Int(clock[1].padding(toLength: 3, withPad: "0", startingAt: 0))
        else { return nil }
        var seconds = 0
        for number in numbers {
            let (scaled, scaleOverflow) = seconds.multipliedReportingOverflow(by: 60)
            let (sum, sumOverflow) = scaled.addingReportingOverflow(number)
            if scaleOverflow || sumOverflow { return nil }
            seconds = sum
        }
        // Past this a time no longer survives the trip through seconds as a Double exactly.
        guard seconds <= maxSeconds else { return nil }
        let total = seconds * 1000 + fraction
        return total <= maxSeconds * 1000 ? total : nil
    }

    private static let maxSeconds = 100_000 * 3600

    // MARK: Writing

    /// `hh:mm:ss<separator>ttt`, hours at least two digits.
    private static func clock(_ seconds: Double, separator: String) -> String {
        let clamped = seconds.isFinite ? min(max(seconds, 0), Double(maxSeconds)) : 0
        let total = Int((clamped * 1000).rounded())
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let fraction = String(total % 1000)
        return "\(two(total / 3_600_000)):\(two(total / 60_000 % 60)):\(two(total / 1000 % 60))\(separator)"
            + String(repeating: "0", count: 3 - fraction.count) + fraction
    }

    /// WebVTT from cues alone: no ids, settings or notes.
    static func webVTT(from cues: [Cue]) -> String {
        webVTT(Document(blocks: cues.map { .cue(Document.Entry(id: nil, cue: $0, settings: "")) }))
    }

    /// Cue text is written as given, with its arrows escaped; ids, settings and kept blocks come out as parsed.
    static func webVTT(_ document: Document) -> String {
        guard !document.blocks.isEmpty else { return "" }
        let body = document.blocks.map { block -> String in
            switch block {
            case .kept(let lines):
                return lines.joined(separator: "\n")
            case .cue(let entry):
                let timing = "\(clock(entry.cue.start, separator: ".")) --> \(clock(entry.cue.end, separator: "."))"
                    + (entry.settings.isEmpty ? "" : " " + entry.settings)
                return ((entry.id.map { [$0] } ?? []) + [timing] + entry.cue.lines.map(escapedArrows)).joined(separator: "\n")
            }
        }
        return "WEBVTT\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    /// WebVTT forbids `-->` in cue text, where a parser would read the line as a timing line.
    private static let arrowEntity = "--&gt;"

    private static func escapedArrows(_ line: String) -> String {
        line.replacingOccurrences(of: timingSeparator, with: arrowEntity)
    }

    /// SubRip from cues alone, numbered from 1, with VTT markup reduced to what SubRip players read.
    static func subRip(from cues: [Cue]) -> String {
        subRip(
            Document(blocks: cues.map { .cue(Document.Entry(id: nil, cue: $0, settings: "")) }),
            line: { strippedTags($0).replacingOccurrences(of: arrowEntity, with: timingSeparator) })
    }

    /// Cue text goes through `line`; ids and settings come out as parsed, and a missing id is the cue's number.
    static func subRip(_ document: Document, line: (String) -> String = { $0 }) -> String {
        var number = 0
        let body = document.blocks.compactMap { block -> String? in
            guard case .cue(let entry) = block else { return nil }
            number += 1
            let timing = "\(clock(entry.cue.start, separator: ",")) --> \(clock(entry.cue.end, separator: ","))"
                + (entry.settings.isEmpty ? "" : " " + entry.settings)
            return (["\(entry.id ?? String(number))", timing] + entry.cue.lines.map(line)).joined(separator: "\n")
        }
        return body.isEmpty ? "" : body.joined(separator: "\n\n") + "\n"
    }

    private static func strippedTags(_ line: String) -> String {
        var result = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "<") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard afterOpen < rest.endIndex, rest[afterOpen].isLetter || rest[afterOpen].isNumber || rest[afterOpen] == "/",
                let close = rest[afterOpen...].firstIndex(of: ">")
            else {
                result.append("<")
                rest = rest[afterOpen...]
                continue
            }
            let tag = rest[afterOpen..<close]
            let isClosing = tag.hasPrefix("/")
            let body = isClosing ? tag.dropFirst() : tag
            let name = body.prefix { !$0.isWhitespace && $0 != "." }.lowercased()
            if keptTags.contains(name) {
                result += isClosing ? "</\(name)>" : "<\(name)>"
            } else if name == "v", !isClosing {
                let speaker = body.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
                if !speaker.isEmpty { result += "\(speaker): " }
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}
