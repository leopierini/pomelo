import Foundation

/// Reads `*.pomelo-plugin.json` manifests from folders.
public enum PluginLoader {
    static let fileSuffix = ".pomelo-plugin.json"
    /// The suffix before the rename (P92), still read from the folders a caller names, so an old user plugin keeps
    /// working (P96).
    static let legacyFileSuffix = ".kumquat-plugin.json"

    /// Folders are read in order, files by name. A file that does not decode or validate is listed in `failures`;
    /// a missing folder is skipped. When two manifests share an id, the earlier one (earlier folder) wins. A folder in
    /// `legacyFolders` also yields its `*.kumquat-plugin.json` files, after its `*.pomelo-plugin.json` ones, so a
    /// renamed copy of a manifest wins over the old one.
    public static func load(
        folders: [URL], acceptingLegacyNamesIn legacyFolders: Set<URL> = []
    ) -> (manifests: [PluginManifest], failures: [URL]) {
        var manifests: [PluginManifest] = []
        var seen: Set<String> = []
        var failures: [URL] = []
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            let suffixes = legacyFolders.contains(folder) ? [fileSuffix, legacyFileSuffix] : [fileSuffix]
            let candidates = suffixes.flatMap { suffix in
                files.filter { $0.lastPathComponent.hasSuffix(suffix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            for file in candidates {
                guard let manifest = try? PluginManifest.load(from: file) else {
                    failures.append(file)
                    continue
                }
                if seen.insert(manifest.id).inserted { manifests.append(manifest) }
            }
        }
        return (manifests, failures)
    }
}
