import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import os
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

private let registry = FormatRegistry.builtIn

private func targetSize(_ input: URL, bytes: Int64?, in staging: URL) throws -> ConversionStep {
    let format = try #require(registry.format(for: input))
    return ConversionStep(
        input: input, stagingDirectory: staging, from: format, to: format,
        options: PresetOptions(targetBytes: bytes), operation: "target-size"
    )
}

private func makeStaging(in dir: URL) throws -> URL {
    let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    return staging
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
}

private func staged(_ staging: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: staging.path)
}

/// The reason of a `.notApplicable` the body throws, or nil when it throws something else or nothing.
private func reason(_ body: () async throws -> URL) async -> String? {
    do {
        _ = try await body()
        return nil
    } catch ConversionError.notApplicable(let reason) {
        return reason
    } catch {
        return nil
    }
}

@Suite struct TargetSizeEngineTests {
    // MARK: ImageSizeSearch

    /// Bytes = 1,000,000 × quality × scale², recording every call.
    private final class FakeEncoder: @unchecked Sendable {
        var calls: [(quality: Double, scale: Double)] = []

        func encode(_ quality: Double, _ scale: Double) -> Data {
            calls.append((quality, scale))
            return Data(count: Int(1_000_000 * quality * scale * scale))
        }
    }

