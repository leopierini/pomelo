import Foundation
import Testing
@testable import Pomelo

@Suite struct TranslationLanguagesTests {
    private static let supported = ["en-US", "en-GB", "it-IT", "de-DE", "ja-JP", "pt-PT"].map(Locale.Language.init(identifier:))

    /// Pairs between any two of `installed` read installed.
    private func choices(installed: Set<String>, anchors: [String]) async -> [LanguageChoice] {
        await TranslationLanguages.choices(
            supported: Self.supported, anchors: anchors.map(Locale.Language.init(identifier:))
        ) { source, target in
            installed.contains(source.minimalIdentifier) && installed.contains(target.minimalIdentifier)
        }
    }

    private func installed(_ choices: [LanguageChoice]) -> [String] {
        choices.filter(\.isInstalled).map(\.identifier)
    }

    @Test func everySupportedLanguageIsListedByItsShortIdentifier() async {
        let list = await choices(installed: [], anchors: ["it-IT", "en"])
        #expect(list.map(\.identifier) == ["en", "en-GB", "it", "de", "ja", "pt-PT"])
        #expect(installed(list).isEmpty)
    }

    @Test func theLanguagesPairedWithTheSystemOnesAreInstalled() async {
        let list = await choices(installed: ["it", "en", "de"], anchors: ["it-IT", "en"])
        #expect(installed(list) == ["en", "it", "de"])
    }

    /// The anchor's own variants are asked against an installed partner, since a language never pairs with itself.
    @Test func theAnchorsVariantsAreAskedAgainstAnotherLanguage() async {
        let list = await choices(installed: ["en", "en-GB", "ja"], anchors: ["en-US"])
        #expect(installed(list) == ["en", "en-GB", "ja"])
    }

    @Test func aSystemLanguageThatIsNotInstalledFallsBackToEnglish() async {
        let list = await choices(installed: ["en", "pt-PT"], anchors: ["ja-JP", "en"])
        #expect(installed(list) == ["en", "pt-PT"])
    }

    @Test func aLoneInstalledLanguageHasNoPairSoNothingReadsInstalled() async {
        #expect(installed(await choices(installed: ["ja"], anchors: ["ja-JP", "en"])).isEmpty)
    }
}
