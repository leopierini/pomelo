import AVFoundation
import CoreMedia
import Foundation
import PomeloCore
import VideoToolbox

extension AVFoundationEngine {
    /// Re-encodes the first video track in HEVC (and the first audio track in AAC) at the bitrates `TargetSize`
    /// plans from the duration. Rate control can overshoot, so a result over the target is retried once with a
    /// bitrate scaled down by the overshoot; one still over is refused, never published.
    func compressToSize(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let target = step.options.targetBytes else {
            throw ConversionError.notApplicable(reason: "No size was chosen")
        }
        let label = TargetSize.label(bytes: target)
        if let size = try? step.input.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) <= target {
            throw ConversionError.notApplicable(reason: "It's already under \(label)")
        }
        let fileType = try Self.fileType(of: step.to)
        let video = try await firstTrack(of: asset, mediaType: .video, input: step.input)
        let audio = try await tracks(of: asset, mediaType: .audio, input: step.input).first
        let (naturalSize, transform, frameRate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let sourceWidth = Int(naturalSize.width.rounded())
        let sourceHeight = Int(naturalSize.height.rounded())
        let fps = frameRate.isFinite && frameRate > 0 ? Double(frameRate) : 30
        guard let plan = TargetSize.videoPlan(
            targetBytes: target, durationSeconds: duration, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            frameRate: fps, hasAudio: audio != nil
        ) else { throw ConversionError.notApplicable(reason: "It's too long to fit in \(label)") }

        // Encoders want even sides; rounding down never makes the picture larger than the source.
        let height = max(2, min(sourceHeight, plan.maxHeight) / 2 * 2)
        let width = max(2, min(sourceWidth, sourceWidth * height / max(1, sourceHeight)) / 2 * 2)
        let encoding = TargetSizeEncoding(
            fileType: fileType, width: width, height: height,
            transform: Self.scaledTransform(transform, from: naturalSize, to: CGSize(width: width, height: height)),
            frameRate: fps,
            videoBitsPerSecond: plan.videoBitsPerSecond, audioBitsPerSecond: plan.audioBitsPerSecond,
            metadata: try await asset.load(.metadata)
        )

        var attempt = encoding
        for retry in [false, true] {
            try await transcode(
                asset, video: video, audio: audio, encoding: attempt, duration: duration, to: output, input: step.input,
                progress: progress
            )
            let size = try measureTargetSize(output)
            if size <= target { return }
            try? FileManager.default.removeItem(at: output)
            if retry { break }
            let scaled = Double(attempt.videoBitsPerSecond) * Double(target) / Double(max(1, size)) * 0.95
            attempt.videoBitsPerSecond = max(1, Int(scaled))
        }
        throw ConversionError.notApplicable(reason: "Can't get it under \(label)")
    }

