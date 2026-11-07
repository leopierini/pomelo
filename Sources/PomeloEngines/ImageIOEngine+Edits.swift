import CoreGraphics
import Foundation
import ImageIO
import PomeloCore

extension ImageIOEngine {
    /// P84: these writers refuse a `cropping(to:)` sub-image of the picture `OrientedImage` decodes (checked on this
    /// macOS: the whole picture and any fresh copy of the cut write fine), so the cut is copied out first.
    static let freshPixelTargets: Set<FormatID> = ["bmp", "tga", "exr"]

    /// Formats Redact writes (P27). gif and avif are left out until ruled on: `RedactionCheck` refuses what their bare
    /// encoders write (gif's {GIF} frame timing; an AVIF answers the HEIC thumbnail probe with its own picture), and
    /// its allowlist is never widened beyond what ImageIO writes for a bare image (P70, P274).
    static let redactFormats: Set<FormatID> = ["jpg", "png", "heic", "tiff", "bmp"]
    static let redactLossyFormats: Set<FormatID> = ["jpg", "heic", "avif"]

    /// Compress to size lowers these formats' quality first, then their pixels.
    static let targetSizeLossyFormats: Set<FormatID> = ["jpg", "heic", "avif"]
    /// These formats can only lose pixels.
    static let targetSizeLosslessFormats: Set<FormatID> = ["png", "tiff", "bmp"]

    /// The system type `step.to` is written as, and the opened input, with the failures every editor reports alike.
    func openForEdit(_ step: ConversionStep) throws -> (destinationType: String, source: CGImageSource) {
        guard let destinationType = step.to.utTypeIdentifier else {
            throw Failure("\(step.to.displayName) has no system type, so ImageIO cannot write it")
        }
        guard let source = CGImageSourceCreateWithURL(step.input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure("cannot open \(step.input.lastPathComponent) as an image")
        }
        return (destinationType, source)
    }

