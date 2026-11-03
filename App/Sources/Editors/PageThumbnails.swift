// The Organize pages editor's page images (P27): drawn only when a cell scrolls into view, from a document of its
// own so the main thread never waits for PDFKit, and kept for the 120 most recently used so a 300-page PDF stays
// modest in memory.
import AppKit
import PDFKit

actor PageThumbnails {
    static let capacity = 120

    private struct Key: Hashable {
        var page: Int
        var side: Int
    }

    private let url: URL
    private let capacity: Int
    /// Opened by the first request, so the editor's `init` does not parse the file.
    private var document: PDFDocument?
    private var opened = false
    private var images: [Key: CGImage] = [:]
    /// Least recently used first.
    private var recency: [Key] = []

    /// Pages drawn so far (a cache hit does not count), for the tests.
    private(set) var renderedCount = 0

    var cachedCount: Int { images.count }

    init(url: URL, capacity: Int = PageThumbnails.capacity) {
        self.url = url
        self.capacity = capacity
    }

    /// The page as the viewer shows it (its own rotation applied), at most `maxSide` pixels on its longer side; nil
    /// for a page that doesn't exist, a file that won't open, or a request whose task was cancelled (the cell
    /// scrolled away) before the page was drawn.
    func image(page: Int, maxSide: CGFloat) -> CGImage? {
        let key = Key(page: page, side: Int(maxSide.rounded()))
        if let cached = images[key] {
            touch(key)
            return cached
        }
        guard !Task.isCancelled, let pdfPage = openDocument()?.page(at: page) else { return nil }
        let box = pdfPage.bounds(for: .cropBox)
        let turned = pdfPage.rotation % 180 != 0
        let (width, height) = turned ? (box.height, box.width) : (box.width, box.height)
        guard width > 0, height > 0 else { return nil }
        let scale = maxSide / max(width, height)
        let size = NSSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        let thumbnail = pdfPage.thumbnail(of: size, for: .cropBox)
        guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        renderedCount += 1
        images[key] = image
        recency.append(key)
        while recency.count > capacity {
            images[recency.removeFirst()] = nil
        }
        return image
    }

    /// Whether the file asks for a password, for the editor's reason.
    func isLocked() -> Bool {
        openDocument()?.isLocked ?? false
    }

    private func openDocument() -> PDFDocument? {
        if !opened {
            document = PDFDocument(url: url)
            opened = true
        }
        return document
    }

    private func touch(_ key: Key) {
        if let index = recency.lastIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }
}
