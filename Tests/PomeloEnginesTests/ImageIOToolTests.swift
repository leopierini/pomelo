import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

/// The image tools of ImageIO: compress and remove metadata.
@Suite struct ImageIOToolTests {
    private let registry = FormatRegistry.builtIn

    private func step(
        _ input: URL, format: FormatID, operation: String, in staging: URL, options: PresetOptions = PresetOptions()
    ) throws -> ConversionStep {
        let format = try #require(registry.format(id: format))
        return ConversionStep(
            input: input, stagingDirectory: staging, from: format, to: format, options: options, operation: operation
        )
    }

    private func staging(in dir: URL) throws -> URL {
        let url = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue)
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// The decoded pixels of frame 0 as 8-bit sRGB RGBA, with the stored orientation left unapplied.
    private func pixels(of url: URL) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return data
    }

    private func iccProfileName(of url: URL) throws -> String? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return image.colorSpace?.name as String?
    }

    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func preset(_ id: String) throws -> Preset {
        try #require(Preset.builtIns.first { $0.id == id })
    }

    // MARK: Edges

    @Test func toolEdgesExistForTheRightFormats() {
        let edges = ImageIOEngine().edges()
        let compress = edges.filter { $0.operation == "compress" }
        #expect(compress.allSatisfy { $0.from == $0.to && $0.flags.contains(.lossy) })
        #expect(Set(compress.map(\.from)).isSubset(of: ["jpg", "heic", "avif"]))
        #expect(compress.contains { $0.from == "jpg" })

        let strip = edges.filter { $0.operation == "strip-metadata" }
        #expect(strip.allSatisfy { $0.from == $0.to && !$0.flags.contains(.lossy) })
        for format: FormatID in ["jpg", "png", "heic", "tiff"] {
            #expect(strip.contains { $0.from == format }, "\(format)")
        }
        #expect(!strip.contains { $0.from == "pdf" || $0.from == "webp" })
    }

    // MARK: Compress

    @Test func compressLowersAJPEGsSize() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.photo(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", quality: 0.95, in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "compress", in: try staging(in: dir), options: PresetOptions(quality: 0.7))
        ) { _ in }

        #expect(try fileSize(output) < fileSize(input))
        #expect(Fixtures.imageSize(output) == CGSize(width: 2000, height: 1500))
        #expect(Fixtures.imageUTType(output) == "public.jpeg")
    }

    @Test func compressKeepsTheMetadata() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "compress", in: try staging(in: dir), options: PresetOptions(quality: 0.7))
        ) { _ in }

        #expect(try properties(of: output)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func compressingAnAlreadySmallJPEGPublishesNothing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.photo(width: 1200, height: 900, type: "public.jpeg", ext: "jpg", quality: 0.3, in: dir)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let results = await runner().run(ConversionRequest.from(try preset("compress"), inputs: [input]))

        #expect(results == [.failed(source: input, error: .notApplicable(reason: "Already compressed"))])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before)
    }

    @Test func compressPublishesASmallerFileNextToTheSource() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.photo(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", quality: 0.95, in: dir)

        let results = await runner().run(ConversionRequest.from(try preset("compress"), inputs: [input]))

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        #expect(output.lastPathComponent == input.deletingPathExtension().lastPathComponent + "-compressed.jpg")
        #expect(try fileSize(output) < fileSize(input))
    }

    @Test func compressMoreAlsoCapsTheSize() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.photo(width: 2000, height: 1500, type: "public.jpeg", ext: "jpg", quality: 0.95, in: dir)

        let output = try await ImageIOEngine().convert(
            try step(
                input, format: "jpg", operation: "compress", in: try staging(in: dir),
                options: PresetOptions(quality: 0.5, maxPixelSize: 1000)
            )
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 1000, height: 750))
    }

    // MARK: Remove metadata

    @Test func strippingRemovesGPSAndKeepsOrientation() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(orientation: 6, in: dir)
        #expect(try properties(of: input)[kCGImagePropertyGPSDictionary] != nil)

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "strip-metadata", in: try staging(in: dir))
        ) { _ in }

        let result = try properties(of: output)
        #expect(result[kCGImagePropertyGPSDictionary] == nil)
        let exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect((result[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
    }

    @Test func strippingAJPEGDoesNotReencodeIt() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(orientation: 6, in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "strip-metadata", in: try staging(in: dir))
        ) { _ in }

        #expect(try pixels(of: output) == pixels(of: input))
    }

    @Test func strippingAPhotoWithoutOrientationLeavesNone() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.jpgWithGPS(in: dir)

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "strip-metadata", in: try staging(in: dir))
        ) { _ in }

        let result = try properties(of: output)
        #expect(result[kCGImagePropertyGPSDictionary] == nil)
        #expect(((result[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1)
    }

    @Test func strippingKeepsTheColorProfile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.2, 0.1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let input = dir.appending(path: "p3.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil))
        let gps = [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"]]
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), gps as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        #expect(try iccProfileName(of: input) == (CGColorSpace.displayP3 as String))

        let output = try await ImageIOEngine().convert(
            try step(input, format: "jpg", operation: "strip-metadata", in: try staging(in: dir))
        ) { _ in }

        #expect(try iccProfileName(of: output) == (CGColorSpace.displayP3 as String))
        #expect(try properties(of: output)[kCGImagePropertyGPSDictionary] == nil)
    }

    // MARK: Byte-level checks

    /// Strings planted in the seeds below. A stripped file must not contain any of them anywhere in its bytes.
    private static let markers = [
        "KQ-COMMENT", "KQ-CAPTION", "KQ-BYLINE", "KQ-ARTIST", "KQ-SOFTWARE", "KQ-COPYRIGHT", "KQ-TITLE", "KQ-SOURCE",
        "KQ-AUTHOR", "KQ-TOOL", "KQ-DESC",
    ]

    private func markers(in url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return Self.markers.filter { data.range(of: Data($0.utf8)) != nil }
    }

    private func swatch(width: Int = 64, height: Int = 64) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 8, y: 8, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    /// A JPEG with a marker in EXIF, IPTC and TIFF fields, plus GPS.
    private func markedJPEG(in dir: URL) throws -> URL {
        let url = dir.appending(path: "marked.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 3,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "KQ-COMMENT"],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: "KQ-CAPTION", kCGImagePropertyIPTCByline: ["KQ-BYLINE"],
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: "KQ-ARTIST", kCGImagePropertyTIFFSoftware: "KQ-SOFTWARE",
                kCGImagePropertyTIFFCopyright: "KQ-COPYRIGHT",
            ],
        ]
        CGImageDestinationAddImage(destination, try swatch(), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// A PNG whose only metadata is `tEXt` chunks, inserted after IHDR by hand.
    private func textChunkPNG(in dir: URL) throws -> URL {
        var data = try Data(contentsOf: try Fixtures.png(width: 24, height: 24, in: dir))
        let ihdrEnd = 8 + 12 + 13
        var chunks = Data()
        for (keyword, value) in [
            ("Author", "KQ-AUTHOR"), ("Software", "KQ-SOFTWARE"), ("Comment", "KQ-COMMENT"),
            ("Copyright", "KQ-COPYRIGHT"), ("Title", "KQ-TITLE"), ("Source", "KQ-SOURCE"),
        ] {
            let body = Data("tEXt".utf8) + Data(keyword.utf8) + Data([0]) + Data(value.utf8)
            var length = UInt32(body.count - 4).bigEndian
            var crc = Self.crc32(body).bigEndian
            chunks += Data(bytes: &length, count: 4) + body + Data(bytes: &crc, count: 4)
        }
        data.insert(contentsOf: chunks, at: ihdrEnd)
        let url = dir.appending(path: "text.png")
        try data.write(to: url)
        return url
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// A PNG carrying GPS, EXIF, IPTC and XMP, the XMP written through ImageIO's metadata object.
    private func xmpPNG(in dir: URL) throws -> URL {
        let url = dir.appending(path: "xmp.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        let metadata = CGImageMetadataCreateMutable()
        for (path, value) in [
            ("xmp:CreatorTool", "KQ-TOOL"), ("dc:description", "KQ-DESC"), ("exif:UserComment", "KQ-COMMENT"),
            ("tiff:Artist", "KQ-ARTIST"), ("tiff:Software", "KQ-SOFTWARE"),
        ] {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString), "\(path)")
        }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"]
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCCaptionAbstract: "KQ-CAPTION"]
        let options: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyIPTCDictionary: iptc]
        CGImageDestinationAddImageAndMetadata(destination, try swatch(), metadata, options as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    private func strip(_ input: URL, format: FormatID, in dir: URL) async throws -> URL {
        let out = dir.appending(path: "out-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return try await ImageIOEngine().convert(try step(input, format: format, operation: "strip-metadata", in: out)) { _ in }
    }

    @Test func strippingAPNGWithOnlyTextChunksRemovesThemAll() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try textChunkPNG(in: dir)
        #expect(try markers(in: input).count == 6)

        let output = try await strip(input, format: "png", in: dir)

        #expect(try markers(in: output) == [])
        let exif = try properties(of: output)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(Fixtures.imageSize(output) == Fixtures.imageSize(input))
    }

    @Test func strippingAPNGWithEXIFIPTCAndXMPRemovesThemAll() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try xmpPNG(in: dir)
        #expect(try markers(in: input).contains("KQ-TOOL") || markers(in: input).contains("KQ-DESC"))

        let output = try await strip(input, format: "png", in: dir)

        #expect(try markers(in: output) == [])
        #expect(try properties(of: output)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func strippingAMultiPageTIFFChecksEveryPage() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "pages.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.tiff" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try swatch(width: 40, height: 40), nil)
        let second: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "KQ-COMMENT"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "KQ-ARTIST"],
        ]
        CGImageDestinationAddImage(destination, try swatch(width: 30, height: 30), second as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        #expect(try markers(in: input).contains("KQ-COMMENT"))

        let output = try await strip(input, format: "tiff", in: dir)

        #expect(try markers(in: output) == [])
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        for index in 0..<2 {
            let frame = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            #expect(frame[kCGImagePropertyGPSDictionary] == nil, "page \(index)")
        }
        let sizes = (0..<2).compactMap { index in
            (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        }
        #expect(sizes == [40, 30])
    }

    /// Formats the jpg seed cannot be converted into on this machine (icns takes fixed sizes only).
    private static let unseedableFormats: Set<FormatID> = ["icns"]

    @Test func strippingLeavesNoMarkerInAnyFormatItIsOfferedFor() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let seed = try markedJPEG(in: dir)
        #expect(try markers(in: seed).count >= 5)
        var checked: Set<FormatID> = []
        var unseedable: Set<FormatID> = []
        for edge in ImageIOEngine().edges().filter({ $0.operation == "strip-metadata" }) {
            let work = dir.appending(path: edge.from.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let converted: URL
            do {
                converted = try await ImageIOEngine().convert(
                    ConversionStep(
                        input: seed, stagingDirectory: try staging(in: work),
                        from: try #require(registry.format(id: "jpg")), to: try #require(registry.format(id: edge.from)),
                        options: PresetOptions()
                    ),
                    progress: { _ in }
                )
            } catch {
                unseedable.insert(edge.from)
                continue
            }

            let output = try await strip(converted, format: edge.from, in: work)

            #expect(Fixtures.imageSize(output) == Fixtures.imageSize(converted), "\(edge.from)")
            #expect(try markers(in: output) == [], "\(edge.from)")
            let result = try properties(of: output)
            #expect(result[kCGImagePropertyGPSDictionary] == nil, "\(edge.from)")
            #expect(result[kCGImagePropertyIPTCDictionary] == nil, "\(edge.from)")
            checked.insert(edge.from)
        }
        #expect(checked.isSuperset(of: ["jpg", "png", "heic", "tiff"]))
        #expect(unseedable.isSubset(of: Self.unseedableFormats), "\(unseedable.subtracting(Self.unseedableFormats))")
    }
}