    /// Writes `image` to the step's staged output; a file that could not be finished is removed.
    private func writeImage(
        _ image: CGImage, properties: [CFString: Any], as destinationType: String, for step: ConversionStep,
        named name: URL? = nil
    ) throws -> URL {
        let output = name ?? step.suggestedOutput
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, destinationType as CFString, 1, nil)
        else { throw Failure("cannot create a \(step.to.displayName) file; ImageIO cannot write that format here") }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent) as \(step.to.displayName)")
        }
        return output
    }

    /// The primary image decoded upright, with its properties for the writer; an animation is refused with
    /// `animated` (an edit of one frame would drop the rest).
    static func uprightPrimary(
        _ source: CGImageSource, animated: String
    ) throws -> (properties: [CFString: Any], image: CGImage) {
        guard !OrientedImage.isAnimated(source) else { throw ConversionError.notApplicable(reason: animated) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, OrientedImage.primary(of: source), nil)
            as? [CFString: Any] ?? [:]
        return (properties, try OrientedImage.decodeUpright(source))
    }

    /// Re-encodes the upright primary image until it fits `targetBytes`, in memory, so only the winner is written.
    func compressToSize(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard let target = step.options.targetBytes else {
            throw ConversionError.notApplicable(reason: "No size was chosen")
        }
        let label = TargetSize.label(bytes: target)
        let (destinationType, source) = try openForEdit(step)
        if let size = try? step.input.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) <= target {
            throw ConversionError.notApplicable(reason: "It's already under \(label)")
        }
        let (sourceProperties, upright) = try Self.uprightPrimary(source, animated: "Animated images can't be resized")
        let image = Self.opaqueTargets.contains(step.to.id) ? flattenedOnWhite(upright) : upright
        let lossy = Self.targetSizeLossyFormats.contains(step.to.id)
        var encodes = 0
        var scaled: (scale: Double, image: CGImage)?
        let found = try ImageSizeSearch.search(
            targetBytes: target, lossy: lossy, longestSide: max(image.width, image.height)
        ) { quality, scale in
            try Task.checkCancellation()
            encodes += 1
            progress(Double(encodes) / Double(ImageSizeSearch.maxEncodes + 1))
            let pixels: CGImage
            if scale >= 1 {
                pixels = image
            } else if let scaled, scaled.scale == scale {
                pixels = scaled.image
            } else {
                pixels = try Self.scaled(image, by: scale)
                scaled = (scale, pixels)
            }
            return try Self.encode(
                pixels, as: destinationType, quality: lossy ? quality : nil, sourceProperties: sourceProperties,
                stripMetadata: step.options.stripMetadata
            )
        }
        guard let found else { throw ConversionError.notApplicable(reason: "Can't get it under \(label)") }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        do {
            try found.write(to: output, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
        }
        progress(1)
        return output
    }

    /// Cuts the editor's rectangle out of the upright primary image (`OrientedImage`), so the output holds what the
    /// editor showed whatever the stored orientation; it is written upright, with no thumbnail of the uncropped
    /// picture.
    func crop(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard case .crop = step.options.edit else {
            throw ConversionError.notApplicable(reason: CropEdit.wholeImageReason)
        }
        let (destinationType, source) = try openForEdit(step)
        let (sourceProperties, upright) = try Self.uprightPrimary(source, animated: Self.animatedCropReason)
        let kept = try CropEdit.imagePixels(step.options.edit, width: upright.width, height: upright.height)
        let output = try writeCut(kept, of: upright, sourceProperties: sourceProperties, as: destinationType, for: step)
        progress(1)
        return output
    }

    /// Cuts the upright primary image to its subject (P261): `subjectFinder` finds it, `SmartCropRules` adds the
    /// margin or grows it to the preset's shape, and the cut is written exactly as Crop writes it.
    func smartCrop(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let (destinationType, source) = try openForEdit(step)
        let (sourceProperties, upright) = try Self.uprightPrimary(source, animated: Self.animatedCropReason)
        guard let subject = try await subjectFinder.subject(in: upright) else {
            throw ConversionError.notApplicable(reason: SmartCropRules.noSubjectReason)
        }
        guard let rect = SmartCropRules.rect(
            subject: subject, shape: step.options.aspect, imageWidth: upright.width, imageHeight: upright.height
        ) else { throw ConversionError.notApplicable(reason: CropEdit.wholeImageReason) }
        let kept = try CropEdit.imagePixels(.crop(rect), width: upright.width, height: upright.height)
        try Task.checkCancellation()
        let output = try writeCut(kept, of: upright, sourceProperties: sourceProperties, as: destinationType, for: step)
        progress(1)
        return output
    }

    private static let animatedCropReason = "Animated images can't be cropped"

    /// The tail Crop and Smart crop share: `kept` cut out of the upright picture, copied fresh for the writers that
    /// refuse a cut (P84), flattened for the opaque targets, and written upright.
    private func writeCut(
        _ kept: CGRect, of upright: CGImage, sourceProperties: [CFString: Any], as destinationType: String,
        for step: ConversionStep
    ) throws -> URL {
        guard let cut = upright.cropping(to: kept) else {
            throw Failure("cannot cut \(Int(kept.width))x\(Int(kept.height)) out of \(step.input.lastPathComponent)")
        }
        let pixels = Self.freshPixelTargets.contains(step.to.id) ? try Self.freshCopy(of: cut) : cut
        return try writeEdited(pixels, sourceProperties: sourceProperties, as: destinationType, for: step)
    }

    /// The tail of Crop, Smart crop, Rotate and Vision's Straighten document (P262): flattened for the opaque targets
    /// and written upright. Resize does the same itself, since it names its file after the new size.
    func writeEdited(
        _ edited: CGImage, sourceProperties: [CFString: Any], as destinationType: String, for step: ConversionStep
    ) throws -> URL {
        let image = Self.opaqueTargets.contains(step.to.id) ? flattenedOnWhite(edited) : edited
        try Task.checkCancellation()
        return try writeUpright(image, sourceProperties: sourceProperties, as: destinationType, for: step)
    }

    /// Redraws the upright primary image at the editor's size (P197): Width, Height and Scale keep the picture's
    /// proportions, Exact fills the box from the centre of the picture and never stretches. Alpha is kept (flattened on
    /// white for jpg and bmp) and the file is named `<stem>-<width>x<height>`.
    func resize(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard case .resize(let spec) = step.options.edit else {
            throw ConversionError.notApplicable(reason: ResizeEdit.chooseSizeReason)
        }
        let (destinationType, source) = try openForEdit(step)
        let (sourceProperties, upright) = try Self.uprightPrimary(source, animated: "Animated images can't be resized")
        let target = try ResizeEdit.size(step.options.edit, width: upright.width, height: upright.height)
        var kept = CGRect(x: 0, y: 0, width: upright.width, height: upright.height)
        if case .exact = spec {
            kept = ResizeEdit.keptRect(width: upright.width, height: upright.height, target: target)
        }
        guard let cut = upright.cropping(to: kept) else {
            throw Failure("cannot cut \(Int(kept.width))x\(Int(kept.height)) out of \(step.input.lastPathComponent)")
        }
        try Task.checkCancellation()
        let resized = try Self.redrawn(cut, width: target.width, height: target.height) { context, rect in
            context.interpolationQuality = .high
            context.draw(cut, in: rect)
        }
        let image = Self.opaqueTargets.contains(step.to.id) ? flattenedOnWhite(resized) : resized
        try Task.checkCancellation()

        let name = step.stagingDirectory.appending(
            path: "\(OutputNamer.stem(of: step.input))-\(ResizeEdit.nameSuffix(width: target.width, height: target.height))"
                + ".\(step.to.extensions[0])",
            directoryHint: .notDirectory)
        let output = try writeUpright(
            image, sourceProperties: sourceProperties, as: destinationType, for: step, named: name)
        progress(1)
        return output
    }

    /// Turns and flips the pixels of the upright primary image (P198), not the orientation tag: an upload that strips
    /// EXIF would show a tag-only rotation sideways.
    func rotate(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let spec = try RotateEdit.spec(step.options.edit)
        let (destinationType, source) = try openForEdit(step)
        let (sourceProperties, upright) = try Self.uprightPrimary(source, animated: "Animated images can't be rotated")
        let (width, height) = (upright.width, upright.height)
        let size = spec.outputSize(width: width, height: height)
        let transform = spec.transform(width: width, height: height)
        let turned = try Self.redrawn(upright, width: size.width, height: size.height) { context, _ in
            // The transform is top-left and y-down; a bitmap context is y-up, so the output and the picture are flipped
            // around it.
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: CGFloat(size.height))
            context.scaleBy(x: 1, y: -1)
            context.concatenate(transform)
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(upright, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = try writeEdited(turned, sourceProperties: sourceProperties, as: destinationType, for: step)
        progress(1)
        return output
    }

    /// Writes an edited upright picture as the source's own properties describe it (orientation 1, the new pixel size)
    /// at the preset's quality.
    private func writeUpright(
        _ image: CGImage, sourceProperties: [CFString: Any], as destinationType: String, for step: ConversionStep,
        named name: URL? = nil
    ) throws -> URL {
        var properties = Self.outputProperties(
            from: sourceProperties, stripMetadata: step.options.stripMetadata, orientationBakedIn: true,
            size: (image.width, image.height)
        )
        // Explicitly none: the source's thumbnail showed the picture as it was, what the edit cuts away included.
        properties[kCGImageDestinationEmbedThumbnail] = false
        properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, step.options.quality))
        return try writeImage(image, properties: properties, as: destinationType, for: step, named: name)
    }

    /// Burns the boxes into a new bitmap of the upright primary image and writes only that bitmap (P27): no property,
    /// metadata, thumbnail or auxiliary image of the source reaches the output, and `check` (`RedactionCheck`) must
    /// pass on the staged file before it is returned.
    func redact(
        _ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void,
        check: (URL) throws -> Void = RedactionCheck.verify
    ) throws -> URL {
        try Task.checkCancellation()
        progress(0)
        guard case .redact(let spec) = step.options.edit, !spec.boxes.isEmpty else {
            throw ConversionError.notApplicable(reason: Self.nothingToHide)
        }
        let (destinationType, source) = try openForEdit(step)
        guard !OrientedImage.isAnimated(source) else {
            throw ConversionError.notApplicable(reason: "Animated images can't be redacted")
        }
        let upright = try OrientedImage.decodeUpright(source)
        let boxes = spec.boxes.map { $0.pixels(width: upright.width, height: upright.height) }.filter { !$0.isEmpty }
        guard !boxes.isEmpty else { throw ConversionError.notApplicable(reason: Self.nothingToHide) }
        let image = try Self.redacted(
            upright, boxes: boxes, style: spec.style, opaque: Self.opaqueTargets.contains(step.to.id)
        )
        try Task.checkCancellation()

        // Built from nothing: the source's properties are never read, so none can be copied.
        var properties: [CFString: Any] = [kCGImageDestinationEmbedThumbnail: false]
        if Self.redactLossyFormats.contains(step.to.id) {
            properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, step.options.quality))
        }
        let output = try writeImage(image, properties: properties, as: destinationType, for: step)
        do {
            try check(output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.converterFault(engine: id, message: "redacted file kept metadata")
        }
        progress(1)
        return output
    }

    private static let nothingToHide = "Choose something to hide"

    /// `image` drawn into a new 8-bit RGBA bitmap (Display P3 for a wide-gamut source, else sRGB) with every box
    /// replaced: solid black, or near-equal blocks of at least max(16, ceil(longer side / 6)) px, each the mean colour
    /// of its own pixels (solid black for a box under 2 px thin). Every replaced pixel is opaque, so no transparency
    /// is left to carry what was there.
    private static func redacted(_ image: CGImage, boxes: [CGRect], style: RedactionStyle, opaque: Bool) throws -> CGImage {
        let keepsAlpha = !opaque && ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let info = (keepsAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        // P85: a system space, never the source's own: its ICC profile is written into the output byte for byte and
        // can hold private tags or a display's vendor, model and serial.
        let wide = image.colorSpace?.isWideGamutRGB ?? false
        let space = CGColorSpace(name: wide ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        let (width, height) = (image.width, image.height)
        guard let space, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: info
        ), let data = context.data else {
            throw Failure("cannot make a \(width)x\(height) bitmap to redact")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if !keepsAlpha {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
        }
        context.draw(image, in: rect)

        // A bitmap context's memory starts at the top row, so the boxes' top-left pixels index it directly.
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func paint(_ area: CGRect, _ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let offset = (y * width + x) * 4
                    (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]) = (red, green, blue, 255)
                }
            }
        }
        for box in boxes {
            try Task.checkCancellation()
            switch style {
            case .fill:
                paint(box, 0, 0, 0)
            case .pixelate:
                guard let blocks = pixelationBlocks(of: box) else {
                    // A block one pixel thin would be the mean of a strip, close to what it covers; a 1x1 one, the pixel.
                    paint(box, 0, 0, 0)
                    continue
                }
                for block in blocks {
                    let (red, green, blue) = mean(of: block, in: pixels, width: width, alpha: keepsAlpha)
                    paint(block, red, green, blue)
                }
            }
        }
        guard let redacted = context.makeImage() else { throw Failure("cannot render the redacted picture") }
        return redacted
    }

    /// The blocks a pixelated box (whole pixels, inside the picture) is cut into, each filled with its own mean
    /// colour: sides of max(16, ceil(longer side / 6)) px. nil for a box under 2 px thin, which is filled black.
    /// The editor's preview calls this too, so it shows the blocks that will be saved.
    public static func pixelationBlocks(of box: CGRect) -> [CGRect]? {
        guard box.width >= 2, box.height >= 2 else { return nil }
        let side = max(16, Int((Double(max(box.width, box.height)) / 6).rounded(.up)))
        var result: [CGRect] = []
        for rows in blocks(from: Int(box.minY), length: Int(box.height), side: side) {
            for columns in blocks(from: Int(box.minX), length: Int(box.width), side: side) {
                result.append(CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count))
            }
        }
        return result
    }

    /// `length` px from `start` cut into max(1, length / side) near-equal blocks (P86): none is thinner than `side`
    /// unless the whole length is, so no clipped last block can keep a sliver of single source pixels.
    static func blocks(from start: Int, length: Int, side: Int) -> [Range<Int>] {
        let count = max(1, length / side)
        return (0..<count).map { start + $0 * length / count ..< start + ($0 + 1) * length / count }
    }

    /// The block's mean colour in RGBA pixels `width` wide. With `alpha` the pixels are premultiplied, so the sums are
    /// weighted by coverage and divided by the total alpha: transparent pixels count for nothing, and a wholly
    /// transparent block is black. The editor's preview calls this too, so its blocks have the saved colours.
    public static func mean(
        of block: CGRect, in pixels: UnsafePointer<UInt8>, width: Int, alpha: Bool
    ) -> (UInt8, UInt8, UInt8) {
        var sums = (red: 0, green: 0, blue: 0, alpha: 0)
        for y in Int(block.minY)..<Int(block.maxY) {
            for x in Int(block.minX)..<Int(block.maxX) {
                let offset = (y * width + x) * 4
                sums.red += Int(pixels[offset])
                sums.green += Int(pixels[offset + 1])
                sums.blue += Int(pixels[offset + 2])
                sums.alpha += alpha ? Int(pixels[offset + 3]) : 255
            }
        }
        guard sums.alpha > 0 else { return (0, 0, 0) }
        func channel(_ sum: Int) -> UInt8 {
            UInt8(min(255, (Double(sum) * 255 / Double(sums.alpha)).rounded()))
        }
        return (channel(sums.red), channel(sums.green), channel(sums.blue))
    }

    /// One encode in memory, with the source's metadata as a conversion keeps it and the orientation already applied.
    private static func encode(
        _ image: CGImage, as type: String, quality: Double?, sourceProperties: [CFString: Any], stripMetadata: Bool
    ) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else { throw Failure("cannot encode the image") }
        var properties = outputProperties(
            from: sourceProperties, stripMetadata: stripMetadata, orientationBakedIn: true,
            size: (image.width, image.height)
        )
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality)) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot encode the image") }
        return data as Data
    }

    /// `image` drawn into a bitmap of its own pixel format, which keeps an EXR's 16-bit float; where no bitmap
    /// context takes that format, 8-bit RGB in its own RGB colour space or else sRGB, keeping its alpha.
    static func freshCopy(of image: CGImage) throws -> CGImage {
        try redrawn(image, width: image.width, height: image.height) { context, rect in context.draw(image, in: rect) }
    }

    /// A new `width` x `height` bitmap in the formats `freshCopy` tries, painted by `draw` (given the context and its
    /// whole rect, origin at the bottom left).
    static func redrawn(
        _ image: CGImage, width: Int, height: Int, draw: (CGContext, CGRect) -> Void
    ) throws -> CGImage {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let rgbInfo = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        var attempts: [(bits: Int, space: CGColorSpace, info: UInt32)] = []
        if let own = image.colorSpace {
            attempts.append((image.bitsPerComponent, own, image.bitmapInfo.rawValue))
            if own.model == .rgb { attempts.append((8, own, rgbInfo)) }
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { attempts.append((8, srgb, rgbInfo)) }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        for attempt in attempts {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: attempt.bits, bytesPerRow: 0,
                space: attempt.space, bitmapInfo: attempt.info
            ) else { continue }
            draw(context, rect)
            if let copy = context.makeImage() { return copy }
        }
        throw Failure("cannot make a \(width)x\(height) bitmap from the \(image.width)x\(image.height) picture")
    }

    /// `image` resampled to `scale` of its size with high-quality interpolation, keeping its alpha. The image's own
    /// color space is used where a bitmap context accepts it; anything else (CMYK, grey with alpha) becomes sRGB.
    private static func scaled(_ image: CGImage, by scale: Double) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let rgbInfo = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        var attempts: [(CGColorSpace, UInt32)] = []
        if let own = image.colorSpace {
            if own.model == .rgb { attempts.append((own, rgbInfo)) }
            if own.model == .monochrome, !hasAlpha { attempts.append((own, CGImageAlphaInfo.none.rawValue)) }
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) { attempts.append((srgb, rgbInfo)) }
        for (space, info) in attempts {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: info
            ) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if let resized = context.makeImage() { return resized }
        }
        throw Failure("cannot resize the image to \(width)x\(height)")
    }
}
