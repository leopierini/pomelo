// Which entries of a watched folder are worth a look: the cheap, name-and-type checks that run before any file is
// opened or any job is made.
import Foundation

public enum ArrivalFilter {
    /// Browsers and download managers write under these names until the file is whole.
    private static let partialExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "tmp", "opdownload", "!qb",
    ]

    /// A regular file, not a link (P117: following one would convert a file outside the folder), that isn't hidden, an
    /// Office lock file, a partial download or one of Pomelo's own outputs (`isMarked`, the loop guard of P109).
    public static func isCandidate(name: String, isRegularFile: Bool, isSymbolicLink: Bool, isMarked: Bool) -> Bool {
        guard isRegularFile, !isSymbolicLink, !isMarked else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        return !partialExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
