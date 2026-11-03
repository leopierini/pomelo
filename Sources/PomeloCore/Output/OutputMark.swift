import Foundation
import os

/// §3.4 rule 10: every output Pomelo publishes carries this extended attribute, so a watch folder never takes Pomelo's
/// own work (a copy made by Finder or `cp` keeps it too). Links are never followed: a link is marked, or read, itself.
public enum OutputMark {
    public static let attributeName = "io.github.pomelo-app.output"
    private static let value = Array("1".utf8)
    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "output-mark")

    public static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, attributeName, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Marks `item` alone: inside a folder output nothing is an output of its own. Best effort: a volume that refuses
    /// extended attributes still gets the output, unmarked (the mark only keeps a watch folder from taking it), and
    /// the reason is logged at `.notice`, which the unified log keeps (`.info` is in memory only).
    @discardableResult
    static func apply(to item: URL) -> Bool {
        guard setxattr(item.path, attributeName, value, value.count, 0, XATTR_NOFOLLOW) != 0 else { return true }
        let code = errno
        log.notice("could not mark an output (errno \(code, privacy: .public))")
        return false
    }
}
