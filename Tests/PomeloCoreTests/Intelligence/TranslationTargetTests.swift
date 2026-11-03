import Foundation
import Testing
@testable import PomeloCore

@Suite struct TranslationTargetTests {
    @Test func theSettingWinsOverTheSystemLanguage() {
        #expect(TranslationTarget.identifier("de", preferred: ["it-IT"]) == "de")
        #expect(TranslationTarget.suffix("de", preferred: ["it-IT"]) == "de")
    }

    @Test func noSettingIsTheFirstPreferredLanguage() {
        #expect(TranslationTarget.identifier(nil, preferred: ["it-IT", "en-US"]) == "it-IT")
        #expect(TranslationTarget.suffix(nil, preferred: ["it-IT", "en-US"]) == "it")
        #expect(TranslationTarget.suffix("  ", preferred: ["fr-FR"]) == "fr")
        #expect(TranslationTarget.identifier(nil, preferred: []) == "en")
    }

    @Test func aRegionThatChangesTheLanguageStays() {
        #expect(TranslationTarget.suffix("pt-PT", preferred: []) == "pt-PT")
        #expect(TranslationTarget.suffix("pt-BR", preferred: []) == "pt")
    }

    @Test func theSuffixNeverHoldsAPathSeparator() {
        for hostile in ["../x", "it/../../etc", "it\u{0}", "///"] {
            let suffix = TranslationTarget.suffix(hostile, preferred: [])
            #expect(!suffix.contains("/") && !suffix.contains("\u{0}") && !suffix.contains("."), "\(suffix)")
            #expect(!suffix.isEmpty)
        }
    }

    @Test func theBuiltInPresetIsNamedAfterTheSystemLanguage() throws {
        let preset = try #require(Preset.builtIns.first { $0.id == "translate" })
        #expect(preset.operation == "translate")
        #expect(preset.nameSuffix == TranslationTarget.suffix(nil))
        #expect(preset.target == nil)
    }

    @Test func theNameIsTheLanguageAsPeopleReadIt() {
        let english = Locale(identifier: "en_US")
        #expect(TranslationTarget.name("it", preferred: [], locale: english) == "Italian")
        #expect(TranslationTarget.name("it-IT", preferred: [], locale: english) == "Italian")
        #expect(TranslationTarget.name("pt-PT", preferred: [], locale: english) == "Portuguese (Portugal)")
        #expect(TranslationTarget.name("zh-Hant-TW", preferred: [], locale: english) == "Chinese (Taiwan)")
        #expect(TranslationTarget.name(nil, preferred: ["de-DE"], locale: english) == "German")
        #expect(TranslationTarget.name(nil, preferred: ["it-IT"], locale: Locale(identifier: "it_IT")) == "italiano")
    }
}