    @Test func searchFindsTheHighestQualityThatFits() throws {
        let encoder = FakeEncoder()
        let result = try #require(ImageSizeSearch.search(targetBytes: 500_000, lossy: true, longestSide: 2000,
                                                         encode: encoder.encode))
        #expect(result.count <= 500_000 && result.count >= 450_000)
        #expect(encoder.calls.allSatisfy { $0.scale == 1 })
        #expect(encoder.calls.first?.quality == 0.92)
    }

    @Test func searchShrinksPixelsWhenQualityIsNotEnough() throws {
        let encoder = FakeEncoder()
        let result = try #require(ImageSizeSearch.search(targetBytes: 100_000, lossy: true, longestSide: 2000,
                                                         encode: encoder.encode))
        #expect(result.count <= 100_000)
        #expect(encoder.calls.count <= 12)
        #expect(encoder.calls.contains { $0.scale < 1 })
        #expect(encoder.calls.filter { $0.scale < 1 }.allSatisfy { $0.quality == 0.6 })
    }

    @Test func losslessSearchOnlyScales() throws {
        let encoder = FakeEncoder()
        let result = try #require(ImageSizeSearch.search(targetBytes: 300_000, lossy: false, longestSide: 2000,
                                                         encode: encoder.encode))
        #expect(result.count <= 300_000)
        #expect(!encoder.calls.isEmpty && encoder.calls.allSatisfy { $0.quality == 1 })
        #expect(encoder.calls.count <= 7)
    }

    @Test func searchNeverReturnsMoreThanTheTarget() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let target = Int64.random(in: 1_000...2_000_000, using: &generator)
            for lossy in [true, false] {
                let encoder = FakeEncoder()
                let result = ImageSizeSearch.search(targetBytes: target, lossy: lossy, longestSide: 4000,
                                                    encode: encoder.encode)
                #expect(result == nil || Int64(result!.count) <= target, "target \(target), lossy \(lossy)")
                #expect(encoder.calls.count <= 12, "target \(target), lossy \(lossy)")
                #expect(encoder.calls.allSatisfy { $0.scale <= 1 })
            }
        }
    }

    @Test func searchGivesUpUnder64Pixels() {
        // 500 bytes need a scale under 0.03: under 60 px on a 2000 px side.
        for lossy in [true, false] {
            let encoder = FakeEncoder()
            #expect(ImageSizeSearch.search(targetBytes: 500, lossy: lossy, longestSide: 2000,
                                           encode: encoder.encode) == nil)
            #expect(encoder.calls.allSatisfy { 2000 * $0.scale >= 64 })
        }
        let tiny = FakeEncoder()
        #expect(ImageSizeSearch.search(targetBytes: 100, lossy: false, longestSide: 60, encode: tiny.encode) == nil)
        #expect(tiny.calls.count == 1)
    }

    @Test func anEncoderErrorPropagates() {
        struct Broken: Error {}
        #expect(throws: Broken.self) {
            _ = try ImageSizeSearch.search(targetBytes: 1_000, lossy: true, longestSide: 100) { _, _ in throw Broken() }
        }
    }

    // MARK: Edges

    @Test func targetSizeEdgesAreTheBriefs() {
        func formats(_ engine: some ConversionEngine) -> Set<FormatID> {
            let edges = engine.edges().filter { $0.operation == "target-size" }
            #expect(edges.allSatisfy { $0.from == $0.to && $0.flags == [.lossy] })
            return Set(edges.map(\.from))
        }
        #expect(formats(ImageIOEngine()) == ["jpg", "heic", "avif", "png", "tiff", "bmp"])
        #expect(formats(PDFKitEngine()) == ["pdf"])
        #expect(formats(AVFoundationEngine()) == ["mov", "mp4", "m4v"])
    }

    // MARK: Images

    @Test func aJPEGComesOutUnderTheTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyImage(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", quality: 0.95,
                                            in: dir)
        let target = try fileSize(input) / 3
        let staging = try makeStaging(in: dir)

        let output = try await ImageIOEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(output.pathExtension == "jpg" && output.path.hasPrefix(staging.path))
        #expect(Fixtures.imageUTType(output) == "public.jpeg")
        #expect(Fixtures.imageSize(output) == CGSize(width: 2000, height: 1500))
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    @Test func aPNGShrinksInPixelsAndKeepsAlpha() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 2000, height: 1500, alpha: true, in: dir)
        let target = try fileSize(input) / 2
        let staging = try makeStaging(in: dir)

        let output = try await ImageIOEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(Fixtures.imageUTType(output) == "public.png")
        let size = try #require(Fixtures.imageSize(output))
        #expect(size.width < 2000 && size.height < 1500)
        #expect(abs(size.width / size.height - 2000.0 / 1500.0) < 0.01)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
        #expect(try alpha(of: image, atX: 10, y: image.height / 2) == 0)
        #expect(try alpha(of: image, atX: image.width - 10, y: image.height / 2) == 255)
    }

    @Test func aRotatedPhotoComesOutUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 300 wide and 200 high with orientation 6: shown 200 wide and 300 high.
        let input = try Fixtures.jpgWithOrientation(6, width: 300, height: 200, in: dir)
        let staging = try makeStaging(in: dir)
        let target = try fileSize(input) - 1

        let output = try await ImageIOEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let size = try #require(Fixtures.imageSize(output))
        #expect(size.height > size.width)
    }

    @Test func anImageKeepsItsMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(in: dir)
        let staging = try makeStaging(in: dir)
        let target = try fileSize(input) - 1

        let output = try await ImageIOEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func anImageAlreadyUnderTheTargetIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 64, height: 64, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: 10_000_000, in: staging)

        #expect(await reason { try await ImageIOEngine().convert(step) { _ in } } == "It's already under 10 MB")
        #expect(try staged(staging).isEmpty)
    }

    @Test func anImpossibleImageTargetIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyImage(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", in: dir)
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: 1_000, in: staging)

        #expect(await reason { try await ImageIOEngine().convert(step) { _ in } } == "Can't get it under 1 KB")
        #expect(try staged(staging).isEmpty)
    }

    @Test func anAnimatedImageIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gif = try Fixtures.animatedGIF(width: 64, height: 64, delays: [0.1, 0.1], loopCount: 0, in: dir)
        // An animated PNG made from the GIF, since target-size has no GIF edge.
        let apng = dir.appending(path: "animated.png")
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(apng as CFURL, "public.png" as CFString, 2, nil))
        for index in 0..<2 {
            let frame = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]]
            CGImageDestinationAddImage(destination, frame, delay as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let staging = try makeStaging(in: dir)
        let step = try targetSize(apng, bytes: 100, in: staging)

        #expect(await reason { try await ImageIOEngine().convert(step) { _ in } } == "Animated images can't be resized")
    }

    @Test func noSizeIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let image = try targetSize(try Fixtures.png(width: 64, height: 64, in: dir), bytes: nil, in: staging)
        let pdf = try targetSize(try Fixtures.pdf(pages: 1, in: dir), bytes: nil, in: staging)
        let movie = try targetSize(try await Fixtures.movie(seconds: 1, withAudio: false, in: dir), bytes: nil, in: staging)

        #expect(await reason { try await ImageIOEngine().convert(image) { _ in } } == "No size was chosen")
        #expect(await reason { try await PDFKitEngine().convert(pdf) { _ in } } == "No size was chosen")
        #expect(await reason { try await AVFoundationEngine().convert(movie) { _ in } } == "No size was chosen")
    }

    private func alpha(of image: CGImage, atX x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Image rows run top to bottom; the context's origin is bottom-left.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    // MARK: PDFs

    @Test func systemReduceFileSizeFilterHasImageSettings() throws {
        let data = try Data(contentsOf: URL(filePath: "/System/Library/Filters/Reduce File Size.qfilter"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let filterData = try #require(plist["FilterData"] as? [String: Any])
        let color = try #require(filterData["ColorSettings"] as? [String: Any])
        let image = try #require(color["ImageSettings"] as? [String: Any])
        #expect(image["Compression Quality"] is NSNumber)
        let scale = try #require(image["ImageScaleSettings"] as? [String: Any])
        #expect(scale["ImageSizeMax"] is NSNumber)

        let tuned = try PDFKitEngine.reduceFileSizeFilter(maxPixelSize: 1100, quality: 0.5)
        let tunedImage = try #require(
            ((tuned["FilterData"] as? [String: Any])?["ColorSettings"] as? [String: Any])?["ImageSettings"]
                as? [String: Any]
        )
        #expect((tunedImage["Compression Quality"] as? NSNumber)?.doubleValue == 0.5)
        #expect(((tunedImage["ImageScaleSettings"] as? [String: Any])?["ImageSizeMax"] as? NSNumber)?.intValue == 1100)
    }

    @Test func aPDFWithPhotosComesOutUnderTheTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdfWithPhoto(pages: 2, in: dir)
        let target = try fileSize(input) * 6 / 10
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(PDFDocument(url: output)?.pageCount == 2)
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    /// A target the screen optimisation alone can't reach, so the filter ladder must do it.
    @Test func theFilterLadderGoesFurtherThanCompress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdfWithPhoto(pages: 2, in: dir)
        let staging = try makeStaging(in: dir)
        let compressStep = ConversionStep(
            input: input, stagingDirectory: staging, from: try #require(registry.format(id: "pdf")),
            to: try #require(registry.format(id: "pdf")), options: PresetOptions(), operation: "compress"
        )
        let compressed = try await PDFKitEngine().convert(compressStep) { _ in }
        let target = try fileSize(compressed) * 8 / 10
        try FileManager.default.removeItem(at: compressed)

        let output = try await PDFKitEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(PDFDocument(url: output)?.pageCount == 2)
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    @Test func aTextOnlyPDFThatCannotShrinkIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 3, in: dir)
        let target = try fileSize(input) / 4
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: target, in: staging)

        let expected = "Can't get it under \(TargetSize.label(bytes: target))"
        #expect(await reason { try await PDFKitEngine().convert(step) { _ in } } == expected)
        #expect(try staged(staging).isEmpty)
    }

    @Test func aPDFAlreadyUnderTheTargetIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: 10_000_000, in: staging)

        #expect(await reason { try await PDFKitEngine().convert(step) { _ in } } == "It's already under 10 MB")
    }

}

