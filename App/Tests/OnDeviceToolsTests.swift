import Foundation
import PomeloCore
import PomeloEngines
import PomeloUIModel
import Testing
@testable import Pomelo

/// Phase 4b in the app: what Settings › Tools loads for the on-device tools, and how the catalog meets the real engines.
@MainActor
@Suite struct ToolChoicesModelTests {
    @Test func theLanguagesLoadOffTheMainThreadNamedAndSorted() async {
        let onMain = LockedFlag()
        let model = ToolChoicesModel(
            loadLanguages: { _ in
                onMain.set(pthread_main_np() != 0)
                return [LanguageChoice(identifier: "it", isInstalled: true),
                        LanguageChoice(identifier: "de", isInstalled: false),
                        LanguageChoice(identifier: "pt-PT", isInstalled: false)]
            },
            loadReasons: { [:] }
        )
        await model.load()
        #expect(onMain.value == false)
        let english = Locale(identifier: "en_US")
        let named = ToolChoicesModel.options(
            [LanguageChoice(identifier: "it", isInstalled: true), LanguageChoice(identifier: "de", isInstalled: false),
             LanguageChoice(identifier: "pt-PT", isInstalled: false)], locale: english)
        #expect(named.map(\.name) == ["German", "Italian", "Portuguese (Portugal)"])
        #expect(named.map(\.isInstalled) == [false, true, false])
        #expect(model.languages[.translation]?.map(\.identifier).sorted() == ["de", "it", "pt-PT"])
    }

    @Test func theReasonsLoadOffTheMainThread() async {
        let onMain = LockedFlag()
        let model = ToolChoicesModel(
            loadLanguages: { _ in [] },
            loadReasons: {
                onMain.set(pthread_main_np() != 0)
                return ["translate": "Needs macOS 26."]
            }
        )
        await model.load()
        #expect(onMain.value == false)
        #expect(model.unsupportedReasons == ["translate": "Needs macOS 26."])
    }

    /// Below macOS 26 the three engines report themselves unsupported: their tools carry the reason, the others none.
    @Test func everyToolOfAnUnsupportedEngineHasItsReason() async {
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        let planner = await registry.planner(includingMissing: true)
        let unsupported: [EngineID: String] = [
            "translation": "Needs macOS 26.", "documentscan": "Needs macOS 26.", "intelligence": "Needs macOS 26.",
            "speech": "Needs macOS 26.",
        ]
        let reasons = ToolChoicesModel.reasons(planner: planner, engineReasons: unsupported)
        #expect(reasons == [
            "translate": "Needs macOS 26.", "summarize": "Needs macOS 26.", "scan-document": "Needs macOS 26.",
            "extract-tables": "Needs macOS 26.", "extract-data": "Needs macOS 26.", "transcribe": "Needs macOS 26.",
            "make-subtitles": "Needs macOS 26.",
        ])
        #expect(ToolChoicesModel.reasons(planner: planner, engineReasons: [:]).isEmpty)
    }
}

