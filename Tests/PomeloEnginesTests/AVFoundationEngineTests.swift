import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ImageIO
import Testing
import os
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct AVFoundationEngineTests {
    private let registry = FormatRegistry.builtIn
    /// A quarter turn, the way a phone held upright records.
    private let sideways = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)

    private func step(
        _ input: URL, to target: FormatID, in staging: URL, options: PresetOptions = PresetOptions()
    ) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target))
        return ConversionStep(input: input, stagingDirectory: staging, from: from, to: to, options: options)
    }

    private func tool(
        _ operation: String, _ input: URL, to target: FormatID? = nil, in staging: URL,
        options: PresetOptions = PresetOptions()
    ) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target ?? from.id))
        return ConversionStep(
            input: input, stagingDirectory: staging, from: from, to: to, options: options, operation: operation
        )
    }

    private func presetOptions(_ id: String) throws -> PresetOptions {
        try #require(Preset.builtIns.first { $0.id == id }).options
    }

    private func makeStaging(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func seconds(of url: URL) async throws -> Double {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    /// The Core Audio file type (`kAudioFileM4AType`, `kAudioFileWAVEType`, …) of the file at `url`.
    private func audioFileType(_ url: URL) throws -> AudioFileTypeID {
        var file: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        let opened = try #require(openStatus == noErr ? file : nil)
        defer { AudioFileClose(opened) }
        var type: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        let status = AudioFileGetProperty(opened, kAudioFilePropertyFileFormat, &size, &type)
        #expect(status == noErr)
        return type
    }

    @Test func edgesMatchTheBrief() {
        let engine = AVFoundationEngine()
        let edges = engine.edges().filter { $0.operation == nil }
        func edge(_ from: FormatID, _ to: FormatID) -> ConversionEdge? {
            edges.first { $0.from == from && $0.to == to }
        }
        let videos: [FormatID] = ["mov", "mp4", "m4v"]
        let audios: [FormatID] = ["wav", "aiff", "caf", "m4a", "mp3", "flac"]
        #expect(edges.count == videos.count * 3 + audios.count * 4)
        #expect(Set(edges.map { "\($0.from)>\($0.to)" }).count == edges.count)
        #expect(edges.allSatisfy { $0.engineID == "avfoundation" && $0.cost == 10 })
        for video in videos {
            #expect(edge(video, "mp4")?.flags == [.lossy])
            #expect(edge(video, "mov")?.flags == [.lossy])
            #expect(edge(video, "m4a")?.flags == [.lossy])
        }
        for audio in audios {
            #expect(edge(audio, "m4a")?.flags == [.lossy])
            for lpcm: FormatID in ["wav", "aiff", "caf"] {
                #expect(edge(audio, lpcm)?.flags == [])
            }
        }
        #expect(edge("m4v", "m4v") == nil)
        #expect(engine.edges() == engine.edges())
        #expect(engine.id == "avfoundation")
        #expect(engine.displayName == "AVFoundation")
        #expect(engine.maxConcurrentJobs == 2)
    }

    @Test func movToMP4() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try step(input, to: "mp4", in: staging)
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(output.pathExtension == "mp4")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let duration = try await seconds(of: output)
        #expect(abs(duration - 1.0) <= 0.15)
    }

    @Test func hevcCompressionHonoursMaxHeight() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let options = PresetOptions(videoCodec: .hevc, videoMaxHeight: 1080)
        let output = try await AVFoundationEngine().convert(try step(input, to: "mp4", in: staging, options: options)) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)  // 'hvc1'
        let size = try await track.load(.naturalSize)
        #expect(size.height == 240)
        #expect(size.width == 320)
    }

    @Test func videoToM4AHasOnlyAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try step(input, to: "m4a", in: staging)) { _ in }

        #expect(output.pathExtension == "m4a")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    /// Extract audio's Quality setting is the AAC bitrate; the export preset ignored it.
    @Test(arguments: ["128k", "256k"])
    func videoToM4AHonoursTheBitrate(bitrate: String) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let options = PresetOptions(audioBitrate: bitrate)
        let output = try await AVFoundationEngine().convert(try step(input, to: "m4a", in: staging, options: options)) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let rate = Double(try await track.load(.estimatedDataRate))
        let wanted = Double(try AVFoundationEngine.bitsPerSecond(bitrate))
        #expect(abs(rate - wanted) / wanted <= 0.2, "\(rate) b/s for \(bitrate)")
    }

    /// A 5.1 AAC .mov made by ffmpeg: AVFoundation cannot write six-channel AAC itself.
    private func surroundMovie(in dir: URL) throws -> URL {
        guard let ffmpeg = Installed.path(of: "ffmpeg") else { throw Fixtures.Failure("ffmpeg is not installed") }
        let url = dir.appending(path: "surround.mov")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=440:d=2",
            "-filter_complex", "[0:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-c:a", "aac", url.path,
        ]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return url
    }

    /// The AAC writer refuses six discrete channels at every bitrate, so a surround track is downmixed to stereo, as
    /// the old AppleM4A export did.
    @Test(.enabled(if: Installed.has("ffmpeg")))
    func videoToM4ADownmixesSurroundToStereo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try surroundMovie(in: dir)
        let staging = try makeStaging(in: dir)
        let source = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .audio).first)
        let sourceFormat = try #require(try await source.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee.mChannelsPerFrame == 6)

        let output = try await AVFoundationEngine().convert(try step(input, to: "m4a", in: staging)) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame == 2)
        #expect(try peakLevel(of: output) > 0.05)
    }

    /// Only Remove metadata may drop a video's metadata, so Extract audio keeps its title. The location stays behind:
    /// AVFoundation's m4a writer stores no location in any keyspace.
    @Test func videoToM4AKeepsTheMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movieWithLocationAndTitle(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try step(input, to: "m4a", in: staging)) { _ in }

        let bytes = try Data(contentsOf: output)
        #expect(bytes.range(of: Data(Fixtures.movieTitle.utf8)) != nil)
    }

    @Test func wavToM4A() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.wav(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try step(input, to: "m4a", in: staging)) { _ in }

        #expect(output.pathExtension == "m4a")
        #expect(try audioFileType(output) == kAudioFileM4AType)
        let duration = try await seconds(of: output)
        #expect(abs(duration - 1.0) <= 0.15)
    }

    @Test func m4aToWav() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 1, in: dir)
        let firstStaging = try makeStaging(in: dir)
        let m4a = try await AVFoundationEngine().convert(try step(wav, to: "m4a", in: firstStaging)) { _ in }
        let secondStaging = dir.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondStaging, withIntermediateDirectories: true)

        let conversion = try step(m4a, to: "wav", in: secondStaging)
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(try audioFileType(output) == kAudioFileWAVEType)
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate > 0)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(duration - 1.0) <= 0.15)
    }

    @Test func reportsProgress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)
        let reported = OSAllocatedUnfairLock<[Double]>(initialState: [])

        _ = try await AVFoundationEngine().convert(try step(input, to: "mov", in: staging)) { value in
            reported.withLock { $0.append(value) }
        }

        let values = reported.withLock { $0 }
        #expect(!values.isEmpty)
        #expect(values.last == 1.0)
        #expect(values.allSatisfy { (0...1).contains($0) })
    }

    @Test(arguments: [
        (VideoCodec.h264, Int?.none, AVAssetExportPresetHighestQuality),
        (.h264, 480, AVAssetExportPreset640x480),
        (.h264, 600, AVAssetExportPreset960x540),
        (.h264, 720, AVAssetExportPreset1280x720),
        (.h264, 1080, AVAssetExportPreset1920x1080),
        (.h264, 1500, AVAssetExportPreset1920x1080),
        (.h264, 2160, AVAssetExportPreset3840x2160),
        (.h264, 4320, AVAssetExportPreset3840x2160),
        (.hevc, nil, AVAssetExportPresetHEVCHighestQuality),
        (.hevc, 1080, AVAssetExportPresetHEVC1920x1080),
        (.hevc, 1500, AVAssetExportPresetHEVC1920x1080),
        (.hevc, 2160, AVAssetExportPresetHEVC3840x2160),
        (.hevc, 4320, AVAssetExportPresetHEVC3840x2160),
    ])
    func videoPresetIsTheLargestWithinTheCap(codec: VideoCodec, maxHeight: Int?, preset: String) throws {
        #expect(try AVFoundationEngine.videoPreset(codec: codec, maxHeight: maxHeight) == preset)
    }

    @Test(arguments: [
        (VideoCodec.hevc, 480, "HEVC export needs a height cap of at least 1080, not 480"),
        (.hevc, 600, "HEVC export needs a height cap of at least 1080, not 600"),
        (.hevc, 720, "HEVC export needs a height cap of at least 1080, not 720"),
        (.h264, 360, "H.264 export needs a height cap of at least 480, not 360"),
    ])
    func videoPresetRejectsACapBelowTheSmallestPreset(codec: VideoCodec, maxHeight: Int, message: String) {
        let error = #expect(throws: AVFoundationEngine.Failure.self) {
            try AVFoundationEngine.videoPreset(codec: codec, maxHeight: maxHeight)
        }
        #expect(error?.description == message)
    }

    /// A cancel that arrives before the export session starts must stop it from starting: AVAssetExportSession raises
    /// an uncaught exception when `exportAsynchronously` follows `cancelExport()`.
    @Test func exportGateRefusesToStartAfterACancel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.wav(seconds: 1, in: dir)
        let output = dir.appending(path: "out.m4a", directoryHint: .notDirectory)
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A))
        session.outputURL = output
        session.outputFileType = .m4a
        let gate = ExportGate(session)

        gate.cancel()
        let started = gate.start { Issue.record("the export ran after a cancel") }
        gate.cancel()

        #expect(!started)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// Cancels within the first 2 ms of a conversion that takes far longer, sweeping the moment so the cancels land
    /// at different points of the setup. Each must end in CancellationError with nothing left in staging.
    @Test func cancelAtTheStartThrowsAndLeavesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let wav = try Fixtures.wav(seconds: 60, in: dir)

        for attempt in 0..<20 {
            let staging = dir.appending(path: "staging-\(attempt)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let conversion = attempt.isMultiple(of: 2)
                ? try step(movie, to: "mp4", in: staging, options: PresetOptions(videoCodec: .hevc))
                : try step(wav, to: "m4a", in: staging)
            let task = Task { try await AVFoundationEngine().convert(conversion) { _ in } }
            if attempt > 0 { try await Task.sleep(for: .microseconds(attempt * 100)) }
            task.cancel()
            let result = await task.result
            #expect(throws: CancellationError.self, "attempt \(attempt)") { try result.get() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, "attempt \(attempt)")
        }
        // A cancelled export session can create its file a few milliseconds late; none may surface in staging.
        try await Task.sleep(for: .milliseconds(100))
        for attempt in 0..<20 {
            let staging = dir.appending(path: "staging-\(attempt)", directoryHint: .isDirectory)
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, "attempt \(attempt), later")
        }
    }

    @Test func cancelMidExportThrowsAndLeavesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 20, withAudio: false, in: dir)
        let staging = try makeStaging(in: dir)
        let conversion = try step(input, to: "mp4", in: staging, options: PresetOptions(videoCodec: .hevc))
        let running = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            try await AVFoundationEngine().convert(conversion) { value in
                if value > 0, value < 1 { running.withLock { $0 = true } }
            }
        }
        for _ in 0..<2_000 where !running.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(running.withLock { $0 }, "the export never reported partial progress")
        task.cancel()
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // MARK: Tools

    @Test func operationEdgesMatchTheBrief() {
        let edges = AVFoundationEngine().edges().filter { $0.operation != nil }
        func pairs(_ operation: String) -> Set<String> {
            Set(edges.filter { $0.operation == operation }.map { "\($0.from)>\($0.to)" })
        }
        func flags(_ operation: String) -> Set<EdgeFlags.RawValue> {
            Set(edges.filter { $0.operation == operation }.map(\.flags.rawValue))
        }
        #expect(pairs("compress") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(pairs("remove-audio") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(pairs("snapshot") == ["mov>png", "mp4>png", "m4v>png"])
        #expect(pairs("speed") == ["mov>mov", "mp4>mp4", "m4v>m4v", "m4a>m4a"])
        #expect(pairs("mono") == ["m4a>m4a", "wav>wav", "aiff>aiff", "caf>caf"])
        #expect(pairs("strip-metadata") == ["mov>mov", "mp4>mp4", "m4v>m4v", "m4a>m4a"])
        #expect(pairs("trim") == ["mov>mov", "mp4>mp4", "m4v>m4v", "m4a>m4a", "wav>wav", "aiff>aiff", "caf>caf"])
        #expect(pairs("split") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(pairs("crop") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(pairs("resize") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(pairs("rotate") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(flags("resize") == [EdgeFlags.lossy.rawValue] && flags("rotate") == [EdgeFlags.lossy.rawValue])
        #expect(flags("trim") == [0] && flags("split") == [0])
        #expect(flags("crop") == [EdgeFlags.lossy.rawValue])
        #expect(flags("compress") == [EdgeFlags.lossy.rawValue])
        #expect(pairs("target-size") == ["mov>mov", "mp4>mp4", "m4v>m4v"])
        #expect(flags("target-size") == [EdgeFlags.lossy.rawValue])
        #expect(flags("speed") == [EdgeFlags.lossy.rawValue])
        #expect(flags("remove-audio") == [0])
        #expect(flags("snapshot") == [0])
        #expect(flags("strip-metadata") == [0])
        #expect(edges.first { $0.operation == "mono" && $0.from == "m4a" }?.flags == [.lossy])
        #expect(edges.first { $0.operation == "mono" && $0.from == "wav" }?.flags == [])
        #expect(edges.count == 43)
        #expect(edges.allSatisfy { $0.engineID == "avfoundation" && $0.cost == 10 })
    }

    @Test func compressMakesHEVCNoTallerThan720() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, width: 1920, height: 1080, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try tool("compress", input, in: staging, options: try presetOptions("compress-more"))
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let size = try await track.load(.naturalSize)
        #expect(size.height == 720)
        #expect(size.width == 1280)
        #expect(try await !AVURLAsset(url: output).loadTracks(withMediaType: .audio).isEmpty)
        #expect(try fileSize(output) < fileSize(input))
        #expect(abs(try await seconds(of: output) - 2) <= 0.15)
    }

    @Test func compressAt1080UsesTheSizedHEVCPreset() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, width: 1920, height: 1080, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(
            try tool("compress", input, in: staging, options: try presetOptions("compress"))
        ) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(try await track.load(.naturalSize).height == 1080)
    }

    /// The 720 cap applies to the picture as it plays, after the track's preferred transform.
    @Test func compressingASidewaysVideoTo720KeepsItUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(
            seconds: 1, withAudio: false, width: 1920, height: 1080, transform: sideways, in: dir
        )
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(
            try tool("compress", input, in: staging, options: try presetOptions("compress-more"))
        ) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let shown = CGRect(origin: .zero, size: size).applying(transform).size
        #expect(abs(shown.height) == 720)
        #expect(abs(abs(shown.width) - 405) <= 1)
    }

    @Test func compressNeverScalesUp() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(
            try tool("compress", input, in: staging, options: try presetOptions("compress-more"))
        ) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 240))
    }

    @Test func removeAudioLeavesNoAudioTrack() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try tool("remove-audio", input, in: staging)
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(abs(try await seconds(of: output) - 1) <= 0.15)
    }

    @Test func removeAudioKeepsTheRotation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: true, transform: sideways, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try tool("remove-audio", input, in: staging)) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let source = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform) == source.load(.preferredTransform))
    }

    /// Only Remove metadata may drop where and when a video was taken.
    @Test func removeAudioKeepsTheMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movieWithLocationAndTitle(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try tool("remove-audio", input, in: staging)) { _ in }

        let bytes = try Data(contentsOf: output)
        #expect(bytes.range(of: Data(Fixtures.movieTitle.utf8)) != nil)
        #expect(bytes.range(of: Data(Fixtures.movieLocation.utf8)) != nil)
    }

    @Test func removeAudioOnASilentVideoIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.notApplicable(reason: "It has no sound")) {
            _ = try await AVFoundationEngine().convert(try tool("remove-audio", input, in: staging)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// `Fixtures.movie` fades its frames from (0, 0.4, 1) to (1, 0.4, 0); the snapshot at 1 s of a 2 s movie is
    /// frame 30 of 60.
    @Test func snapshotIsTheMiddleFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try tool("snapshot", input, to: "png", in: staging)
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(output.pathExtension == "png")
        #expect(Fixtures.imageUTType(output) == "public.png")
        #expect(Fixtures.imageSize(output) == CGSize(width: 320, height: 240))
        let (red, _, blue) = try cornerColor(of: output)
        let expected = 30.0 / 59.0
        #expect(abs(red - expected) <= 0.08, "red \(red)")
        #expect(abs(blue - (1 - expected)) <= 0.08, "blue \(blue)")
    }

    @Test func snapshotOfASidewaysVideoIsUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, transform: sideways, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try tool("snapshot", input, to: "png", in: staging)) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 240, height: 320))
    }

    @Test func speedTwoHalvesTheDuration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 4, withAudio: true, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try tool("speed", input, in: staging, options: try presetOptions("speed-up"))
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let duration = try await seconds(of: output)
        #expect(abs(duration - 2) <= 0.1, "\(duration) s")
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        // The time-pitch algorithm's tail (50 to 120 ms) must not outlast the picture.
        let audioDuration = try await #require(audio.first).load(.timeRange).duration.seconds
        #expect(abs(audioDuration - 2) <= 0.03, "\(audioDuration) s")
    }

    @Test func halfSpeedDoublesAnAudioFilesDuration() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.m4a(seconds: 2, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(
            try tool("speed", input, in: staging, options: try presetOptions("slow-down"))
        ) { _ in }

        #expect(output.pathExtension == "m4a")
        #expect(try audioFileType(output) == kAudioFileM4AType)
        let duration = try await seconds(of: output)
        #expect(abs(duration - 4) <= 0.1, "\(duration) s")
    }

    @Test(arguments: [Double?.none, 1.0])
    func anUnchangedSpeedIsNotApplicable(speed: Double?) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.m4a(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.notApplicable(reason: "The speed is unchanged")) {
            _ = try await AVFoundationEngine().convert(
                try tool("speed", input, in: staging, options: PresetOptions(speed: speed))
            ) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func monoHasOneChannel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.stereoWavWithSilentRight(seconds: 1, in: dir)
        let m4a = try Fixtures.m4a(seconds: 1, in: dir)

        let wavStaging = try makeStaging(in: dir)
        let wavOutput = try await AVFoundationEngine().convert(try tool("mono", wav, in: wavStaging)) { _ in }
        let m4aStaging = dir.appending(path: "m4a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: m4aStaging, withIntermediateDirectories: true)
        let m4aOutput = try await AVFoundationEngine().convert(try tool("mono", m4a, in: m4aStaging)) { _ in }

        let wavFile = try AVAudioFile(forReading: wavOutput)
        #expect(try audioFileType(wavOutput) == kAudioFileWAVEType)
        #expect(wavFile.fileFormat.channelCount == 1)
        #expect(wavFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(abs(Double(wavFile.length) / wavFile.fileFormat.sampleRate - 1) <= 0.15)
        let m4aFile = try AVAudioFile(forReading: m4aOutput)
        #expect(try audioFileType(m4aOutput) == kAudioFileM4AType)
        #expect(m4aFile.fileFormat.channelCount == 1)
        #expect(abs(Double(m4aFile.length) / m4aFile.fileFormat.sampleRate - 1) <= 0.15)
    }

    /// A downmix keeps both channels: the left tone over a silent right comes out quieter than the tone, and never
    /// silent (which taking the right channel alone would give).
    @Test func monoMixesBothChannels() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.stereoWavWithSilentRight(seconds: 1, in: dir)

        let output = try await AVFoundationEngine().convert(try tool("mono", wav, in: try makeStaging(in: dir))) { _ in }

        let peak = try peakLevel(of: output)
        #expect(peak > 0.15, "peak \(peak)")
        #expect(peak < 0.45, "peak \(peak)")
    }

    /// Only Remove metadata may drop a song's tags; Mono re-encodes the AAC through a writer that starts empty.
    @Test func monoKeepsTheTags() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.m4aWithTags(seconds: 1, in: dir)

        let output = try await AVFoundationEngine().convert(try tool("mono", input, in: try makeStaging(in: dir))) { _ in }

        let metadata = try await AVURLAsset(url: output).load(.metadata)
        func value(_ identifier: AVMetadataIdentifier) async throws -> String? {
            let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
            return try await item?.load(.stringValue)
        }
        #expect(try await value(.iTunesMetadataSongName) == Fixtures.songTitle)
        #expect(try await value(.iTunesMetadataArtist) == Fixtures.songArtist)
        let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first
        #expect(try await artwork?.load(.dataValue) == Fixtures.songArtwork)
        #expect(try AVAudioFile(forReading: output).fileFormat.channelCount == 1)
    }

    @Test(arguments: [
        (Float(29.97), Int32(30)), (23.976, 24), (60, 60), (240, 120), (0.4, 1), (0, 30), (.nan, 30),
    ] as [(Float, Int32)])
    func compositionFrameRateIsTheNominalRate(nominal: Float, framesPerSecond: Int32) {
        #expect(AVFoundationEngine.frameDuration(nominalFrameRate: nominal) == CMTime(value: 1, timescale: framesPerSecond))
    }

    /// The AAC encoder takes 8 to 24 kbps for 8 kHz mono, 32 to 256 kbps for 44.1 kHz mono and from 64 kbps for
    /// stereo, and fails the whole file ("Cannot Encode Media") when asked for more.
    @Test(arguments: [
        (192_000, 8_000.0, 1, 24_000), (192_000, 44_100.0, 1, 192_000), (320_000, 44_100.0, 1, 256_000),
        (256_000, 48_000.0, 2, 256_000), (16_000, 44_100.0, 2, 64_000),
    ] as [(Int, Double, Int, Int)])
    func theAACBitrateIsOneTheEncoderTakes(requested: Int, sampleRate: Double, channels: Int, used: Int) {
        #expect(AVFoundationEngine.aacBitrate(requested, sampleRate: sampleRate, channelCount: channels) == used)
    }

    @Test func monoOfALowSampleRateSongSucceeds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "voice.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for channel in 0..<2 {
            for index in 0..<8_000 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) / 4)) * 0.5 }
        }
        do {
            let file = try AVAudioFile(forWriting: input, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 2,
            ])
            try file.write(from: buffer)
        }

        let output = try await AVFoundationEngine().convert(try tool("mono", input, in: try makeStaging(in: dir))) { _ in }

        #expect(try AVAudioFile(forReading: output).fileFormat.channelCount == 1)
    }

    @Test func monoOnAMonoFileIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.wav(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.notApplicable(reason: "It's already mono")) {
            _ = try await AVFoundationEngine().convert(try tool("mono", input, in: staging)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func strippingRemovesLocationAndTitle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movieWithLocationAndTitle(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)
        let sourceBytes = try Data(contentsOf: input)
        try #require(sourceBytes.range(of: Data(Fixtures.movieTitle.utf8)) != nil)
        try #require(sourceBytes.range(of: Data(Fixtures.movieLocation.utf8)) != nil)

        let conversion = try tool("strip-metadata", input, in: staging)
        let output = try await AVFoundationEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let bytes = try Data(contentsOf: output)
        #expect(bytes.range(of: Data(Fixtures.movieTitle.utf8)) == nil)
        #expect(bytes.range(of: Data(Fixtures.movieLocation.utf8)) == nil)
        let asset = AVURLAsset(url: output)
        #expect(try await asset.load(.metadata).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await seconds(of: output) - 1) <= 0.15)
    }

    @Test func strippingAnAudioFileKeepsItsSound() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.m4a(seconds: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try tool("strip-metadata", input, in: staging)) { _ in }

        #expect(try audioFileType(output) == kAudioFileM4AType)
        #expect(abs(try await seconds(of: output) - 1) <= 0.15)
    }

    /// A video's frames are only retimed, which is too quick to cancel midway; three minutes of audio go through the
    /// time-pitch algorithm for about half a second.
    @Test func cancellingASpeedChangeLeavesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.m4a(seconds: 180, in: dir)
        let staging = try makeStaging(in: dir)
        let conversion = try tool("speed", input, in: staging, options: try presetOptions("speed-up"))
        let running = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            try await AVFoundationEngine().convert(conversion) { value in
                if value > 0, value < 1 { running.withLock { $0 = true } }
            }
        }
        for _ in 0..<2_000 where !running.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(running.withLock { $0 }, "the export never reported partial progress")
        task.cancel()
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // MARK: Helpers

    private func fileSize(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// The colour of a pixel in the image's top-left corner, away from the moving square, as 0...1 sRGB.
    private func cornerColor(of url: URL) throws -> (Double, Double, Double) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let size = CGSize(width: image.width, height: image.height)
            context.draw(image, in: CGRect(origin: CGPoint(x: -4, y: 5 - size.height), size: size))
            return true
        }
        try #require(drawn)
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// The largest absolute sample of a 16-bit PCM file, as a fraction of full scale.
    private func peakLevel(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        return (0..<Int(buffer.frameLength)).reduce(0) { max($0, Double(abs(samples[$1]))) }
    }
}
