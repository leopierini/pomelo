// The Shelf's Quick Look thumbnails (S26): drawn only for what shows (the stack's three, the visible rows), off the
// main thread, and kept for the 120 most recently used, as `PageThumbnails` keeps a document's pages.
import AppKit
import QuickLookThumbnailing

actor ShelfThumbnails {
    static let capacity = 120

    typealias Render = @Sendable (URL, CGFloat, CGFloat) async -> CGImage?

    private struct Key: Hashable {
        var id: UUID
        var path: String
        var side: Int
    }

    private let capacity: Int
    private let render: Render
    private var images: [Key: CGImage] = [:]
    /// Least recently used first.
    private var recency: [Key] = []

    init(capacity: Int = ShelfThumbnails.capacity, render: @escaping Render = ShelfThumbnails.quickLook) {
        self.capacity = capacity
        self.render = render
    }

    /// The item's thumbnail at `side` points; nil when Quick Look has none (the view keeps the file's icon). A
    /// renamed file is drawn again under its new path.
    func image(for id: UUID, url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let key = Key(id: id, path: url.path, side: Int(side.rounded()))
        if let cached = images[key] {
            touch(key)
            return cached
        }
        guard !Task.isCancelled, let image = await render(url, side, scale) else { return nil }
        // Another request for the same key may have finished during the await.
        if images[key] == nil { recency.append(key) } else { touch(key) }
        images[key] = image
        while recency.count > capacity {
            images[recency.removeFirst()] = nil
        }
        return image
    }

    /// Thumbnails go with their items (S26).
    func forget(_ ids: Set<UUID>) {
        recency.removeAll { ids.contains($0.id) }
        images = images.filter { !ids.contains($0.key.id) }
    }

    private func touch(_ key: Key) {
        if let index = recency.lastIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }

    static let quickLook: Render = { url, side, scale in
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .all
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
