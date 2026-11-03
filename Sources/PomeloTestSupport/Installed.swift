import Foundation
import os
import PomeloCore
import PomeloEngines
import Speech
@_weakLinked import Translation

/// Which external tools and engines this Mac has, for tests and evals that need a plugin's executable or an engine
/// that only some Macs can run.
public enum Installed {
    public static let searchFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    public static let enginePrefix = "engine:"
    public static let translationPrefix = "translation:"
    public static let speechPrefix = "speech:"

    /// Where the app's locator looks first (`AppSupportFolders.enginesFolder`). Only ever read here.
    public static var enginesFolder: URL { AppSupportFolders.enginesFolder }

    /// `engine:<id>` is true when the default registry (bundled plugins only) reports that engine available;
    /// `translation:<source>-<target>` (`translation:en-it`) when Translation has that pair installed;
    /// `speech:<locale>` (`speech:en-US`) when the speech recognizer has that language's model on this Mac, so
    /// nothing downloads; anything else is an executable, true when `path(of:)` finds it.
    public static func has(
        _ executable: String, enginesFolder: URL = Installed.enginesFolder,
        searchFolders: [String] = Installed.searchFolders
    ) -> Bool {
        if executable.hasPrefix(enginePrefix) {
            return engineIsAvailable(EngineID(String(executable.dropFirst(enginePrefix.count))))
        }
        if executable.hasPrefix(translationPrefix) {
            return translationPairIsInstalled(String(executable.dropFirst(translationPrefix.count)))
        }
        if executable.hasPrefix(speechPrefix) {
            return speechLocaleIsInstalled(String(executable.dropFirst(speechPrefix.count)))
        }
        return path(of: executable, enginesFolder: enginesFolder, searchFolders: searchFolders) != nil
    }

    private static let answers = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Asked once per token per process. `has` is synchronous (test traits, corpus recipes), so this waits for
    /// `work` on a detached task.
    private static func answer(_ token: String, _ work: @escaping @Sendable () async -> Bool) -> Bool {
        if let known = answers.withLock({ $0[token] }) { return known }
        let answer = OSAllocatedUnfairLock(initialState: false)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let value = await work()
            answer.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        let value = answer.withLock { $0 }
        answers.withLock { $0[token] = value }
        return value
    }

    /// `pair` is "en-it": two language codes. False below macOS 26, for a malformed pair, and when the process is
    /// linked against an SDK older than 26.4, where Translation reports every installed language as merely supported.
    private static func translationPairIsInstalled(_ pair: String) -> Bool {
        let codes = pair.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard #available(macOS 26, *), codes.count == 2, !codes[0].isEmpty, !codes[1].isEmpty else { return false }
        return answer(translationPrefix + pair) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: codes[0]), to: Locale.Language(identifier: codes[1]))
            return status == .installed
        }
    }

    /// `identifier` is a locale with its region ("en-US"). False below macOS 26.
    private static func speechLocaleIsInstalled(_ identifier: String) -> Bool {
        let wanted = Locale.Language(identifier: identifier)
        guard #available(macOS 26, *), wanted.languageCode != nil, wanted.region != nil else { return false }
        return answer(speechPrefix + identifier) {
            await SpeechTranscriber.installedLocales.contains {
                $0.language.languageCode == wanted.languageCode && $0.language.region == wanted.region
            }
        }
    }

    private static func engineIsAvailable(_ id: EngineID) -> Bool {
        answer(enginePrefix + id.rawValue) {
            let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
            if case .available? = await registry.engine(id: id)?.availability() { return true }
            return false
        }
    }

    /// `executable` in some `<plugin>/bin` of `enginesFolder` (an engine installed from Settings), else in
    /// `/opt/homebrew/bin` or `/usr/local/bin`, or the path itself when it names an executable file. A GUI app's
    /// PATH lacks Homebrew, so the PATH is deliberately not searched.
    public static func path(
        of executable: String, enginesFolder: URL = Installed.enginesFolder,
        searchFolders: [String] = Installed.searchFolders
    ) -> URL? {
        let manager = FileManager.default
        if executable.hasPrefix("/") {
            return manager.isExecutableFile(atPath: executable) ? URL(filePath: executable) : nil
        }
        let plugins = ((try? manager.contentsOfDirectory(atPath: enginesFolder.path)) ?? []).sorted()
        let candidates = plugins.map { "\(enginesFolder.path)/\($0)/bin/\(executable)" }
            + searchFolders.map { "\($0)/\(executable)" }
        return candidates.first(where: manager.isExecutableFile(atPath:)).map { URL(filePath: $0) }
    }
}
