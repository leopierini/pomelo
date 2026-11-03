import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

/// Serialized: each test makes a movie with the hardware encoder, and several at once starved the HEIC encoder of
/// ImageIOToolTests (it failed "cannot write marked.heic").
@Suite(.serialized) struct FFmpegToolTests {
    /// Pomelo's installer brings ffmpeg but never ffprobe, so the tests that inspect an output skip without it.
    static let canProbe = Installed.has("ffmpeg") && Installed.has("ffprobe")

    private func bundled() throws -> PluginManifest {
        let (manifests, _) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        return try #require(manifests.first { $0.id == "ffmpeg" })
    }

    /// The (operation, source) pairs the bundled ffmpeg manifest must offer, each to the same format but snapshot.
    private static let toolTable: [String: [FormatID]] = [
        "compress": ["mkv", "webm"],
        "remove-audio": ["mkv", "webm", "avi", "wmv"],
        "snapshot": ["mkv", "webm", "avi", "wmv"],
        "normalize-volume": ["mp3", "m4a", "ogg", "opus", "wma", "wav", "flac", "aiff", "mp4", "mov", "m4v", "mkv", "webm"],
        "speed": ["mkv", "avi", "wmv", "webm", "mp3", "wav", "flac", "aiff", "ogg", "opus", "wma"],
        "mono": ["mp3", "flac", "ogg", "opus", "wma"],
        "strip-metadata": ["mkv", "webm", "avi", "wmv", "mp3", "flac", "ogg", "opus", "wav", "aiff", "wma"],
        "trim": ["mp3", "flac"],
    ]

