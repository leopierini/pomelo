// Lives in the app, not PomeloEngines: only Settings asks for it, and in the engines it added 18 KB to the CLI.
import Foundation
@_weakLinked import Translation

/// A language a Settings picker offers, by its BCP-47 identifier, and whether its model is on this Mac.
struct LanguageChoice: Sendable, Equatable {
    let identifier: String
    let isInstalled: Bool
}

/// The languages Translate can write into, for Settings › Tools. Read-only: it asks Translation what it supports and
/// has installed, never downloads anything (P154), and shows no prompt.
enum TranslationLanguages {
    typealias PairIsInstalled = @Sendable (Locale.Language, Locale.Language) async -> Bool

    /// Every supported language, in the framework's order, the installed ones marked. Empty below macOS 26. Slow
    /// enough (about a hundred status queries) that callers run it off the main thread.
    static func load(preferredLanguages: [String] = Locale.preferredLanguages) async -> [LanguageChoice] {
        guard #available(macOS 26, *) else { return [] }
        let supported = await LanguageAvailability().supportedLanguages
        let anchors = [preferredLanguages.first, "en"].compactMap { $0 }.map { Locale.Language(identifier: $0) }
        return await choices(supported: supported, anchors: anchors) { source, target in
            await LanguageAvailability().status(from: source, to: target) == .installed
        }
    }

    /// Translation installs languages but only answers for pairs, so a language counts as installed when its pair with
    /// an installed anchor is. The first anchor that pairs with anything is used: the system's language, then English.
    /// A language sharing the anchor's language code (en-GB for English) is paired with an installed one instead.
    static func choices(
        supported: [Locale.Language], anchors: [Locale.Language], isInstalled: PairIsInstalled
    ) async -> [LanguageChoice] {
        var installed: Set<String> = []
        for anchor in anchors {
            var partner: Locale.Language?
            for language in supported where language.languageCode != anchor.languageCode {
                if await isInstalled(language, anchor) {
                    installed.insert(language.minimalIdentifier)
                    partner = partner ?? language
                }
            }
            guard let partner else { continue }
            for language in supported where language.languageCode == anchor.languageCode {
                if await isInstalled(language, partner) {
                    installed.insert(language.minimalIdentifier)
                }
            }
            break
        }
        var seen: Set<String> = []
        return supported.compactMap { language in
            let identifier = language.minimalIdentifier
            guard seen.insert(identifier).inserted else { return nil }
            return LanguageChoice(identifier: identifier, isInstalled: installed.contains(identifier))
        }
    }
}