/// One encode at a time: run in parallel beside the other suites, these HEVC encodes made an ImageIO HEIC write in
/// `ImageIOToolTests` fail ("cannot write marked.heic as HEIC"); HEIC is encoded with HEVC too.
@Suite(.serialized) struct TargetSizeVideoTests {
    private let sideways = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)

    @Test func aVideoComesOutUnderTheTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 6, withAudio: true, width: 1280, height: 720, grain: 0.08, in: dir)
        let target: Int64 = 1_500_000
        try #require(try fileSize(input) > target, "the source must start over the target")
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(output.pathExtension == "mov")
        let asset = AVURLAsset(url: output)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 6) <= 0.15)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1280, height: 720))
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    @Test func aStarvedVideoIsScaledDown() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 4, withAudio: false, width: 1280, height: 720, grain: 0.08, in: dir)
        // 250 KB over 4 s is 470 kb/s: too few bits for 720 or 540, enough for 360 (0.068 bits per pixel).
        let target: Int64 = 250_000
        try #require(try fileSize(input) > target)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 640, height: 360))
    }

    @Test func aRotatedVideoKeepsItsTransform() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(
            seconds: 2, withAudio: true, width: 640, height: 360, transform: sideways, grain: 0.08, in: dir
        )
        let target = try fileSize(input) / 2
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.preferredTransform) == sideways)
        #expect(try await video.load(.naturalSize) == CGSize(width: 640, height: 360))
    }

    /// An iPhone portrait: natural 1920x1080 turned a quarter with tx 1080. Scaled to 720 the translation must
    /// shrink too, or players that apply the matrix show the picture 360 pt off.
    @Test func aScaledPortraitVideoStaysInPlace() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let input = try await Fixtures.movie(
            seconds: 4, withAudio: false, width: 1920, height: 1080, transform: portrait, grain: 0.08, in: dir
        )
        // 1 MB over 4 s is 1.88 Mb/s: 0.03 bits per pixel at 1080, 0.068 at 720.
        let target: Int64 = 1_000_000
        try #require(try fileSize(input) > target)
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        let video = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
        #expect(size == CGSize(width: 1280, height: 720))
        #expect(CGRect(origin: .zero, size: size).applying(transform) == CGRect(x: 0, y: 0, width: 720, height: 1280))
    }

    @Test func aScaledTransformKeepsTheRotationAndItsPlace() {
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let scaled = AVFoundationEngine.scaledTransform(
            portrait, from: CGSize(width: 1920, height: 1080), to: CGSize(width: 1280, height: 720)
        )
        #expect(scaled == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0))
        let upsideDown = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        #expect(AVFoundationEngine.scaledTransform(
            upsideDown, from: CGSize(width: 1920, height: 1080), to: CGSize(width: 960, height: 540)
        ) == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 960, ty: 540))
        #expect(AVFoundationEngine.scaledTransform(
            sideways, from: CGSize(width: 640, height: 360), to: CGSize(width: 640, height: 360)
        ) == sideways)
        #expect(AVFoundationEngine.scaledTransform(
            .identity, from: CGSize(width: 1920, height: 1080), to: CGSize(width: 640, height: 360)
        ) == .identity)
    }

    /// Far noisier than any camera: the average bitrate alone overshot this twice running (310 then 295 KB for a
    /// 281 KB target); the data rate cap (P79) holds it.
    @Test func aVeryNoisyVideoStillComesOutUnderTheTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, width: 640, height: 360, grain: 0.35, in: dir)
        let target = try fileSize(input) / 2
        let staging = try makeStaging(in: dir)

        let output = try await AVFoundationEngine().convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    @Test func aVideoTooLongForItsTargetIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 4, withAudio: true, width: 640, height: 360, grain: 0.08, in: dir)
        // 40 KB over 4 s is 75 kb/s: under the 100 kb/s floor before the sound takes its share.
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: 40_000, in: staging)

        #expect(await reason { try await AVFoundationEngine().convert(step) { _ in } } == "It's too long to fit in 40 KB")
        #expect(try staged(staging).isEmpty)
    }

    @Test func aVideoAlreadyUnderTheTargetIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: 10_000_000, in: staging)

        #expect(await reason { try await AVFoundationEngine().convert(step) { _ in } } == "It's already under 10 MB")
    }

    @Test func anOvershootIsRetriedThenRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, width: 640, height: 360, grain: 0.08, in: dir)
        let target = try fileSize(input) / 2
        let staging = try makeStaging(in: dir)
        let reports = OSAllocatedUnfairLock(initialState: [target * 110 / 100, target * 105 / 100])
        let measured = OSAllocatedUnfairLock(initialState: 0)
        var engine = AVFoundationEngine()
        engine.measureTargetSize = { _ in
            measured.withLock { $0 += 1 }
            return reports.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
        }

        let step = try targetSize(input, bytes: target, in: staging)
        let reason = await reason { try await engine.convert(step) { _ in } }

        #expect(reason == "Can't get it under \(TargetSize.label(bytes: target))")
        #expect(measured.withLock { $0 } == 2)
        #expect(try staged(staging).isEmpty)
    }

    @Test func anOvershootThatTheRetryFixesIsKept() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 2, withAudio: true, width: 640, height: 360, grain: 0.08, in: dir)
        let target = try fileSize(input) / 2
        let staging = try makeStaging(in: dir)
        let first = OSAllocatedUnfairLock(initialState: true)
        var engine = AVFoundationEngine()
        engine.measureTargetSize = { url in
            if first.withLock({ let was = $0; $0 = false; return was }) { return target * 110 / 100 }
            return try AVFoundationEngine().measureTargetSize(url)
        }

        let output = try await engine.convert(try targetSize(input, bytes: target, in: staging)) { _ in }

        #expect(try fileSize(output) <= target)
        #expect(try staged(staging) == [output.lastPathComponent])
    }

    /// A URL caches its resource values; the retry rewrites the same URL, so a cached size would refuse every retry.
    @Test func theSizeIsReadAfreshEachTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "result.mov")
        try Data(count: 10).write(to: file)
        let measure = AVFoundationEngine().measureTargetSize
        #expect(try measure(file) == 10)
        try FileManager.default.removeItem(at: file)
        try Data(count: 20).write(to: file)
        #expect(try measure(file) == 20)
    }

    @Test func cancellingATargetSizeEncodeLeavesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try await Fixtures.movie(seconds: 10, withAudio: true, width: 1280, height: 720, grain: 0.08, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try targetSize(input, bytes: try fileSize(input) / 2, in: staging)
        let running = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            try await AVFoundationEngine().convert(step) { value in
                if value > 0, value < 1 { running.withLock { $0 = true } }
            }
        }
        for _ in 0..<2_000 where !running.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try #require(running.withLock { $0 }, "the encode never reported partial progress")
        task.cancel()
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try staged(staging).isEmpty)
    }
}
