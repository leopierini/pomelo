import Foundation

/// Decides which folder an output goes to. Does not touch the filesystem itself: writability is injected.
public struct DestinationResolver: Sendable {
    private let downloadsFolder: URL
    private let isWritable: @Sendable (URL) -> Bool

    public init(downloadsFolder: URL, isWritable: @escaping @Sendable (URL) -> Bool) {
        self.downloadsFolder = downloadsFolder
        self.isWritable = isWritable
    }

    /// An explicit `override` always wins and never falls back. Otherwise the source's own folder if writable,
    /// else the Downloads folder with `fellBack` set.
    public func destination(for source: URL, override: URL?) -> (folder: URL, fellBack: Bool) {
        if let override { return (override, false) }
        let parent = source.deletingLastPathComponent()
        return isWritable(parent) ? (parent, false) : (downloadsFolder, true)
    }
}
