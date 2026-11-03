import Foundation
import UniformTypeIdentifiers

public struct FormatRegistry: Sendable {
    public let all: [FileFormat]
    private let byID: [FormatID: FileFormat]
    private let byExtension: [String: FileFormat]
    private let byUTType: [String: FileFormat]

    /// When two formats claim the same id, extension or UTType, the first one wins.
    public init(formats: [FileFormat]) {
        var all: [FileFormat] = []
        var byID: [FormatID: FileFormat] = [:]
        var byExtension: [String: FileFormat] = [:]
        var byUTType: [String: FileFormat] = [:]
        for format in formats where byID[format.id] == nil {
            all.append(format)
            byID[format.id] = format
            for ext in format.extensions where byExtension[ext] == nil {
                byExtension[ext] = format
            }
            if let ut = format.utTypeIdentifier, byUTType[ut] == nil {
                byUTType[ut] = format
            }
        }
        self.all = all
        self.byID = byID
        self.byExtension = byExtension
        self.byUTType = byUTType
    }

    public func format(id: FormatID) -> FileFormat? { byID[id] }

    public func format(forExtension ext: String) -> FileFormat? {
        byExtension[ext.lowercased()]
    }

    public func format(forUTType identifier: String) -> FileFormat? { byUTType[identifier] }

    /// Tries the URL's extension first, then falls back to the file's content type.
    public func format(for url: URL) -> FileFormat? {
        if let match = format(forExtension: url.pathExtension) { return match }
        if let identifier = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier {
            return format(forUTType: identifier)
        }
        return nil
    }
}

extension FormatRegistry {
    public static let builtIn = FormatRegistry(formats: builtInFormats)

    // Out of line: inlined, its calls made `builtInFormats` 22 KB of code per architecture (Phase 6 Task 7).
    @inline(never)
    private static func f(
        _ id: String, _ name: String, _ category: FormatCategory,
        _ aliases: [String] = [], ut: String?
    ) -> FileFormat {
        FileFormat(
            id: FormatID(id), displayName: name, category: category,
            extensions: [id] + aliases, utTypeIdentifier: ut
        )
    }

    private static let builtInFormats: [FileFormat] = [
        f("png", "PNG", .image, ut: "public.png"),
        f("jpg", "JPEG", .image, ["jpeg", "jpe", "jfif"], ut: "public.jpeg"),
        f("gif", "GIF", .image, ut: "com.compuserve.gif"),
        f("tiff", "TIFF", .image, ["tif"], ut: "public.tiff"),
        f("heic", "HEIC", .image, ["heif", "hif"], ut: "public.heic"),
        f("avif", "AVIF", .image, ut: "public.avif"),
        f("webp", "WebP", .image, ut: "org.webmproject.webp"),
        f("bmp", "BMP", .image, ["dib"], ut: "com.microsoft.bmp"),
        f("ico", "ICO", .image, ut: "com.microsoft.ico"),
        f("icns", "ICNS", .image, ut: "com.apple.icns"),
        f("jp2", "JPEG 2000", .image, ["j2k", "jpf", "jpx"], ut: "public.jpeg-2000"),
        f("psd", "Photoshop", .image, ut: "com.adobe.photoshop-image"),
        f("tga", "TGA", .image, ut: "com.truevision.tga-image"),
        f("exr", "OpenEXR", .image, ut: "com.ilm.openexr-image"),
        f("svg", "SVG", .image, ut: "public.svg-image"),
        f("pdf", "PDF", .pdf, ut: "com.adobe.pdf"),
        // Video (mkv has no system UTType, so it is matched by extension only)
        f("mp4", "MP4", .video, ut: "public.mpeg-4"),
        f("mov", "QuickTime", .video, ut: "com.apple.quicktime-movie"),
        f("m4v", "M4V", .video, ut: "com.apple.m4v-video"),
        f("mkv", "Matroska", .video, ut: nil),
        f("webm", "WebM", .video, ut: "org.webmproject.webm"),
        f("avi", "AVI", .video, ut: "public.avi"),
        f("wmv", "Windows Media Video", .video, ut: "com.microsoft.windows-media-wmv"),
        // Audio (opus shares the system Ogg audio type, so it is matched by extension only)
        f("mp3", "MP3", .audio, ut: "public.mp3"),
        f("m4a", "M4A", .audio, ut: "com.apple.m4a-audio"),
        f("wav", "WAV", .audio, ut: "com.microsoft.waveform-audio"),
        f("aiff", "AIFF", .audio, ["aif"], ut: "public.aiff-audio"),
        f("caf", "CAF", .audio, ut: "com.apple.coreaudio-format"),
        f("flac", "FLAC", .audio, ut: "org.xiph.flac"),
        f("ogg", "Ogg Vorbis", .audio, ut: "org.xiph.ogg-audio"),
        f("opus", "Opus", .audio, ut: nil),
        f("wma", "Windows Media Audio", .audio, ut: "com.microsoft.windows-media-wma"),
        f("docx", "Word", .document, ut: "org.openxmlformats.wordprocessingml.document"),
        f("doc", "Word 97-2003", .document, ut: "com.microsoft.word.doc"),
        f("odt", "OpenDocument Text", .document, ut: "org.oasis-open.opendocument.text"),
        f("rtf", "RTF", .document, ut: "public.rtf"),
        f("rtfd", "RTFD", .document, ut: "com.apple.rtfd"),
        f("html", "HTML", .document, ["htm"], ut: "public.html"),
        f("md", "Markdown", .document, ["markdown"], ut: "net.daringfireball.markdown"),
        f("epub", "EPUB", .document, ut: "org.idpf.epub-container"),
        f("pptx", "PowerPoint", .document, ut: "org.openxmlformats.presentationml.presentation"),
        f("ppt", "PowerPoint 97-2003", .document, ut: "com.microsoft.powerpoint.ppt"),
        f("odp", "OpenDocument Presentation", .document, ut: "org.oasis-open.opendocument.presentation"),
        f("xlsx", "Excel", .document, ut: "org.openxmlformats.spreadsheetml.sheet"),
        f("xls", "Excel 97-2003", .document, ut: "com.microsoft.excel.xls"),
        f("ods", "OpenDocument Spreadsheet", .document, ut: "org.oasis-open.opendocument.spreadsheet"),
        f("txt", "Plain Text", .text, ut: "public.plain-text"),
        f("csv", "CSV", .data, ut: "public.comma-separated-values-text"),
        f("json", "JSON", .data, ut: "public.json"),
        // Archives (a .tar.gz is gz by its last extension; extract tells a tarball from one gzipped file)
        f("zip", "ZIP archive", .archive, ut: "public.zip-archive"),
        f("tar", "TAR archive", .archive, ut: "public.tar-archive"),
        f("tgz", "Compressed TAR", .archive, ut: "org.gnu.gnu-zip-tar-archive"),
        f("gz", "GZIP", .archive, ["gzip"], ut: "org.gnu.gnu-zip-archive"),
        f("rar", "RAR archive", .archive, ut: "com.rarlab.rar-archive"),
        // Subtitles (srt has no stable system UTType, so it is matched by extension only)
        f("srt", "SubRip", .subtitle, ut: nil),
        f("vtt", "WebVTT", .subtitle, ut: "org.w3.webvtt"),
    ]
}
