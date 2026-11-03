import Foundation
import PomeloCore

/// The engines Pomelo ships with, wired into one registry.
public enum DefaultEngines {
    /// Which engine wins when several offer the same conversion at the same score.
    public static let priority: [EngineID] = [
        "imageio", "pdfkit", "avfoundation", "attributedtext", "vision", "archive", "quicklook", "subtitles", "translation", "documentscan", "spreadsheet", "intelligence", "speech", "cwebp", "pngquant", "ffmpeg", "pandoc",
        "unar", "libreoffice", "slides",
    ]

    /// The `Plugins` resource folder of this package, which holds the bundled manifests. Should the folder be
    /// missing from the bundle, the returned URL does not exist and `PluginLoader` skips it.
    public static var bundledPluginsFolder: URL {
        Bundle.module.url(forResource: "Plugins", withExtension: nil)
            ?? Bundle.module.bundleURL.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    /// The folders `AppSupportFolders` resolves, under the names the app and the CLI use.
    public static var appSupportFolder: URL { AppSupportFolders.appSupport }
    public static var legacyAppSupportFolder: URL { AppSupportFolders.legacyAppSupport }
    public static var userPluginsFolder: URL { AppSupportFolders.pluginsFolder }
    public static var enginesFolder: URL { AppSupportFolders.enginesFolder }

    public static func preferredFolder(_ folder: URL, legacy: URL, fileManager: FileManager = .default) -> URL {
        AppSupportFolders.preferredFolder(folder, legacy: legacy, fileManager: fileManager)
    }

    /// The plugin manifests, `userPluginsFolder` first so its manifests win over bundled ones with the same id,
    /// and the files that could not be loaded (not valid JSON, or failing validation). Pass nil to load the bundled
    /// manifests only. The user's folder also accepts the pre-rename `*.kumquat-plugin.json` names (P96).
    public static func loadPlugins(
        userPluginsFolder: URL? = DefaultEngines.userPluginsFolder
    ) -> (manifests: [PluginManifest], failures: [URL]) {
        PluginLoader.load(
            folders: (userPluginsFolder.map { [$0] } ?? []) + [bundledPluginsFolder],
            acceptingLegacyNamesIn: Set(userPluginsFolder.map { [$0] } ?? [])
        )
    }

    /// The built-in engines followed by one `CommandEngine` per plugin manifest, then `SlidesEngine` on the
    /// `libreoffice` one. A manifest in `userPluginsFolder` (the user's folder unless another is given; nil skips
    /// it) replaces a bundled one with the same id. Plugin ids missing from `priority` rank after it.
    public static func makeRegistry(userPluginsFolder: URL? = DefaultEngines.userPluginsFolder) -> EngineRegistry {
        var engines: [any ConversionEngine] = [
            ImageIOEngine(), PDFKitEngine(), AVFoundationEngine(), AttributedTextEngine(), VisionEngine(), ArchiveEngine(),
            SVGEngine(), SubtitleEngine(), TranslationEngine(), DocumentScanEngine(), SpreadsheetEngine(), IntelligenceEngine(), SpeechEngine(),
        ]
        let manifests = loadPlugins(userPluginsFolder: userPluginsFolder).manifests
        let locator = ExecutableLocator(enginesFolder: enginesFolder)
        engines += manifests.map { EditValidatingEngine(base: CommandEngine(manifest: $0, locator: locator)) }
        engines.append(SlidesEngine(office: engines.first { $0.id == "libreoffice" }))

        let known = Set(priority)
        let extra = manifests.map { EngineID($0.id) }.filter { !known.contains($0) }
        return EngineRegistry(engines: engines, priority: priority + extra)
    }
}
