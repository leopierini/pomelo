import CryptoKit
import Foundation

/// A file's SHA-256, read in 1 MB pieces so no file is held in memory (P263).
public enum FileDigest {
    static let readSize = 1 << 20

    /// `isCancelled` is asked before every read; when it says yes, this throws `CancellationError`.
    public static func sha256(of url: URL, isCancelled: @Sendable () -> Bool) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            guard let piece = try handle.read(upToCount: readSize), !piece.isEmpty else { break }
            hasher.update(data: piece)
        }
        return Data(hasher.finalize())
    }
}
