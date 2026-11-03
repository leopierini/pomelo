// What the Shelf learns about a dropped file and how it finds it again (S11, S15). Pomelo isn't sandboxed, so a
// plain bookmark is enough (as `WatchFolder`'s); nothing here writes, moves or opens a file.
import Foundation
import PomeloUIModel

struct ShelfFiles: Sendable {
    /// Identity, name and size of a dropped file: the identity is `fileResourceIdentifier`, else the canonical path.
    var item: @Sendable (URL) -> ShelfItem
    var bookmark: @Sendable (URL) -> Data?
    /// Where the item is now and what it is called; never prompts, never mounts.
    var resolve: @Sendable (ShelfItem) -> (url: URL, name: String, state: ShelfItemState)

    static let live = ShelfFiles(
        item: { url in
            let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .isDirectoryKey])
            let size = values?.isDirectory == true ? nil : values?.fileSize.map(Int64.init)
            return ShelfItem(url: url, identity: identity(of: url, resourceIdentifier: values?.fileResourceIdentifier),
                             name: url.lastPathComponent, byteCount: size)
        },
        bookmark: { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) },
        resolve: { item in
            var stale = false
            let bookmarked = item.bookmark.flatMap {
                try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                         bookmarkDataIsStale: &stale)
            }
            // The bookmark may spell the item's own path another way (`/private/var` for `/var`): keep the dropped one.
            let followed = bookmarked.map { samePath($0, item.url) ? item.url : $0 }
            // Replaced in place (S15): a bookmark that no longer resolves falls back to the path.
            guard let url = [followed, item.url].compactMap({ $0 }).first(where: exists) else {
                return (item.url, item.name, .missing)
            }
            return (url, url.lastPathComponent, isInTrash(url) ? .inTrash : .present)
        }
    )

    /// The resource identifier's bytes when there is one; the canonical path otherwise.
    static func identity(of url: URL, resourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)?) -> String {
        if let data = resourceIdentifier as? Data {
            return "id:" + data.map { String(format: "%02x", $0) }.joined()
        }
        if let resourceIdentifier { return "id:\(resourceIdentifier)" }
        return "path:" + canonicalPath(of: url)
    }

    /// The path with the folders above it resolved (`/var` and `/private/var` agree) but not the item, so a symlink
    /// stays an item of its own.
    static func canonicalPath(of url: URL) -> String {
        let standard = url.standardizedFileURL
        let folder = standard.deletingLastPathComponent().resolvingSymlinksInPath()
        return folder.appending(path: standard.lastPathComponent).path
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Inside a Trash folder: the user's, or a volume's `.Trashes`, or any folder named `.Trash` on the way.
    static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".Trash") || components.contains(".Trashes") { return true }
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return false }
        let trashPath = trash.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(trashPath + "/")
    }
}
