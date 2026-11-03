import CoreGraphics
import Foundation
import ImageIO
import PomeloTestSupport
import Testing
@testable import PomeloEngines

/// Writes a bare image the way an engine would: no properties unless given.
private func writeImage(
    _ type: String, _ ext: String, width: Int = 64, height: Int = 48, alpha: Bool = false,
    options: [CFString: Any]? = nil, in directory: URL
) throws -> URL {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let url = directory.appending(path: "bare-\(UUID().uuidString).\(ext)")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, options as CFDictionary?)
    try #require(CGImageDestinationFinalize(destination))
    return url
}

@Suite struct RedactionCheckTests {
    @Test func theCheckRejectsAFileWithMetadata() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(Fixtures.jpgWithGPS(in: dir)) }
        #expect(throws: RedactionCheck.Leak.self) {
            try RedactionCheck.verify(Fixtures.jpgWithOrientation(6, width: 64, height: 32, in: dir))
        }
    }

    @Test func theCheckAcceptsABareImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try RedactionCheck.verify(Fixtures.png(width: 64, height: 48, in: dir))
        try RedactionCheck.verify(writeImage("public.png", "png", in: dir))
    }

    @Test func whatImageIOWritesForABareImageInEachFormatPasses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let formats = [("public.jpeg", "jpg"), ("public.png", "png"), ("public.heic", "heic"), ("public.tiff", "tiff")]
        for (type, ext) in formats {
            for alpha in [false, true] where !(alpha && ext == "jpg") {
                for options in [nil, [kCGImageDestinationLossyCompressionQuality: 0.9] as [CFString: Any]?] {
                    let url = try writeImage(type, ext, alpha: alpha, options: options, in: dir)
                    try RedactionCheck.verify(url)
                }
            }
        }
    }

    @Test func aTagOutsideTheEncodersOwnIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let makeAndModel = [kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone",
        ]] as [CFString: Any]
        let software = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "Photos"]] as [CFString: Any]
        let date = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2026:10:26 10:00:00"]] as [CFString: Any]
        let iptc = [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "secret"]] as [CFString: Any]
        let exifDate = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:26 10:00:00"]]
            as [CFString: Any]
        for properties in [makeAndModel, software, date, iptc, exifDate] {
            for (type, ext) in [("public.jpeg", "jpg"), ("public.heic", "heic"), ("public.tiff", "tiff")] {
                let url = try writeImage(type, ext, options: properties, in: dir)
                #expect(throws: RedactionCheck.Leak.self, "\(ext) \(properties.keys)") { try RedactionCheck.verify(url) }
            }
        }
    }

    @Test func pngTextIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "private note"]] as [CFString: Any]
        let url = try writeImage("public.png", "png", options: text, in: dir)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(url) }
    }

    /// P85: a cICP chunk is four enumerated colour codes (what ImageIO writes for Display P3); any other length is
    /// refused as data.
    @Test func aCICPChunkPassesOnlyAtFourBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bare = try Data(contentsOf: writeImage("public.png", "png", in: dir))
        let afterIHDR = 8 + 12 + 13
        func withCICP(_ payload: [UInt8]) throws -> URL {
            let body = Array("cICP".utf8) + payload
            let length = (0..<4).map { UInt8(payload.count >> (24 - 8 * $0) & 0xFF) }
            let crc = (0..<4).map { UInt8(pngCRC(body) >> (24 - 8 * $0) & 0xFF) }
            var data = bare
            data.insert(contentsOf: length + body + crc, at: afterIHDR)
            let url = dir.appending(path: "cicp-\(payload.count)-\(UUID().uuidString).png")
            try data.write(to: url)
            return url
        }
        try RedactionCheck.verify(withCICP([12, 13, 0, 1]))
        for payload: [UInt8] in [[], [12, 13, 0], [12, 13, 0, 1, 0], Array("a secret of any length".utf8)] {
            let url = try withCICP(payload)
            #expect(throws: RedactionCheck.Leak(reason: "it carries the PNG chunk cICP"), "\(payload.count) bytes") {
                try RedactionCheck.verify(url)
            }
        }
    }

    private func pngCRC(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }

    @Test func anEmbeddedThumbnailIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let embed = [kCGImageDestinationEmbedThumbnail: true] as [CFString: Any]
        for (type, ext) in [("public.jpeg", "jpg"), ("public.heic", "heic")] {
            for size in [(64, 48), (640, 480)] {
                let url = try writeImage(type, ext, width: size.0, height: size.1, options: embed, in: dir)
                #expect(throws: RedactionCheck.Leak.self, "\(ext) \(size)") { try RedactionCheck.verify(url) }
            }
        }
    }

    @Test func aSecondImageIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let two = try Fixtures.multiPageTIFF(width: 16, height: 16, pages: 2, in: dir)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(two) }
    }

    @Test func aJPEGCommentIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeImage("public.jpeg", "jpg", in: dir)
        var data = try Data(contentsOf: url)
        let comment = Data("secret".utf8)
        let length = comment.count + 2
        data.insert(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + comment, at: 2)
        try data.write(to: url)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(url) }
    }

    @Test func aFileThatIsNotAnImageIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try Fixtures.textFile("hello", ext: "txt", in: dir)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(text) }
    }
}

