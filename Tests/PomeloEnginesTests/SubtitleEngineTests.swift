import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct SubtitleEngineTests {
    private let formats = FormatRegistry.builtIn

    private func convert(_ source: URL, to target: FormatID, in dir: URL) async throws -> URL {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging,
            from: try #require(formats.format(for: source)), to: try #require(formats.format(id: target)),
            options: PresetOptions()
        )
        return try await SubtitleEngine().convert(step) { _ in }
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func srtBecomesVTT() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(try Fixtures.srt(in: dir), to: "vtt", in: dir)

        #expect(output.pathExtension == "vtt")
        #expect(try text(output) == """
            WEBVTT

            00:00:01.000 --> 00:00:03.500
            Hello, <i>Pomelo</i>.

            00:00:04.000 --> 00:00:06.250
            Second line one
            Second line two

            """)
    }

    @Test func vttBecomesSRT() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await convert(try Fixtures.vtt(in: dir), to: "srt", in: dir)

        #expect(output.pathExtension == "srt")
        #expect(try text(output) == """
            1
            00:01:02,000 --> 00:01:04,500
            Ann: Hello, <i>Pomelo</i>.

            2
            01:00:05,000 --> 01:00:07,250
            Second line
            two

            """)
    }

    @Test func windows1252SRTIsRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let latin1 = try #require("1\r\n00:00:01,000 --> 00:00:02,000\r\ncafé\r\n".data(using: .windowsCP1252))
        #expect(String(data: latin1, encoding: .utf8) == nil)

        let output = try await convert(try Fixtures.textFile(latin1, ext: "srt", in: dir), to: "vtt", in: dir)

        #expect(try text(output) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\ncafé\n")
    }

    @Test func aUTF8BOMIsAcceptedAndNotWritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("1\n00:00:01,000 --> 00:00:02,000\nhi\n".utf8)

        let output = try await convert(try Fixtures.textFile(data, ext: "srt", in: dir), to: "vtt", in: dir)

        let bytes = try Data(contentsOf: output)
        #expect(bytes.starts(with: Data("WEBVTT".utf8)))
        #expect(try text(output) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n")
    }

    @Test func aUTF16SRTIsRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require("\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nhi\n".data(using: .utf16LittleEndian))

        let output = try await convert(try Fixtures.textFile(data, ext: "srt", in: dir), to: "vtt", in: dir)

        #expect(try text(output) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n")
    }

    @Test func windowsLineEndingsAreNormalised() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let crlf = Fixtures.sampleSRT.replacingOccurrences(of: "\n", with: "\r\n")

        let output = try await convert(try Fixtures.srt(crlf, in: dir), to: "vtt", in: dir)

        let result = try text(output)
        #expect(!result.contains("\r"))
        #expect(result.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:03.500\nHello"))
    }

    @Test func vttTagsOtherThanItalicBoldUnderlineAreStripped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vtt = """
            WEBVTT

            00:01.000 --> 00:02.000
            <b>bold</b> <u.x>under</u> <c.red>red</c> <00:01.500>timed <ruby>r<rt>t</rt></ruby> a < b
            <v Bob Smith>Hi</v>

            """

        let output = try await convert(try Fixtures.vtt(vtt, in: dir), to: "srt", in: dir)

        #expect(try text(output) == """
            1
            00:00:01,000 --> 00:00:02,000
            <b>bold</b> <u>under</u> red timed rt a < b
            Bob Smith: Hi

            """)
    }

    @Test func aVTTRegionBlockAndCueSettingsAreDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vtt = """
            WEBVTT - a title

            REGION
            id:r1
            width:40%

            00:00:01.000 --> 00:00:02.000 region:r1 line:0

            """

        let output = try await convert(try Fixtures.vtt(vtt, in: dir), to: "srt", in: dir)

        #expect(try text(output) == "1\n00:00:01,000 --> 00:00:02,000\n")
    }

    @Test func aFileWithoutCuesFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (ext, content, target) in [("srt", "just some words\n\nnot a subtitle", "vtt"), ("vtt", "WEBVTT\n\n", "srt")] {
            let source = try Fixtures.textFile(content, ext: ext, in: dir)
            await #expect(throws: ConversionError.engineFailed(engine: "subtitles", message: "no subtitles found")) {
                _ = try await convert(source, to: FormatID(stringLiteral: target), in: dir)
            }
        }
    }

    @Test func aCancelledStepWritesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.srt(in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging,
            from: try #require(formats.format(id: "srt")), to: try #require(formats.format(id: "vtt")),
            options: PresetOptions()
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubtitleEngine().convert(step) { _ in }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func edgesRoundTripWithTheRightLossiness() {
        let edges = SubtitleEngine().edges()
        #expect(edges.count == 2)
        #expect(edges.first { $0.from == "srt" && $0.to == "vtt" }?.flags == [])
        #expect(edges.first { $0.from == "vtt" && $0.to == "srt" }?.flags == [.lossy])
        #expect(edges.allSatisfy { $0.cost == 10 && $0.operation == nil })
    }

    @Test func aVTTRoundTripKeepsTheCues() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let srt = try await convert(try Fixtures.vtt(in: dir), to: "srt", in: dir)
        let vtt = try await convert(srt, to: "vtt", in: dir)

        #expect(try text(vtt) == """
            WEBVTT

            00:01:02.000 --> 00:01:04.500
            Ann: Hello, <i>Pomelo</i>.

            01:00:05.000 --> 01:00:07.250
            Second line
            two

            """)
    }

    @Test func aVoiceTagWithAClassNamesTheSpeaker() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\n<v.loud Ann>Hi</v> <v.quiet>no name</v>\n"

        let output = try await convert(try Fixtures.vtt(vtt, in: dir), to: "srt", in: dir)

        #expect(try text(output) == "1\n00:00:01,000 --> 00:00:02,000\nAnn: Hi no name\n")
    }

    @Test func cuesWithoutABlankLineBetweenThemStaySeparate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nA\n2\n00:00:03,000 --> 00:00:04,000\nB\nC\n"

        let output = try await convert(try Fixtures.srt(srt, in: dir), to: "vtt", in: dir)

        #expect(try text(output) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA\n\n00:00:03.000 --> 00:00:04.000\nB\nC\n")
    }

    @Test func shortFractionsArePaddedNotDropped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\n00:00:01,5 --> 00:00:02,50\nA\n\n2\n00:00:03,005 --> 00:00:04,000\nB\n"

        let output = try await convert(try Fixtures.srt(srt, in: dir), to: "vtt", in: dir)

        #expect(try text(output) == "WEBVTT\n\n00:00:01.500 --> 00:00:02.500\nA\n\n00:00:03.005 --> 00:00:04.000\nB\n")
    }

    @Test func aTimingLineThatCannotBeReadFailsTheFileInsteadOfDroppingTheCue() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:03,00x --> 00:00:04,000\nB\n"
        let source = try Fixtures.srt(srt, in: dir)

        await #expect(throws: ConversionError.self) { _ = try await convert(source, to: "vtt", in: dir) }
    }

    @Test func aVTTWithNoBlankLineAfterTheHeaderKeepsItsFirstCue() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vtt = "WEBVTT\n00:01.000 --> 00:02.000\nA\n\n00:03.000 --> 00:04.000\nB\n"

        let output = try await convert(try Fixtures.vtt(vtt, in: dir), to: "srt", in: dir)

        #expect(try text(output) == "1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:03,000 --> 00:00:04,000\nB\n")
    }

    @Test func anArrowInCueTextIsText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nA\nx --> y\n5 --> 6\nmore\n"
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000\nA\nx --> y\n5 --&gt; 6\nmore\n"

        let fromSRT = try await convert(try Fixtures.srt(srt, in: dir), to: "vtt", in: dir)
        let fromVTT = try await convert(try Fixtures.vtt(vtt, in: dir), to: "srt", in: dir)

        #expect(try text(fromSRT) == "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA\nx --&gt; y\n5 --&gt; 6\nmore\n")
        #expect(try text(fromVTT) == "1\n00:00:01,000 --> 00:00:02,000\nA\nx --> y\n5 --> 6\nmore\n")
    }

    @Test func anArrowSurvivesAnSRTToVTTToSRTRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n<i>x --> y</i>\n"

        let vtt = try await convert(try Fixtures.srt(srt, in: dir), to: "vtt", in: dir)
        let back = try await convert(vtt, to: "srt", in: dir)

        #expect(try text(vtt).contains("<i>x --&gt; y</i>"))
        #expect(try text(back) == srt)
    }
}
