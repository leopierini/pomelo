// Lives in the app, as TranslationLanguages does: only Settings asks for it, and the CLI needn't carry it.
import Foundation
import Speech

/// The languages the speech tools can listen for, for Settings › Tools and Settings › Engines. Read-only: it asks the
/// recognizer what it supports and has on this Mac, never downloads anything (a model downloads the first time a
/// transcription needs it, P155), and shows no prompt.
enum SpeechLanguages {
    /// Every supported locale by its BCP-47 identifier ("en-US"), the ones on this Mac marked. Empty below macOS 26.
    static func load() async -> [LanguageChoice] {
        guard #available(macOS 26, *) else { return [] }
        return choices(supported: await SpeechTranscriber.supportedLocales, installed: await SpeechTranscriber.installedLocales)
    }

    /// The languages on this Mac by name ("English", "Italian"), for the Engines pane. Empty below macOS 26.
    static func installedNames(in locale: Locale = .current) async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        return names(of: await SpeechTranscriber.installedLocales, in: locale)
    }

    static func choices(supported: [Locale], installed: [Locale]) -> [LanguageChoice] {
        let here = Set(installed.map { $0.identifier(.bcp47) })
        var seen: Set<String> = []
        return supported.compactMap { locale in
            let identifier = locale.identifier(.bcp47)
            guard seen.insert(identifier).inserted else { return nil }
            return LanguageChoice(identifier: identifier, isInstalled: here.contains(identifier))
        }
    }

    /// Each language once, without its region (nine kinds of English are "English"), sorted by name.
    static func names(of locales: [Locale], in locale: Locale) -> [String] {
        let codes = Set(locales.compactMap { $0.language.languageCode?.identifier })
        return codes.map { locale.localizedString(forLanguageCode: $0) ?? $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
