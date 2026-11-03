import AVFoundation
import CoreGraphics
import Foundation
import Testing
import os
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// Resize and Rotate on videos (P197, P198), through the whole runner so the published names are the ones people see.
/// Serialized for the reason `CropTests` is: parallel hardware-encoded movies starve the other suites' encoders.
@Suite(.serialized) struct ResizeRotateVideoTests {
    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func run(_ presetID: String, _ input: URL, _ edit: EditSpec?) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == presetID })
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

    private func resize(_ input: URL, _ spec: ResizeSpec) async throws -> URL {
        try output(try await run("resize", input, .resize(spec)))
    }

    private func rotate(_ input: URL, _ spec: RotateSpec) async throws -> URL {
        try output(try await run("rotate", input, .rotate(spec)))
    }

    private func moved(_ file: URL, to name: String) throws -> URL {
        let target = file.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// The first video track's stored samples: what a re-encode changes and a passthrough keeps.
    private struct Samples: Equatable {
        var codec: FourCharCode
        var width: Int32
        var height: Int32
        var count: Int
        var bytes: Int
    }

    private func samples(of url: URL) async throws -> Samples {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var (count, bytes) = (0, 0)
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
            bytes += CMSampleBufferGetTotalSampleSize(sample)
        }
        #expect(reader.status == .completed)
        return Samples(
            codec: format.mediaSubType.rawValue, width: dimensions.width, height: dimensions.height, count: count,
            bytes: bytes
        )
    }

    private func preferredTransform(of url: URL) async throws -> CGAffineTransform {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.preferredTransform)
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// The quadrant shown at each quarter of `frame`'s picture, keyed by where it is shown.
    private func shownQuadrants(_ frame: CGImage) throws -> [Fixtures.Quadrant: Fixtures.Quadrant?] {
        let spots: [(Fixtures.Quadrant, Int, Int)] = [
            (.topLeft, 1, 1), (.topRight, 3, 1), (.bottomLeft, 1, 3), (.bottomRight, 3, 3),
        ]
        var shown: [Fixtures.Quadrant: Fixtures.Quadrant?] = [:]
        for (place, column, row) in spots {
            shown[place] = quadrant(of: try rgb(of: frame, x: frame.width * column / 4, y: frame.height * row / 4))
        }
        return shown
    }

    // MARK: Resize

    @Test func resizeTo720p() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(
            try await Fixtures.movie(seconds: 1, withAudio: true, width: 1920, height: 1080, in: dir), to: "clip.mov"
        )

        let resized = try await resize(input, .height(720))

        #expect(resized.lastPathComponent == "clip-1280x720.mov")
        #expect(try await videoSizes(resized).stored == CGSize(width: 1280, height: 720))
        #expect(try await samples(of: resized).count == samples(of: input).count)
        #expect(abs(try await duration(of: resized) - duration(of: input)) < 0.05)
        #expect(try await !AVURLAsset(url: resized).loadTracks(withMediaType: .audio).isEmpty, "the sound is kept")
    }

    @Test func exactResizeCentres() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.quadrantMovie(width: 1920, height: 1080, seconds: 1, rotated90: false, in: dir)

        let resized = try await resize(input, .exact(width: 1080, height: 1080))

        #expect(try await videoSizes(resized).stored == CGSize(width: 1080, height: 1080))
        let frame = try await shownFrame(resized)
        // 420 px cut from each side: the edges still hold the inner quadrants, and their border is in the middle.
        for (x, top, bottom) in [(8, Fixtures.Quadrant.topLeft, Fixtures.Quadrant.bottomLeft), (520, .topLeft, .bottomLeft),
                                 (560, .topRight, .bottomRight), (1071, .topRight, .bottomRight)] {
            #expect(try quadrant(of: rgb(of: frame, x: x, y: 270)) == top, "\(x)")
            #expect(try quadrant(of: rgb(of: frame, x: x, y: 810)) == bottom, "\(x)")
        }
    }

    @Test func resizePortraitIPhoneClip() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 1920 × 1080 with an iPhone portrait's transform: shown 1080 × 1920.
        let input = try await Fixtures.quadrantMovie(width: 1920, height: 1080, seconds: 1, rotated90: true, in: dir)

        let resized = try await resize(input, .width(540))

        #expect(resized.lastPathComponent.hasSuffix("-540x960.mov"))
        let sizes = try await videoSizes(resized)
        #expect(sizes.stored == CGSize(width: 540, height: 960))
        #expect(try await preferredTransform(of: resized) == .identity)
        for (place, found) in try shownQuadrants(try await shownFrame(resized)) {
            #expect(found == place, "\(place)")
        }
    }

    @Test func resizeRefusals() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)

        #expect(reason(try await run("resize", input, nil)) == ResizeEdit.chooseSizeReason)
        #expect(reason(try await run("resize", input, .resize(.height(240)))) == ResizeEdit.alreadyThatSizeReason)
        #expect(reason(try await run("resize", input, .resize(.width(20_000)))) == ResizeEdit.pixelRangeReason)
    }

    /// The H.264 preset quietly shrinks a frame wider than 4K (P205), so such a target is encoded as HEVC and the name is
    /// the real size, every frame kept.
    @Test func anH264SourceAboveTheH264LimitIsWhatItsNameSays() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(
            try await Fixtures.movie(seconds: 1, withAudio: false, width: 640, height: 48, in: dir), to: "wide.mov"
        )

        let resized = try await resize(input, .width(4000))

        #expect(resized.lastPathComponent == "wide-4000x300.mov")
        #expect(try await videoSizes(resized).shown == CGSize(width: 4000, height: 300))
        let found = try await samples(of: resized)
        #expect(found.codec == kCMVideoCodecType_HEVC)
        #expect(found.count == (try await samples(of: input).count))
    }

    /// A size no encoder here writes fails the job; nothing named for a size it is not is published.
    @Test func aSizeTheEncoderCannotWriteIsNeverMislabelled() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(
            try await Fixtures.movie(seconds: 1, withAudio: false, width: 640, height: 48, in: dir), to: "wide.mov"
        )

        let result = try await run("resize", input, .resize(.exact(width: 16_384, height: 16)))

        if case .succeeded(_, let outputs, _) = result, let output = outputs.first {
            #expect(output.lastPathComponent == "wide-16384x16.mov")
            #expect(try await videoSizes(output).shown == CGSize(width: 16_384, height: 16))
        } else {
            guard case .failed(_, let error) = result else { Issue.record("\(result)"); return }
            if case .notApplicable = error { Issue.record("\(error)") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") } == ["wide.mov"])
        }
    }

    /// The H.264 preset caps a frame's area, about 9.4 million pixels, not its longer side (P205): a 3840 × 3840 frame
    /// of an H.264 source is written whole, as HEVC.
    @Test func aSquare4KResizeOfAnH264SourceIsWrittenWhole() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(try await Fixtures.movie(seconds: 1, withAudio: false, in: dir), to: "small.mov")
        try #require(try await samples(of: input).codec == kCMVideoCodecType_H264)

        let resized = try await resize(input, .exact(width: 3_840, height: 3_840))

        #expect(resized.lastPathComponent == "small-3840x3840.mov")
        #expect(try await videoSizes(resized).shown == CGSize(width: 3_840, height: 3_840))
        #expect(try await samples(of: resized).codec == kCMVideoCodecType_HEVC)
    }

    /// A flip or a crop of an H.264 source over 3840 × 2160 of area renders through the same rule as a resize, so the
    /// picture keeps its size instead of being quietly scaled down (P205).
    @Test func aFlipAndACropOfALargeH264SourceKeepTheirSize() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(
            try await Fixtures.movie(seconds: 0.2, withAudio: false, width: 4_000, height: 3_000, in: dir), to: "big.mov"
        )
        try #require(try await samples(of: input).codec == kCMVideoCodecType_H264)

        let flipped = try await rotate(input, RotateSpec(quarterTurns: 0, flipHorizontal: true))
        let flippedSize = try await videoSizes(flipped).shown
        #expect(flippedSize == CGSize(width: 4_000, height: 3_000))

        let cropped = try output(try await run("crop", input, .crop(UnitRect(x: 0, y: 0, width: 0.95, height: 0.95))))
        let croppedSize = try await videoSizes(cropped).shown
        #expect(croppedSize == CGSize(width: 3_800, height: 2_850))
    }

    @Test func anHEVCSourceStaysHEVC() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let staging = try makeStaging("hevc", in: dir)
        let mov = try #require(FormatRegistry.builtIn.format(id: "mov"))
        let mp4 = try #require(FormatRegistry.builtIn.format(id: "mp4"))
        let encoded = try await AVFoundationEngine().convert(ConversionStep(
            input: movie, stagingDirectory: staging, from: mov, to: mp4, options: PresetOptions(videoCodec: .hevc)
        )) { _ in }
        let input = try moved(encoded, to: "hevc.mp4")
        try #require(try await samples(of: input).codec == kCMVideoCodecType_HEVC)

        let resized = try await resize(input, .height(120))

        #expect(resized.lastPathComponent == "hevc-160x120.mp4")
        #expect(try await samples(of: resized).codec == kCMVideoCodecType_HEVC)
    }

    // MARK: Rotate

    @Test func quarterTurnComposesWithPreferredTransform() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try moved(
            try await Fixtures.quadrantMovie(width: 1920, height: 1080, seconds: 1, rotated90: true, in: dir),
            to: "portrait.mov"
        )
        #expect(try await videoSizes(input).shown == CGSize(width: 1080, height: 1920))

        let rotated = try await rotate(input, RotateSpec(quarterTurns: 1, flipHorizontal: false))

        #expect(rotated.lastPathComponent == "portrait-rotated.mov")
        let sizes = try await videoSizes(rotated)
        #expect(sizes.shown == CGSize(width: 1920, height: 1080))
        // Turns commute, so a turn of the stored pixels shows the same picture, but off the origin.
        let placed = CGRect(origin: .zero, size: sizes.stored).applying(try await preferredTransform(of: rotated))
        #expect(placed.origin == .zero, "\(placed)")
        // A right turn of what was shown: its top left is now at the top right, and so on around.
        let shown = try shownQuadrants(try await shownFrame(rotated))
        #expect(shown[.topRight] == .topLeft)
        #expect(shown[.bottomRight] == .topRight)
        #expect(shown[.bottomLeft] == .bottomRight)
        #expect(shown[.topLeft] == .bottomLeft)
        #expect(try await samples(of: rotated) == samples(of: input), "the samples are copied, not re-encoded")
        #expect(try await !AVURLAsset(url: rotated).loadTracks(withMediaType: .audio).isEmpty, "the sound is kept")
    }

    @Test func flipReencodes() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.quadrantMovie(width: 640, height: 360, seconds: 1, rotated90: false, in: dir)

        let flipped = try await rotate(input, RotateSpec(quarterTurns: 0, flipHorizontal: true))

        #expect(try await preferredTransform(of: flipped) == .identity)
        #expect(try await videoSizes(flipped).stored == CGSize(width: 640, height: 360))
        let shown = try shownQuadrants(try await shownFrame(flipped))
        #expect(shown[.topLeft] == .topRight)
        #expect(shown[.topRight] == .topLeft)
        #expect(shown[.bottomLeft] == .bottomRight)
        #expect(shown[.bottomRight] == .bottomLeft)
        #expect(try await samples(of: flipped).count == samples(of: input).count)
    }

    /// A right turn and a flip of a portrait clip is a transpose of what was shown: the turn and the flip land on top
    /// of the preferred transform, not on the stored pixels.
    @Test func turnAndFlipOfAPortraitClip() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.quadrantMovie(width: 640, height: 360, seconds: 1, rotated90: true, in: dir)

        let turned = try await rotate(input, RotateSpec(quarterTurns: 1, flipHorizontal: true))

        #expect(try await videoSizes(turned).stored == CGSize(width: 640, height: 360))
        #expect(try await preferredTransform(of: turned) == .identity)
        let shown = try shownQuadrants(try await shownFrame(turned))
        #expect(shown[.topLeft] == .topLeft)
        #expect(shown[.topRight] == .bottomLeft)
        #expect(shown[.bottomLeft] == .topRight)
        #expect(shown[.bottomRight] == .bottomRight)
    }

    /// Where each quadrant of what was shown ends up after `spec`.
    private static func placed(_ quadrant: Fixtures.Quadrant, by spec: RotateSpec) -> Fixtures.Quadrant {
        var place = quadrant
        for _ in 0..<spec.quarterTurns {
            place = switch place {
            case .topLeft: .topRight
            case .topRight: .bottomRight
            case .bottomRight: .bottomLeft
            case .bottomLeft: .topLeft
            }
        }
        guard spec.flipHorizontal else { return place }
        return switch place {
        case .topLeft: .topRight
        case .topRight: .topLeft
        case .bottomLeft: .bottomRight
        case .bottomRight: .bottomLeft
        }
    }

    /// A mirrored (EXIF 2) or upside-down (EXIF 3) preferred transform: the turn or the flip acts on what was shown.
    @Test(arguments: [2, 3], [
        RotateSpec(quarterTurns: 1, flipHorizontal: false), RotateSpec(quarterTurns: 0, flipHorizontal: true),
    ])
    func mirroredAndUpsideDownSourcesRotateWhatWasShown(orientation: Int, spec: RotateSpec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.quadrantMovie(width: 320, height: 180, seconds: 1, orientation: orientation, in: dir)
        for (place, found) in try shownQuadrants(try await shownFrame(input)) {
            try #require(found == place, "the fixture shows \(String(describing: found)) at \(place)")
        }

        let rotated = try await rotate(input, spec)

        let shown = try shownQuadrants(try await shownFrame(rotated))
        for quadrant in Fixtures.Quadrant.allCases {
            #expect(shown[Self.placed(quadrant, by: spec)] == quadrant, "\(quadrant)")
        }
    }

    /// Subtitles survive a lossless quarter turn (mov_text in an mp4, made by ffmpeg).
    @Test(.enabled(if: Installed.has("ffmpeg"))) func aQuarterTurnKeepsTheSubtitles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let subtitles = try Fixtures.srt("1\n00:00:00,000 --> 00:00:01,000\nHello\n\n2\n00:00:01,000 --> 00:00:02,000\nAgain\n", in: dir)
        let input = dir.appending(path: "subtitled.mp4")
        let process = Process()
        process.executableURL = try #require(Installed.path(of: "ffmpeg"))
        process.arguments = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", movie.path, "-i", subtitles.path,
            "-map", "0", "-map", "1", "-c", "copy", "-c:s", "mov_text", input.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        func subtitleTracks(_ url: URL) async throws -> Int {
            try await AVURLAsset(url: url).load(.tracks)
                .filter { [.subtitle, .text, .closedCaption].contains($0.mediaType) }.count
        }
        try #require(try await subtitleTracks(input) == 1)

        let rotated = try await rotate(input, RotateSpec(quarterTurns: 1, flipHorizontal: false))

        #expect(try await subtitleTracks(rotated) == 1)
        #expect(try await videoSizes(rotated).shown == CGSize(width: 240, height: 320))
    }

    @Test func rotateIdentityRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)

        #expect(reason(try await run("rotate", input, .rotate(.identity))) == RotateEdit.nothingToRotateReason)
        #expect(reason(try await run("rotate", input, .rotate(RotateSpec(quarterTurns: 4, flipHorizontal: false))))
                == RotateEdit.nothingToRotateReason)
        #expect(reason(try await run("rotate", input, nil)) == RotateEdit.nothingToRotateReason)
    }

    // MARK: Cancel

    private func step(_ input: URL, _ operation: String, _ edit: EditSpec, in staging: URL) throws -> ConversionStep {
        let mov = try #require(FormatRegistry.builtIn.format(id: "mov"))
        return ConversionStep(
            input: input, stagingDirectory: staging, from: mov, to: mov, options: PresetOptions(edit: edit),
            operation: operation
        )
    }

    private func makeStaging(_ name: String, in dir: URL) throws -> URL {
        let staging = dir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Re-encodes are cancelled once they report progress; nothing may be left in staging.
    @Test(arguments: [
        ("resize", EditSpec.resize(.scale(percent: 50))),
        ("rotate", EditSpec.rotate(RotateSpec(quarterTurns: 1, flipHorizontal: true))),
    ])
    func cancelLeavesNothing(operation: String, edit: EditSpec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 20, withAudio: false, in: dir)
        let staging = try makeStaging("staging", in: dir)
        let conversion = try step(input, operation, edit, in: staging)
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
        try await Task.sleep(for: .milliseconds(100))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    /// A quarter turn only copies samples, too quick to catch midway, so the cancel sweeps across its first moments.
    @Test func cancellingAQuarterTurnLeavesNothing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 20, withAudio: true, in: dir)

        var cancelled = 0
        for attempt in 0..<8 {
            let staging = try makeStaging("staging-\(attempt)", in: dir)
            let conversion = try step(input, "rotate", .rotate(RotateSpec(quarterTurns: 1, flipHorizontal: false)), in: staging)
            let task = Task { try await AVFoundationEngine().convert(conversion) { _ in } }
            if attempt > 0 { try await Task.sleep(for: .milliseconds(attempt * 5)) }
            task.cancel()
            let result = await task.result
            if case .success(let output) = result {
                #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == [output.lastPathComponent])
            } else {
                cancelled += 1
                #expect(throws: CancellationError.self, "attempt \(attempt)") { try result.get() }
                #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty, "attempt \(attempt)")
            }
        }
        #expect(cancelled > 0)
        // A cancelled export session can create its file a few milliseconds late; none may surface in staging.
        try await Task.sleep(for: .milliseconds(100))
        for attempt in 0..<8 {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "staging-\(attempt)").path)
            #expect(names.allSatisfy { !$0.hasPrefix(".") }, "attempt \(attempt)")
        }
    }

    // MARK: Routes

    @Test func resizeAndRotateRouteToAVFoundationForVideo() async throws {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()
        for operation in ["resize", "rotate"] {
            for format: FormatID in ["mov", "mp4", "m4v"] {
                let route = try #require(planner.route(from: format, operation: operation, to: nil), "\(operation) \(format)")
                #expect(route.edges.map(\.engineID) == ["avfoundation"], "\(operation) \(format)")
                #expect(route.edges.first?.flags.contains(.lossy) == true, "\(operation) \(format)")
            }
        }
    }
}
