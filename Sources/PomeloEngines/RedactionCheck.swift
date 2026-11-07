import CoreGraphics
import Foundation
import ImageIO

/// Reopens a redacted image and fails if it still carries anything but pixels: a second image, metadata, a
/// thumbnail or an auxiliary image (depth, matte, gain map) could each hold what the boxes were meant to hide.
///
/// The rule is an allowlist: only what ImageIO writes itself for an image with no properties passes (probed for
/// JPEG, PNG, HEIC and TIFF, opaque and with alpha, P70). Nothing derived from a source photo is on it.
public enum RedactionCheck {
    public struct Leak: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    public static func verify(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Leak(reason: "it is not an image") }
        guard CGImageSourceGetCount(source) == 1 else {
            throw Leak(reason: "it holds \(CGImageSourceGetCount(source)) images")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        try verifyProperties(properties)
        try verifyTags(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        try verifyThumbnail(source, properties: properties)
        try verifyAuxiliaryData(source)
        try verifyContainer(url)
    }

    // MARK: Allowlists

    private static let scalarProperties: Set<String> = [
        "ColorModel", "Depth", "HasAlpha", "Headroom", "Orientation", "PixelHeight", "PixelWidth", "PrimaryImage",
        "ProfileName",
    ]

    private static let dictionaries: [String: Set<String>] = [
        "{Exif}": ["ColorSpace", "PixelXDimension", "PixelYDimension"],
        "{TIFF}": ["Compression", "Orientation", "PhotometricInterpretation", "ResolutionUnit", "TileLength", "TileWidth"],
        "{JFIF}": ["DensityUnit", "JFIFVersion", "XDensity", "YDensity"],
        "{PNG}": ["Chromaticities", "Gamma", "InterlaceType", "sRGBIntent"],
        // macOS 27.2's ImageIO writes these two light levels into every HEIC, a bare image's too (203 and 64 for any
        // content, probed 2026-11-08): two numbers, never a source's data.
        "ContentLightLevelInfo": ["MaxContentLightLevel", "MaxPicAverageLightLevel"],
    ]

    private static let tags: Set<String> = [
        "exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension", "tiff:Compression", "tiff:Orientation",
        "tiff:PhotometricInterpretation", "tiff:ResolutionUnit", "tiff:TileLength", "tiff:TileWidth",
    ]

    private static let pngChunks: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "iCCP", "tRNS", "eXIf"]

    // MARK: Checks

    static func verifyProperties(_ properties: [String: Any]) throws {
        for (key, value) in properties {
            if let allowed = dictionaries[key] {
                guard let inner = value as? [String: Any] else { throw Leak(reason: "it carries \(key)") }
                if let extra = inner.keys.sorted().first(where: { !allowed.contains($0) }) {
                    throw Leak(reason: "it carries \(key) \(extra)")
                }
                if key == "{TIFF}", let orientation = inner["Orientation"], !isUpright(orientation) {
                    throw Leak(reason: "it carries an orientation tag")
                }
                if key == "ContentLightLevelInfo", inner.values.contains(where: { !($0 is NSNumber) }) {
                    throw Leak(reason: "it carries \(key)")
                }
            } else if scalarProperties.contains(key) {
                if key == "Orientation", !isUpright(value) { throw Leak(reason: "it carries an orientation tag") }
            } else {
                throw Leak(reason: "it carries \(key)")
            }
        }
    }

    private static func isUpright(_ value: Any) -> Bool {
        (value as? NSNumber)?.intValue == 1
    }

