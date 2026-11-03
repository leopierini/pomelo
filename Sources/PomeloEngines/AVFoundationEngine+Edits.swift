import AVFoundation
import CoreMedia
import Foundation
import PomeloCore

extension AVFoundationEngine {
    /// Fine enough for any frame or sample boundary of the formats trim and split take.
    private static let editTimescale: CMTimeScale = 60_000
    /// The H.264 export preset quietly scales down a frame with a side over 3,840 pixels or more than about 9.4
    /// million pixels (measured: 4000 × 300 came out 3840 × 288, 3840 × 3840 came out 3072 × 3072), so a frame
    /// beyond either limit of 4K UHD is encoded as HEVC (P205).
    static let h264MaxSide = 3_840
    static let h264MaxArea = 3_840 * 2_160

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: editTimescale)
    }

    /// Keeps `edit`'s range without re-encoding. A passthrough export keeps the samples back to the previous
    /// keyframe and an edit list starts playback at the cut; LPCM files are cut at the sample.
    func trim(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let range = try TimeEdit.trimRange(step.options.edit, duration: duration)
        let fileType = try Self.fileType(of: step.to)

        if Self.lpcmTargets.contains(step.from.id) {
            let track = try await firstTrack(of: asset, mediaType: .audio, input: step.input)
            let (sampleRate, _) = try await Self.pcmShape(of: track)
            // A timescale equal to the sample rate puts both ends on whole frames.
            let scale = CMTimeScale(sampleRate.rounded())
            let first = Int64((range.start * Double(scale)).rounded())
            let last = Int64((range.end * Double(scale)).rounded())
            let sample = try await Self.sampleFormat(of: track)
            // AVAssetWriter refuses float samples in WAV and AIFF (and 64-bit float anywhere), so AVAudioFile writes
            // them, a 64-bit float source only as 32-bit float (P89: the one sample format a trim narrows).
            if sample.isFloat, !(fileType == .caf && sample.bitDepth == 32) {
                try copyFrames(of: step.input, from: first, to: last, scale: scale, sample: sample, into: output, progress: progress)
                return
            }
            try await writeAudio(
                from: asset, track: track, as: fileType,
                timeRange: CMTimeRange(start: CMTime(value: first, timescale: scale), duration: CMTime(value: last - first, timescale: scale)),
                keepsSampleFormat: true, to: output, input: step.input, progress: progress
            )
            return
        }
        try await exportPassthrough(
            asset, range: CMTimeRange(start: Self.time(range.start), end: Self.time(range.end)), as: fileType,
            to: output, input: step.input, progress: progress
        )
    }

    /// Copies frames `first..<last` (counted at `scale` frames per second) of an LPCM file into a new file of the
    /// same format, the way a trim of float samples must since the asset writer cannot write them.
    private func copyFrames(
        of input: URL, from first: Int64, to last: Int64, scale: CMTimeScale, sample: SampleFormat, into output: URL,
        progress: @Sendable (Double) -> Void
    ) throws {
        let name = input.lastPathComponent
        let common: AVAudioCommonFormat = sample.bitDepth == 64 ? .pcmFormatFloat64 : .pcmFormatFloat32
        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: input, commonFormat: common, interleaved: false)
        } catch {
            throw Failure("cannot read \(name): \(error.localizedDescription)")
        }
        let total = last - first
        guard Double(scale) == source.fileFormat.sampleRate, total > 0, first + total <= source.length else {
            throw Failure("cannot cut \(name) at those frames")
        }
        source.framePosition = first
        do {
            let sink = try AVAudioFile(
                forWriting: output, settings: source.fileFormat.settings, commonFormat: common, interleaved: false
            )
            let chunk = AVAudioFrameCount(16_384)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else {
                throw Failure("cannot allocate an audio buffer for \(name)")
            }
            var done: Int64 = 0
            while done < total {
                try Task.checkCancellation()
                try source.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), total - done)))
                guard buffer.frameLength > 0 else { throw Failure("\(name) ended early") }
                try sink.write(from: buffer)
                done += Int64(buffer.frameLength)
                progress(Double(done) / Double(total))
            }
        } catch let error as Failure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Cuts the movie at each usable point into `<stem>-1.<ext>`, `<stem>-2.<ext>`… inside the folder it returns.
    /// Anything that stops it, a cancel included, removes the folder with the parts made so far.
    func split(
        _ asset: AVURLAsset, _ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let duration = try await asset.load(.duration)
        let points = try TimeEdit.splitPoints(step.options.edit, duration: CMTimeGetSeconds(duration))
        let fileType = try Self.fileType(of: step.to)
        let bounds = [CMTime.zero] + points.map(Self.time) + [duration]
        let count = bounds.count - 1
        let folder = step.suggestedFolder
        let stem = OutputNamer.stem(of: step.input)
        let ext = step.to.extensions[0]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<count {
                try Task.checkCancellation()
                let part = folder.appending(path: "\(stem)-\(index + 1).\(ext)", directoryHint: .notDirectory)
                try await exportPassthrough(
                    asset, range: CMTimeRange(start: bounds[index], end: bounds[index + 1]), as: fileType, to: part,
                    input: step.input, progress: { progress((Double(index) + $0) / Double(count)) }
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Renders the editor's rectangle of the upright picture, so a portrait iPhone video keeps what the editor showed
    /// and comes out upright in its own pixels.
    func crop(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileType = try Self.fileType(of: step.to)
        let video = try await uprightVideo(of: asset, input: step.input)
        let kept = try CropEdit.videoPixels(step.options.edit, width: video.width, height: video.height)
        try await render(
            asset, video, transform: CGAffineTransform(translationX: -kept.minX, y: -kept.minY), size: kept.size,
            as: fileType, to: output, input: step.input, progress: progress
        )
    }

    /// Scales the upright picture to the editor's size (P197) into `<stem>-<width>x<height>.<ext>`, the even size it
    /// gets. Exact fills the box from the centre of the picture and never stretches.
    func resize(
        _ asset: AVURLAsset, _ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let fileType = try Self.fileType(of: step.to)
        let video = try await uprightVideo(of: asset, input: step.input)
        let target = try ResizeEdit.videoSize(step.options.edit, width: video.width, height: video.height)
        var kept = CGRect(x: 0, y: 0, width: video.width, height: video.height)
        // The box is the even size the video gets, not the one typed, so the picture fills every pixel it renders.
        if case .resize(.exact) = step.options.edit {
            kept = ResizeEdit.keptRect(width: video.width, height: video.height, target: target)
        }
        let output = step.stagingDirectory.appending(
            path: "\(OutputNamer.stem(of: step.input))-\(ResizeEdit.nameSuffix(width: target.width, height: target.height))"
                + ".\(step.to.extensions[0])",
            directoryHint: .notDirectory
        )
        // Each side scales on its own: rounding to even sizes moves the proportions by less than a pixel.
        let scale = CGAffineTransform(
            scaleX: CGFloat(target.width) / kept.width, y: CGFloat(target.height) / kept.height
        )
        try await render(
            asset, video, transform: CGAffineTransform(translationX: -kept.minX, y: -kept.minY).concatenating(scale),
            size: CGSize(width: target.width, height: target.height), as: fileType, to: output, input: step.input,
            progress: progress
        )
        return output
    }

    /// The size a written movie's first video track shows.
    private static func upright(of movie: URL) async throws -> (width: Int, height: Int) {
        guard let track = try await AVURLAsset(url: movie).loadTracks(withMediaType: .video).first else {
            throw Failure("\(movie.lastPathComponent) was written without a video track")
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = upright(transform, naturalSize: naturalSize)
        return (upright.width, upright.height)
    }

    /// Turns and flips the picture players show (P198). Quarter turns alone are lossless: only the video track's
    /// preferred transform changes, and the samples are copied. A flip is drawn into new pixels as crop draws.
    func rotate(
        _ asset: AVURLAsset, _ step: ConversionStep, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let spec = try RotateEdit.spec(step.options.edit)
        let fileType = try Self.fileType(of: step.to)
        let video = try await uprightVideo(of: asset, input: step.input)
        if spec.flipHorizontal {
            let size = spec.outputSize(width: video.width, height: video.height)
            try await render(
                asset, video, transform: spec.transform(width: video.width, height: video.height),
                size: CGSize(width: size.width, height: size.height), as: fileType, to: output, input: step.input,
                progress: progress
            )
            return
        }
        let tracks: [AVAssetTrack]
        do {
            // Timed metadata and timecode stay out: untested in a composition's passthrough with an iPhone's tracks.
            let kept: Set<AVMediaType> = [.video, .audio, .subtitle, .closedCaption, .text]
            tracks = try await asset.load(.tracks).filter { kept.contains($0.mediaType) }
        } catch {
            throw Failure("cannot open \(step.input.lastPathComponent): \(error.localizedDescription)")
        }
        try await exportPassthrough(
            try await Self.composition(of: tracks, turn: spec), keepingMetadataOf: asset, as: fileType, to: output,
            input: step.input, progress: progress
        )
    }

    /// `transform` (a track's preferred one) shifted so the picture it shows starts at the origin, and that picture's
    /// size. Preferred transforms are top-left and y-down, as `RotateSpec.transform` is, so the two compose directly.
    static func upright(
        _ transform: CGAffineTransform, naturalSize: CGSize
    ) -> (transform: CGAffineTransform, width: Int, height: Int) {
        let shown = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return (
            transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY)),
            Int(shown.width.rounded()), Int(shown.height.rounded())
        )
    }

    /// The first video track, with what `render` needs to draw its upright picture.
    private struct UprightVideo {
        let track: AVAssetTrack
        /// From the stored frame to the picture players show, `width` × `height` from the origin.
        let upright: CGAffineTransform
        let width: Int
        let height: Int
        let frameRate: Float
        let isHEVC: Bool
    }

    private func uprightVideo(of asset: AVURLAsset, input: URL) async throws -> UprightVideo {
        let track = try await firstTrack(of: asset, mediaType: .video, input: input)
        let (naturalSize, transform, frameRate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )
        let upright = Self.upright(transform, naturalSize: naturalSize)
        return UprightVideo(
            track: track, upright: upright.transform, width: upright.width, height: upright.height,
            frameRate: frameRate, isHEVC: formats.contains { $0.mediaSubType == .hevc }
        )
    }

    /// Re-encodes `video`'s upright picture drawn through `transform` into a `size` frame, with the HEVC preset for an
    /// HEVC source or a frame larger than the H.264 preset writes (P205); sound and metadata follow the preset. A
    /// preset shrinks a frame it cannot encode without saying so, so the written size is checked: an output is
    /// always the size its name and the editor promised, or nothing.
    private func render(
        _ asset: AVURLAsset, _ video: UprightVideo, transform: CGAffineTransform, size: CGSize,
        as fileType: AVFileType, to output: URL, input: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let hevc = video.isHEVC || max(width, height) > Self.h264MaxSide || width * height > Self.h264MaxArea
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video.track)
        layer.setTransform(video.upright.concatenating(transform), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = Self.frameDuration(nominalFrameRate: video.frameRate)
        composition.instructions = [instruction]
        try await export(
            asset, preset: hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality,
            as: fileType, to: output, input: input, configure: { $0.videoComposition = composition },
            progress: progress
        )
        let written: (width: Int, height: Int)
        do {
            written = try await Self.upright(of: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        guard written == (width, height) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure(
                "cannot encode \(input.lastPathComponent) at \(width)x\(height) pixels"
                    + " (the encoder wrote \(written.width)x\(written.height))"
            )
        }
    }

    private func exportPassthrough(
        _ asset: AVURLAsset, range: CMTimeRange, as fileType: AVFileType, to output: URL, input: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await export(
            asset, preset: AVAssetExportPresetPassthrough, as: fileType, to: output, input: input,
            configure: { $0.timeRange = range }, progress: progress
        )
    }
}