    @Test func everyToolEdgeIsValidAndHasItsOperation() throws {
        let manifest = try bundled()
        try manifest.validate()
        for (operation, formats) in Self.toolTable {
            for format in formats {
                let target: FormatID = operation == "snapshot" ? "png" : format
                let edge = try #require(
                    manifest.edge(from: format, to: target, operation: operation), "\(operation) \(format)"
                )
                #expect(edge.arguments.starts(with: ["-hide_banner", "-nostdin", "-y", "-i", "{input}"]))
                #expect(edge.arguments.last == "{output}")
            }
        }
        // No manifest edge may widen into a pair nobody asked for (a cross product of from and to).
        let expected = Set(Self.toolTable.flatMap { operation, formats in
            formats.map { "\(operation):\($0)>\(operation == "snapshot" ? "png" : $0)" }
        })
        let actual = Set(manifest.conversionEdges().compactMap { edge in
            edge.operation.map { "\($0):\(edge.from)>\(edge.to)" }
        })
        #expect(actual == expected)
    }

    @Test func filterCommasAreEscaped() throws {
        let manifest = try bundled()
        for format: FormatID in ["mkv", "webm"] {
            let edge = try #require(manifest.edge(from: format, to: format, operation: "compress"))
            let arguments = try ArgumentTemplate.expand(
                edge.arguments, values: ["input": "in", "output": "out"], options: PresetOptions(videoMaxHeight: 1080)
            )
            let filter = try #require(arguments.firstIndex(of: "-vf"))
            #expect(arguments[filter + 1] == "scale=-2:min(1080\\,ih)")
        }
    }

    @Test func wmvAndAVIAndWMAEdges() throws {
        let manifest = try bundled()
        let avi = try #require(manifest.edge(from: "wmv", to: "avi", operation: nil))
        #expect(avi.arguments == [
            "-hide_banner", "-nostdin", "-y", "-i", "{input}", "-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4",
            "-c:a", "libmp3lame", "-q:a", "4", "{output}",
        ])
        let wmv = try #require(manifest.edge(from: "avi", to: "wmv", operation: nil))
        #expect(wmv.arguments == [
            "-hide_banner", "-nostdin", "-y", "-i", "{input}", "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2",
            "-b:a", "192k", "{output}",
        ])
        let wma = try #require(manifest.edge(from: "mp4", to: "wma", operation: nil))
        #expect(wma.arguments == [
            "-hide_banner", "-nostdin", "-y", "-i", "{input}", "-vn", "-c:a", "wmav2", "-b:a", "{audioBitrate:192k}",
            "{output}",
        ])
        for edge in [avi, wmv, wma] { #expect(edge.flags == ["lossy"]) }
        for source: FormatID in ["mov", "mp4", "m4v", "mkv", "webm", "wmv"] {
            #expect(manifest.edge(from: source, to: "avi", operation: nil) != nil, "\(source) to avi")
        }
        for source: FormatID in ["mov", "mp4", "m4v", "mkv", "webm", "avi"] {
            #expect(manifest.edge(from: source, to: "wmv", operation: nil) != nil, "\(source) to wmv")
        }
        for source: FormatID in ["mov", "mp4", "m4v", "mkv", "webm", "avi", "wmv", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"] {
            #expect(manifest.edge(from: source, to: "wma", operation: nil) != nil, "\(source) to wma")
        }
        // Everything ffmpeg writes can be read back from the new formats.
        for target: FormatID in ["mp4", "webm", "mkv", "gif"] {
            #expect(manifest.edge(from: "wmv", to: target, operation: nil) != nil, "wmv to \(target)")
        }
        for target: FormatID in ["mp3", "m4a", "ogg", "opus", "flac"] {
            #expect(manifest.edge(from: "wma", to: target, operation: nil) != nil, "wma to \(target)")
            #expect(manifest.edge(from: "wmv", to: target, operation: nil) != nil, "wmv to \(target)")
        }
    }

    /// P57: iPhone videos carry data tracks (mebx, tmcd) that the mp4 muxer rejects under `-map 0`; normalize keeps
    /// the picture, every sound track and the subtitles, which the same container always takes.
    @Test func videoNormalizeMapsPictureSoundAndSubtitlesOnly() throws {
        let manifest = try bundled()
        for source: FormatID in ["mp4", "mov", "m4v"] {
            let args = try #require(manifest.edge(from: source, to: source, operation: "normalize-volume")).arguments
            #expect(!args.contains("0"), "\(source)")
            #expect(Self.maps(args) == ["0:v?", "0:a", "0:s?"], "\(source)")
        }
    }

    /// P62: Compress re-encodes the picture and copies every other stream (extra sound tracks, subtitles); Speed keeps
    /// only picture and sound, since a bitmap subtitle track cannot be retimed and fails the job.
    @Test func compressKeepsEveryStreamAndSpeedOnlyPictureAndSound() throws {
        let manifest = try bundled()
        for source: FormatID in ["mkv", "webm"] {
            let args = try #require(manifest.edge(from: source, to: source, operation: "compress")).arguments
            #expect(Self.maps(args) == ["0"], "\(source)")
            let copy = try #require(args.firstIndex(of: "-c"), "\(source)")
            #expect(args[copy + 1] == "copy" && copy < args.firstIndex(of: "-c:v")!, "\(source)")
        }
        for source: FormatID in ["mkv", "webm", "avi", "wmv"] {
            let args = try #require(manifest.edge(from: source, to: source, operation: "speed")).arguments
            #expect(Self.maps(args) == ["0:v", "0:a?"], "\(source)")
        }
    }

    private static func maps(_ arguments: [String]) -> [String] {
        arguments.indices.filter { arguments[$0] == "-map" }.map { arguments[$0 + 1] }
    }

    // MARK: With ffmpeg

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        guard let url = Installed.path(of: executable) else {
            throw Fixtures.Failure("\(executable) is not installed")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Fixtures.Failure("\(executable) \(arguments) failed") }
        return String(decoding: data, as: UTF8.self)
    }

    private func ffmpeg(_ arguments: [String]) throws {
        _ = try run("ffmpeg", ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + arguments)
    }

    private struct Probe {
        var streams: [[String: Any]]
        var format: [String: Any]
        func streams(_ type: String) -> [[String: Any]] { streams.filter { $0["codec_type"] as? String == type } }
        var duration: Double { Double(format["duration"] as? String ?? "") ?? 0 }
        var tags: [String: String] { (format["tags"] as? [String: String]) ?? [:] }
    }

    private func probe(_ url: URL) throws -> Probe {
        let json = try run("ffprobe", ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return Probe(
            streams: root["streams"] as? [[String: Any]] ?? [], format: root["format"] as? [String: Any] ?? [:]
        )
    }

    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func output(of results: [FileResult]) throws -> URL {
        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            throw Fixtures.Failure("\(results)")
        }
        return output
    }

    private func applyPreset(_ id: String, to input: URL) async throws -> URL {
        let preset = try #require(Preset.builtIns.first { $0.id == id })
        return try output(of: await runner().run(ConversionRequest.from(preset, inputs: [input])))
    }

    private func convert(_ input: URL, to target: FormatID) async throws -> URL {
        let request = ConversionRequest(inputs: [input], target: target)
        return try output(of: await runner().run(request))
    }

    /// A 3 second clip with sound in a container ffmpeg writes, made from the AVFoundation fixture.
    private func clip(as ext: String, seconds: Double = 3, withAudio: Bool = true, in dir: URL) async throws -> URL {
        let movie = try await Fixtures.movie(seconds: seconds, withAudio: withAudio, in: dir)
        let url = dir.appending(path: "sample.\(ext)")
        try ffmpeg(["-i", movie.path, "-c:v", "libx264", "-pix_fmt", "yuv420p"] + (withAudio ? ["-c:a", ext == "webm" ? "libopus" : "aac"] : ["-an"]) + [url.path])
        return url
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func wmvRoundTrips() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)

        let wmv = try await convert(movie, to: "wmv")
        #expect(wmv.pathExtension == "wmv")
        let wmvProbe = try probe(wmv)
        #expect(wmvProbe.streams("video").first?["codec_name"] as? String == "wmv2")
        #expect(wmvProbe.streams("audio").first?["codec_name"] as? String == "wmav2")

        let mp4 = try await convert(wmv, to: "mp4")
        let mp4Probe = try probe(mp4)
        #expect(abs(mp4Probe.duration - 2) <= 0.3, "\(mp4Probe.duration) s")
        #expect(mp4Probe.streams("video").first?["codec_name"] as? String == "h264")
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func aviAndWMAAreWritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)

        let avi = try probe(try await convert(movie, to: "avi"))
        #expect(avi.streams("video").first?["codec_name"] as? String == "mpeg4")
        #expect(avi.streams("audio").first?["codec_name"] as? String == "mp3")

        let wma = try probe(try await convert(try Fixtures.wav(seconds: 2, in: dir), to: "wma"))
        #expect(wma.streams("audio").first?["codec_name"] as? String == "wmav2")
        #expect(wma.streams("video").isEmpty)
        #expect(abs(wma.duration - 2) <= 0.3, "\(wma.duration) s")
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func normalizeKeeps48kHz() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 3, in: dir)

        let normalized = try probe(try await applyPreset("normalize-volume", to: wav))

        let sampleRate = normalized.streams("audio").first?["sample_rate"] as? String
        #expect(sampleRate == "48000", "\(sampleRate ?? "nil")")
        #expect(abs(normalized.duration - 3) <= 0.3, "\(normalized.duration) s")
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func normalizeKeepsTheVideoOfAnMKV() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await clip(as: "mkv", in: dir)

        let normalized = try probe(try await applyPreset("normalize-volume", to: mkv))

        #expect(normalized.streams("video").first?["codec_name"] as? String == "h264")
        #expect(normalized.streams("audio").first?["sample_rate"] as? String == "48000")
    }

    /// P57: a timecode track like an iPhone's made the mp4 muxer fail the whole job.
    @Test(.enabled(if: FFmpegToolTests.canProbe)) func normalizeAnMP4WithATimecodeTrackAndSubtitles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let subtitles = try Fixtures.srt(in: dir)
        let mp4 = dir.appending(path: "phone.mp4")
        try ffmpeg([
            "-i", movie.path, "-i", subtitles.path, "-map", "0", "-map", "1", "-c", "copy", "-c:s", "mov_text",
            "-timecode", "01:00:00:00", mp4.path,
        ])
        try #require(try probe(mp4).streams("data").count == 1)

        let normalized = try probe(try await applyPreset("normalize-volume", to: mp4))

        #expect(normalized.streams("video").first?["codec_name"] as? String == "h264")
        #expect(normalized.streams("audio").first?["sample_rate"] as? String == "48000")
        #expect(normalized.streams("subtitle").count == 1)
    }

    /// An MKV with a second sound track and a subtitle track, as a film with a commentary track comes.
    private func mkvWithTwoSoundTracksAndSubtitles(seconds: Double, in dir: URL) async throws -> URL {
        let movie = try await Fixtures.movie(seconds: seconds, withAudio: true, width: 640, height: 480, in: dir)
        let subtitles = try Fixtures.srt(in: dir)
        let mkv = dir.appending(path: "film.mkv")
        try ffmpeg([
            "-i", movie.path, "-i", subtitles.path, "-map", "0:v", "-map", "0:a", "-map", "0:a", "-map", "1",
            "-c:v", "libx264", "-crf", "10", "-c:a", "aac", "-c:s", "srt", mkv.path,
        ])
        try #require(try probe(mkv).streams("audio").count == 2)
        return mkv
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func compressAnMKVKeepsEverySoundTrackAndTheSubtitles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await mkvWithTwoSoundTracksAndSubtitles(seconds: 2, in: dir)

        let compressed = try probe(try await applyPreset("compress", to: mkv))

        #expect(compressed.streams("video").first?["codec_name"] as? String == "hevc")
        #expect(compressed.streams("audio").count == 2)
        #expect(compressed.streams("subtitle").count == 1)
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func speedOnAnMKVKeepsEverySoundTrackAndDropsSubtitles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await mkvWithTwoSoundTracksAndSubtitles(seconds: 4, in: dir)

        let sped = try probe(try await applyPreset("speed-up", to: mkv))

        #expect(abs(sped.duration - 2) <= 0.3, "\(sped.duration) s")
        #expect(sped.streams("audio").count == 2)
        #expect(sped.streams("subtitle").isEmpty)
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func speedOnASilentMKVSucceeds() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await clip(as: "mkv", seconds: 4, withAudio: false, in: dir)

        let sped = try probe(try await applyPreset("speed-up", to: mkv))

        #expect(abs(sped.duration - 2) <= 0.3, "\(sped.duration) s")
        #expect(sped.streams("audio").isEmpty)
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func speedHalvesAnMKVWithSound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await clip(as: "mkv", seconds: 4, in: dir)

        let sped = try probe(try await applyPreset("speed-up", to: mkv))

        #expect(abs(sped.duration - 2) <= 0.3, "\(sped.duration) s")
        #expect(sped.streams("audio").count == 1)
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func compressAnMKVHonoursTheCap() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, width: 1280, height: 720, in: dir)
        let mkv = dir.appending(path: "big.mkv")
        try ffmpeg(["-i", movie.path, "-c:v", "libx264", "-crf", "10", "-c:a", "aac", mkv.path])
        let preset = try #require(Preset.builtIns.first { $0.id == "compress-more" })
        var request = ConversionRequest.from(preset, inputs: [mkv])
        request.options.videoMaxHeight = 360

        let compressed = try probe(try output(of: await runner().run(request)))

        #expect(compressed.streams("video").first?["codec_name"] as? String == "hevc")
        #expect(compressed.streams("video").first?["height"] as? Int == 360)
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func removeAudioFromMKV() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await clip(as: "mkv", in: dir)

        let silent = try probe(try await applyPreset("remove-audio", to: mkv))

        #expect(silent.streams("audio").isEmpty)
        #expect(silent.streams("video").count == 1)
        #expect(abs(silent.duration - 3) <= 0.3, "\(silent.duration) s")
    }

    @Test(.enabled(if: Installed.has("ffmpeg"))) func snapshotOfMKV() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await clip(as: "mkv", in: dir)

        let snapshot = try await applyPreset("snapshot", to: mkv)

        #expect(snapshot.pathExtension == "png")
        #expect(Fixtures.imageSize(snapshot) == CGSize(width: 320, height: 240))
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func stripMetadataOfMP3() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 2, in: dir)
        let mp3 = dir.appending(path: "tagged.mp3")
        try ffmpeg(["-i", wav.path, "-metadata", "title=Secret title", "-metadata", "artist=Someone", mp3.path])
        #expect(try probe(mp3).tags["title"] == "Secret title")

        let stripped = try probe(try await applyPreset("strip-metadata", to: mp3))

        #expect(stripped.tags["title"] == nil)
        #expect(stripped.tags["artist"] == nil)
        #expect(stripped.streams("audio").count == 1)
        #expect(abs(stripped.duration - 2) <= 0.3, "\(stripped.duration) s")
    }

    @Test(.enabled(if: FFmpegToolTests.canProbe)) func monoOfAnMP3HasOneChannel() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 2, channels: 2, in: dir)
        let mp3 = dir.appending(path: "stereo.mp3")
        try ffmpeg(["-i", wav.path, mp3.path])

        let mono = try probe(try await applyPreset("mono", to: mp3))

        #expect(mono.streams("audio").first?["channels"] as? Int == 1)
    }
}
