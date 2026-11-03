import Foundation

/// Pomelo's folders under Application Support, and the one rule for the pre-rename ones (P96): the Kumquat folder
/// serves only while the Pomelo one does not exist. Nothing here creates, copies or moves either.
public enum AppSupportFolders {
    /// `~/Library/Application Support/Pomelo`.
    public static var appSupport: URL { applicationSupport.appending(path: "Pomelo", directoryHint: .isDirectory) }

    /// `~/Library/Application Support/Kumquat`, the folder before the rename (P92). Its plugins are only read (P96);
    /// the installer writes into its `Engines` while only that one exists (P113).
    public static var legacyAppSupport: URL { applicationSupport.appending(path: "Kumquat", directoryHint: .isDirectory) }

    /// Where users drop their own manifests: `appSupport/Plugins`, or the pre-rename folder's while only that exists.
    public static var pluginsFolder: URL { preferred("Plugins") }

    /// Where engines live (`<plugin id>/bin`), installed by hand or by the installer (P113), with the same fallback,
    /// so an old user plugin finds its executable too.
    public static var enginesFolder: URL { preferred("Engines") }

    /// `folder`, unless it is not a directory and `legacy` is (P96). Once the new folder exists it wins for good.
    public static func preferredFolder(_ folder: URL, legacy: URL, fileManager: FileManager = .default) -> URL {
        func isDirectory(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return isDirectory(folder) || !isDirectory(legacy) ? folder : legacy
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func preferred(_ name: String) -> URL {
        preferredFolder(
            appSupport.appending(path: name, directoryHint: .isDirectory),
            legacy: legacyAppSupport.appending(path: name, directoryHint: .isDirectory)
        )
    }
}
