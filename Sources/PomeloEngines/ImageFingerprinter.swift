import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// What a picture looks like, reduced so two pictures can be compared: the smaller the distance, the more alike.
public protocol ImageFingerprint: Sendable {
    func distance(to other: any ImageFingerprint) -> Float
}

/// Reads a picture's fingerprint. A seam, so Find duplicates' tests give fixed prints (P263). `context` is the run's
/// one Core Image context: a context per print kept about 3 MB of caches each until the run ended (final review).
public protocol ImageFingerprinting: Sendable {
    func fingerprint(of image: URL, using context: CIContext) throws -> any ImageFingerprint
}

/// Vision's `VNGenerateImageFeaturePrintRequest` on the upright primary image. Only the print leaves it; nothing is
/// logged.
public struct SystemImageFingerprinter: ImageFingerprinting {
    /// The picture is decoded at most this large; `analysisSide` is far below it.
    static let decodeSide = 1024
    /// Every picture is brought to this long side with Lanczos and blurred by `blurSigma` before Vision sees it, so
    /// grain and compression noise (finer than what a picture shows) don't count: without it a half-size copy of a
    /// grainy photo printed as far from its original as a burst frame (P268's measurements).
    static let analysisSide = 256
    static let blurSigma = 1.0

    public init() {}

    public func fingerprint(of image: URL, using context: CIContext) throws -> any ImageFingerprint {
        let name = image.lastPathComponent
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(image as CFURL, options) else {
            throw VisionEngine.Failure("cannot open \(name)")
        }
        // The thumbnail path is the one that applies the EXIF orientation; `FromImageAlways` decodes the picture
        // itself, never an embedded thumbnail.
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.decodeSide,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            source, CGImageSourceGetPrimaryImageIndex(source), thumbnail as CFDictionary
        ) else { throw VisionEngine.Failure("cannot decode \(name)") }
        let request = VNGenerateImageFeaturePrintRequest()
        // Pinned: `defaultLookAlikeThreshold` was measured on this revision's distances.
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        do {
            try VNImageRequestHandler(cgImage: try Self.normalised(upright, in: context), orientation: .up, options: [:])
                .perform([request])
        } catch {
            throw VisionEngine.Failure("cannot look at \(name): \(error.localizedDescription)")
        }
        guard let print = request.results?.first else { throw VisionEngine.Failure("cannot look at \(name)") }
        return SystemImageFingerprint(observation: print)
    }

    /// `image` on white, its long side exactly `analysisSide`, blurred, as opaque 8-bit sRGB, whatever its size or
    /// pixel format.
    private static func normalised(_ image: CGImage, in context: CIContext) throws -> CGImage {
        let scale = Double(analysisSide) / Double(max(image.width, image.height, 1))
        let frame = CGRect(
            x: 0, y: 0, width: max(1, (Double(image.width) * scale).rounded()),
            height: max(1, (Double(image.height) * scale).rounded())
        )
        let picture = CIImage(cgImage: image)
        let opaque = picture.composited(over: CIImage(color: .white).cropped(to: picture.extent))
        let scaled = opaque.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        // Clamped, so the blur doesn't darken the edges with the transparency beyond them.
        let blurred = scaled.clampedToExtent().applyingGaussianBlur(sigma: blurSigma).cropped(to: frame)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let drawn = context.createCGImage(blurred, from: frame, format: .RGBA8, colorSpace: space)
        else { throw VisionEngine.Failure("cannot redraw the picture") }
        return drawn
    }
}

/// The observation is never changed after Vision made it.
private struct SystemImageFingerprint: ImageFingerprint, @unchecked Sendable {
    let observation: VNFeaturePrintObservation

    func distance(to other: any ImageFingerprint) -> Float {
        guard let other = other as? SystemImageFingerprint else { return .infinity }
        var distance: Float = 0
        do {
            try observation.computeDistance(&distance, to: other.observation)
        } catch {
            return .infinity
        }
        return distance
    }
}
