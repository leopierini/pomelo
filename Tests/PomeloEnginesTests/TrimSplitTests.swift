import AVFoundation
import Foundation
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// Serialized for the reason `FFmpegToolTests` is: parallel hardware-encoded movies starve ImageIOToolTests' HEIC encoder.
@Suite(.serialized) struct TrimSplitTests {
    private let registry = FormatRegistry.builtIn

    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    /// Runs the built-in preset `id` with `edit` through the whole runner and returns the first result.
    private func apply(_ id: String, _ edit: EditSpec?, to input: URL) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == id })
        preset.options.edit = edit
        return try #require(await runner().run(ConversionRequest.from(preset, inputs: [input])).first)
    }

    private func output(_ result: FileResult) throws -> URL {
        guard case .succeeded(_, let outputs, _) = result, let output = outputs.first else {
            throw Fixtures.Failure("\(result)")
        }
        return output
    }

    private func reason(_ result: FileResult) -> String? {
        if case .failed(_, .notApplicable(let reason)) = result { reason } else { nil }
    }

    private func seconds(of url: URL) async throws -> Double {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    private func codecs(of url: URL, _ type: AVMediaType) async throws -> [FourCharCode] {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: type)
        var found: [FourCharCode] = []
        for track in tracks {
            for description in try await track.load(.formatDescriptions) { found.append(description.mediaSubType.rawValue) }
        }
        return found
    }

    private func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private func named(_ name: String, from url: URL, in dir: URL) throws -> URL {
        let copy = dir.appending(path: name)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    // MARK: Trim

    @Test func trimmingAMovieKeepsTheRangeWithoutReencoding() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: true, in: dir)
        let sourceVideo = try await codecs(of: movie, .video)
        let sourceAudio = try await codecs(of: movie, .audio)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 1, end: 4)), to: movie))

        #expect(trimmed.pathExtension == "mov")
        #expect(trimmed.deletingPathExtension().lastPathComponent.hasSuffix("-trimmed"))
        let duration = try await seconds(of: trimmed)
        #expect(abs(duration - 3) <= 0.1, "\(duration) s")
        #expect(try await codecs(of: trimmed, .video) == sourceVideo)
        #expect(try await codecs(of: trimmed, .audio) == sourceAudio)
        #expect(sourceVideo.contains(fourCC("avc1")))
    }

    @Test func trimmingM4AIsPassthrough() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.m4a(seconds: 4, in: dir)
        let sourceCodecs = try await codecs(of: tone, .audio)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 0.5, end: 2.5)), to: tone))

        #expect(trimmed.pathExtension == "m4a")
        #expect(try await codecs(of: trimmed, .audio) == sourceCodecs)
        #expect(sourceCodecs.contains(fourCC("aac ")))
        let duration = try await seconds(of: trimmed)
        #expect(abs(duration - 2) <= 0.1, "\(duration) s")
    }

    @Test(arguments: ["wav", "aiff", "caf"])
    func trimmingLPCMIsSampleExact(_ ext: String) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 3, in: dir)
        let tone: URL
        if ext == "wav" {
            tone = wav
        } else {
            tone = try output(try await runner().run(ConversionRequest(inputs: [wav], target: FormatID(ext))).first.unwrap())
        }

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 0.5, end: 2.0)), to: tone))

        #expect(trimmed.pathExtension == ext)
        let file = try AVAudioFile(forReading: trimmed)
        #expect(file.length == 66_150, "\(file.length) frames")
        #expect(file.fileFormat.sampleRate == 44_100)
    }

    @Test func trimmedWAVHoldsTheSamplesOfTheRange() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 3, in: dir)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 0.5, end: 2.0)), to: wav))

        func samples(_ url: URL, from frame: Int64, count: Int) throws -> [Int16] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            file.framePosition = frame
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            return Array(UnsafeBufferPointer(start: try #require(buffer.int16ChannelData?[0]), count: Int(buffer.frameLength)))
        }
        #expect(try samples(trimmed, from: 0, count: 1000) == samples(wav, from: 22_050, count: 1000))
    }

    /// A 1 s mono file of a 440 Hz sine at 48 kHz in `ext`, stored with the given sample format.
    private func tone(
        ext: String, bitDepth: Int, isFloat: Bool, bigEndian: Bool = false, in dir: URL
    ) throws -> URL {
        let url = dir.appending(path: "format-\(UUID().uuidString.prefix(6)).\(ext)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bitDepth, AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: bigEndian, AVLinearPCMIsNonInterleaved: false,
        ]
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48_000 { samples[index] = 0.6 * sin(Float(index) * 2 * .pi * 440 / 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func streamDescription(of url: URL) throws -> AudioStreamBasicDescription {
        // The pointer lives only as long as its format: read through a temporary, it reads zeros.
        let format = try AVAudioFile(forReading: url).fileFormat
        return withExtendedLifetime(format) { format.streamDescription.pointee }
    }

    /// Reads in a loop: one `read` may return fewer frames than asked.
    private func floatSamples(_ url: URL, from frame: Int64, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = frame
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        var samples: [Float] = []
        while samples.count < count, file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count - samples.count))
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength))
        }
        return samples
    }

    /// P81: the trim keeps the source's sample format, so 24-bit and float files are not squeezed to 16-bit.
    @Test(arguments: [
        ("wav", 24, false, false), ("wav", 32, true, false), ("wav", 16, false, false),
        ("aiff", 24, false, true), ("caf", 24, false, false), ("caf", 32, true, false),
    ])
    func trimmingLPCMKeepsTheSampleFormat(_ ext: String, _ bitDepth: Int, _ isFloat: Bool, _ bigEndian: Bool) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tone(ext: ext, bitDepth: bitDepth, isFloat: isFloat, bigEndian: bigEndian, in: dir)
        let sourceDescription = try streamDescription(of: source)
        #expect(sourceDescription.mBitsPerChannel == UInt32(bitDepth), "the fixture has the format under test")

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 0.25, end: 0.75)), to: source))

        let file = try AVAudioFile(forReading: trimmed)
        let description = try streamDescription(of: trimmed)
        #expect(description.mBitsPerChannel == sourceDescription.mBitsPerChannel)
        #expect(description.mFormatFlags & kAudioFormatFlagIsFloat == sourceDescription.mFormatFlags & kAudioFormatFlagIsFloat)
        #expect(description.mFormatFlags & kAudioFormatFlagIsBigEndian == sourceDescription.mFormatFlags & kAudioFormatFlagIsBigEndian)
        #expect(file.length == 24_000, "\(file.length) frames")
        #expect(try floatSamples(trimmed, from: 0, count: 24_000) == floatSamples(source, from: 12_000, count: 24_000))
    }

    /// P89: the one exception to P81. 64-bit float comes out 32-bit float, which is past audible precision.
    @Test(arguments: ["wav", "caf"])
    func trimming64BitFloatWrites32BitFloat(_ ext: String) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // AVAudioFile writes 32-bit float when asked for 64, so the system's afconvert widens the tone.
        let narrow = try tone(ext: ext, bitDepth: 32, isFloat: true, in: dir)
        let source = dir.appending(path: "wide.\(ext)")
        let convert = Process()
        convert.executableURL = URL(filePath: "/usr/bin/afconvert")
        convert.arguments = ["-f", ext == "wav" ? "WAVE" : "caff", "-d", "LEF64", narrow.path, source.path]
        try convert.run()
        convert.waitUntilExit()
        #expect(try streamDescription(of: source).mBitsPerChannel == 64)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 0.25, end: 0.75)), to: source))

        let description = try streamDescription(of: trimmed)
        #expect(description.mBitsPerChannel == 32)
        #expect(description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(try AVAudioFile(forReading: trimmed).length == 24_000)
        #expect(try floatSamples(trimmed, from: 0, count: 24_000) == floatSamples(source, from: 12_000, count: 24_000))
    }

    @Test func trimToTheVeryEndKeepsTheLastFrame() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: true, in: dir)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 4, end: 6)), to: movie))

        let duration = try await seconds(of: trimmed)
        #expect(abs(duration - 2) <= 0.1, "\(duration) s")
    }

    @Test func aRangeOutsideTheFileIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let tone = try Fixtures.wav(seconds: 3, in: dir)

        #expect(reason(try await apply("trim", .trim(TimeRange(start: 1, end: 99)), to: movie)) == "The range is outside the file")
        #expect(reason(try await apply("trim", .trim(TimeRange(start: 2, end: 2.05)), to: tone)) == "The range is outside the file")
        #expect(reason(try await apply("trim", .trim(TimeRange(start: -1, end: 2)), to: tone)) == "The range is outside the file")
    }

    @Test func theWholeFileIsNothingToTrim() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)

        let result = try await apply("trim", .trim(TimeRange(start: 0.02, end: 6)), to: movie)

        #expect(reason(result) == "Nothing to trim")
    }

    @Test func aMissingRangeIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: false, in: dir)
        let tone = try Fixtures.wav(seconds: 2, in: dir)

        #expect(reason(try await apply("trim", nil, to: movie)) == "Nothing was chosen")
        #expect(reason(try await apply("trim", nil, to: tone)) == "Nothing was chosen")
        #expect(reason(try await apply("trim", .split([1]), to: movie)) == "Nothing was chosen")
    }

    // MARK: Split

    @Test func splitMakesNumberedParts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await Fixtures.movie(seconds: 6, withAudio: true, in: dir)
        let movie = try named("clip.mov", from: source, in: dir)

        let folder = try output(try await apply("split-video", .split([2, 4]), to: movie))

        #expect(folder.lastPathComponent == "clip-parts")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["clip-1.mov", "clip-2.mov", "clip-3.mov"])
        for name in names {
            let duration = try await seconds(of: folder.appending(path: name))
            #expect(abs(duration - 2) <= 0.1, "\(name) \(duration) s")
        }
        #expect(try await codecs(of: folder.appending(path: "clip-2.mov"), .video).contains(fourCC("avc1")))
    }

    @Test func splitPointsAreSortedBeforeTheyCut() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let movie = try named("clip.mov", from: source, in: dir)

        let folder = try output(try await apply("split-video", .split([4, 2]), to: movie))

        let first = try await seconds(of: folder.appending(path: "clip-1.mov"))
        #expect(abs(first - 2) <= 0.1, "\(first) s")
    }

    @Test func crowdedSplitPointsAreDropped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let movie = try named("clip.mov", from: source, in: dir)

        let folder = try output(try await apply("split-video", .split([0.05, 2, 2.05, 5.97]), to: movie))

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["clip-1.mov", "clip-2.mov"])
        let first = try await seconds(of: folder.appending(path: "clip-1.mov"))
        #expect(abs(first - 2) <= 0.1, "\(first) s")
    }

    @Test func splitWithNoUsablePointIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)

        #expect(reason(try await apply("split-video", .split([]), to: movie)) == "Add a split point first")
        #expect(reason(try await apply("split-video", .split([0.05, 5.99]), to: movie)) == "Add a split point first")
        #expect(reason(try await apply("split-video", nil, to: movie)) == "Nothing was chosen")
    }

    @Test func cancellingASplitLeavesNoPart() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 20, withAudio: true, in: dir)
        let format = try #require(registry.format(for: movie))

        var cancelled = 0
        for attempt in 0..<8 {
            let staging = dir.appending(path: "staging-\(attempt)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let step = ConversionStep(
                input: movie, stagingDirectory: staging, from: format, to: format,
                options: PresetOptions(edit: .split([3, 6, 9, 12, 15])), operation: "split"
            )
            let task = Task { try await AVFoundationEngine().convert(step) { _ in } }
            try await Task.sleep(for: .milliseconds(attempt * 25))
            task.cancel()
            let result = await task.result
            // A fast machine may finish all six parts first; then the folder is the whole result.
            if case .success(let folder) = result {
                #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 6)
            } else {
                cancelled += 1
                #expect(throws: CancellationError.self, "attempt \(attempt)") { try result.get() }
                #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, "attempt \(attempt)")
            }
        }
        #expect(cancelled > 0)
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func splitReportsProgressAcrossTheParts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let format = try #require(registry.format(for: movie))
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: movie, stagingDirectory: staging, from: format, to: format,
            options: PresetOptions(edit: .split([2, 4])), operation: "split"
        )
        let seen = LockedValues()

        _ = try await AVFoundationEngine().convert(step) { seen.add($0) }

        let values = seen.values
        #expect(values.first == 0 && values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "\(values)")
    }

    // MARK: Routes and manifest

    @Test func trimEdgesAreNotLossy() async throws {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()
        for source: FormatID in ["mov", "mp4", "m4v", "m4a", "wav", "aiff", "caf"] {
            let route = try #require(planner.route(from: source, operation: "trim", to: nil), "\(source)")
            #expect(route.edges.map(\.engineID) == ["avfoundation"], "\(source)")
            #expect(!route.edges.contains { $0.flags.contains(.lossy) }, "\(source)")
        }
        for source: FormatID in ["mov", "mp4", "m4v"] {
            let route = try #require(planner.route(from: source, operation: "split", to: nil), "\(source)")
            #expect(route.edges.map(\.engineID) == ["avfoundation"], "\(source)")
            #expect(!route.edges.contains { $0.flags.contains(.lossy) }, "\(source)")
        }
        // Split PDF shares the operation id and keeps its own route.
        #expect(planner.route(from: "pdf", operation: "split", to: "pdf")?.edges.map(\.engineID) == ["pdfkit"])
        #expect(planner.route(from: "wav", operation: "split", to: nil) == nil)
    }

    /// FLAC cannot be stream-copied: the copied STREAMINFO block keeps the source's sample count, so the trimmed file
    /// would report the full length. The audio is re-encoded losslessly (`-c:a flac`) and the rest still copies.
    @Test func ffmpegTrimEdgeIsValid() throws {
        let (manifests, _) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        let manifest = try #require(manifests.first { $0.id == "ffmpeg" })
        try manifest.validate()
        let head = ["-hide_banner", "-nostdin", "-y", "-i", "{input}", "-ss", "{trimStart}", "-to", "{trimEnd}", "-map", "0", "-c", "copy"]
        let expected: [FormatID: [String]] = [
            "mp3": head + ["{output}"], "flac": head + ["-c:a", "flac", "{output}"],
        ]
        for (format, arguments) in expected {
            let edge = try #require(manifest.edge(from: format, to: format, operation: "trim"), "\(format)")
            #expect(edge.arguments == arguments, "\(format)")
            #expect(edge.flags == nil || edge.flags?.contains("lossy") == false)
        }
    }

    @Test func mp3PassthroughProbeIsRecorded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        guard Installed.has("ffmpeg") else { return }
        let wav = try Fixtures.wav(seconds: 2, in: dir)
        let mp3 = dir.appending(path: "tone.mp3")
        try Self.ffmpeg(["-i", wav.path, mp3.path])

        let compatible = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: AVURLAsset(url: mp3), outputFileType: .mp3
        )

        #expect(compatible == false, "mp3 joined AVFoundation's passthrough list; add it to the trim edges and the spec")
    }

    // MARK: ffmpeg

    private static func ffmpeg(_ arguments: [String]) throws {
        guard let ffmpeg = Installed.path(of: "ffmpeg") else { throw Fixtures.Failure("ffmpeg is not installed") }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Fixtures.Failure("ffmpeg \(arguments) failed") }
    }

    @Test(.enabled(if: Installed.has("ffmpeg")), arguments: ["mp3", "flac"])
    func ffmpegTrimsWithoutReencoding(_ ext: String) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 4, in: dir)
        let source = dir.appending(path: "tone.\(ext)")
        try Self.ffmpeg(["-i", wav.path, source.path])
        let sourceCodecs = try await codecs(of: source, .audio)

        let trimmed = try output(try await apply("trim", .trim(TimeRange(start: 1, end: 2.5)), to: source))

        #expect(trimmed.pathExtension == ext)
        let duration = try await seconds(of: trimmed)
        #expect(abs(duration - 1.5) <= 0.1, "\(duration) s")
        #expect(try await codecs(of: trimmed, .audio) == sourceCodecs)
    }

    @Test(.enabled(if: Installed.has("ffmpeg")))
    func ffmpegTrimIsValidatedBeforeItRuns() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try Fixtures.wav(seconds: 3, in: dir)
        let mp3 = dir.appending(path: "tone.mp3")
        try Self.ffmpeg(["-i", wav.path, mp3.path])

        #expect(reason(try await apply("trim", .trim(TimeRange(start: 1, end: 99)), to: mp3)) == "The range is outside the file")
        #expect(reason(try await apply("trim", .trim(TimeRange(start: 0, end: 3)), to: mp3)) == "Nothing to trim")
        #expect(reason(try await apply("trim", nil, to: mp3)) == "Nothing was chosen")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["tone.mp3", wav.lastPathComponent].sorted())
    }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw Fixtures.Failure("nothing") }
        return self
    }
}
