import Foundation
import Testing
import PomeloCore
import PomeloTestSupport
@testable import PomeloEngines

@Suite struct SubtitleDocumentTests {
    @Test func aCueKeepsItsIDSettingsAndTheBlocksAroundIt() throws {
        let vtt = """
            WEBVTT

            NOTE a note

            REGION
            id:r1

            intro
            00:00:01.000 --> 00:00:03.500 align:start position:10%
            Hello

            00:00:04.250 --> 00:00:05.000
            Bye
            """

        let document = try SubtitleEngine.parse(vtt, isVTT: true)

        #expect(document.cues == [
            Cue(start: 1, end: 3.5, lines: ["Hello"]), Cue(start: 4.25, end: 5, lines: ["Bye"]),
        ])
        guard case .kept(let note) = document.blocks[0], case .kept(let region) = document.blocks[1],
            case .cue(let first) = document.blocks[2], case .cue(let second) = document.blocks[3]
        else {
            Issue.record("unexpected blocks \(document.blocks)")
            return
        }
        #expect(note == ["NOTE a note"] && region == ["REGION", "id:r1"])
        #expect(first.id == "intro" && first.settings == "align:start position:10%")
        #expect(second.id == nil && second.settings.isEmpty)
    }

    @Test func anSRTKeepsItsNumbersAndCoordinatesAndAGluedHeaderIsNotAnID() throws {
        let srt = "5\n00:00:01,000 --> 00:00:02,000 X1:1 X2:2\none\ntwo\n9\n00:00:03,000 --> 00:00:04,000\nthree\n"
        let document = try SubtitleEngine.parse(srt, isVTT: false)
        let entries = document.blocks.compactMap { if case .cue(let entry) = $0 { entry } else { nil } }

        #expect(entries.map(\.id) == ["5", "9"])
        #expect(entries.map(\.settings) == ["X1:1 X2:2", ""])
        #expect(entries.map(\.cue.lines) == [["one", "two"], ["three"]])

        let glued = try SubtitleEngine.parse("WEBVTT\n00:00:01.000 --> 00:00:02.000\nhi\n", isVTT: true)
        guard case .cue(let entry) = glued.blocks[0] else {
            Issue.record("no cue")
            return
        }
        #expect(entry.id == nil)
    }

    @Test func cuesInSecondsAreWrittenAsClockTimes() {
        let cues = [Cue(start: 1, end: 3.5, lines: ["a --> b", "second"]), Cue(start: 3723.0425, end: 7200, lines: ["x"])]

        #expect(SubtitleEngine.webVTT(from: cues) == """
            WEBVTT

            00:00:01.000 --> 00:00:03.500
            a --&gt; b
            second

            01:02:03.043 --> 02:00:00.000
            x

            """)
        #expect(SubtitleEngine.subRip(from: cues) == """
            1
            00:00:01,000 --> 00:00:03,500
            a --> b
            second

            2
            01:02:03,043 --> 02:00:00,000
            x

            """)
        #expect(SubtitleEngine.webVTT(from: []).isEmpty && SubtitleEngine.subRip(from: []).isEmpty)
    }

    @Test func aTimeIsWrittenBackAsItWasRead() throws {
        for time in ["00:00:00.001", "00:59:59.999", "10:00:00.500", "123:45:06.007"] {
            let document = try SubtitleEngine.parse("\(time) --> \(time)\nx\n", isVTT: true)
            #expect(SubtitleEngine.webVTT(from: document.cues).contains("\(time) --> \(time)"), "\(time)")
        }
    }

    private static let unreadable = ConversionError.engineFailed(
        engine: "subtitles", message: "a subtitle has a time that can't be read")

    @Test(arguments: [
        "999999999999999999:00:00,000 --> 999999999999999999:00:01,000",
        "2562047788015:12:55,807 --> 2562047788015:12:56,807",
        "99999999999:00:00,000 --> 99999999999:00:01,000",
        "00:99999999999999999:00,000 --> 00:00:01,000",
        "100001:00:00,000 --> 100001:00:01,000",
        "00:00:01,000 --> 100000:00:00,001",
    ])
    func aTimeThatCannotBeHeldExactlyFailsTheFile(timing: String) throws {
        #expect(throws: Self.unreadable) {
            try SubtitleEngine.parse("1\n\(timing)\nx\n", isVTT: false)
        }
    }

    @Test func theLargestTimeIsKeptWholeThroughTheTrip() throws {
        let timing = "99999:00:00.000 --> 100000:00:00.000"
        let document = try SubtitleEngine.parse("\(timing)\nx\n", isVTT: true)

        #expect(SubtitleEngine.webVTT(from: document.cues).contains(timing))
    }

    @Test func aFileWithAHugeTimeFailsInsteadOfCrashing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.srt("1\n999999999999999999:00:00,000 --> 999999999999999999:00:01,000\nx\n", in: dir)
        let formats = FormatRegistry.builtIn
        let step = ConversionStep(
            input: source, stagingDirectory: dir, from: try #require(formats.format(for: source)),
            to: try #require(formats.format(id: "vtt")), options: PresetOptions())

        await #expect(throws: Self.unreadable) { try await SubtitleEngine().convert(step) { _ in } }
    }

    @Test func writingATimeNeverTrapsOrTruncates() {
        let cues = [
            Cue(start: 1e300, end: .infinity, lines: ["x"]), Cue(start: .nan, end: -5, lines: ["y"]),
            Cue(start: 360_000_000, end: 360_000_000.5, lines: ["z"]),
        ]

        let vtt = SubtitleEngine.webVTT(from: cues)

        #expect(vtt.contains("100000:00:00.000 --> 00:00:00.000\nx"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:00.000\ny"))
        #expect(vtt.contains("100000:00:00.000 --> 100000:00:00.000\nz"))
    }
}
