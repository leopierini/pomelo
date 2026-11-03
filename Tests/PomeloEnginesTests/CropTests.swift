import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// A PNG written byte by byte (stored deflate blocks), for what CoreGraphics never writes: straight (unpremultiplied)
/// alpha with colour under transparent pixels, and a palette with tRNS.
private func handmadePNG(
    width: Int, height: Int, colorType: UInt8, palette: [UInt8] = [], transparency: [UInt8] = [],
    pixel: (Int, Int) -> [UInt8], to url: URL
) throws {
    var crcTable = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        crcTable[n] = c
    }
    func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) } }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        let crc = typed.reduce(UInt32(0xFFFF_FFFF)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } ^ 0xFFFF_FFFF
        return bigEndian(UInt32(body.count)) + typed + bigEndian(crc)
    }
    var raw: [UInt8] = []
    for y in 0..<height {
        raw.append(0)
        for x in 0..<width { raw += pixel(x, y) }
    }
    var deflated: [UInt8] = [0x78, 0x01]
    var offset = 0
    repeat {
        let length = min(65_535, raw.count - offset)
        deflated.append(offset + length == raw.count ? 1 : 0)
        deflated += [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)]
        deflated += raw[offset..<(offset + length)]
        offset += length
    } while offset < raw.count
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in raw { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    deflated += bigEndian(b << 16 | a)
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png += chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, colorType, 0, 0, 0])
    if !palette.isEmpty { png += chunk("PLTE", palette) }
    if !transparency.isEmpty { png += chunk("tRNS", transparency) }
    png += chunk("IDAT", deflated) + chunk("IEND", [])
    try Data(png).write(to: url)
}

/// The 8-bit sRGB colour of the pixel at (`x`, `y`) of `image`, counted from its top-left corner.
func rgb(of image: CGImage, x: Int, y: Int) throws -> [Int] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        // Shifts the image so its pixel (x, y) lands on the context's only pixel; a context's origin is bottom left.
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return true
    }
    #expect(drawn)
    return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
}

private func near(_ found: [Int], _ expected: [Int], _ tolerance: Int) -> Bool {
    zip(found, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

/// The quadrant whose colour `found` is closest to. A video's colour pipeline shifts the colours by up to about 40
/// (green came back 81, 226, 72), and lossy or paletted images a little, but never closer to another quadrant's.
func quadrant(of found: [Int]) -> Fixtures.Quadrant? {
    Fixtures.Quadrant.allCases.min { a, b in
        zip(found, a.rgb).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
            < zip(found, b.rgb).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
    }
}

/// The quadrant shown at (`x`, `y`) of `url`, decoded as the editor shows it.
private func shownQuadrant(of url: URL, x: Int, y: Int) throws -> Fixtures.Quadrant? {
    quadrant(of: try rgb(of: shownImage(url), x: x, y: y))
}

/// The image as stored (no orientation applied).
private func storedImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The image as shown: its EXIF orientation applied.
private func shownImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 10_000,
    ]
    return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
}

private func properties(of url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}

/// A movie's frame at `seconds` as players show it (preferred transform applied).
func shownFrame(_ url: URL, at seconds: Double = 0.5) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// A movie's first video track: its stored size and its size as shown.
func videoSizes(_ url: URL) async throws -> (stored: CGSize, shown: CGSize) {
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
    let shown = CGRect(origin: .zero, size: size).applying(transform)
    return (size, CGSize(width: shown.width.rounded(), height: shown.height.rounded()))
}

