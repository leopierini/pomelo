import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// A segmenter that answers a fixed page and records the size of every picture it was shown.
private final class FixedPage: DocumentSegmenting, @unchecked Sendable {
    private let page: (quad: PageQuad, confidence: Double)?
    private let lock = NSLock()
    private var shown: [CGSize] = []

    init(_ quad: PageQuad?, confidence: Double = 0.95) {
        page = quad.map { ($0, confidence) }
    }

    var sizes: [CGSize] { lock.withLock { shown } }

    func page(in image: CGImage) async throws -> (quad: PageQuad, confidence: Double)? {
        lock.withLock { shown.append(CGSize(width: image.width, height: image.height)) }
        return page
    }
}

private func quad(_ tl: (Double, Double), _ tr: (Double, Double), _ br: (Double, Double), _ bl: (Double, Double))
    -> PageQuad {
    PageQuad(
        topLeft: CGPoint(x: tl.0, y: tl.1), topRight: CGPoint(x: tr.0, y: tr.1),
        bottomRight: CGPoint(x: br.0, y: br.1), bottomLeft: CGPoint(x: bl.0, y: bl.1)
    )
}

/// Straighten document (P262): the page a segmenter reports, flattened by Core Image and written as Crop writes.
@Suite struct StraightenTests {
    /// Off-centre and skewed, every corner in its own quadrant of a 1200 x 900 picture.
    private static let skewed = quad((150, 80), (1010, 130), (1100, 820), (90, 860))

    private func runner(_ segmenter: any DocumentSegmenting) -> JobRunner {
        JobRunner(
            registry: EngineRegistry(engines: [VisionEngine(segmenter: segmenter)], priority: ["vision"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func straighten(_ input: URL, _ segmenter: any DocumentSegmenting) async throws -> FileResult {
        let preset = try #require(Preset.builtIns.first { $0.id == "straighten" })
        return try #require(await runner(segmenter).run(ConversionRequest.from(preset, inputs: [input])).first)
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

    private func stored(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// `Fixtures.png`'s gradient written as `format`, from 8-bit RGB every ImageIO writer takes.
    private func image(_ format: FormatID, width: Int, height: Int, in dir: URL) throws -> URL {
        let file = try #require(FormatRegistry.builtIn.format(id: format))
        let png = try Fixtures.png(width: width, height: height, in: dir)
        let pixels = try stored(png)
        let url = dir.appending(path: "gradient-\(UUID().uuidString.prefix(8)).\(file.extensions[0])")
        let type = try #require(file.utTypeIdentifier)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination), "\(format) source")
        return url
    }

    @Test func straightensToTheOutputSizeWithEveryCornerInPlace() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.quadrantPNG(width: 1200, height: 900, in: dir)
        let segmenter = FixedPage(Self.skewed)

        let straightened = try output(try await straighten(input, segmenter))

        #expect(segmenter.sizes == [CGSize(width: 1200, height: 900)])
        #expect(straightened.pathExtension == "png")
        #expect(straightened.deletingPathExtension().lastPathComponent.hasSuffix("-straightened"))
        let image = try stored(straightened)
        let size = StraightenRules.outputSize(for: Self.skewed)
        #expect(image.width == size.width && image.height == size.height, "\(image.width)x\(image.height)")
        // A flipped y or a mirrored corner order would show another quadrant's colour here.
        let (width, height) = (image.width, image.height)
        #expect(quadrant(of: try rgb(of: image, x: width / 5, y: height / 5)) == .topLeft)
        #expect(quadrant(of: try rgb(of: image, x: width * 4 / 5, y: height / 5)) == .topRight)
        #expect(quadrant(of: try rgb(of: image, x: width / 5, y: height * 4 / 5)) == .bottomLeft)
        #expect(quadrant(of: try rgb(of: image, x: width * 4 / 5, y: height * 4 / 5)) == .bottomRight)
    }

    @Test func orientation6PhotoIsStraightenedUpright() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 800 x 1000 with orientation 6: shown 1000 x 800, its marker in the shown top-left quarter.
        let input = try Fixtures.jpgWithOrientation(6, width: 800, height: 1000, in: dir)
        // Inside that quarter, off its centre: read with y up, it would land in the blue bottom-left quarter.
        let page = quad((40, 30), (460, 50), (470, 370), (20, 380))
        let segmenter = FixedPage(page)

        let straightened = try output(try await straighten(input, segmenter))

        #expect(segmenter.sizes == [CGSize(width: 1000, height: 800)])
        let source = try #require(CGImageSourceCreateWithURL(straightened as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let image = try stored(straightened)
        let size = StraightenRules.outputSize(for: page)
        #expect(image.width == size.width && image.height == size.height, "\(image.width)x\(image.height)")
        for (x, y) in [(1, 1), (9, 1), (5, 5), (1, 9), (9, 9)] {
            let found = try rgb(of: image, x: image.width * x / 10, y: image.height * y / 10)
            #expect(zip(found, Fixtures.orientationMarker).allSatisfy { abs($0 - $1) <= 24 }, "\(x),\(y): \(found)")
        }
    }

    @Test func noDocumentAndAlreadyFlatPublishNothing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeTempDir(); defer { try? FileManager.default.removeItem(at: staging) }
        let input = try Fixtures.png(width: 400, height: 300, in: dir)
        let png = try #require(FormatRegistry.builtIn.format(id: "png"))
        let step = ConversionStep(
            input: input, stagingDirectory: staging, from: png, to: png, options: PresetOptions(quality: 0.92),
            operation: "straighten"
        )
        let whole = quad((0, 0), (400, 0), (400, 300), (0, 300))

        await #expect(throws: ConversionError.notApplicable(reason: "No document found")) {
            try await VisionEngine(segmenter: FixedPage(nil)).convert(step) { _ in }
        }
        await #expect(throws: ConversionError.notApplicable(reason: "It's already flat")) {
            try await VisionEngine(segmenter: FixedPage(whole)).convert(step) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        #expect(reason(try await straighten(input, FixedPage(nil))) == "No document found")
        #expect(reason(try await straighten(input, FixedPage(Self.skewed, confidence: 0.4))) == "No document found")
        #expect(reason(try await straighten(input, FixedPage(whole))) == "It's already flat")
    }

    @Test func animatedGifIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = try Fixtures.animatedGIF(width: 40, height: 40, delays: [0.1, 0.1], loopCount: 0, in: dir)
        let segmenter = FixedPage(Self.skewed)
        #expect(reason(try await straighten(gif, segmenter)) == "Animated images can't be straightened")
        #expect(segmenter.sizes.isEmpty)
    }

    @Test func jpgComesOutOpaqueAndOpens() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try image("jpg", width: 1200, height: 900, in: dir)

        let straightened = try output(try await straighten(input, FixedPage(Self.skewed)))

        #expect(straightened.pathExtension == "jpg")
        let image = try stored(straightened)
        #expect([.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo), "\(image.alphaInfo)")
        let size = StraightenRules.outputSize(for: Self.skewed)
        #expect(image.width == size.width && image.height == size.height)
    }

