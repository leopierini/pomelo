import CoreGraphics
import Foundation
import ImageIO
import PomeloCore

/// Converts between the image formats the system's ImageIO can read and write, and offers eight image tools:
/// compress (a lossy re-encode), compress to size (quality, then pixels, until it fits), remove metadata (a copy
/// that does not recompress), crop (the upright picture cut to the editor's rectangle), smart crop (cut to the subject
/// `subjectFinder` finds), resize and rotate (the upright picture redrawn at the editor's size or turn) and redact (the
/// editor's boxes burnt into a new bitmap written with nothing else).
public struct ImageIOEngine: ConversionEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private static let edgeCost = 10
    private static let lossyTargets: Set<FormatID> = ["jpg", "heic", "avif", "jp2"]
    /// Formats Compress re-encodes in place; PNG's compress tool is the pngquant plugin.
    private static let compressibleFormats: Set<FormatID> = ["jpg", "heic", "avif"]
    /// A PDF is read and written by ImageIO, but it holds pages, not an image with metadata.
    private static let metadataToolExcludedFormats: Set<FormatID> = ["pdf"]
    /// A PDF holds pages; an icon cut to an arbitrary size is no valid icon (P84: ImageIO published an ICO it could
    /// not read back, and ICNS refuses most sizes). Smart crop, resize, rotate and Vision's Straighten document take
    /// the same formats (P261, P197, P198, P262), through `cropFormats()`.
    private static let cropExcludedFormats: Set<FormatID> = ["pdf", "ico", "icns"]
    /// Targets that cannot store transparency; the image is flattened onto white first.
    static let opaqueTargets: Set<FormatID> = ["jpg", "bmp"]
    /// Targets whose files store the EXIF orientation tag, so the full-size path may leave the pixels unrotated.
    /// Any other target gets the rotation baked into the pixels instead. avif drops the tag on this macOS and the
    /// jp2 encoder fails to write when the tag is set, so both are deliberately absent. PNG can carry the tag (eXIf),
    /// but many readers, cwebp among them, ignore it, so PNG output (also the hop to WebP) is always upright.
    private static let orientationPreservingTargets: Set<FormatID> = ["jpg", "tiff", "heic"]
    /// WebP output comes from the cwebp plugin, even on systems whose ImageIO can write it.
    private static let excludedTargets: Set<FormatID> = ["webp"]
    /// Metadata dictionaries removed by `stripMetadata`.
    private static var metadataDictionaries: [CFString] { [
        kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
        kCGImageProperty8BIMDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyCIFFDictionary,
        kCGImagePropertyRawDictionary,
    ] }

    /// The PNG dictionary's keys that describe how the pixels are stored. Everything else in it is text a writer
    /// feeds back into tEXt, XMP and eXIf chunks (Author, Comment, Copyright, Software, Title, ...).
    private static var technicalPNGKeys: Set<CFString> { [
        kCGImagePropertyPNGGamma, kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGsRGBIntent,
        kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
        kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
        kCGImagePropertyAPNGFrameInfoArray, kCGImagePropertyAPNGCanvasPixelWidth, kCGImagePropertyAPNGCanvasPixelHeight,
    ] }
    private static var technicalExifKeys: Set<CFString> { [
        kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
        kCGImagePropertyExifVersion, kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifFlashPixVersion,
    ] }
    private static var technicalTIFFKeys: Set<CFString> { [
        kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
        kCGImagePropertyTIFFResolutionUnit, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
        kCGImagePropertyTIFFTileLength, kCGImagePropertyTIFFTileWidth,
    ] }
    /// Formats whose encoder refuses quality 1.0 (checked on this macOS), so the metadata-free re-encode tries 0.99.
    private static let encodersRefusingFullQuality: Set<FormatID> = ["avif"]
    /// Formats that can hold several images, all of which the metadata-free re-encode keeps.
    private static let multiImageFormats: Set<FormatID> = ["tiff", "gif", "heic", "ico"]

    /// What remains in a file after Remove metadata: how the pixels are stored, never what or where was shot.
    private static let technicalMetadataTags: Set<String> = [
        "tiff:Orientation", "tiff:Compression", "tiff:PhotometricInterpretation", "tiff:ResolutionUnit",
        "tiff:XResolution", "tiff:YResolution", "tiff:TileLength", "tiff:TileWidth",
        "exif:ColorSpace", "exif:PixelXDimension", "exif:PixelYDimension", "exif:ExifVersion",
        "exif:ComponentsConfiguration", "exif:FlashPixVersion", "iio:hasXMP",
    ]

    private let formats: FormatRegistry
    let subjectFinder: any SubjectFinding

    public init(formats: FormatRegistry = .builtIn, subjectFinder: any SubjectFinding = SystemSubjectFinder()) {
        self.formats = formats
        self.subjectFinder = subjectFinder
    }

    public var id: EngineID { "imageio" }
    public var displayName: String { "ImageIO" }
    public var maxConcurrentJobs: Int { ProcessInfo.processInfo.activeProcessorCount }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        let (readable, writable) = readableAndWritable()
        let croppable = Set(cropFormats())
        var edges: [ConversionEdge] = []
        for from in readable.sorted(by: { $0.rawValue < $1.rawValue }) {
            for to in writable.sorted(by: { $0.rawValue < $1.rawValue }) {
                var flags: EdgeFlags = []
                if Self.lossyTargets.contains(to) { flags.insert(.lossy) }
                if to == "pdf" { flags.insert(.directOnly) }
                edges.append(ConversionEdge(from: from, to: to, engineID: id, cost: Self.edgeCost, flags: flags))
            }
        }
        for format in readable.intersection(writable).sorted(by: { $0.rawValue < $1.rawValue }) {
            if Self.compressibleFormats.contains(format) {
                edges.append(ConversionEdge(
                    from: format, to: format, engineID: id, cost: Self.edgeCost, flags: .lossy, operation: "compress"
                ))
            }
            if Self.targetSizeLossyFormats.contains(format) || Self.targetSizeLosslessFormats.contains(format) {
                edges.append(ConversionEdge(
                    from: format, to: format, engineID: id, cost: Self.edgeCost, flags: .lossy, operation: "target-size"
                ))
            }
            if !Self.metadataToolExcludedFormats.contains(format) {
                edges.append(ConversionEdge(
                    from: format, to: format, engineID: id, cost: Self.edgeCost, flags: [], operation: "strip-metadata"
                ))
            }
            if croppable.contains(format) {
                for operation in ["crop", "smart-crop", "resize", "rotate"] {
                    edges.append(Self.editEdge(format, operation: operation, engineID: id))
                }
            }
            if Self.redactFormats.contains(format) {
                edges.append(ConversionEdge(
                    from: format, to: format, engineID: id, cost: Self.edgeCost,
                    flags: Self.redactLossyFormats.contains(format) ? .lossy : [], operation: "redact"
                ))
            }
        }
        return edges
    }

    /// The formats Crop takes, sorted: every format ImageIO reads and writes but `cropExcludedFormats`.
    func cropFormats() -> [FormatID] {
        let (readable, writable) = readableAndWritable()
        return readable.intersection(writable).subtracting(Self.cropExcludedFormats).sorted { $0.rawValue < $1.rawValue }
    }

    /// An edit of `format` written back as `format`: lossy where a conversion to it is (P84).
    static func editEdge(_ format: FormatID, operation: String, engineID: EngineID) -> ConversionEdge {
        ConversionEdge(
            from: format, to: format, engineID: engineID, cost: edgeCost,
            flags: lossyTargets.contains(format) ? .lossy : [], operation: operation
        )
    }

    private func readableAndWritable() -> (readable: Set<FormatID>, writable: Set<FormatID>) {
        (
            formatIDs(of: CGImageSourceCopyTypeIdentifiers()),
            formatIDs(of: CGImageDestinationCopyTypeIdentifiers()).subtracting(Self.excludedTargets)
        )
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        switch step.operation {
        case nil, "compress": return try await reencode(step, progress: progress)
        case "strip-metadata": return try await removeMetadata(step, progress: progress)
        case "target-size": return try compressToSize(step, progress: progress)
        case "crop": return try crop(step, progress: progress)
        case "smart-crop": return try await smartCrop(step, progress: progress)
        case "resize": return try resize(step, progress: progress)
        case "rotate": return try rotate(step, progress: progress)
        case "redact": return try redact(step, progress: progress)
        default: throw Failure("ImageIO has no \(step.operation ?? "") tool")
        }
    }

    /// Copies the image data of the source without recompressing it, keeping only the orientation tag and the color
    /// profile. Where ImageIO cannot copy the format, or the copy still carries metadata, the image is re-encoded at full
    /// quality without it.
    private func removeMetadata(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard let destinationType = step.to.utTypeIdentifier,
            let source = CGImageSourceCreateWithURL(step.input as CFURL, nil), CGImageSourceGetCount(source) > 0
        else { return try await reencodeWithoutMetadata(step, progress: progress) }

        let output = step.suggestedOutput
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, destinationType as CFString, CGImageSourceGetCount(source), nil
        ) else { return try await reencodeWithoutMetadata(step, progress: progress) }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let kept = CGImageMetadataCreateMutable()
        if let orientation = (sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            CGImageMetadataSetValueWithPath(kept, nil, "tiff:Orientation" as CFString, orientation as CFNumber)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: kept,
            kCGImageDestinationMergeMetadata: false,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            try? FileManager.default.removeItem(at: output)
            return try await reencodeWithoutMetadata(step, progress: progress)
        }
        try Task.checkCancellation()
        // PNG, TIFF and HEIC copies can keep EXIF, IPTC or XMP that the empty metadata did not remove.
        guard Self.carriesOnlyTechnicalMetadata(output) else {
            try? FileManager.default.removeItem(at: output)
            return try await reencodeWithoutMetadata(step, progress: progress)
        }
        progress(1)
        return output
    }

    /// Whether every image of the file carries only technical metadata: no GPS, IPTC, maker notes or other
    /// dictionary, nothing but storage keys in {Exif}, {TIFF} and {PNG}, and no XMP or other tag.
    private static func carriesOnlyTechnicalMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let alwaysEmpty = metadataDictionaries.filter { $0 != kCGImagePropertyExifDictionary && $0 != kCGImagePropertyTIFFDictionary }
        let allowedKeys: [(CFString, Set<CFString>)] = [
            (kCGImagePropertyExifDictionary, technicalExifKeys), (kCGImagePropertyTIFFDictionary, technicalTIFFKeys),
            (kCGImagePropertyPNGDictionary, technicalPNGKeys),
        ]
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            guard alwaysEmpty.allSatisfy({ properties[$0] == nil }) else { return false }
            for (dictionary, allowed) in allowedKeys {
                let keys = (properties[dictionary] as? [CFString: Any])?.keys ?? [:].keys
                if !Set(keys).isSubset(of: allowed) { return false }
            }
            guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { continue }
            var clean = true
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
                if !technicalMetadataTags.contains(path as String) { clean = false }
                return clean
            }
            if !clean { return false }
        }
        return true
    }

    private func reencodeWithoutMetadata(
        _ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var options = step.options
        options.quality = 1
        options.stripMetadata = true
        let fallback = ConversionStep(
            input: step.input, stagingDirectory: step.stagingDirectory, from: step.from, to: step.to, options: options,
            operation: step.operation
        )
        do {
            return try await reencode(fallback, progress: progress)
        } catch where Self.encodersRefusingFullQuality.contains(step.to.id) && !(error is CancellationError) {
            options.quality = 0.99
            return try await reencode(
                ConversionStep(
                    input: step.input, stagingDirectory: step.stagingDirectory, from: step.from, to: step.to,
                    options: options, operation: step.operation
                ),
                progress: progress
            )
        }
    }

    private func reencode(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard let destinationType = step.to.utTypeIdentifier else {
            throw Failure("\(step.to.displayName) has no system type, so ImageIO cannot write it")
        }
        guard let source = CGImageSourceCreateWithURL(step.input as CFURL, nil) else {
            throw Failure("cannot open \(step.input.lastPathComponent) as an image")
        }
        let sourceFrames = CGImageSourceGetCount(source)
        guard sourceFrames > 0 else {
            throw Failure("\(step.input.lastPathComponent) contains no image")
        }
        // GIF output keeps every frame of an animated source (one whose frames carry a GIF, APNG, HEICS or WebP delay),
        // with its timing. Every other target, and every other source, gets frame 0 only: that includes multi-image
        // sources without timing, such as a multi-size ICO or a multi-page TIFF.
        let isAnimation = step.to.id == "gif" && sourceFrames > 1 && Self.hasFrameDelay(source)
        // Remove metadata must not drop the other pages of a multi-page file.
        let keepsEveryImage = step.operation == "strip-metadata" && Self.multiImageFormats.contains(step.to.id)
        let frameCount = isAnimation || keepsEveryImage ? sourceFrames : 1

        let output = step.suggestedOutput
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, destinationType as CFString, frameCount, nil
        ) else {
            throw Failure("cannot create a \(step.to.displayName) file; ImageIO cannot write that format here")
        }
        do {
            if isAnimation, let loopCount = Self.loopCount(of: source) {
                let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
                CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
            }
            for index in 0..<frameCount {
                try Task.checkCancellation()
                try addFrame(index, of: source, to: destination, step: step, animated: isAnimation)
                if isAnimation { progress(Double(index + 1) / Double(frameCount + 1)) }
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else {
                throw Failure("cannot write \(output.lastPathComponent) as \(step.to.displayName)")
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
        return output
    }

    /// Decodes frame `index` with the step's size options and appends it to `destination`. An `animated` frame
    /// carries its delay as GIF frame properties.
    private func addFrame(
        _ index: Int, of source: CGImageSource, to destination: CGImageDestination, step: ConversionStep, animated: Bool
    ) throws {
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let (image, orientationBakedIn) = try decode(
            source, at: index, properties: sourceProperties, options: step.options, target: step.to.id, input: step.input
        )
        let finalImage = Self.opaqueTargets.contains(step.to.id) ? flattenedOnWhite(image) : image

        var properties = Self.outputProperties(
            from: sourceProperties, stripMetadata: step.options.stripMetadata,
            orientationBakedIn: orientationBakedIn, size: (finalImage.width, finalImage.height)
        )
        properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, step.options.quality))
        if animated {
            properties[kCGImagePropertyGIFDictionary] = Self.gifFrameProperties(delayOf: sourceProperties)
        }
        CGImageDestinationAddImage(destination, finalImage, properties as CFDictionary)
    }

    // MARK: Animation

    /// Where each animated format keeps its timing: (frame and file dictionary, delay, unclamped delay, loop count).
    private static var animationKeys: [(dictionary: CFString, delay: CFString, unclampedDelay: CFString, loopCount: CFString)] { [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime,
         kCGImagePropertyGIFLoopCount),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime,
         kCGImagePropertyAPNGLoopCount),
        (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSUnclampedDelayTime,
         kCGImagePropertyHEICSLoopCount),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPUnclampedDelayTime,
         kCGImagePropertyWebPLoopCount),
    ] }

    /// Whether the source is an animation: its first frame carries a delay in one of `animationKeys`' dictionaries.
    static func hasFrameDelay(_ source: CGImageSource) -> Bool {
        let frame = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return frameDelay(of: frame) != nil
    }

    /// The source's loop count (0 repeats forever), or nil when it does not say.
    private static func loopCount(of source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        for keys in animationKeys {
            if let count = (properties[keys.dictionary] as? [CFString: Any])?[keys.loopCount] as? NSNumber {
                return count.intValue
            }
        }
        return nil
    }

    /// The frame's (delay, unclamped delay), from whichever animation dictionary it has; either falls back to the other.
    private static func frameDelay(of frame: [CFString: Any]) -> (delay: NSNumber, unclamped: NSNumber)? {
        for keys in animationKeys {
            guard let dictionary = frame[keys.dictionary] as? [CFString: Any] else { continue }
            let delay = dictionary[keys.delay] as? NSNumber
            let unclamped = dictionary[keys.unclampedDelay] as? NSNumber
            if let value = delay ?? unclamped { return (delay ?? value, unclamped ?? value) }
        }
        return nil
    }

    /// GIF frame properties holding the frame's delay, or none when the frame has no timing.
    private static func gifFrameProperties(delayOf frame: [CFString: Any]) -> [CFString: Any] {
        guard let (delay, unclamped) = frameDelay(of: frame) else { return [:] }
        return [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: unclamped]
    }

    // MARK: Decoding

    /// Returns frame `index` decoded and whether the source orientation is already applied to its pixels.
    private func decode(
        _ source: CGImageSource, at index: Int, properties: [CFString: Any], options: PresetOptions, target: FormatID,
        input: URL
    ) throws -> (CGImage, Bool) {
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longestSide = max(width, height)

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        var limit = Self.pixelLimit(longestSide: longestSide, options: options)
        if let requested = limit, requested >= longestSide { limit = nil }  // never upscale
        if limit == nil, longestSide > 0, orientation != 1, !Self.orientationPreservingTargets.contains(target) {
            limit = longestSide  // full size, but through the transforming thumbnail path
        }

        if let limit {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary) else {
                throw Failure("cannot decode \(input.lastPathComponent) at \(limit) px")
            }
            return (thumbnail, true)
        }
        guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw Failure("cannot decode \(input.lastPathComponent)")
        }
        return (full, false)
    }

    /// The smaller of the sizes `scale` and `maxPixelSize` ask for, or nil when neither is set.
    static func pixelLimit(longestSide: Int, options: PresetOptions) -> Int? {
        var limits: [Int] = []
        if let scale = options.scale { limits.append(max(1, Int((Double(longestSide) * scale).rounded()))) }
        if let maxPixelSize = options.maxPixelSize { limits.append(max(1, maxPixelSize)) }
        return limits.min()
    }

    // MARK: Encoding

    static func outputProperties(
        from source: [CFString: Any], stripMetadata: Bool, orientationBakedIn: Bool, size: (width: Int, height: Int)
    ) -> [CFString: Any] {
        var properties = source
        if stripMetadata {
            for key in metadataDictionaries { properties[key] = nil }
            if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                properties[kCGImagePropertyPNGDictionary] = png.filter { technicalPNGKeys.contains($0.key) }
            }
        }
        // These describe the source's pixels; the encoder writes the real values for the output.
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyHasAlpha] {
            properties[key] = nil
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = size.width
            exif[kCGImagePropertyExifPixelYDimension] = size.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if orientationBakedIn {
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        return properties
    }

    /// Draws `image` onto opaque white when it has an alpha channel; otherwise returns it unchanged.
    func flattenedOnWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { spaces.append(srgb) }
        for space in spaces {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            if let flattened = context.makeImage() { return flattened }
        }
        return image
    }

    private func formatIDs(of identifiers: CFArray) -> Set<FormatID> {
        let identifiers = identifiers as? [String] ?? []
        return Set(identifiers.compactMap { formats.format(forUTType: $0)?.id })
    }
}
