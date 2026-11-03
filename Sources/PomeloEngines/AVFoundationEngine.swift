import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ImageIO
import PomeloCore
import os

/// Re-encodes video (H.264 or HEVC), extracts and converts audio, and runs the audio and video tools (compress,
/// compress to size, remove audio, snapshot, speed, mono, remove metadata, trim and split without re-encoding, crop,
/// resize and rotate), with the system's AVFoundation.
public struct AVFoundationEngine: ConversionEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private static let edgeCost = 10
    private static let videoSources: [FormatID] = ["m4v", "mov", "mp4"]
    private static let videoTargets: [FormatID] = ["mov", "mp4"]
    private static let audioSources: [FormatID] = ["aiff", "caf", "flac", "m4a", "mp3", "wav"]
    private static let monoSources: [FormatID] = ["aiff", "caf", "m4a", "wav"]
    /// Where trim cuts without re-encoding: a passthrough export, or for LPCM the reader and writer. MP3 is not
    /// here: its passthrough is incompatible (`mp3PassthroughProbeIsRecorded`), so ffmpeg trims it.
    static let trimSources: [FormatID] = ["aiff", "caf", "m4a", "m4v", "mov", "mp4", "wav"]
    /// Uncompressed targets, written as 16-bit integer LPCM.
    static let lpcmTargets: [FormatID] = ["aiff", "caf", "wav"]
    private static let fileTypes: [FormatID: AVFileType] = [
        "mp4": .mp4, "mov": .mov, "m4v": .m4v, "m4a": .m4a, "wav": .wav, "aiff": .aiff, "caf": .caf,
    ]
    /// Used when the source track does not describe its own sample rate or channel count.
    private static let fallbackSampleRate = 44_100.0
    private static let fallbackChannelCount = 2
    private static let progressInterval = Duration.milliseconds(100)
    /// Sized export presets by ascending height.
    private static let h264SizedPresets: [(height: Int, name: String)] = [
        (480, AVAssetExportPreset640x480), (540, AVAssetExportPreset960x540), (720, AVAssetExportPreset1280x720),
        (1080, AVAssetExportPreset1920x1080), (2160, AVAssetExportPreset3840x2160),
    ]
    private static let hevcSizedPresets: [(height: Int, name: String)] = [
        (1080, AVAssetExportPresetHEVC1920x1080), (2160, AVAssetExportPresetHEVC3840x2160),
    ]

    /// How big a compress-to-size result came out; a test seam, so an overshoot can be staged. It reads the disk
    /// each time: a URL caches its resource values, and the retry rewrites the same URL.
    var measureTargetSize: @Sendable (URL) throws -> Int64 = { url in
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw Failure("cannot read the size of \(url.lastPathComponent)")
        }
        return size.int64Value
    }

    public init() {}

    public var id: EngineID { "avfoundation" }
    public var displayName: String { "AVFoundation" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        var edges: [ConversionEdge] = []
        for from in Self.videoSources {
            for to in Self.videoTargets + ["m4a"] {
                edges.append(ConversionEdge(from: from, to: to, engineID: id, cost: Self.edgeCost, flags: [.lossy]))
            }
        }
        for from in Self.audioSources {
            edges.append(ConversionEdge(from: from, to: "m4a", engineID: id, cost: Self.edgeCost, flags: [.lossy]))
            for to in Self.lpcmTargets {
                edges.append(ConversionEdge(from: from, to: to, engineID: id, cost: Self.edgeCost, flags: []))
            }
        }
        edges += toolEdges()
        return edges.sorted {
            ($0.from.rawValue, $0.to.rawValue, $0.operation ?? "") < ($1.from.rawValue, $1.to.rawValue, $1.operation ?? "")
        }
    }

    /// Operation edges, from a format to itself except Snapshot. Mono on m4a re-encodes the AAC, so it is lossy.
    private func toolEdges() -> [ConversionEdge] {
        func edge(_ from: FormatID, to: FormatID? = nil, _ operation: String, lossy: Bool) -> ConversionEdge {
            ConversionEdge(
                from: from, to: to ?? from, engineID: id, cost: Self.edgeCost, flags: lossy ? [.lossy] : [],
                operation: operation
            )
        }
        var edges: [ConversionEdge] = []
        for video in Self.videoSources {
            edges.append(edge(video, "compress", lossy: true))
            edges.append(edge(video, "target-size", lossy: true))
            edges.append(edge(video, "remove-audio", lossy: false))
            edges.append(edge(video, "trim", lossy: false))
            edges.append(edge(video, "split", lossy: false))
            edges.append(edge(video, "crop", lossy: true))
            edges.append(edge(video, "resize", lossy: true))
            edges.append(edge(video, "rotate", lossy: true))
            edges.append(edge(video, to: "png", "snapshot", lossy: false))
        }
        for source in Self.videoSources + ["m4a"] {
            edges.append(edge(source, "speed", lossy: true))
            edges.append(edge(source, "strip-metadata", lossy: false))
        }
        for audio in Self.monoSources {
            edges.append(edge(audio, "mono", lossy: audio == "m4a"))
        }
        for audio in Self.trimSources where !Self.videoSources.contains(audio) {
            edges.append(edge(audio, "trim", lossy: false))
        }
        return edges
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard edges().contains(where: {
            $0.from == step.from.id && $0.to == step.to.id && $0.operation == step.operation
        }) else {
            if let operation = step.operation {
                throw Failure("\(operation) on \(step.from.displayName) is not something AVFoundation can do")
            }
            throw Failure("\(step.from.displayName) to \(step.to.displayName) is not something AVFoundation can do")
        }
        progress(0)
        var output = step.suggestedOutput
        let asset = AVURLAsset(url: step.input)
        do {
            switch step.operation {
            case "compress": try await compress(asset, step, to: output, progress: progress)
            case "target-size": try await compressToSize(asset, step, to: output, progress: progress)
            case "remove-audio": try await removeAudio(asset, step, to: output, progress: progress)
            case "snapshot": try await snapshot(asset, step, to: output)
            case "speed": try await changeSpeed(asset, step, to: output, progress: progress)
            case "mono": try await makeMono(asset, step, to: output, progress: progress)
            case "strip-metadata": try await stripMetadata(asset, step, to: output, progress: progress)
            case "trim": try await trim(asset, step, to: output, progress: progress)
            case "split": output = try await split(asset, step, progress: progress)
            case "crop": try await crop(asset, step, to: output, progress: progress)
            case "resize": output = try await resize(asset, step, progress: progress)
            case "rotate": try await rotate(asset, step, to: output, progress: progress)
            default: try await convertFormat(asset, step, to: output, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return output
    }

    private func convertFormat(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        switch step.to.id {
        case "m4a" where Self.videoSources.contains(step.from.id):
            // Extract audio's Quality is the AAC bitrate, which the AppleM4A preset ignores. The AAC writer refuses
            // the discrete layouts of more than two channels, so surround is downmixed to stereo.
            let track = try await firstTrack(of: asset, mediaType: .audio, input: step.input)
            let channelCount = min(2, try await Self.pcmShape(of: track).1)
            try await writeAudio(
                from: asset, track: track, as: fileType, channelCount: channelCount,
                aacBitrate: try Self.bitsPerSecond(step.options.audioBitrate),
                metadata: try await asset.load(.metadata), to: output, input: step.input, progress: progress
            )
        case "m4a":
            _ = try await firstTrack(of: asset, mediaType: .audio, input: step.input)
            try await export(
                asset, preset: AVAssetExportPresetAppleM4A, as: fileType, to: output, input: step.input, progress: progress
            )
        case "wav", "aiff", "caf":
            let track = try await firstTrack(of: asset, mediaType: .audio, input: step.input)
            try await writeAudio(from: asset, track: track, as: fileType, to: output, input: step.input, progress: progress)
        default:
            let preset = try Self.videoPreset(codec: step.options.videoCodec, maxHeight: step.options.videoMaxHeight)
            _ = try await firstTrack(of: asset, mediaType: .video, input: step.input)
            try await export(asset, preset: preset, as: fileType, to: output, input: step.input, progress: progress)
        }
    }

    static func fileType(of format: FileFormat) throws -> AVFileType {
        guard let fileType = fileTypes[format.id] else { throw Failure("AVFoundation cannot write \(format.displayName)") }
        return fileType
    }

    /// The export preset for a video target: the largest sized preset no taller than `maxHeight`, or the highest
    /// quality preset when there is no cap. The presets never upscale, so a small source keeps its size.
    static func videoPreset(codec: VideoCodec, maxHeight: Int?) throws -> String {
        let (name, unlimited, sized) = switch codec {
        case .h264: ("H.264", AVAssetExportPresetHighestQuality, h264SizedPresets)
        case .hevc: ("HEVC", AVAssetExportPresetHEVCHighestQuality, hevcSizedPresets)
        }
        guard let maxHeight else { return unlimited }
        guard let preset = sized.last(where: { $0.height <= maxHeight }) else {
            throw Failure("\(name) export needs a height cap of at least \(sized[0].height), not \(maxHeight)")
        }
        return preset.name
    }

    // MARK: Tools

    /// Always HEVC. A cap below the smallest sized HEVC preset (1080) renders the picture through a video
    /// composition instead, since no HEVC preset is that small.
    private func compress(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        let track = try await firstTrack(of: asset, mediaType: .video, input: step.input)
        let maxHeight = step.options.videoMaxHeight
        guard let maxHeight, maxHeight < Self.hevcSizedPresets[0].height else {
            let preset = try Self.videoPreset(codec: .hevc, maxHeight: maxHeight)
            try await export(asset, preset: preset, as: fileType, to: output, input: step.input, progress: progress)
            return
        }
        guard maxHeight > 0 else { throw Failure("a height cap of \(maxHeight) is not possible") }
        let composition = try await Self.scaledComposition(of: asset, track: track, maxHeight: maxHeight)
        try await export(
            asset, preset: AVAssetExportPresetHEVCHighestQuality, as: fileType, to: output, input: step.input,
            configure: { $0.videoComposition = composition }, progress: progress
        )
    }

    /// Renders `track` upright (its preferred transform applied) and scaled to at most `maxHeight` high, never up.
    private static func scaledComposition(
        of asset: AVURLAsset, track: AVAssetTrack, maxHeight: Int
    ) async throws -> AVMutableVideoComposition {
        let (naturalSize, preferredTransform, nominalFrameRate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )
        let duration = try await asset.load(.duration)
        let shown = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let scale = min(1, CGFloat(maxHeight) / shown.height)
        // Encoders want even dimensions; rounding down keeps the height within the cap.
        func even(_ length: CGFloat) -> CGFloat { max(2, (length * scale / 2).rounded(.down) * 2) }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            preferredTransform
                .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            at: .zero
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: even(shown.width), height: even(shown.height))
        composition.frameDuration = frameDuration(nominalFrameRate: nominalFrameRate)
        composition.instructions = [instruction]
        return composition
    }

    /// A variable-rate source's shortest frame gap would render every frame at that rate and inflate the output, so
    /// the composition runs at the track's nominal rate.
    static func frameDuration(nominalFrameRate: Float) -> CMTime {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else { return CMTime(value: 1, timescale: 30) }
        return CMTime(value: 1, timescale: Int32(min(120, max(1, nominalFrameRate.rounded()))))
    }

    private func removeAudio(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        guard try await !tracks(of: asset, mediaType: .audio, input: step.input).isEmpty else {
            throw ConversionError.notApplicable(reason: "It has no sound")
        }
        let video = try await tracks(of: asset, mediaType: .video, input: step.input)
        guard !video.isEmpty else { throw Failure("\(step.input.lastPathComponent) has no video track") }
        try await exportPassthrough(
            try await Self.composition(of: video), keepingMetadataOf: asset, as: fileType, to: output, input: step.input,
            progress: progress
        )
    }

    /// An export of a composition carries none of the asset's metadata (such as its creation date) unless given.
    func exportPassthrough(
        _ composition: AVComposition, keepingMetadataOf asset: AVURLAsset, as fileType: AVFileType, to output: URL,
        input: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let metadata = try await asset.load(.metadata)
        try await export(
            composition, preset: AVAssetExportPresetPassthrough, as: fileType, to: output, input: input,
            configure: { $0.metadata = metadata }, progress: progress
        )
    }

    private func snapshot(_ asset: AVURLAsset, _ step: ConversionStep, to output: URL) async throws {
        let name = step.input.lastPathComponent
        _ = try await firstTrack(of: asset, mediaType: .video, input: step.input)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)).image
        } catch {
            throw Failure("cannot take a snapshot of \(name): \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure("cannot create \(output.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot write \(output.lastPathComponent)") }
    }

    /// Retimes every audio and video track; the spectral time-pitch algorithm keeps voices at their pitch.
    private func changeSpeed(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let speed = step.options.speed, speed != 1 else {
            throw ConversionError.notApplicable(reason: "The speed is unchanged")
        }
        guard speed.isFinite, speed > 0 else { throw Failure("a speed of \(speed) is not possible") }
        let fileType = try Self.fileType(of: step.to)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        } catch {
            throw Failure("cannot open \(step.input.lastPathComponent): \(error.localizedDescription)")
        }
        guard !tracks.isEmpty else { throw Failure("\(step.input.lastPathComponent) has no audio or video track") }
        let duration = try await asset.load(.duration)
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / speed)
        let composition = try await Self.composition(of: tracks)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: scaled)
        let metadata = try await asset.load(.metadata)
        let preset = step.to.id == "m4a" ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        try await export(
            composition, preset: preset, as: fileType, to: output, input: step.input,
            configure: { session in
                session.audioTimePitchAlgorithm = .spectral
                session.metadata = metadata
                // The time-pitch algorithm leaves a tail of 50 to 120 ms of audio past the end without this.
                session.timeRange = CMTimeRange(start: .zero, duration: scaled)
            },
            progress: progress
        )
    }

    private func makeMono(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        let track = try await firstTrack(of: asset, mediaType: .audio, input: step.input)
        guard try await Self.pcmShape(of: track).1 > 1 else {
            throw ConversionError.notApplicable(reason: "It's already mono")
        }
        let bitrate = fileType == .m4a ? try Self.bitsPerSecond(step.options.audioBitrate) : nil
        try await writeAudio(
            from: asset, track: track, as: fileType, channelCount: 1, aacBitrate: bitrate,
            metadata: try await asset.load(.metadata), to: output, input: step.input, progress: progress
        )
    }

    private func stripMetadata(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        try await export(
            asset, preset: AVAssetExportPresetPassthrough, as: fileType, to: output, input: step.input,
            configure: { session in
                session.metadata = []
                session.metadataItemFilter = .forSharing()
            },
            progress: progress
        )
    }

    /// A composition of `tracks` over their own time ranges, each keeping its preferred transform; with `turn`, each
    /// video track's shown picture is also turned (only its transform changes, so a passthrough export copies samples).
    static func composition(of tracks: [AVAssetTrack], turn: RotateSpec? = nil) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in tracks {
            let (timeRange, transform, naturalSize) = try await track.load(.timeRange, .preferredTransform, .naturalSize)
            guard let copy = composition.addMutableTrack(
                withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw Failure("cannot copy a \(track.mediaType.rawValue) track") }
            try copy.insertTimeRange(timeRange, of: track, at: timeRange.start)
            copy.preferredTransform = transform
            if let turn, track.mediaType == .video {
                let upright = Self.upright(transform, naturalSize: naturalSize)
                copy.preferredTransform = upright.transform
                    .concatenating(turn.transform(width: upright.width, height: upright.height))
            }
        }
        return composition
    }

    /// "192k" as 192000; a plain number is bits per second.
    static func bitsPerSecond(_ bitrate: String) throws -> Int {
        let text = bitrate.lowercased().trimmingCharacters(in: .whitespaces)
        let (digits, factor) = text.hasSuffix("k") ? (String(text.dropLast()), 1_000) : (text, 1)
        guard let value = Int(digits), value > 0 else { throw Failure("\(bitrate) is not an audio bitrate") }
        return value * factor
    }

    /// The highest bitrate the AAC encoder takes for this shape at or under `requested`, or its lowest. Asked for more
    /// than it takes (192 kbps for 8 kHz mono), the writer fails the whole file with "Cannot Encode Media".
    static func aacBitrate(_ requested: Int, sampleRate: Double, channelCount: Int) -> Int {
        let channels = UInt32(max(1, channelCount))
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1, mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return requested }
        defer { AudioConverterDispose(converter) }
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr
        else { return requested }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr
        else { return requested }
        // The encoder lists discrete rates (a range whose ends are equal), padded with zeros.
        let rates = Set(ranges.map { Int($0.mMaximum) }).filter { $0 > 0 }.sorted()
        return rates.last { $0 <= requested } ?? rates.first ?? requested
    }

    // MARK: Export session (video, and audio files to m4a)

    /// `configure` adjusts the session (a video composition, metadata) before it starts.
    func export(
        _ asset: AVAsset, preset: String, as fileType: AVFileType, to output: URL, input: URL,
        configure: (AVAssetExportSession) -> Void = { _ in }, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let name = input.lastPathComponent
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: fileType) else {
            throw Failure("\(name) cannot be exported with the \(preset) preset as \(fileType.rawValue)")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure("cannot create an export session for \(name) with the \(preset) preset")
        }
        // A session cancelled just after it starts can still create an empty output file a few milliseconds after
        // reporting that it ended. It therefore writes into a private folder that is always removed, so a late file
        // has no folder to land in, and a finished file is moved out to `output`.
        let workFolder = output.deletingLastPathComponent()
            .appending(path: ".avfoundation-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: false)
        } catch {
            throw Failure("cannot create a working folder for \(output.lastPathComponent): \(error.localizedDescription)")
        }
        defer {
            for _ in 0..<3 where FileManager.default.fileExists(atPath: workFolder.path) {
                try? FileManager.default.removeItem(at: workFolder)
            }
        }
        let workFile = workFolder.appending(path: output.lastPathComponent, directoryHint: .notDirectory)
        session.outputURL = workFile
        session.outputFileType = fileType
        configure(session)
        let gate = ExportGate(session)

        let started = await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self, returning: Bool.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        progress(min(1, max(0, Double(gate.progress))))
                        try? await Task.sleep(for: Self.progressInterval)
                    }
                }
                let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if !gate.start(completion: { continuation.resume(returning: true) }) {
                        continuation.resume(returning: false)
                    }
                }
                group.cancelAll()
                return started
            }
        } onCancel: {
            gate.cancel()
        }
        guard started else { throw CancellationError() }

        switch session.status {
        case .completed:
            try Task.checkCancellation()
            do {
                try FileManager.default.moveItem(at: workFile, to: output)
            } catch {
                throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
            }
        case .cancelled:
            throw CancellationError()
        default:
            let reason = session.error?.localizedDescription ?? "unknown error"
            throw Failure("cannot export \(name) as \(fileType.rawValue): \(reason)")
        }
    }

    // MARK: Reader and writer (audio to LPCM, video to m4a, and mono)

    /// Decodes `track` to `channelCount` channels (the source's when nil; fewer downmixes), then writes 16-bit LPCM,
    /// or AAC at `aacBitrate` when it is set. The WAV, AIFF and CAF writers drop `metadata`; only m4a keeps it.
    func writeAudio(
        from asset: AVURLAsset, track: AVAssetTrack, as fileType: AVFileType, channelCount: Int? = nil,
        aacBitrate: Int? = nil, metadata: [AVMetadataItem] = [], timeRange: CMTimeRange? = nil,
        keepsSampleFormat: Bool = false, to output: URL, input: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let name = input.lastPathComponent
        let (sampleRate, sourceChannelCount) = try await Self.pcmShape(of: track)
        let channelCount = channelCount ?? sourceChannelCount
        let duration: Double
        if let timeRange {
            duration = CMTimeGetSeconds(timeRange.duration)
        } else {
            duration = CMTimeGetSeconds(try await asset.load(.duration))
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure("cannot read \(name): \(error.localizedDescription)")
        }
        // P81: a trim keeps the source's depth and float-ness; conversions and mono write 16-bit.
        let sample = keepsSampleFormat ? try await Self.sampleFormat(of: track) : SampleFormat()
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: Self.lpcmSettings(
                sampleRate: sampleRate, channelCount: channelCount, bigEndian: false, bitDepth: sample.bitDepth,
                isFloat: sample.isFloat
            )
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw Failure("cannot decode the audio of \(name)") }
        reader.add(readerOutput)
        if let timeRange { reader.timeRange = timeRange }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        } catch {
            throw Failure("cannot create \(output.lastPathComponent): \(error.localizedDescription)")
        }
        let writerSettings = if let aacBitrate {
            Self.aacSettings(
                sampleRate: sampleRate, channelCount: channelCount,
                bitrate: Self.aacBitrate(aacBitrate, sampleRate: sampleRate, channelCount: channelCount)
            )
        } else {
            Self.lpcmSettings(
                sampleRate: sampleRate, channelCount: channelCount,
                bigEndian: fileType == .aiff || (keepsSampleFormat && fileType != .wav && sample.bigEndian),
                bitDepth: sample.bitDepth, isFloat: sample.isFloat
            )
        }
        // AVAssetWriterInput raises an uncaught exception for settings the encoder refuses (such as a bitrate).
        guard writer.canApply(outputSettings: writerSettings, forMediaType: .audio) else {
            throw Failure("cannot encode the audio of \(name) for \(output.lastPathComponent)")
        }
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw Failure("cannot write audio to \(output.lastPathComponent)")
        }
        writer.add(writerInput)
        writer.metadata = metadata

        guard reader.startReading() else {
            throw Failure("cannot read \(name): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure("cannot write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        let origin = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: origin)

        let copy = SampleCopy(reader: reader, output: readerOutput, input: writerInput)
        let outcome = await withTaskCancellationHandler {
            await copy.run(duration: duration, origin: CMTimeGetSeconds(origin), progress: progress)
        } onCancel: {
            copy.cancel()
        }

        switch outcome {
        case .finished:
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw Failure("cannot finish \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
            }
            try Task.checkCancellation()
        case .cancelled:
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        case .readFailed:
            writer.cancelWriting()
            throw Failure("cannot decode \(name): \(reader.error?.localizedDescription ?? "unknown error")")
        case .writeFailed:
            reader.cancelReading()
            writer.cancelWriting()
            throw Failure("cannot write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// The source track's sample rate and channel count, or 44.1 kHz stereo when the track does not say.
    static func pcmShape(of track: AVAssetTrack) async throws -> (Double, Int) {
        let description = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = description.map(\.mSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? fallbackSampleRate
        let channelCount = description.map { Int($0.mChannelsPerFrame) }.flatMap { $0 > 0 ? $0 : nil }
            ?? fallbackChannelCount
        return (sampleRate, channelCount)
    }

    /// Integer depth and float-ness of an LPCM file's samples; 16-bit integer unless a trim asks to keep the source's.
    struct SampleFormat {
        var bitDepth = 16
        var isFloat = false
        var bigEndian = false
    }

    /// The track's own depth, float-ness and byte order, limited to what the LPCM writer takes (8-bit sources and
    /// odd depths come out 16-bit, which holds them exactly).
    static func sampleFormat(of track: AVAssetTrack) async throws -> SampleFormat {
        guard let description = try await track.load(.formatDescriptions).first
            .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
            description.mFormatID == kAudioFormatLinearPCM else { return SampleFormat() }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(description.mBitsPerChannel)
        let depth = isFloat ? ([32, 64].contains(bits) ? bits : 32) : ([16, 24, 32].contains(bits) ? bits : 16)
        return SampleFormat(
            bitDepth: depth, isFloat: isFloat, bigEndian: description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        )
    }

    static func lpcmSettings(
        sampleRate: Double, channelCount: Int, bigEndian: Bool, bitDepth: Int = 16, isFloat: Bool = false
    ) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: channelLayout(channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func aacSettings(sampleRate: Double, channelCount: Int, bitrate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: channelLayout(channelCount),
            AVEncoderBitRateKey: bitrate,
            // The default strategy spends far less than the bitrate on simple audio, so Quality would barely matter.
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
    }

    private static func channelLayout(_ channelCount: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = switch channelCount {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        default: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount)
        }
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    // MARK: Shared

    func tracks(of asset: AVURLAsset, mediaType: AVMediaType, input: URL) async throws -> [AVAssetTrack] {
        do {
            return try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            throw Failure("cannot open \(input.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func firstTrack(of asset: AVURLAsset, mediaType: AVMediaType, input: URL) async throws -> AVAssetTrack {
        guard let track = try await tracks(of: asset, mediaType: mediaType, input: input).first else {
            throw Failure("\(input.lastPathComponent) has no \(mediaType == .audio ? "audio" : "video") track")
        }
        return track
    }
}

/// Starts and cancels one export session in either order, from any thread. AVAssetExportSession raises an uncaught
/// exception when `exportAsynchronously` follows `cancelExport()`, so a cancel that arrives before the start only
/// records itself, and the start is then refused.
///
/// `@unchecked Sendable` is safe because `start` and `cancel` touch the session only while holding `state`, and the
/// progress poller only reads the session's `progress` property.
final class ExportGate: @unchecked Sendable {
    private enum State {
        case idle, started, cancelled
    }

    private let session: AVAssetExportSession
    private let state = OSAllocatedUnfairLock(initialState: State.idle)

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    var progress: Float { session.progress }

    /// Starts the export and returns true, unless `cancel()` came first. `completion` runs when the export ends.
    /// The lock is held across `exportAsynchronously`, which returns at once; `completion` never takes the lock.
    func start(completion: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state == .idle else { return false }
            state = .started
            session.exportAsynchronously(completionHandler: completion)
            return true
        }
    }

    /// Cancels a running export, or makes a later `start` refuse to run. Safe to call more than once, and after the
    /// export has ended.
    func cancel() {
        state.withLock { state in
            if state == .started { session.cancelExport() } else { state = .cancelled }
        }
    }
}

/// Pumps decoded sample buffers from a reader output into a writer input, driven by the input's
/// `requestMediaDataWhenReady` callbacks.
///
/// `@unchecked Sendable` is safe because the reader, output, input and continuation are touched only on `queue` (a
/// serial queue) once `run` starts, and the cancellation flag is guarded by its own lock.
final class SampleCopy: @unchecked Sendable {
    enum Outcome {
        case finished, cancelled, readFailed, writeFailed
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "pomelo.avfoundation.sample-copy")
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Read and written only on `queue`.
    private var done = false
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Ends a copy whose writer may never ask for data again (its other track failed), without touching the input;
    /// the caller then cancels the writer. Runs on `queue`, so it never overlaps an append.
    func abandon() {
        queue.async { [self] in
            guard !done, let continuation else { return }
            done = true
            continuation.resume(returning: .cancelled)
        }
    }

    /// Copies every buffer, then marks the input as finished. Progress is the presentation time past `origin` over
    /// `duration`.
    func run(duration: Double, origin: Double = 0, progress: @escaping @Sendable (Double) -> Void) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !done else { return }
                    func finish(_ outcome: Outcome) {
                        done = true
                        input.markAsFinished()
                        continuation.resume(returning: outcome)
                    }
                    while input.isReadyForMoreMediaData {
                        if cancelled.withLock({ $0 }) { return finish(.cancelled) }
                        guard let buffer = output.copyNextSampleBuffer() else {
                            // With two outputs, one runs dry while the reader is still reading the other.
                            return finish(reader.status == .completed || reader.status == .reading ? .finished : .readFailed)
                        }
                        if duration > 0 {
                            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) - origin
                            if time.isFinite { progress(min(1, max(0, time / duration))) }
                        }
                        guard input.append(buffer) else { return finish(.writeFailed) }
                    }
                }
            }
        }
    }
}