private func makeImage(width: Int = 64, height: Int = 48) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

@Suite struct RedactionCheckHiddenDataTests {
    @Test func auxiliaryDataIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let width = 16, height = 12
        let depth = [Float32](repeating: 0.5, count: width * height)
        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: depth.withUnsafeBufferPointer { Data(buffer: $0) } as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: [
                "Width": width, "Height": height, "BytesPerRow": width * 4, "PixelFormat": 0x6664_6973,  // 'fdis'
            ] as [String: Any],
        ]
        let url = dir.appending(path: "disparity.heic")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(), nil)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, info as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        try #require(
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil,
            "the fixture holds no disparity map")
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(url) }
    }

    @Test func anXMPTagIsRejectedInEveryFormat() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (type, ext) in [("public.jpeg", "jpg"), ("public.png", "png"), ("public.heic", "heic"), ("public.tiff", "tiff")] {
            let metadata = CGImageMetadataCreateMutable()
            let tag = try #require(CGImageMetadataTagCreate(
                kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "title" as CFString, .string,
                "secret" as CFString))
            try #require(CGImageMetadataSetTagWithPath(metadata, nil, "dc:title" as CFString, tag))
            let url = dir.appending(path: "xmp.\(ext)")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
            CGImageDestinationAddImageAndMetadata(destination, try makeImage(), metadata, nil)
            try #require(CGImageDestinationFinalize(destination))

            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let written = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap {
                CGImageMetadataCopyTagWithPath($0, nil, "dc:title" as CFString)
            }
            try #require(written != nil, "the \(ext) fixture holds no XMP title")
            #expect(throws: RedactionCheck.Leak.self, "\(ext)") { try RedactionCheck.verify(url) }
        }
    }

    @Test func aMalformedJPEGSegmentIsRefusedNotATrap() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeImage("public.jpeg", "jpg", in: dir)
        let original = try Data(contentsOf: url)
        let zeroLength = Data([0xFF, 0xE5, 0x00, 0x00])
        let shortLength = Data([0xFF, 0xE5, 0x00, 0x01])
        let pastTheEnd = Data([0xFF, 0xE5, 0xFF, 0xFF])
        for segment in [zeroLength, shortLength, pastTheEnd] {
            var data = original
            data.insert(contentsOf: segment, at: 2)
            try data.write(to: url)
            #expect(throws: RedactionCheck.Leak.self, "\(Array(segment))") { try RedactionCheck.verify(url) }
        }
    }

    @Test func aTruncatedFileIsRefusedNotATrap() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (type, ext) in [("public.jpeg", "jpg"), ("public.png", "png"), ("public.tiff", "tiff"), ("public.heic", "heic")] {
            let url = try writeImage(type, ext, in: dir)
            let original = try Data(contentsOf: url)
            // Too short to be an image: refused. Longer cuts may still be readable by ImageIO with a clean header,
            // which leaks nothing; they only must not trap.
            for keep in [0, 1, 2, 3, 5, 7] {
                try original.prefix(keep).write(to: url)
                #expect(throws: RedactionCheck.Leak.self, "\(ext) cut at \(keep)") { try RedactionCheck.verify(url) }
            }
            for keep in 8..<original.count where keep < 80 || keep % 97 == 0 || keep == original.count - 1 {
                try original.prefix(keep).write(to: url)
                _ = try? RedactionCheck.verify(url)
            }
        }
    }

    @Test func aTruncatedExifSegmentIsRefused() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeImage("public.jpeg", "jpg", in: dir)
        var data = try Data(contentsOf: url)
        let exif = try #require(data.range(of: Data("Exif\0\0".utf8)))
        // Points the first IFD past the end of the segment.
        let tiffStart = exif.upperBound
        data.replaceSubrange((tiffStart + 4)..<(tiffStart + 8), with: [0x00, 0x00, 0xFF, 0xFF])
        try data.write(to: url)
        #expect(throws: RedactionCheck.Leak.self) { try RedactionCheck.verify(url) }
    }
}
