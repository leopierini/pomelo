import AppKit
import CoreGraphics
import CoreText
import Foundation
import PomeloCore

/// Converts between docx, doc, odt, rtf, rtfd, html and txt with the system's attributed-string document
/// support, and turns any of them into a paginated PDF with CoreText. All of it runs off the main actor except
/// reading HTML, which WebKit does on the main thread.
public struct AttributedTextEngine: ConversionEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private static let edgeCost = 10
    /// The order of the edges: every source against every other format in this order, then each against PDF.
    private static let textFormats: [FormatID] = ["docx", "doc", "odt", "rtf", "rtfd", "html", "txt"]
    /// Formats whose layout (pages, tables, floating objects) does not survive an attributed string.
    private static let layoutRiskSources: Set<FormatID> = ["docx", "doc", "odt"]

    public init() {}

    public var id: EngineID { "attributedtext" }
    public var displayName: String { "Text" }
    public var maxConcurrentJobs: Int { 1 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        var edges: [ConversionEdge] = []
        for source in Self.textFormats {
            let sourceRisk: EdgeFlags = Self.layoutRiskSources.contains(source) ? [.layoutRisk] : []
            for target in Self.textFormats where target != source {
                edges.append(ConversionEdge(from: source, to: target, engineID: id, cost: Self.edgeCost, flags: sourceRisk))
            }
            edges.append(ConversionEdge(from: source, to: "pdf", engineID: id, cost: Self.edgeCost, flags: [.layoutRisk]))
        }
        return edges
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let output = try await Self.perform(step)
        progress(1)
        return output
    }

    // MARK: Conversion

    /// Runs off the main actor. Only an HTML read hops to it (WebKit's importer needs the main thread), and that read
    /// comes back as archived bytes, so no `NSAttributedString` ever crosses an isolation boundary.
    @concurrent
    private static func perform(_ step: ConversionStep) async throws -> URL {
        guard textFormats.contains(step.from.id) else {
            throw Failure("\(step.from.displayName) is not a text document this engine can read")
        }
        guard step.to.id == "pdf" || textFormats.contains(step.to.id) else {
            throw Failure("\(step.to.displayName) is not something this engine can write")
        }
        let text = try await readDocument(step.input, as: step.from)
        try Task.checkCancellation()
        return try write(text, for: step)
    }

    /// The text of a document in one of `textFormats`, without its attachments: what Summarize reads (`DocumentText`).
    @concurrent
    static func plainText(of url: URL, as format: FileFormat) async throws -> String {
        guard textFormats.contains(format.id) else {
            throw Failure("\(format.displayName) is not a text document this engine can read")
        }
        return try await readDocument(url, as: format).string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func readDocument(_ url: URL, as format: FileFormat) async throws -> NSAttributedString {
        guard format.id == "html" else { return try read(url, as: format) }
        // Without a charset declaration Foundation reads HTML as Windows-1252 and garbles UTF-8 text. Valid UTF-8
        // is assumed to be UTF-8; anything else is left to the document's own declaration.
        let isUTF8 = (try? Data(contentsOf: url)).map { String(data: $0, encoding: .utf8) != nil } ?? false
        let archive = try await readHTMLArchive(url, as: format, assumingUTF8: isUTF8)
        return try unarchive(archive, readFrom: url, as: format)
    }

    private static func write(_ text: NSAttributedString, for step: ConversionStep) throws -> URL {
        let output = step.suggestedOutput
        do {
            switch step.to.id {
            case "pdf":
                try TextPaginator.writePDF(text, to: output, pageSize: TextPaginator.defaultPageSize())
            case "rtfd":
                try writePackage(text, to: output)
            case "txt":
                try Data(text.string.replacingOccurrences(of: "\u{FFFC}", with: "").utf8).write(to: output)
            default:
                // The HTML exporter, like the others, works off the main thread; only the importer needs WebKit.
                try encodedData(text, as: step.to).write(to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError || error is Failure { throw error }
            throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
        }
        return output
    }

    private static func documentType(of format: FileFormat) throws -> NSAttributedString.DocumentType {
        switch format.id {
        case "docx": return .officeOpenXML
        case "doc": return .docFormat
        case "odt": return .openDocument
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "html": return .html
        case "txt": return .plain
        default: throw Failure("\(format.displayName) is not a text document this engine can handle")
        }
    }

    /// Reads every format but HTML, which `readHTMLArchive` handles on the main actor.
    private static func read(_ url: URL, as format: FileFormat) throws -> NSAttributedString {
        let type = try documentType(of: format)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if format.id == "txt" {
            options[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            if format.id == "txt" {
                // Not UTF-8: let Foundation detect the encoding.
                if let detected = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) {
                    return detected
                }
                // An empty file has nothing to detect.
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 0 {
                    return NSAttributedString()
                }
            }
            throw readFailure(url, as: format, error)
        }
    }

    /// Reads an HTML file on the main actor and returns the result keyed-archived, so the caller rebuilds its own
    /// copy (attachments, lists and tables included) instead of sharing objects the main actor created.
    @MainActor
    private static func readHTMLArchive(_ url: URL, as format: FileFormat, assumingUTF8: Bool) throws -> Data {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html]
        if assumingUTF8 { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            let text = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            return try NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
        } catch {
            throw readFailure(url, as: format, error)
        }
    }

    /// Decodes what `readHTMLArchive` produced. Secure coding is off on purpose: the bytes were made in this process a
    /// moment ago, never touch the disk, and attribute values need not adopt `NSSecureCoding`.
    private static func unarchive(_ archive: Data, readFrom url: URL, as format: FileFormat) throws -> NSAttributedString {
        let decoded: Any?
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
            unarchiver.requiresSecureCoding = false
            decoded = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
        } catch {
            throw readFailure(url, as: format, error)
        }
        guard let text = decoded as? NSAttributedString else {
            throw Failure("cannot read \(url.lastPathComponent) as \(format.displayName): the document did not decode")
        }
        return text
    }

    private static func readFailure(_ url: URL, as format: FileFormat, _ error: any Error) -> Failure {
        Failure("cannot read \(url.lastPathComponent) as \(format.displayName): \(error.localizedDescription)")
    }

    private static func encodedData(_ text: NSAttributedString, as format: FileFormat) throws -> Data {
        let type = try documentType(of: format)
        return try text.data(
            from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type]
        )
    }

    /// Writes `text` as an RTFD package directory at `url`.
    private static func writePackage(_ text: NSAttributedString, to url: URL) throws {
        let wrapper = try text.fileWrapper(
            from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        try wrapper.write(to: url, options: [], originalContentsURL: nil)
    }
}