/// The catalog against the engines Pomelo ships.
@Suite struct OnDeviceCatalogTests {
    private static let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)

    /// P159, Task 0's deferred minor: an output-format setting offers exactly what the tool's edges make, from every
    /// format of every kind it applies to.
    @Test func anOutputFormatSettingOffersWhatTheEdgesMakeForEveryKind() async throws {
        let planner = await Self.registry.planner(includingMissing: true)
        for info in ToolCatalog.all where !ToolCatalog.outputFormats(of: info).isEmpty {
            let preset = try #require(Preset.builtIns.first { $0.id == info.id })
            let operation = try #require(preset.operation)
            let kinds = try #require(info.kinds)
            for kind in kinds {
                let sources = FormatRegistry.builtIn.all.filter { $0.category == kind }
                let made = sources.map { source in
                    Set(FormatRegistry.builtIn.all.map(\.id).filter {
                        planner.route(from: source.id, operation: operation, to: $0) != nil
                    })
                }.filter { !$0.isEmpty }
                #expect(!made.isEmpty, "\(info.id) has no edge for \(kind)")
                for targets in made {
                    #expect(targets == Set(ToolCatalog.outputFormats(of: info)), "\(info.id) for \(kind)")
                }
            }
        }
    }

    /// Translate's kinds hold every document, but only Markdown has its edge (Task 3's note).
    @Test func translateIsOfferedOnlyForFormatsWithATranslationEdge() async {
        let registry = Self.registry
        let builder = WheelContentBuilder(
            formats: .builtIn, available: await registry.planner(), all: await registry.planner(includingMissing: true),
            installHints: await registry.installHints(), unsupportedReasons: await registry.unsupportedReasons(),
            tools: ToolCatalog.presets(settings: AppSettings())
        )
        func offersTranslate(_ name: String) -> Bool {
            builder.pages(for: [URL(fileURLWithPath: "/x/\(name)")]).flatMap(\.slices)
                .contains { $0.id == "preset.translate" }
        }
        for name in ["a.srt", "a.vtt", "a.txt", "a.md"] { #expect(offersTranslate(name), "\(name)") }
        for name in ["a.docx", "a.pdf", "a.html", "a.rtf", "a.png"] { #expect(!offersTranslate(name), "\(name)") }
    }

    /// The Engines pane lists the registry's engines, with an unsupported one's reason under its name (Task 0).
    @Test func theRegistryHoldsTheOnDeviceEngines() async {
        let names = await ["translation", "documentscan", "intelligence", "speech"].asyncMap {
            await Self.registry.engine(id: EngineID($0))?.displayName
        }
        #expect(names == ["Translation", "Document scan", "Apple Intelligence", "Speech"])
    }

    /// P157: a video's Convert page keeps its formats; the speech tools are on its AI page only.
    @Test func theSpeechToolsAreToolsNotConversions() async {
        let registry = Self.registry
        let builder = WheelContentBuilder(
            formats: .builtIn, available: await registry.planner(), all: await registry.planner(includingMissing: true),
            installHints: await registry.installHints(), unsupportedReasons: await registry.unsupportedReasons(),
            tools: ToolCatalog.presets(settings: AppSettings())
        )
        let pages = builder.pages(for: [URL(fileURLWithPath: "/x/clip.mp4")])
        let convert = pages.first { $0.kind == .convert }?.slices.map(\.id) ?? []
        #expect(!convert.contains { $0.hasSuffix(".txt") || $0.hasSuffix(".srt") || $0.hasSuffix(".vtt") }, "\(convert)")
        #expect(pages.first { $0.kind == .ai }?.slices.contains { $0.id == "preset.make-subtitles" } == true)
    }
}

/// The spoken languages Settings offers and the Engines pane names (P155, P158).
@MainActor
@Suite struct SpeechLanguagesTests {
    @Test func everySupportedLocaleIsListedOnceWithTheInstalledOnesMarked() {
        let supported = ["en_US", "it_IT", "en_GB", "en_US"].map(Locale.init(identifier:))
        let choices = SpeechLanguages.choices(supported: supported, installed: [Locale(identifier: "en_US")])
        #expect(choices == [
            LanguageChoice(identifier: "en-US", isInstalled: true), LanguageChoice(identifier: "it-IT", isInstalled: false),
            LanguageChoice(identifier: "en-GB", isInstalled: false),
        ])
    }

    @Test func theEnginesPaneNamesEachInstalledLanguageOnce() async {
        let english = Locale(identifier: "en_US")
        let installed = ["en_US", "en_GB", "en_AU", "it_IT"].map(Locale.init(identifier:))
        #expect(SpeechLanguages.names(of: installed, in: english) == ["English", "Italian"])

        let onMain = LockedFlag()
        let model = EnginesModel(
            loadStatuses: { [EngineStatus(id: "speech", displayName: "Speech", availability: .available(version: nil))] },
            refresh: {},
            loadSpokenLanguages: {
                onMain.set(pthread_main_np() != 0)
                return ["English", "Italian"]
            })
        await model.load()
        #expect(onMain.value == false)
        let speech = EngineStatus(id: "speech", displayName: "Speech", availability: .available(version: nil))
        let other = EngineStatus(id: "ffmpeg", displayName: "FFmpeg", availability: .available(version: nil))
        #expect(model.detail(for: speech) == "Spoken languages on this Mac: \(ListFormatter.localizedString(byJoining: ["English", "Italian"])).")
        #expect(model.detail(for: other) == nil)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var mapped: [T] = []
        for element in self { mapped.append(await transform(element)) }
        return mapped
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }

    func set(_ value: Bool) { lock.withLock { stored = value } }
}
