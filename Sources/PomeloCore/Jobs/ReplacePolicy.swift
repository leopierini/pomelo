import Foundation
import ImageIO

/// Which results may replace their source (P273, P275): only a result that keeps what the source holds. A format
/// change is allowed only in kinds whose conversions keep what a person sees or hears, never from a source whose
/// layers, vectors or extra tracks the conversion drops; documents and spreadsheets never (an export is not the file
/// you edit, and a CSV keeps one sheet).
public enum ReplacePolicy {
    static let formatChangeKinds: Set<FormatCategory> = [.image, .video, .audio, .subtitle, .archive]
    /// A PSD's layers, an EXR's channels, an SVG's vectors and an MKV's extra audio and subtitle tracks are lost.
    static let richSources: Set<FormatID> = ["psd", "exr", "svg", "mkv"]

    /// Whether a result in `result`'s format may replace a source in `source`'s, before the file itself is read.
    public static func allows(from source: FileFormat, to result: FileFormat) -> Bool {
        guard source.category != .other, source.category == result.category else { return false }
        if source.id == result.id { return true }
        return formatChangeKinds.contains(source.category) && !richSources.contains(source.id)
    }

    /// An animated GIF, a multi-page TIFF or an image sequence: the image tools keep one frame.
    public static func holdsSeveralImages(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}
