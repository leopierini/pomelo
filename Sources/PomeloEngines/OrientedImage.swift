import CoreGraphics
import Foundation
import ImageIO

/// The image an editor showed: the primary image of a file with its EXIF orientation applied to the pixels. Compress
/// to size, crop and redaction all work on it, so their output is upright and holds what was shown.
enum OrientedImage {
    struct Failure: Error, CustomStringConvertible, Equatable {
        let description: String
    }

    static func primary(of source: CGImageSource) -> Int {
        CGImageSourceGetPrimaryImageIndex(source)
    }

    /// More than one frame with a frame delay: an animation, whose frames a single upright image would lose.
    static func isAnimated(_ source: CGImageSource) -> Bool {
        CGImageSourceGetCount(source) > 1 && ImageIOEngine.hasFrameDelay(source)
    }

    /// The primary image at full size, upright. The thumbnail path is the one ImageIO call that applies the
    /// orientation; asked for the larger side with `FromImageAlways`, it decodes the full image, never an embedded
    /// thumbnail. `straight: false` is for the tests, which compare the two paths.
    static func decodeUpright(_ source: CGImageSource, straight allowsStraight: Bool = true) throws -> CGImage {
        let index = primary(of: source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        if allowsStraight, let image = straightDecode(source, index: index, properties: properties) { return image }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard max(width, height) > 0 else { throw Failure(description: "the image has no size") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw Failure(description: "cannot decode the image")
        }
        return image
    }

    static func decodesStraight(_ source: CGImageSource) -> Bool {
        let index = primary(of: source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        return straightDecode(source, index: index, properties: properties) != nil
    }

    /// An upright, opaque 8-bit sRGB PNG needs no transform, and the thumbnail path holds two more copies of it (a
    /// 12 MP crop peaked at 155 MB against 64); for these the two write the same bytes. Output must not
    /// change, so the rest stay on that path: JPEG and HEIC decode differently there, it premultiplies transparent
    /// pixels (P150; a palette with tRNS arrives here as RGBA), and 16-bit, grey or wide-gamut PNGs would keep their
    /// own depth or colours.
    private static func straightDecode(_ source: CGImageSource, index: Int, properties: [CFString: Any]) -> CGImage? {
        guard CGImageSourceGetType(source) as String? == "public.png",
              ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, index, nil),
              image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo),
              image.colorSpace?.name == CGColorSpace.sRGB else { return nil }
        return image
    }
}
