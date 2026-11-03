// What the Tools pane learns from the engines: the languages its pickers offer, and why this Mac can't run a tool.
// Both are read off the main thread when the pane appears; the wheel never waits on them.
import Foundation
import PomeloCore
import PomeloUIModel

/// A list of languages a picker offers; each language setting in the catalog reads one.
enum LanguageList: CaseIterable, Sendable {
    /// What Translate can write into.
    case translation
    /// What the speech tools can listen for.
    case speech
}

/// A language as a picker shows it.
struct LanguageOption: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let isInstalled: Bool

    var id: String { identifier }
}

@MainActor
final class ToolChoicesModel: ObservableObject {
    typealias LoadLanguages = @Sendable (LanguageList) async -> [LanguageChoice]
    typealias LoadReasons = @Sendable () async -> [String: String]

    @Published private(set) var languages: [LanguageList: [LanguageOption]] = [:]
    /// Tool id → the sentence that says why this Mac can't run it ("Needs macOS 26.").
    @Published private(set) var unsupportedReasons: [String: String] = [:]

    private let loadLanguages: LoadLanguages
    private let loadReasons: LoadReasons

    init(loadLanguages: @escaping LoadLanguages, loadReasons: @escaping LoadReasons) {
        self.loadLanguages = loadLanguages
        self.loadReasons = loadReasons
    }

    convenience init(environment: AppEnvironment) {
        let registry = environment.registry
        self.init(
            loadLanguages: { list in
                switch list {
                case .translation: await TranslationLanguages.load()
                case .speech: await SpeechLanguages.load()
                }
            },
            loadReasons: {
                let reasons = await registry.unsupportedReasons()
                let planner = await registry.planner(includingMissing: true)
                return Self.reasons(planner: planner, engineReasons: reasons)
            }
        )
    }

    /// Reloads every time the pane appears: a language downloaded in System Settings meanwhile shows as installed.
    func load() async {
        let (loadLanguages, loadReasons) = (loadLanguages, loadReasons)
        unsupportedReasons = await Task.detached { await loadReasons() }.value
        for list in LanguageList.allCases {
            languages[list] = await Task.detached {
                Self.options(await loadLanguages(list), locale: .current)
            }.value
        }
    }

    /// Tool id → reason, for the catalog's engine tools that no engine on this Mac can run.
    nonisolated static func reasons(planner: RoutePlanner, engineReasons: [EngineID: String]) -> [String: String] {
        var reasons: [String: String] = [:]
        for preset in ToolCatalog.presets(settings: AppSettings()) {
            reasons[preset.id] = ToolCatalog.unsupportedReason(
                of: preset, formats: .builtIn, planner: planner, reasons: engineReasons)
        }
        return reasons
    }

    /// Named in `locale` and sorted by name.
    nonisolated static func options(_ choices: [LanguageChoice], locale: Locale) -> [LanguageOption] {
        choices.map {
            LanguageOption(identifier: $0.identifier, name: name(of: $0.identifier, in: locale),
                           isInstalled: $0.isInstalled)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func name(of identifier: String, in locale: Locale) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}
