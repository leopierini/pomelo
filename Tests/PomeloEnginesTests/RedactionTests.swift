import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// Every pixel of an image as 8-bit sRGB RGBA, rows counted from the top.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        self.bytes = bytes
    }

    /// The file's primary image as stored: no orientation applied.
    init(_ url: URL) throws {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        try self.init(try #require(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)))
    }

    subscript(x: Int, y: Int) -> [Int] {
        let offset = (y * width + x) * 4
        return bytes[offset..<(offset + 4)].map(Int.init)
    }
}

private func near(_ found: [Int], _ expected: [Int], _ tolerance: Int) -> Bool {
    zip(found, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

private func properties(of url: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}

private func imageCount(_ url: URL) throws -> Int {
    CGImageSourceGetCount(try #require(CGImageSourceCreateWithURL(url as CFURL, nil)))
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

private func disparity(in url: URL) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
}

/// Writes `image` as `type` with `properties`, the way a camera or another app would.
private func write(_ image: CGImage, _ type: String, _ ext: String, properties: [CFString: Any]?, in dir: URL) throws -> URL {
    let url = dir.appending(path: "source-\(UUID().uuidString.prefix(8)).\(ext)")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    try #require(CGImageDestinationFinalize(destination))
    return url
}

private func storedImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Redaction replaces the pixels under each box in a new bitmap and writes nothing but that bitmap.
/// Serialized for the reason `CropTests` is: parallel HEIC encodes starve each other.
@Suite(.serialized) struct RedactionTests {
    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    /// Runs the built-in Redact preset with `edit` through the whole runner and returns the first result.
    private func redact(_ input: URL, _ edit: EditSpec?) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == "redact" })
        preset.options.edit = edit
        return try #require(await runner().run(ConversionRequest.from(preset, inputs: [input])).first)
    }

    private func redact(_ input: URL, _ style: RedactionStyle, _ boxes: UnitRect...) async throws -> URL {
        try output(try await redact(input, .redact(RedactionSpec(boxes: boxes, style: style))))
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

    private static let middle = UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    private static let topLeftQuarter = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)

    // MARK: Pixels

    @Test func fillReplacesEveryPixelInTheBox() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 200, height: 200, in: dir)

        let redacted = try await redact(input, .fill, Self.middle)

        #expect(redacted.pathExtension == "png")
        #expect(redacted.deletingPathExtension().lastPathComponent.hasSuffix("-redacted"))
        let (before, after) = (try Pixels(input), try Pixels(redacted))
        #expect(after.width == 200 && after.height == 200)
        for y in 50..<150 {
            for x in 50..<150 where after[x, y] != [0, 0, 0, 255] {
                Issue.record("pixel \(x),\(y) is \(after[x, y])")
                return
            }
        }
        for (x, y) in [(10, 10), (49, 49), (150, 150), (49, 100), (100, 150), (199, 199)] {
            #expect(after[x, y] == before[x, y], "\(x),\(y)")
        }
    }

    @Test func pixelateMakesFlatBlocks() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 200, height: 200, in: dir)

        let redacted = try await redact(input, .pixelate, Self.middle)

        let (before, after) = (try Pixels(input), try Pixels(redacted))
        // A 100 px box, side max(16, ceil(100 / 6)) = 17: 100 / 17 = 5 near-equal blocks of 20 px (P86).
        let starts = [50, 70, 90, 110, 130]
        #expect(ImageIOEngine.blocks(from: 50, length: 100, side: 17).map(\.lowerBound) == starts)
        var colours: Set<[Int]> = []
        for top in starts {
            for left in starts {
                let (right, bottom) = (left + 20, top + 20)
                let colour = after[left, top]
                var sums = [0, 0, 0]
                for y in top..<bottom {
                    for x in left..<right {
                        #expect(after[x, y] == colour, "block \(left),\(top) pixel \(x),\(y)")
                        for channel in 0..<3 { sums[channel] += before[x, y][channel] }
                    }
                }
                let count = (right - left) * (bottom - top)
                let mean = sums.map { Int((Double($0) / Double(count)).rounded()) }
                #expect(near(colour, mean + [255], 1), "block \(left),\(top): \(colour), mean \(mean)")
                colours.insert(colour)
            }
        }
        #expect(colours.count >= 2)
        for (x, y) in [(49, 100), (150, 100), (100, 49), (100, 150)] {
            #expect(after[x, y] == before[x, y], "\(x),\(y)")
        }
    }

    /// P86: no block is thinner than the side unless the box is, so a length one past a multiple of the side
    /// (17, 33, 81 with side 16) leaves no sliver of single source pixels, and a box under 2 px is filled.
    @Test func blocksAreNearEqualAndNeverThinnerThanTheSide() {
        for length in 1...400 {
            let side = max(16, Int((Double(length) / 6).rounded(.up)))
            let blocks = ImageIOEngine.blocks(from: 7, length: length, side: side)
            #expect(blocks.first?.lowerBound == 7 && blocks.last?.upperBound == 7 + length, "\(length)")
            #expect(zip(blocks, blocks.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "\(length)")
            #expect(blocks.allSatisfy { $0.count >= min(side, length) }, "\(length): \(blocks.map(\.count))")
            #expect(blocks.map(\.count).max()! - blocks.map(\.count).min()! <= 1, "\(length)")
        }
    }

    @Test(arguments: [false, true])
    func pixelateLeavesNoSourcePixel(checkerboard: Bool) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = checkerboard
            ? try write(try Self.checkerboard(width: 200, height: 200), "public.png", "png", properties: nil, in: dir)
            : try Fixtures.noisyPNG(width: 200, height: 200, in: dir)
        let before = try Pixels(input)
        // (x, y, width, height) in pixels: each side is a multiple of 16 plus one, or under 2 px.
        let boxes = [(10, 10, 17, 17), (40, 10, 33, 33), (10, 60, 81, 81), (100, 10, 33, 17), (150, 150, 1, 1),
                     (160, 100, 1, 40), (100, 190, 40, 1)]
        for (x, y, width, height) in boxes {
            let rect = UnitRect(
                x: Double(x) / 200, y: Double(y) / 200, width: Double(width) / 200, height: Double(height) / 200
            )
            let after = try Pixels(try await redact(input, .pixelate, rect))
            var kept: [String] = []
            for row in y..<(y + height) {
                for column in x..<(x + width) where after[column, row] == before[column, row] {
                    kept.append("\(column),\(row)")
                }
            }
            #expect(kept.isEmpty, "\(checkerboard ? "checkerboard" : "noise") \(width)x\(height): \(kept.prefix(5))")
        }
    }

    /// White and blue alternating every pixel: a block of two or more pixels averages to a colour neither has, and
    /// neither is the black a thin box is filled with.
    private static func checkerboard(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 60 / 255, green: 120 / 255, blue: 200 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        for y in 0..<height {
            for x in 0..<width where (x + y) % 2 == 0 { context.fill(CGRect(x: x, y: y, width: 1, height: 1)) }
        }
        return try #require(context.makeImage())
    }

    @Test func boxesRoundOutwards() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 200, height: 200, in: dir)

        // 50.04...149.96 px on each axis: columns and rows 50...149 are hidden.
        let redacted = try await redact(input, .fill, UnitRect(x: 0.2502, y: 0.2502, width: 0.4996, height: 0.4996))

        let (before, after) = (try Pixels(input), try Pixels(redacted))
        for (x, y) in [(50, 100), (149, 100), (100, 50), (100, 149), (50, 50), (149, 149)] {
            #expect(after[x, y] == [0, 0, 0, 255], "\(x),\(y)")
        }
        for (x, y) in [(49, 100), (150, 100), (100, 49), (100, 150)] {
            #expect(after[x, y] == before[x, y], "\(x),\(y)")
        }
    }

    @Test(arguments: [RedactionStyle.fill, .pixelate])
    func redactedPixelsAreOpaqueInATransparentPNG(style: RedactionStyle) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Its left quarter is fully transparent.
        let input = try Fixtures.noisyPNG(width: 200, height: 200, alpha: true, in: dir)

        let redacted = try await redact(input, style, Self.topLeftQuarter)

        let after = try Pixels(redacted)
        for (x, y) in [(0, 0), (20, 20), (49, 99), (99, 99)] { #expect(after[x, y][3] == 255, "\(style) \(x),\(y)") }
        #expect(after[20, 150][3] == 0, "outside the box the transparency stays")
    }

    @Test(arguments: 1...8)
    func boxesLandOnTheRightPixelsInARotatedPhoto(orientation: Int) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 × 300; the marker fills the quarter shown at the top left once the orientation is applied.
        let input = try Fixtures.jpgWithOrientation(orientation, width: 400, height: 300, in: dir)

        let redacted = try await redact(input, .fill, Self.topLeftQuarter)

        #expect((try properties(of: redacted)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let after = try Pixels(redacted)
        let (width, height) = orientation >= 5 ? (300, 400) : (400, 300)
        #expect(after.width == width && after.height == height, "\(orientation): upright")
        var leaks: [String] = []
        for y in 0..<height {
            for x in 0..<width {
                let pixel = after[x, y]
                // JPEG's halved chroma and 8 px blocks blend the blue background into the box's inner edge (up to
                // 0, 2, 41 seen on the last row and column), never the marker, which the box hid.
                let edge = x >= width / 2 - 8 || y >= height / 2 - 8
                if x < width / 2, y < height / 2, !near(pixel, [0, 0, 0], edge ? 48 : 8) {
                    leaks.append("\(x),\(y) \(pixel) not black")
                }
                if near(pixel, Fixtures.orientationMarker, 40) { leaks.append("\(x),\(y) \(pixel) is the marker") }
            }
        }
        #expect(leaks.isEmpty, "\(orientation): \(leaks.count) pixels, first \(leaks.prefix(3))")
        #expect(near(after[width * 3 / 4, height * 3 / 4], Fixtures.orientationBackground, 12))
    }

    // MARK: Nothing but pixels

    @Test func redactedFileHasNoMetadataThumbnailOrAuxiliaryImages() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithThumbnail(in: dir)
        let original = try Data(contentsOf: input)

        let redacted = try await redact(input, .fill, Self.topLeftQuarter)

        try RedactionCheck.verify(redacted)
        let kept = try properties(of: redacted)
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary] {
            #expect(kept[key] == nil, "\(key)")
        }
        let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] == nil)
        let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(try thumbnail(of: redacted) == nil)
        #expect(try imageCount(redacted) == 1)
        #expect(Fixtures.imageSize(redacted) == CGSize(width: 1600, height: 1200))
        let bytes = try Data(contentsOf: redacted)
        for secret in Fixtures.secretMetadata + ["http://ns.adobe.com/xap/1.0/", "pomelo.example"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret)")
        }

        // The source is untouched and still carries all of it.
        #expect(try Data(contentsOf: input) == original)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(input) }
        let source = try properties(of: input)
        #expect(source[kCGImagePropertyGPSDictionary] != nil)
        #expect((source[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String
                == "iPhone 15 Pro")
        #expect(try thumbnail(of: input) != nil)
        for secret in Fixtures.secretMetadata { #expect(original.range(of: Data(secret.utf8)) != nil, "\(secret)") }
    }

    /// The SDK writes a HEIC's disparity map, so the fixture is a real HEIC with auxiliary data.
    @Test func anHEICsAuxiliaryImagesAreDropped() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.heicWithDisparity(in: dir)
        let original = try Data(contentsOf: input)
        #expect(try disparity(in: input))

        let redacted = try await redact(input, .pixelate, Self.topLeftQuarter)

        #expect(redacted.pathExtension == "heic")
        #expect(try !disparity(in: redacted))
        try RedactionCheck.verify(redacted)
        #expect(try imageCount(redacted) == 1)
        #expect(try Data(contentsOf: input) == original)
        #expect(try disparity(in: input))
    }

    // MARK: Colour profiles (P85)

    /// A system profile (`base`) with `tags` appended to its tag table, as a device or another app writes its own.
    private static func profile(_ base: CFString, adding tags: [(String, Data)]) throws -> Data {
        let bytes = [UInt8](try #require(CGColorSpace(name: base)?.copyICCData() as Data?))
        func read(_ at: Int) -> Int { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        func put(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) } }
        func padded(_ data: [UInt8]) -> [UInt8] { data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4) }
        let count = read(128)
        let tableEnd = 132 + count * 12
        let grow = tags.count * 12
        var table: [UInt8] = []
        for index in 0..<count {
            let entry = 132 + index * 12
            table += bytes[entry..<(entry + 4)] + put(read(entry + 4) + grow) + put(read(entry + 8))
        }
        let existing = padded(Array(bytes[tableEnd...]))
        var added: [UInt8] = []
        for (signature, data) in tags {
            table += Array(signature.utf8) + put(tableEnd + grow + existing.count + added.count) + put(data.count)
            added += padded(Array(data))
        }
        var header = Array(bytes[0..<128])
        header.replaceSubrange(0..<4, with: put(tableEnd + grow + existing.count + added.count))
        header.replaceSubrange(84..<100, with: [UInt8](repeating: 0, count: 16))  // the profile ID: not computed
        return Data(header + put(count + tags.count) + table + existing + added)
    }

    /// A 120x80 picture in the colour space of `icc`, written as `type`.
    private func picture(icc: Data, _ type: String, _ ext: String, in dir: URL) throws -> URL {
        let space = try #require(CGColorSpace(iccData: icc as CFData))
        let context = try #require(CGContext(
            data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        return try write(try #require(context.makeImage()), type, ext, properties: nil, in: dir)
    }

    private func profileName(_ url: URL) throws -> String? {
        try properties(of: url)[kCGImagePropertyProfileName] as? String
    }

    @Test func aPrivateICCTagNeverReachesTheOutput() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "SECRETICCTAG pomelo"
        let icc = try Self.profile(CGColorSpace.sRGB, adding: [("kqsc", Data("text\0\0\0\0\(secret)\0".utf8))])
        let input = try picture(icc: icc, "public.jpeg", "jpg", in: dir)
        #expect(try Data(contentsOf: input).range(of: Data(secret.utf8)) != nil, "the source carries the tag")

        let redacted = try await redact(input, .fill, Self.topLeftQuarter)

        #expect(try Data(contentsOf: redacted).range(of: Data(secret.utf8)) == nil)
        #expect(try profileName(redacted) == "sRGB IEC61966-2.1")
        try RedactionCheck.verify(redacted)
    }

    @Test func aDeviceProfileIsReplacedByTheSystemProfile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A display's make and model tag and a serial, on a wide-gamut base.
        let model = Data("mmod\0\0\0\0KQVDKQMD".utf8) + Data(repeating: 0, count: 24)
        let serial = Data("text\0\0\0\0KQSERIAL123\0".utf8)
        let icc = try Self.profile(CGColorSpace.displayP3, adding: [("mmod", model), ("kqsn", serial)])
        let input = try picture(icc: icc, "public.heic", "heic", in: dir)
        let original = try Data(contentsOf: input)
        #expect(original.range(of: Data("KQSERIAL123".utf8)) != nil && original.range(of: Data("KQVDKQMD".utf8)) != nil)

        let redacted = try await redact(input, .pixelate, Self.topLeftQuarter)

        let bytes = try Data(contentsOf: redacted)
        #expect(bytes.range(of: Data("KQSERIAL123".utf8)) == nil && bytes.range(of: Data("KQVDKQMD".utf8)) == nil)
        #expect(try profileName(redacted) == "Display P3")
        let written = try #require(try storedImage(redacted).colorSpace?.copyICCData() as Data?)
        #expect(written == CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        try RedactionCheck.verify(redacted)
    }

    /// ImageIO writes a cICP chunk for a Display P3 PNG, which the check allows at its 4 bytes (P85).
    @Test func aDisplayP3PNGRedacts() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        let input = try picture(icc: p3, "public.png", "png", in: dir)

        let redacted = try await redact(input, .fill, Self.topLeftQuarter)

        #expect(try profileName(redacted) == "Display P3")
        #expect(try Data(contentsOf: redacted).range(of: Data("cICP".utf8)) != nil, "the case the check must allow")
        #expect(try Pixels(redacted)[10, 10] == [0, 0, 0, 255])
    }

    /// What a hostile source can carry beside its pixels: GPS with a rotation, a second image, PNG text, TIFF and
    /// HEIC tags. Each comes out as one bare upright image.
    @Test func hostileSourcesComeOutBare() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pixels = try storedImage(try Fixtures.quadrantPNG(width: 120, height: 80, in: dir))
        let gpsAndTags: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFSoftware: "Photos"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "secret"],
        ]
        let pngText: [CFString: Any] = [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: "private note", kCGImagePropertyPNGAuthor: "someone",
        ]]
        let sources: [(URL, CGSize)] = [
            (try Fixtures.jpgWithGPS(orientation: 8, in: dir), CGSize(width: 64, height: 64)),
            (try Fixtures.multiPageTIFF(width: 90, height: 60, pages: 3, in: dir), CGSize(width: 90, height: 60)),
            (try write(pixels, "public.png", "png", properties: pngText, in: dir), CGSize(width: 120, height: 80)),
            (try write(pixels, "public.tiff", "tiff", properties: gpsAndTags, in: dir), CGSize(width: 120, height: 80)),
            (try write(pixels, "public.heic", "heic", properties: gpsAndTags, in: dir), CGSize(width: 120, height: 80)),
            (try write(pixels, "public.jpeg", "jpg", properties: gpsAndTags.merging(
                [kCGImagePropertyOrientation: 6, kCGImageDestinationEmbedThumbnail: true]) { $1 }, in: dir),
             CGSize(width: 80, height: 120)),
        ]
        for (input, shown) in sources {
            #expect(throws: RedactionCheck.Leak.self, "\(input.lastPathComponent) carries something") {
                try RedactionCheck.verify(input)
            }
            let redacted = try await redact(input, .fill, UnitRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5))
            try RedactionCheck.verify(redacted)
            #expect(try imageCount(redacted) == 1, "\(input.lastPathComponent)")
            #expect(Fixtures.imageSize(redacted) == shown, "\(input.lastPathComponent)")
            let after = try Pixels(redacted)
            let corner = after[after.width - 1, after.height - 1]
            // 16: a 7 px box in a 64 px JPEG shares its 8 px blocks with the green around it (9, 0, 0 seen).
            #expect(near(corner, [0, 0, 0], 16), "\(input.lastPathComponent): \(corner)")
        }
    }

    // MARK: Refusals

    @Test func animatedSourcesAreRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let apng = dir.appending(path: "animation.png")
        let destination = try #require(CGImageDestinationCreateWithURL(apng as CFURL, "public.png" as CFString, 2, nil))
        let frame = try storedImage(try Fixtures.png(width: 40, height: 40, in: dir))
        for _ in 0..<2 {
            let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary
            CGImageDestinationAddImage(destination, frame, delay)
        }
        try #require(CGImageDestinationFinalize(destination))

        let result = try await redact(apng, .redact(RedactionSpec(boxes: [Self.middle], style: .fill)))
        #expect(reason(result) == "Animated images can't be redacted")

        // A GIF has no redact edge, but the engine refuses an animation whatever reaches it.
        let gif = try Fixtures.animatedGIF(width: 40, height: 40, delays: [0.1, 0.1], loopCount: 0, in: dir)
        let format = try #require(FormatRegistry.builtIn.format(id: "gif"))
        var options = PresetOptions(quality: 0.92)
        options.edit = .redact(RedactionSpec(boxes: [Self.middle], style: .fill))
        let step = ConversionStep(
            input: gif, stagingDirectory: dir, from: format, to: format, options: options, operation: "redact"
        )
        await #expect(throws: ConversionError.notApplicable(reason: "Animated images can't be redacted")) {
            try await ImageIOEngine().convert(step) { _ in }
        }
    }

    @Test func noBoxIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 64, height: 64, in: dir)
        let edits: [EditSpec?] = [
            nil,
            .redact(RedactionSpec(boxes: [], style: .fill)),
            .crop(Self.middle),
            // Wholly outside the picture, and no area at all: neither hides a pixel.
            .redact(RedactionSpec(boxes: [UnitRect(x: 2, y: 2, width: 0.5, height: 0.5)], style: .fill)),
            .redact(RedactionSpec(boxes: [UnitRect(x: 0.5, y: 0.5, width: 0, height: 0.3)], style: .pixelate)),
            .redact(RedactionSpec(boxes: [UnitRect(x: .nan, y: 0, width: .infinity, height: 0.3)], style: .fill)),
        ]
        for edit in edits {
            #expect(reason(try await redact(input, edit)) == "Choose something to hide", "\(String(describing: edit))")
        }
    }

    @Test func aFileThatFailsTheCheckIsNeverReturned() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.noisyPNG(width: 64, height: 64, in: dir)
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let format = try #require(FormatRegistry.builtIn.format(id: "png"))
        var options = PresetOptions(quality: 0.92)
        options.edit = .redact(RedactionSpec(boxes: [Self.middle], style: .fill))
        let step = ConversionStep(
            input: input, stagingDirectory: staging, from: format, to: format, options: options, operation: "redact"
        )
        var checked: URL?

        #expect(throws: ConversionError.converterFault(engine: "imageio", message: "redacted file kept metadata")) {
            try ImageIOEngine().redact(step, progress: { _ in }) { url in
                checked = url
                throw RedactionCheck.Leak(reason: "a planted leak")
            }
        }
        #expect(checked == step.suggestedOutput)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // MARK: Every redact format (P84)

    static let redactFormats = ImageIOEngine().edges().filter { $0.operation == "redact" }.map(\.from)

    @Test func redactEdgesAreTheCheckedFormats() async throws {
        let edges = ImageIOEngine().edges().filter { $0.operation == "redact" }
        #expect(Set(edges.map(\.from)) == ["jpg", "png", "heic", "tiff", "bmp"])
        for edge in edges {
            #expect(edge.from == edge.to)
            #expect(edge.flags.contains(.lossy) == ["jpg", "heic"].contains(edge.from), "\(edge.from)")
        }
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()
        for format: FormatID in ["jpg", "png", "heic"] {
            let route = try #require(planner.route(from: format, operation: "redact", to: nil), "\(format)")
            #expect(route.edges.map(\.engineID) == ["imageio"], "\(format)")
        }
        for format: FormatID in ["pdf", "ico", "icns", "mov"] {
            #expect(planner.route(from: format, operation: "redact", to: nil) == nil, "\(format)")
        }
    }

    /// Each redact edge writes a file ImageIO reopens, of the source's size, with the box black, the rest kept, and
    /// nothing the check refuses.
    @Test(arguments: redactFormats)
    func everyRedactFormatWritesWhatItHid(format: FormatID) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try #require(FormatRegistry.builtIn.format(id: format))
        let pixels = try storedImage(try Fixtures.quadrantPNG(width: 96, height: 64, in: dir))
        let input = try write(pixels, try #require(file.utTypeIdentifier), file.extensions[0], properties: nil, in: dir)

        let redacted = try await redact(input, .fill, Self.topLeftQuarter)

        #expect(redacted.pathExtension == file.extensions[0])
        try RedactionCheck.verify(redacted)
        let after = try Pixels(redacted)
        #expect(after.width == 96 && after.height == 64, "\(format)")
        #expect(near(after[12, 12], [0, 0, 0], 8), "\(format): \(after[12, 12])")
        #expect(near(after[36, 24], [0, 0, 0], 8), "\(format): \(after[36, 24])")
        #expect(near(after[72, 48], Fixtures.Quadrant.bottomRight.rgb, 16), "\(format): \(after[72, 48])")
        #expect(near(after[72, 12], Fixtures.Quadrant.topRight.rgb, 16), "\(format): \(after[72, 12])")
    }
}