    private static func verifyTags(_ metadata: CGImageMetadata?) throws {
        guard let metadata, let found = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return }
        for tag in found {
            let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? "?"
            let name = CGImageMetadataTagCopyName(tag) as String? ?? "?"
            guard tags.contains("\(prefix):\(name)") else { throw Leak(reason: "it carries the metadata tag \(prefix):\(name)") }
            if "\(prefix):\(name)" == "tiff:Orientation", (CGImageMetadataTagCopyValue(tag) as? String) != "1" {
                throw Leak(reason: "it carries an orientation tag")
            }
        }
    }

    /// With `ThumbnailFromImageIfAbsent` off ImageIO hands back an embedded thumbnail if there is one, but a JPEG,
    /// PNG or TIFF without one still yields its own pixels, so a thumbnail is a result smaller than the image. A
    /// thumbnail as large as the image (small photos) is caught by the HEIC probe and the JPEG container scan.
    private static func verifyThumbnail(_ source: CGImageSource, properties: [String: Any]) throws {
        let width = (properties["PixelWidth"] as? NSNumber)?.intValue ?? 0
        let height = (properties["PixelHeight"] as? NSNumber)?.intValue ?? 0
        // HEIC first: after a bounded request ImageIO answers the unbounded one with the image itself.
        let type = CGImageSourceGetType(source) as String? ?? ""
        if ["public.heic", "public.heif", "public.avif"].contains(type),
           CGImageSourceCreateThumbnailAtIndex(
               source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false] as CFDictionary) != nil {
            throw Leak(reason: "it carries a thumbnail")
        }
        let bounded: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1) * 4,
        ]
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, bounded as CFDictionary),
           thumbnail.width != width || thumbnail.height != height {
            throw Leak(reason: "it carries a thumbnail")
        }
    }

    private static func verifyAuxiliaryData(_ source: CGImageSource) throws {
        var types: [CFString] = [
            kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        ]
        if #available(macOS 15.0, *) { types.append(kCGImageAuxiliaryDataTypeISOGainMap) }
        for type in types where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
            throw Leak(reason: "it carries auxiliary image data")
        }
    }

    // MARK: Containers

    /// ImageIO does not surface everything a file can hold (a JPEG comment, a PNG text chunk, an EXIF thumbnail
    /// whose size equals the image's), so the two formats a redaction can keep are also read at the byte level.
    private static func verifyContainer(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Leak(reason: "it cannot be read") }
        if data.starts(with: [0xFF, 0xD8]) {
            try verifyJPEG(data)
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            try verifyPNG(data)
        }
    }

    /// A file whose segments run past its end, or that never reaches the scan, is refused: a malformed container
    /// could hide data from the readers below, and nothing here may trap on it.
    private static func verifyJPEG(_ data: Data) throws {
        let invalid = Leak(reason: "it is not a valid JPEG")
        var offset = 2
        while offset + 2 <= data.count {
            guard data[offset] == 0xFF else { throw invalid }
            let marker = data[offset + 1]
            if marker == 0xDA { return }
            if marker == 0xFF { offset += 1; continue }
            if marker == 0x01 || (0xD0...0xD9).contains(marker) { offset += 2; continue }
            guard offset + 4 <= data.count else { throw invalid }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard length >= 2, offset + 2 + length <= data.count else { throw invalid }
            let body = data.subdata(in: (offset + 4)..<(offset + 2 + length))
            switch marker {
            case 0xFE: throw Leak(reason: "it carries a JPEG comment")
            case 0xE0 where body.starts(with: Data("JFIF\0".utf8)): break
            case 0xE2 where body.starts(with: Data("ICC_PROFILE\0".utf8)): break
            case 0xED where body.starts(with: Data("Photoshop 3.0\0".utf8)):
                if !isEmptyPhotoshopBlock(body.dropFirst(14)) { throw Leak(reason: "it carries IPTC or Photoshop data") }
            case 0xE1 where body.starts(with: Data("Exif\0\0".utf8)):
                if try exifHasSecondIFD(body.dropFirst(6)) { throw Leak(reason: "it carries a thumbnail") }
            case 0xE0...0xEF: throw Leak(reason: "it carries an extra JPEG segment")
            default: break
            }
            offset += 2 + length
        }
        throw invalid
    }

    /// ImageIO adds an APP13 block when a JPEG quality is requested, holding an empty IPTC resource (0x0404) and the
    /// MD5 of nothing (0x0425). Any other resource, or an IPTC one with bytes in it, is source data.
    private static func isEmptyPhotoshopBlock(_ resources: Data.SubSequence) -> Bool {
        let md5OfNothing: [UInt8] = [
            0xD4, 0x1D, 0x8C, 0xD9, 0x8F, 0x00, 0xB2, 0x04, 0xE9, 0x80, 0x09, 0x98, 0xEC, 0xF8, 0x42, 0x7E,
        ]
        let bytes = Array(resources)
        var offset = 0
        while offset < bytes.count {
            guard offset + 7 <= bytes.count, bytes[offset..<(offset + 4)].elementsEqual("8BIM".utf8) else { return false }
            let id = Int(bytes[offset + 4]) << 8 | Int(bytes[offset + 5])
            let nameLength = Int(bytes[offset + 6])
            let cursor = offset + 7 + nameLength + (nameLength % 2 == 0 ? 1 : 0)
            guard cursor + 4 <= bytes.count else { return false }
            let size = bytes[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | Int($1) }
            let dataEnd = cursor + 4 + size
            guard dataEnd <= bytes.count else { return false }
            switch id {
            case 0x0404 where size == 0: break
            case 0x0425 where bytes[(cursor + 4)..<dataEnd].elementsEqual(md5OfNothing): break
            default: return false
            }
            offset = dataEnd + size % 2
        }
        return true
    }

    /// Whether the TIFF structure inside an Exif segment links a second image file directory (the thumbnail). An
    /// unreadable structure throws.
    private static func exifHasSecondIFD(_ tiff: Data.SubSequence) throws -> Bool {
        let invalid = Leak(reason: "its Exif data is not valid")
        let bytes = Array(tiff)
        guard bytes.count >= 8 else { throw invalid }
        let littleEndian = bytes[0] == 0x49
        func read(_ at: Int, _ count: Int) -> Int? {
            guard at >= 0, at + count <= bytes.count else { return nil }
            let slice = bytes[at..<(at + count)]
            return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { $0 << 8 | Int($1) }
        }
        guard let first = read(4, 4), let entries = read(first, 2), let next = read(first + 2 + entries * 12, 4) else {
            throw invalid
        }
        return next != 0
    }

    private static func verifyPNG(_ data: Data) throws {
        var offset = 8
        while offset < data.count {
            guard offset + 12 <= data.count else { throw Leak(reason: "it is not a valid PNG") }
            let length = data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let name = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            // cICP is four enumerated colour codes the encoder writes for a Display P3 picture (P85); any other
            // length is not one, so it could carry data.
            guard pngChunks.contains(name) || (name == "cICP" && length == 4) else {
                throw Leak(reason: "it carries the PNG chunk \(name)")
            }
            guard length <= data.count - offset - 12 else { throw Leak(reason: "it is not a valid PNG") }
            offset += 12 + length
        }
    }
}
