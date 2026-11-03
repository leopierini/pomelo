// What an editor shows of its file, read off the main thread after the panel is up: sizes in the displayed
// orientation (EXIF orientation or a video's preferred transform applied), so the editor's rectangles are in the
// same space as `UnitRect` and land on what was shown (global constraints, Coordinates).
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PomeloCore

enum EditorMedia {
    struct MediaInfo: Equatable, Sendable {
        var bytes: Int64
        /// Upright, in pixels; nil for audio and PDFs.
        var displaySize: CGSize?
        /// A video's stored size, before its rotation: what Compress to size plans its height from.
        var encodedSize: CGSize?
        var durationSeconds: Double?
        var frameRate: Double?
        var hasAudio: Bool
        var pageCount: Int?
    }

    struct Unreadable: Error, CustomStringConvertible {
        var description: String
    }

    static func info(of url: URL) async throws -> MediaInfo {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        switch FormatRegistry.builtIn.format(for: url)?.category {
        case .image:
            return MediaInfo(bytes: bytes, displaySize: try imageSize(of: url), hasAudio: false)
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else { throw Unreadable(description: "not a PDF") }
            return MediaInfo(bytes: bytes, hasAudio: false, pageCount: document.numberOfPages)
        case .video, .audio:
            return try await mediaInfo(of: url, bytes: bytes)
        default:
            throw Unreadable(description: "not an image, a PDF or a recording")
        }
    }

    /// A picture's facts and its upright size, or nil when it can't be read or is under a pixel: the editors that
    /// show a picture call such a file damaged.
    static func picture(of url: URL) async -> (info: MediaInfo, size: CGSize)? {
        guard let info = try? await info(of: url), let size = info.displaySize, size.width >= 1, size.height >= 1 else {
            return nil
        }
        return (info, size)
    }

    /// An upright thumbnail of an image (decoded as the engines decode it), or a recording's first frame.
    static func preview(of url: URL, maxPixelSize: Int) async -> CGImage? {
        switch FormatRegistry.builtIn.format(for: url)?.category {
        case .video:
            return await frame(of: url, at: 0, maxPixelSize: maxPixelSize)
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                       options as CFDictionary)
        }
    }

    /// The video frame at `seconds`, upright.
    static func frame(of url: URL, at seconds: Double, maxPixelSize: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: - Private

    /// The primary image's, as the engines decode it (`OrientedImage`): a HEIC's first image need not be it.
    private static func imageSize(of url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw Unreadable(description: "not an image")
        }
        // Orientations 5 to 8 turn the picture a quarter: what shows is the stored height wide.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func mediaInfo(of url: URL, bytes: Int64) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var displaySize: CGSize?
        var encodedSize: CGSize?
        var frameRate: Double?
        if let video {
            let (naturalSize, transform, rate) = try await video.load(.naturalSize, .preferredTransform,
                                                                      .nominalFrameRate)
            let turned = naturalSize.applying(transform)
            displaySize = CGSize(width: abs(turned.width), height: abs(turned.height))
            encodedSize = naturalSize
            frameRate = rate > 0 ? Double(rate) : nil
        }
        return MediaInfo(bytes: bytes, displaySize: displaySize, encodedSize: encodedSize,
                         durationSeconds: duration.seconds.isFinite ? duration.seconds : nil,
                         frameRate: frameRate, hasAudio: !audio.isEmpty)
    }
}
