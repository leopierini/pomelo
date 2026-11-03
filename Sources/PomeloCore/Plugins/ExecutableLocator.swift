import Foundation

public struct ExecutableLocator: Sendable {
    private let enginesFolder: URL
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        enginesFolder: URL,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.enginesFolder = enginesFolder
        self.isExecutable = isExecutable
    }

    /// An absolute name is checked directly. Other names are searched, in this order, in
    /// `enginesFolder/<pluginID>/bin`, the manifest's `searchPaths`, `/opt/homebrew/bin` and `/usr/local/bin`.
    /// Names containing a `/` that are not absolute are ignored.
    public func locate(_ exe: PluginManifest.Executable, pluginID: String) -> URL? {
        let folders =
            [enginesFolder.appending(path: pluginID, directoryHint: .isDirectory).appending(path: "bin").path]
            + exe.searchPaths + ["/opt/homebrew/bin", "/usr/local/bin"]
        for name in exe.names {
            if name.hasPrefix("/") {
                if isExecutable(name) { return URL(fileURLWithPath: name) }
                continue
            }
            guard !name.isEmpty, !name.contains("/") else { continue }
            for folder in folders {
                let candidate = URL(fileURLWithPath: folder).appending(path: name).path
                if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        return nil
    }
}
