import Foundation

/// The checks a folder an external tool made in staging gets before it is returned (ArchiveEngine's extraction,
/// a plugin's `{outputFolder}`, P62).
public enum StagedFolder {
    public enum Containment: Equatable, Sendable {
        case inside, outside
        /// An item the walk could not inspect, named relative to the folder.
        case unreadable(String)
    }

    /// Tools may leave folders without owner access (000, 0555, as archives carry them): they would stop the walk,
    /// the staging cleanup and the publish rename. Every real folder gets owner rwx; links are not followed.
    public static func openFolders(under root: URL) {
        var pending = [root.path]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            if info.st_mode & 0o700 != 0o700 { chmod(path, (info.st_mode & 0o7777) | 0o700) }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                pending.append("\(path)/\(name)")
            }
        }
    }

    /// Whether `root` resolves inside `staging` and so does everything under it. Below the root the walk uses
    /// `lstat`: a symlink is kept as a link and never followed, so only real folders are entered.
    public static func containment(of root: URL, in staging: URL) -> Containment {
        guard let base = realPath(staging.path), let rootPath = realPath(root.path) else {
            return .unreadable(root.lastPathComponent)
        }
        guard rootPath.hasPrefix(base + "/") else { return .outside }
        var pending = [rootPath]
        while let path = pending.popLast() {
            let shown = path == rootPath ? root.lastPathComponent : String(path.dropFirst(rootPath.count + 1))
            var info = stat()
            guard lstat(path, &info) == 0 else { return .unreadable(shown) }
            let url = URL(filePath: path)
            guard let parent = realPath(url.deletingLastPathComponent().path) else { return .unreadable(shown) }
            guard "\(parent)/\(url.lastPathComponent)".hasPrefix(base + "/") else { return .outside }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                    return .unreadable(shown)
                }
                pending += names.map { "\(path)/\($0)" }
            }
        }
        return .inside
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
