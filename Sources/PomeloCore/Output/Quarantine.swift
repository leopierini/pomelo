import Foundation

/// P58: an output made from a downloaded file carries the source's `com.apple.quarantine`, byte for byte, so
/// Gatekeeper still checks what came out of it (an app or script unpacked from a downloaded archive above all).
/// Nothing else ever adds or changes the mark.
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    /// The mark of `url` (a symlinked source is read through its link), or nil when it has none.
    static func mark(of url: URL) -> Data? {
        read(url.path, options: 0)
    }

    /// Puts `mark` on `item`, and inside a folder on every item that has no mark of its own. Links are marked
    /// themselves and never followed, so nothing outside `item` is touched.
    static func apply(_ mark: Data, to item: URL) {
        write(mark, to: item.path)
        var pending = isRealFolder(item.path) ? [item.path] : []
        while let folder = pending.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = "\(folder)/\(name)"
                if read(path, options: XATTR_NOFOLLOW) == nil { write(mark, to: path) }
                if isRealFolder(path) { pending.append(path) }
            }
        }
    }

    private static func read(_ path: String, options: Int32) -> Data? {
        let size = getxattr(path, attribute, nil, 0, 0, options)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(path, attribute, &bytes, size, 0, options) == size else { return nil }
        return Data(bytes)
    }

    private static func write(_ mark: Data, to path: String) {
        _ = mark.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, mark.count, 0, XATTR_NOFOLLOW) }
    }

    private static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
