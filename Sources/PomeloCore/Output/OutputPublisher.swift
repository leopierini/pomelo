import Foundation

/// Moves a staged output into its destination folder without ever replacing an existing item.
public enum OutputPublisher {
    private static let maxAttempts = 1000

    /// Publishes `staged` as a fresh name in `folder` using `renamex_np(RENAME_EXCL)`. If the name was taken in
    /// the meantime (EEXIST), the namer is asked again with that name added to `avoiding`. Returns the final URL.
    public static func publish(
        staged: URL, to folder: URL, stem: String, ext: String, suffix: String?,
        avoiding: Set<String>, namer: OutputNamer
    ) throws -> URL {
        var avoiding = avoiding
        // Marked while still in staging (P116), so no output is ever visible unmarked; the mark moves with the rename,
        // replace-original's included.
        OutputMark.apply(to: staged)
        for _ in 0..<maxAttempts {
            let candidate = namer.uniqueURL(stem: stem, ext: ext, suffix: suffix, in: folder, avoiding: avoiding)
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            guard code == EEXIST else {
                let underlying = POSIXErrorCode(rawValue: code).map { POSIXError($0) as Error }
                throw CocoaError(.fileWriteUnknown, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
            }
            avoiding.insert(candidate.lastPathComponent.lowercased())
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