/// Crop keeps exactly the area the editor showed, upright, for images and video.
/// Serialized for the reason `FFmpegToolTests` is: parallel hardware-encoded movies starve ImageIOToolTests' HEIC encoder.
@Suite(.serialized) struct CropTests {
    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    /// Runs the built-in Crop preset with `edit` through the whole runner and returns the first result.
    private func crop(_ input: URL, _ edit: EditSpec?) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == "crop" })
        preset.options.edit = edit
        return try #require(await runner().run(ConversionRequest.from(preset, inputs: [input])).first)
    }

    private func crop(_ input: URL, x: Double, y: Double, width: Double, height: Double) async throws -> URL {
        try output(try await crop(input, .crop(UnitRect(x: x, y: y, width: width, height: height))))
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

    // MARK: Fixtures

    @Test(arguments: 1...8)
    func theOrientationMarkerShowsAtTheTopLeft(orientation: Int) throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.jpgWithOrientation(orientation, width: 400, height: 300, in: dir)
        let shown = try shownImage(photo)
        let (width, height) = (shown.width, shown.height)
        #expect(try near(rgb(of: shown, x: width / 4, y: height / 4), Fixtures.orientationMarker, 12))
        for (x, y) in [(width * 3 / 4, height / 4), (width / 4, height * 3 / 4), (width * 3 / 4, height * 3 / 4)] {
            #expect(try near(rgb(of: shown, x: x, y: y), Fixtures.orientationBackground, 12), "\(orientation) \(x),\(y)")
        }
    }

    @Test func quadrantFixturesShowTheirColoursWhereNamed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try storedImage(try Fixtures.quadrantPNG(width: 200, height: 100, in: dir))
        let movie = try await shownFrame(try await Fixtures.quadrantMovie(
            width: 320, height: 180, seconds: 1, rotated90: true, in: dir
        ))
        #expect(movie.width == 180 && movie.height == 320)
        let spots: [(Fixtures.Quadrant, Int, Int)] = [
            (.topLeft, 1, 1), (.topRight, 3, 1), (.bottomLeft, 1, 3), (.bottomRight, 3, 3),
        ]
        for (expected, column, row) in spots {
            #expect(try rgb(of: png, x: png.width * column / 4, y: png.height * row / 4) == expected.rgb)
            let found = try rgb(of: movie, x: movie.width * column / 4, y: movie.height * row / 4)
            #expect(quadrant(of: found) == expected, "\(expected): \(found)")
        }
    }

    // MARK: Images

    @Test func croppingAPNGKeepsExactlyTheRect() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.quadrantPNG(width: 200, height: 100, in: dir)

        let cropped = try await crop(input, x: 0, y: 0, width: 0.5, height: 1)

        #expect(cropped.pathExtension == "png")
        #expect(cropped.deletingPathExtension().lastPathComponent.hasSuffix("-cropped"))
        let image = try storedImage(cropped)
        #expect(image.width == 100 && image.height == 100)
        for (x, y, expected) in [(0, 0, Fixtures.Quadrant.topLeft), (99, 49, .topLeft), (0, 50, .bottomLeft),
                                 (99, 99, .bottomLeft)] {
            #expect(try rgb(of: image, x: x, y: y) == expected.rgb, "\(x),\(y)")
        }
    }

    /// `image` cropped as the crop edit does, then written as `type`.
    private func encodedCrop(_ image: CGImage, as type: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        let cut = try #require(image.cropping(to: CGRect(x: 10, y: 20, width: 200, height: 100)))
        CGImageDestinationAddImage(destination, cut, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Whether `file` decodes straight is `straight`, and either way its output equals the thumbnail path's.
    private func expectTheThumbnailPathsBytes(_ file: URL, straight: Bool) throws {
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(OrientedImage.decodesStraight(source) == straight, "\(file.lastPathComponent)")
        let upright = try OrientedImage.decodeUpright(source)
        let thumbnailPath = try OrientedImage.decodeUpright(source, straight: false)
        for type in ["public.png", "public.jpeg"] {
            #expect(try encodedCrop(upright, as: type) == encodedCrop(thumbnailPath, as: type),
                    "\(file.lastPathComponent) \(type)")
        }
    }

    /// An upright, opaque 8-bit sRGB PNG is decoded straight, which writes the same bytes as the full-size
    /// thumbnail path; a JPEG, which that path decodes differently, stays on it.
    @Test func anOpaquePNGIsDecodedStraightAndWritesTheSameBytes() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try expectTheThumbnailPathsBytes(
            try Fixtures.photo(width: 400, height: 300, type: "public.png", ext: "png", in: dir), straight: true
        )
        try expectTheThumbnailPathsBytes(try Fixtures.png(width: 400, height: 300, in: dir), straight: true)
        try expectTheThumbnailPathsBytes(
            try Fixtures.photo(width: 400, height: 300, type: "public.jpeg", ext: "jpg", in: dir), straight: false
        )
    }

    /// P150: the thumbnail path premultiplies a partly transparent picture, so one keeps that path and its output.
    /// Straight alpha with colour under clear pixels, and a palette with tRNS (ImageIO expands it to RGBA).
    @Test func aPartlyTransparentPNGKeepsTheThumbnailPathsBytes() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rgba = dir.appending(path: "straight-alpha.png")
        try handmadePNG(width: 240, height: 160, colorType: 6, pixel: { x, y in
            [UInt8(x), UInt8(y), UInt8((x * y) % 256), UInt8((x + 3 * y) % 256)]
        }, to: rgba)
        let paletted = dir.appending(path: "palette-trns.png")
        let colours: [UInt8] = (0..<16).flatMap { (index: Int) -> [UInt8] in
            [UInt8(index * 16), UInt8(255 - index * 16), UInt8((index * 53) % 256)]
        }
        try handmadePNG(width: 240, height: 160, colorType: 3, palette: colours,
                        transparency: (0..<16).map { UInt8($0 * 17) }, pixel: { x, y in [UInt8((x / 15 + y / 10) % 16)] },
                        to: paletted)
        try expectTheThumbnailPathsBytes(rgba, straight: false)
        try expectTheThumbnailPathsBytes(paletted, straight: false)
    }

    @Test func croppingARotatedPhotoKeepsWhatWasShown() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 × 300 with orientation 6: shown 300 × 400, the marker in the shown top-left quarter.
        let input = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)

        let cropped = try await crop(input, x: 0, y: 0, width: 0.5, height: 0.5)

        #expect(((try properties(of: cropped))[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let image = try storedImage(cropped)
        #expect(image.width == 150 && image.height == 200)
        // The whole output is the marker: its centre and each corner, clear of the JPEG's edge blocks.
        for (x, y) in [(75, 100), (8, 8), (141, 8), (8, 191), (141, 191)] {
            #expect(try near(rgb(of: image, x: x, y: y), Fixtures.orientationMarker, 12), "\(x),\(y)")
        }

        let opposite = try storedImage(try await crop(input, x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        #expect(opposite.width == 150 && opposite.height == 200)
        #expect(try near(rgb(of: opposite, x: 8, y: 8), Fixtures.orientationBackground, 12))
    }

    @Test func croppedJPEGHasNoStaleThumbnail() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "with-thumbnail.jpg")
        // Large enough that ImageIO's thumbnail is smaller than the cropped picture, so the check below can see one.
        let pixels = try storedImage(try Fixtures.quadrantPNG(width: 2000, height: 1500, in: dir))
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try thumbnail(of: input) != nil, "the source carries an EXIF thumbnail")

        let cropped = try await crop(input, x: 0.5, y: 0, width: 0.5, height: 0.5)

        #expect(try thumbnail(of: cropped) == nil)
        #expect(Fixtures.imageSize(cropped) == CGSize(width: 1000, height: 750))
    }

    /// An embedded thumbnail: what ImageIO hands back, without making one, that is smaller than the image.
    private func thumbnail(of url: URL) throws -> CGImage? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let size = try #require(Fixtures.imageSize(url))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)) * 4,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGFloat(image.width) != size.width || CGFloat(image.height) != size.height else { return nil }
        return image
    }

    @Test func croppingAnAnimatedGIFIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = try Fixtures.animatedGIF(width: 40, height: 40, delays: [0.1, 0.1], loopCount: 0, in: dir)
        let result = try await crop(gif, .crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(reason(result) == "Animated images can't be cropped")
    }

    @Test func theWholeImageOrNoEditIsNothingToCrop() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Fixtures.quadrantPNG(width: 200, height: 100, in: dir)
        #expect(reason(try await crop(png, nil)) == "Nothing to crop")
        #expect(reason(try await crop(png, .crop(UnitRect(x: 0, y: 0, width: 1, height: 1)))) == "Nothing to crop")
        // Within one pixel of the whole picture.
        #expect(reason(try await crop(png, .crop(UnitRect(x: 0.005, y: 0, width: 0.995, height: 1))))
                == "Nothing to crop")
        #expect(reason(try await crop(png, .crop(UnitRect(x: 2, y: 2, width: 0.5, height: 0.5))))
                == "The area is too small")
        #expect(reason(try await crop(png, .trim(TimeRange(start: 0, end: 1)))) == "Nothing to crop")
    }

    // MARK: Every ImageIO edit format (P84)

    /// The quadrant picture written as `format` by ImageIO, from 8-bit RGB pixels every writer takes. With `grain`
    /// each pixel is shifted by up to ±16, so a lossy encoder has something to spend bytes on.
    private static func quadrantImage(
        _ format: FormatID, width: Int, height: Int, grain: Bool = false, in dir: URL
    ) throws -> URL {
        let file = try #require(FormatRegistry.builtIn.format(id: format))
        let type = try #require(file.utTypeIdentifier)
        var pixels = try storedImage(try Fixtures.quadrantPNG(width: width, height: height, in: dir))
        if grain { pixels = try grained(pixels) }
        let url = dir.appending(path: "quadrants-\(UUID().uuidString.prefix(8)).\(file.extensions[0])")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination), "\(format) source")
        return url
    }

    private static func grained(_ image: CGImage) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        var state: UInt64 = 0x4752_4149
        for row in 0..<image.height {
            for column in 0..<image.width {
                for channel in 0..<3 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let index = row * context.bytesPerRow + column * 4 + channel
                    bytes[index] = UInt8(clamping: Int(bytes[index]) + Int(state >> 59) - 16)
                }
            }
        }
        return try #require(context.makeImage())
    }

    static let cropFormats = ImageIOEngine().edges().filter { $0.operation == "crop" }.map(\.from)
    static let targetSizeFormats = ImageIOEngine().edges().filter { $0.operation == "target-size" }.map(\.from)

    @Test func iconsAreNotCroppedOrCompressedToASize() {
        #expect(!Self.cropFormats.isEmpty && !Self.targetSizeFormats.isEmpty)
        for icon: FormatID in ["ico", "icns", "pdf"] {
            #expect(!Self.cropFormats.contains(icon) && !Self.targetSizeFormats.contains(icon), "\(icon)")
        }
    }

    /// Each crop edge writes a file ImageIO reopens, of the cut's size and with the cut's pixels.
    @Test(arguments: cropFormats)
    func everyCropFormatWritesWhatItCut(format: FormatID) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Self.quadrantImage(format, width: 96, height: 64, in: dir)

        let cropped = try await crop(input, x: 0, y: 0, width: 0.5, height: 1)

        #expect(Fixtures.imageSize(cropped) == CGSize(width: 48, height: 64), "\(format)")
        #expect(try shownQuadrant(of: cropped, x: 12, y: 12) == .topLeft, "\(format)")
        #expect(try shownQuadrant(of: cropped, x: 36, y: 52) == .bottomLeft, "\(format)")
    }

    /// Each target-size edge writes a file ImageIO reopens, under the target and with the picture's pixels.
    @Test(arguments: targetSizeFormats)
    func everyTargetSizeFormatWritesAPicture(format: FormatID) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Self.quadrantImage(format, width: 640, height: 480, grain: true, in: dir)
        let bytes = try #require(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var preset = try #require(Preset.builtIns.first { $0.id == "compress-to-size" })
        preset.options.targetBytes = Int64(bytes - 1)

        let result = try #require(await runner().run(ConversionRequest.from(preset, inputs: [input])).first)

        let output = try output(result)
        let written = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(written < bytes, "\(format)")
        let size = try #require(Fixtures.imageSize(output))
        #expect(try shownQuadrant(of: output, x: Int(size.width) / 4, y: Int(size.height) / 4) == .topLeft, "\(format)")
        #expect(try shownQuadrant(of: output, x: Int(size.width) * 3 / 4, y: Int(size.height) * 3 / 4) == .bottomRight,
                "\(format)")
    }

    // MARK: Video

    @Test func croppingAVideoKeepsTheRect() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.quadrantMovie(width: 640, height: 360, seconds: 2, rotated90: false, in: dir)

        let cropped = try await crop(movie, x: 0, y: 0, width: 0.5, height: 0.5)

        #expect(cropped.pathExtension == "mov")
        #expect(cropped.deletingPathExtension().lastPathComponent.hasSuffix("-cropped"))
        #expect(try await videoSizes(cropped).shown == CGSize(width: 320, height: 180))
        let frame = try await shownFrame(cropped)
        for (x, y) in [(160, 90), (12, 12), (307, 167)] {
            #expect(try quadrant(of: rgb(of: frame, x: x, y: y)) == .topLeft, "\(x),\(y)")
        }
        let duration = try await AVURLAsset(url: cropped).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        #expect(try await !AVURLAsset(url: cropped).loadTracks(withMediaType: .audio).isEmpty, "the sound is kept")
    }

    @Test func croppingAPortraitVideoKeepsWhatWasShown() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 640 × 360 with an iPhone portrait's transform: shown 360 × 640.
        let movie = try await Fixtures.quadrantMovie(width: 640, height: 360, seconds: 1, rotated90: true, in: dir)
        #expect(try await videoSizes(movie).shown == CGSize(width: 360, height: 640))

        let topLeft = try await crop(movie, x: 0, y: 0, width: 0.5, height: 0.5)
        let bottomRight = try await crop(movie, x: 0.5, y: 0.5, width: 0.5, height: 0.5)

        for (cropped, expected) in [(topLeft, Fixtures.Quadrant.topLeft), (bottomRight, .bottomRight)] {
            let sizes = try await videoSizes(cropped)
            // Upright in its pixels: the output needs no rotation of its own.
            #expect(sizes.stored == CGSize(width: 180, height: 320))
            #expect(sizes.shown == CGSize(width: 180, height: 320))
            let frame = try await shownFrame(cropped)
            for (x, y) in [(90, 160), (12, 12), (167, 307)] {
                #expect(try quadrant(of: rgb(of: frame, x: x, y: y)) == expected, "\(expected) \(x),\(y)")
            }
        }
    }

    @Test func videoCropSizesAreEven() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.quadrantMovie(width: 640, height: 360, seconds: 1, rotated90: false, in: dir)

        // 321.3 × 181 px.
        let cropped = try await crop(movie, x: 0.1, y: 0.1, width: 321.3 / 640, height: 181.0 / 360)

        #expect(try await videoSizes(cropped).shown == CGSize(width: 320, height: 180))
    }

    @Test func videoSizesAreEvenAndAtLeastSixteen() throws {
        func pixels(_ rect: UnitRect, _ width: Int, _ height: Int) throws -> CGRect {
            try CropEdit.videoPixels(.crop(rect), width: width, height: height)
        }
        #expect(try pixels(UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), 1080, 1920)
                == CGRect(x: 270, y: 480, width: 540, height: 960))
        #expect(try pixels(UnitRect(x: 0, y: 0, width: 321.3 / 640, height: 0.5), 640, 360).size
                == CGSize(width: 320, height: 180))
        // A sliver grows to 16 × 16, kept inside the picture.
        #expect(try pixels(UnitRect(x: 0.999, y: 0.999, width: 0.001, height: 0.001), 640, 360)
                == CGRect(x: 624, y: 344, width: 16, height: 16))
        #expect(throws: ConversionError.self) { try pixels(UnitRect(x: 0, y: 0, width: 1, height: 1), 640, 360) }
    }

    @Test func theWholeVideoIsNothingToCrop() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.quadrantMovie(width: 320, height: 180, seconds: 1, rotated90: true, in: dir)
        #expect(reason(try await crop(movie, .crop(UnitRect(x: 0, y: 0, width: 1, height: 1)))) == "Nothing to crop")
        #expect(reason(try await crop(movie, nil)) == "Nothing to crop")
    }

    // MARK: Routes

    @Test func cropRoutesToImageIOAndAVFoundation() async throws {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()
        for (format, engine, lossy) in [("png", "imageio", false), ("jpg", "imageio", true), ("heic", "imageio", true),
                                        ("tiff", "imageio", false), ("gif", "imageio", false),
                                        ("mov", "avfoundation", true), ("mp4", "avfoundation", true),
                                        ("m4v", "avfoundation", true)] {
            let route = try #require(planner.route(from: FormatID(format), operation: "crop", to: nil), "\(format)")
            #expect(route.edges.map(\.engineID) == [EngineID(engine)], "\(format)")
            #expect(route.edges.first?.flags.contains(.lossy) == lossy, "\(format)")
        }
        #expect(planner.route(from: "pdf", operation: "crop", to: nil) == nil)
    }
}