    @Test func transparencyIsKeptWhereTheFormatHoldsIt() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 1200, height: 900, alpha: true, in: dir)

        let straightened = try output(try await straighten(input, FixedPage(Self.skewed)))

        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(try stored(straightened).alphaInfo))
    }

    @Test(arguments: ["bmp", "tga", "exr", "heic", "tiff"] as [FormatID])
    func otherFormatsWrite(format: FormatID) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try image(format, width: 1200, height: 900, in: dir)

        let straightened = try output(try await straighten(input, FixedPage(Self.skewed)))

        #expect(straightened.pathExtension == FormatRegistry.builtIn.format(id: format)?.extensions[0])
        let image = try stored(straightened)
        let size = StraightenRules.outputSize(for: Self.skewed)
        #expect(image.width == size.width && image.height == size.height, "\(format) \(image.width)x\(image.height)")
    }

    @Test func edgesAreExactlyCropsFormats() {
        let crop = ImageIOEngine().edges().filter { $0.operation == "crop" }
        let straighten = VisionEngine().edges().filter { $0.operation == "straighten" }
        #expect(!straighten.isEmpty)
        #expect(straighten.map(\.from) == crop.map(\.from))
        #expect(straighten.map(\.flags) == crop.map(\.flags))
        #expect(straighten.allSatisfy { $0.to == $0.from && $0.cost == 10 && $0.engineID == "vision" })
    }

    // MARK: Real Vision

    @Test func realSegmenterFindsThePageCornerByCorner() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let side = 1200
        let image = try stored(try Fixtures.pagePhoto(side: side, in: dir))

        let found = try #require(try await SystemDocumentSegmenter().page(in: image))

        #expect(found.confidence >= StraightenRules.minimumConfidence)
        #expect(found.quad.coverage(width: side, height: side) > StraightenRules.minimumCoverage)
        // The corners in the upright picture's pixels, y down, each where the fixture put it.
        let corners = [found.quad.topLeft, found.quad.topRight, found.quad.bottomRight, found.quad.bottomLeft]
        for (corner, expected) in zip(corners, Fixtures.pagePhotoCorners) {
            let distance = hypot(corner.x - expected.x * Double(side), corner.y - expected.y * Double(side))
            #expect(distance < 0.02 * Double(side), "\(corner) vs \(expected)")
        }
    }

    @Test func realStraightenGivesAnUprightA4Page() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pagePhoto(side: 1200, in: dir)

        let image = try stored(try output(try await straighten(input, SystemDocumentSegmenter())))

        #expect(image.height > image.width)
        #expect(abs(Double(image.height) / Double(image.width) - Double(2).squareRoot()) < 0.01, "\(image.width)x\(image.height)")
        // The heading and the paragraph sit in the page's top third; the bottom third is blank paper.
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // A bitmap context's memory starts at the top row.
        func darkPixels(rows: ClosedRange<Double>) -> Int {
            var count = 0
            for y in Int(rows.lowerBound * Double(height))..<Int(rows.upperBound * Double(height)) {
                for x in Int(0.05 * Double(width))..<Int(0.95 * Double(width)) {
                    let offset = (y * width + x) * 4
                    if Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) < 300 { count += 1 }
                }
            }
            return count
        }
        let top = darkPixels(rows: 0.05...0.3)
        let bottom = darkPixels(rows: 0.7...0.95)
        #expect(top > 1000 && bottom == 0, "top \(top), bottom \(bottom)")
    }
}
