import Foundation

/// Chooses collision-free output names. Collisions are numbered `base 2.ext`, `base 3.ext`, ... and compared
/// case-insensitively (APFS is case-insensitive by default).
public struct OutputNamer: Sendable {
    private let fileExists: @Sendable (URL) -> Bool

    public init(fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        self.fileExists = fileExists
    }

    /// The last path component minus its final extension (`IMG.Final.HEIC` becomes `IMG.Final`).
    public static func stem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// The first free `<base>.<ext>` / `<base> N.<ext>` in `folder`. `avoiding` holds lowercased file names that
    /// are already claimed (source files, names reserved by earlier items of a batch). An empty `ext` yields a
    /// name without a dot (page folders).
    public func uniqueURL(stem: String, ext: String, suffix: String?, in folder: URL, avoiding: Set<String>) -> URL {
        let base = suffix.map { "\(stem)-\($0)" } ?? stem
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        var number = 1
        while true {
            let name = number == 1 ? "\(base)\(dotExt)" : "\(base) \(number)\(dotExt)"
            let candidate = folder.appending(path: name, directoryHint: .inferFromPath)
            if !avoiding.contains(name.lowercased()) && !fileExists(candidate) {
                return candidate
            }
            number += 1
        }
    }
}