/// Lays an attributed string out on pages with CoreText and writes them as a PDF.
public enum TextPaginator {
    /// A4, or Letter in the regions that use it.
    public static func defaultPageSize() -> CGSize {
        switch Locale.current.region?.identifier {
        case "US", "CA", "MX", "PH": return CGSize(width: 612, height: 792)
        default: return CGSize(width: 595, height: 842)
        }
    }

    /// Writes `text` to `url` as a PDF of `pageSize` pages with `margin` on every side. Empty text gives one blank page.
    /// Safe on any thread: CoreText layout and drawing need neither the main thread nor AppKit's text system.
    public static func writePDF(_ text: NSAttributedString, to url: URL, pageSize: CGSize, margin: CGFloat = 72) throws {
        let content = CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        guard content.width > 0, content.height > 0 else {
            throw AttributedTextEngine.Failure("the page margins leave no room for text")
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw AttributedTextEngine.Failure("cannot create a PDF file at \(url.lastPathComponent)")
        }
        // The context is always closed, so a failure never leaves an unfinished PDF behind a live file handle.
        defer { context.closePDF() }

        let drawable = drawableCopy(of: text)
        let length = drawable.length
        let framesetter = CTFramesetterCreateWithAttributedString(drawable)
        let path = CGPath(rect: content, transform: nil)
        let string = drawable.string as NSString
        var location = 0
        var pages = 0
        while location < length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                // Nothing fits (for example an attachment taller than the page): skip one character so this
                // loop always advances.
                location += string.rangeOfComposedCharacterSequence(at: location).length
                continue
            }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            pages += 1
            location += visible.length
        }
        if pages == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
    }

    /// A copy whose text has an explicit CoreText foreground colour (black unless the text sets one), because
    /// CoreText ignores AppKit's `.foregroundColor`.
    private static func drawableCopy(of text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            var color = black
            if let appKitColor = value as? NSColor {
                // Resolve dynamic colours as in light mode: the page is white whatever the system appearance.
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    color = appKitColor.usingColorSpace(.sRGB)?.cgColor ?? black
                }
            }
            result.addAttribute(key, value: color, range: range)
        }
        return result
    }
}