    /// One pass: `AVAssetReader` decodes, `AVAssetWriter` encodes; the cancellation pattern is `writeAudio`'s.
    private func transcode(
        _ asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?, encoding: TargetSizeEncoding,
        duration: Double, to output: URL, input: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let name = input.lastPathComponent
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure("cannot read \(name): \(error.localizedDescription)")
        }
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: encoding.fileType)
        } catch {
            throw Failure("cannot create \(output.lastPathComponent): \(error.localizedDescription)")
        }

        let videoOutput = AVAssetReaderTrackOutput(
            track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw Failure("cannot decode the video of \(name)") }
        reader.add(videoOutput)
        let videoSettings = encoding.videoSettings
        // AVAssetWriterInput raises an uncaught exception for settings the encoder refuses.
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw Failure("cannot encode the video of \(name) in HEVC")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = encoding.transform
        guard writer.canAdd(videoInput) else { throw Failure("cannot write video to \(output.lastPathComponent)") }
        writer.add(videoInput)

        var built = [SampleCopy(reader: reader, output: videoOutput, input: videoInput)]
        if let audio, encoding.audioBitsPerSecond > 0 {
            let (sampleRate, sourceChannels) = try await Self.pcmShape(of: audio)
            // The AAC writer refuses the discrete layouts of more than two channels.
            let channelCount = min(2, sourceChannels)
            let audioOutput = AVAssetReaderTrackOutput(
                track: audio,
                outputSettings: Self.lpcmSettings(sampleRate: sampleRate, channelCount: channelCount, bigEndian: false)
            )
            audioOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(audioOutput) else { throw Failure("cannot decode the audio of \(name)") }
            reader.add(audioOutput)
            let audioSettings = Self.aacSettings(
                sampleRate: sampleRate, channelCount: channelCount,
                bitrate: Self.aacBitrate(encoding.audioBitsPerSecond, sampleRate: sampleRate, channelCount: channelCount)
            )
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw Failure("cannot encode the audio of \(name)")
            }
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else { throw Failure("cannot write audio to \(output.lastPathComponent)") }
            writer.add(audioInput)
            built.append(SampleCopy(reader: reader, output: audioOutput, input: audioInput))
        }
        let copies = built
        writer.metadata = encoding.metadata

        guard reader.startReading() else {
            throw Failure("cannot read \(name): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure("cannot write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)

        let outcomes = await Self.run(copies, duration: duration, progress: progress)

        if outcomes.allSatisfy({ $0 == .finished }) {
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw Failure("cannot finish \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
            }
            try Task.checkCancellation()
            return
        }
        reader.cancelReading()
        writer.cancelWriting()
        if Task.isCancelled || !outcomes.contains(where: { $0 == .readFailed || $0 == .writeFailed }) {
            throw CancellationError()
        }
        if outcomes.contains(.writeFailed) {
            throw Failure("cannot write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        throw Failure("cannot decode \(name): \(reader.error?.localizedDescription ?? "unknown error")")
    }

    /// `transform` for a picture scaled from `source` to `output`: the rotation is kept and the translation is
    /// rescaled, so the shown rectangle stays where the source's was (usually the origin). Copied as is, an iPhone
    /// portrait's tx of 1080 would push a 720-wide picture 360 pt off its place in players that apply the matrix.
    static func scaledTransform(
        _ transform: CGAffineTransform, from source: CGSize, to output: CGSize
    ) -> CGAffineTransform {
        guard source.height > 0 else { return transform }
        let scale = output.height / source.height
        let shown = CGRect(origin: .zero, size: source).applying(transform)
        var linear = transform
        linear.tx = 0
        linear.ty = 0
        let scaledShown = CGRect(origin: .zero, size: output).applying(linear)
        linear.tx = shown.minX * scale - scaledShown.minX
        linear.ty = shown.minY * scale - scaledShown.minY
        return linear
    }

    /// Runs the copies side by side (the writer interleaves the tracks, so each waits on the other), the first
    /// reporting progress; a cancel or a failure ends them all.
    private static func run(
        _ copies: [SampleCopy], duration: Double, progress: @escaping @Sendable (Double) -> Void
    ) async -> [SampleCopy.Outcome] {
        let silent: @Sendable (Double) -> Void = { _ in }
        return await withTaskCancellationHandler {
            await withTaskGroup(of: SampleCopy.Outcome.self, returning: [SampleCopy.Outcome].self) { group in
                for (index, copy) in copies.enumerated() {
                    let report = index == 0 ? progress : silent
                    group.addTask { await copy.run(duration: duration, progress: report) }
                }
                var outcomes: [SampleCopy.Outcome] = []
                for await outcome in group {
                    outcomes.append(outcome)
                    // A failed track can leave the writer never asking the other for data again.
                    if outcome != .finished {
                        for copy in copies {
                            copy.cancel()
                            copy.abandon()
                        }
                    }
                }
                return outcomes
            }
        } onCancel: {
            for copy in copies { copy.cancel() }
        }
    }
}

/// What one compress-to-size pass writes.
struct TargetSizeEncoding {
    var fileType: AVFileType
    var width: Int
    var height: Int
    var transform: CGAffineTransform
    var frameRate: Double
    var videoBitsPerSecond: Int
    var audioBitsPerSecond: Int
    var metadata: [AVMetadataItem]

    var videoSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitsPerSecond,
                // P79: the average alone overshoots noisy footage 1.5 to 4.5 times (the hardware encoder has a
                // floor); a hard cap of the same bytes per second holds it.
                kVTCompressionPropertyKey_DataRateLimits as String: [videoBitsPerSecond / 8, 1],
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ]
    }
}
