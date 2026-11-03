import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct ImageIOEngineTests {
    private let registry = FormatRegistry.builtIn

    private func step(
        _ input: URL, to target: FormatID, in staging: URL, options: PresetOptions = PresetOptions()
    ) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target))
        return ConversionStep(input: input, stagingDirectory: staging, from: from, to: to, options: options)
    }

    /// Decodes `url` into 8-bit RGBA and returns the pixel at (0, 0).
    private func firstPixel(of url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Draw so that the image's top-left pixel lands on the 1x1 context.
            context.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return pixel
    }

    private func fileSize(_ url: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try #require(size).intValue
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// A PNG of random bytes, which JPEG cannot compress well, so quality changes the size noticeably.
    private func noisePNG(side: Int, in directory: URL) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0..<(side * side * 4)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try #require(context.makeImage())
        }
        let url = directory.appending(path: "noise.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func edgesComeFromImageIOCapabilities() {
        let edges = ImageIOEngine().edges().filter { $0.operation == nil }
        #expect(edges.contains { $0.from == "heic" && $0.to == "png" })
        #expect(edges.contains { $0.from == "png" && $0.to == "png" })  // self edge for re-encode tools
        #expect(edges.contains { $0.to == "webp" } == false)  // WebP comes from the cwebp plugin
        #expect(edges.filter { $0.to == "jpg" }.allSatisfy { $0.flags.contains(.lossy) && $0.cost == 10 })
        #expect(edges.allSatisfy { $0.engineID == "imageio" && $0.cost == 10 })
        #expect(edges.filter { $0.to == "pdf" }.allSatisfy { $0.flags.contains(.directOnly) })
        #expect(edges.filter { $0.to == "png" }.allSatisfy { !$0.flags.contains(.lossy) })
    }

    @Test func pngToJpg() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 40, height: 30, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let conversion = try step(input, to: "jpg", in: staging)
        let output = try await ImageIOEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(output.deletingLastPathComponent() == staging)
        #expect(Fixtures.imageUTType(output) == "public.jpeg")
        #expect(Fixtures.imageSize(output) == Fixtures.imageSize(input))
    }

    @Test func alphaFlattenedOnWhiteForJPEG() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 10, height: 10, alpha: true, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let output = try await ImageIOEngine().convert(try step(input, to: "jpg", in: staging)) { _ in }

        let pixel = try firstPixel(of: output)
        #expect(pixel[0] >= 250 && pixel[1] >= 250 && pixel[2] >= 250)
    }

    @Test func maxPixelSizeDownscales() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 200, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "png", in: staging, options: PresetOptions(maxPixelSize: 100))
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 100, height: 50))
    }

    @Test func scaleHalves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 200, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "png", in: staging, options: PresetOptions(scale: 0.5))
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 200, height: 100))
    }

    @Test func lowerQualityIsSmaller() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try noisePNG(side: 1000, in: dir)
        let lowStaging = dir.appending(path: "low", directoryHint: .isDirectory)
        let highStaging = dir.appending(path: "high", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lowStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: highStaging, withIntermediateDirectories: true)

        let engine = ImageIOEngine()
        let low = try await engine.convert(try step(input, to: "jpg", in: lowStaging, options: PresetOptions(quality: 0.3))) { _ in }
        let high = try await engine.convert(try step(input, to: "jpg", in: highStaging, options: PresetOptions(quality: 0.95))) { _ in }

        let lowSize = try fileSize(low)
        let highSize = try fileSize(high)
        #expect(lowSize < highSize)
    }

    @Test func stripMetadataRemovesGPS() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #expect(try properties(of: input)[kCGImagePropertyGPSDictionary] != nil)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "jpg", in: staging, options: PresetOptions(stripMetadata: true))
        ) { _ in }

        let result = try properties(of: output)
        #expect(result[kCGImagePropertyGPSDictionary] == nil)
        // The encoder may add its own technical Exif entries, but nothing of the source's survives.
        let exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func keepsMetadataByDefault() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "jpg", in: staging, options: PresetOptions(stripMetadata: false))
        ) { _ in }

        let gps = try #require(try properties(of: output)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLatitude] as? Double == 45.0)
    }

    // MARK: Orientation and sizing

    private func staging(in dir: URL) throws -> URL {
        let url = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func orientation(of url: URL) throws -> Int? {
        (try properties(of: url)[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    }

    /// PNG could store the tag (eXIf), but many readers ignore it, and PNG is the hop to cwebp, so it is baked in.
    @Test(arguments: ["bmp", "gif", "png"] as [FormatID])
    func orientationIsBakedInForTargetsThatCannotStoreIt(target: FormatID) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)
        #expect(Fixtures.imageSize(input) == CGSize(width: 40, height: 20))

        let output = try await ImageIOEngine().convert(try step(input, to: target, in: try staging(in: dir))) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 20, height: 40))
        #expect((try orientation(of: output) ?? 1) == 1)
    }

    @Test func orientationIsBakedInForPDF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: "pdf", in: try staging(in: dir))) { _ in }

        let page = try #require(PDFDocument(url: output)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 20, height: 40))
    }

    @Test func orientationIsUprightForAVIF() async throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard writable.contains("public.avif") else { return }  // this macOS cannot write AVIF
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: "avif", in: try staging(in: dir))) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 20, height: 40))
        #expect((try orientation(of: output) ?? 1) == 1)
    }

    @Test func orientationIsUprightForJPEG2000() async throws {
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard writable.contains("public.jpeg-2000") else { return }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: "jp2", in: try staging(in: dir))) { _ in }

        // The JPEG 2000 encoder fails when the orientation tag is set, so the rotation must be in the pixels.
        #expect(Fixtures.imageSize(output) == CGSize(width: 20, height: 40))
        #expect((try orientation(of: output) ?? 1) == 1)
    }

    @Test(arguments: ["jpg", "tiff", "heic"] as [FormatID])
    func orientationIsKeptAsTagWhereTheTargetStoresIt(target: FormatID) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: target, in: try staging(in: dir))) { _ in }

        #expect(try orientation(of: output) == 6)
        #expect(Fixtures.imageSize(output) == CGSize(width: 40, height: 20))
    }

    @Test func thumbnailPathBakesOrientationIn() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithOrientation(6, width: 40, height: 20, in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "png", in: try staging(in: dir), options: PresetOptions(maxPixelSize: 30))
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 15, height: 30))
        #expect(try orientation(of: output) == 1)
    }

    @Test func neverUpscales() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 200, in: dir)
        let engine = ImageIOEngine()

        let capped = try await engine.convert(
            try step(input, to: "png", in: try staging(in: dir), options: PresetOptions(maxPixelSize: 1000))
        ) { _ in }
        #expect(Fixtures.imageSize(capped) == CGSize(width: 400, height: 200))

        let scaled = try await engine.convert(
            try step(input, to: "jpg", in: try staging(in: dir), options: PresetOptions(scale: 2))
        ) { _ in }
        #expect(Fixtures.imageSize(scaled) == CGSize(width: 400, height: 200))
    }

    @Test func smallerOfScaleAndMaxPixelSizeWins() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 200, in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "png", in: try staging(in: dir), options: PresetOptions(scale: 0.5, maxPixelSize: 50))
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 50, height: 25))
    }

    // MARK: Animated GIF

    private struct GIFFrame: Equatable {
        let size: CGSize
        let delay: Double
    }

    /// The size and unclamped delay of every frame of the GIF at `url`, and its loop count.
    private func gifFrames(of url: URL) throws -> (frames: [GIFFrame], loopCount: Int?) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loopCount = ((file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        let frames = try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber).doubleValue
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
            // Hundredths of a second, as GIF stores them.
            return GIFFrame(size: CGSize(width: width, height: height), delay: (delay * 100).rounded() / 100)
        }
        return (frames, loopCount)
    }

    /// The 8-bit RGBA centre pixel of frame `index` of the image at `url`.
    private func centrePixel(of url: URL, frame index: Int) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Draw so that the image's centre pixel lands on the 1x1 context.
            let x = -CGFloat(image.width / 2), y = -CGFloat(image.height / 2)
            context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        #expect(drawn)
        return pixel
    }

    /// Expects every frame of the image at `url` to show `Fixtures.frameColor` of its index.
    private func expectFrameColours(of url: URL, count: Int) throws {
        for index in 0..<count {
            let pixel = try centrePixel(of: url, frame: index)
            let expected = try #require(Fixtures.frameColor(index).components).prefix(3).map { Int(($0 * 255).rounded()) }
            let matches = zip(pixel.prefix(3), expected).allSatisfy { abs(Int($0) - $1) <= 16 }
            #expect(matches, "frame \(index): expected \(expected), got \(pixel)")
        }
    }

    @Test func halfSizeAnimatedGIFStaysAnimated() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.animatedGIF(width: 64, height: 48, delays: [0.1, 0.25, 0.4], loopCount: 3, in: dir)
        let original = try gifFrames(of: input)
        #expect(original.frames.map(\.delay) == [0.1, 0.25, 0.4])
        #expect(original.loopCount == 3)

        let output = try await ImageIOEngine().convert(
            try step(input, to: "gif", in: try staging(in: dir), options: PresetOptions(scale: 0.5))
        ) { _ in }

        let converted = try gifFrames(of: output)
        #expect(converted.frames == [0.1, 0.25, 0.4].map { GIFFrame(size: CGSize(width: 32, height: 24), delay: $0) })
        #expect(converted.loopCount == 3)
        try expectFrameColours(of: output, count: 3)
    }

    @Test func animatedGIFKeepsItsFramesAtFullSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.animatedGIF(width: 20, height: 10, delays: [0.5, 0.2], loopCount: 0, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: "gif", in: try staging(in: dir))) { _ in }

        let converted = try gifFrames(of: output)
        #expect(converted.frames == [0.5, 0.2].map { GIFFrame(size: CGSize(width: 20, height: 10), delay: $0) })
        #expect(converted.loopCount == 0)
        try expectFrameColours(of: output, count: 2)
    }

    @Test func animatedGIFToPNGKeepsTheFirstFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.animatedGIF(width: 16, height: 16, delays: [0.1, 0.2, 0.3], loopCount: 0, in: dir)

        let output = try await ImageIOEngine().convert(try step(input, to: "png", in: try staging(in: dir))) { _ in }

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let pixel = try firstPixel(of: output)
        #expect(pixel[0] >= 250 && pixel[1] <= 5 && pixel[2] <= 5, "expected frame 0 (red), got \(pixel)")
    }

    @Test func multiPageSourceWithoutTimingGivesASingleFrameGIF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.multiPageTIFF(width: 24, height: 16, pages: 2, in: dir)
        let pages = try #require(CGImageSourceCreateWithURL(input as CFURL, nil))
        #expect(CGImageSourceGetCount(pages) == 2)

        let output = try await ImageIOEngine().convert(try step(input, to: "gif", in: try staging(in: dir))) { _ in }

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(Fixtures.imageSize(output) == CGSize(width: 24, height: 16))
        try expectFrameColours(of: output, count: 1)
    }
}
