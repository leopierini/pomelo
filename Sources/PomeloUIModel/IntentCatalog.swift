// What Shortcuts offers (App Intents): the formats a file can become and the tools that run with no input from the
// person. An intent runs unattended (P106), so editors (P103) and clipboard tools (P119) are left out.
import Foundation
import PomeloCore

public enum IntentCatalog {
    /// Every format some format can be converted to over `planner`, by category, then by name. Operation edges are
    /// tools, not conversions, and `reachableTargets` never follows them.
    public static func targetFormats(formats: FormatRegistry, planner: RoutePlanner) -> [FileFormat] {
        var targets: Set<FormatID> = []
        for format in formats.all {
            targets.formUnion(planner.reachableTargets(from: format.id).keys)
        }
        let order = Dictionary(uniqueKeysWithValues: FormatCategory.allCases.enumerated().map { ($1, $0) })
        return formats.all.filter { targets.contains($0.id) }.sorted { a, b in
            if a.category != b.category { return order[a.category, default: 0] < order[b.category, default: 0] }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    /// The engine tools with the user's Settings › Tools options, in catalog order, without the editors and the
    /// clipboard tools; without the combines too unless `includingCombines`.
    public static func tools(settings: AppSettings, includingCombines: Bool = true) -> [Preset] {
        ToolCatalog.presets(settings: settings).filter { preset in
            !preset.needsInput && preset.delivery == .file && (includingCombines || !preset.combinesInputs)
        }
    }

    /// The summary as two sentences, for a Shortcut's error: "2 of 3 converted. bad.png may be damaged."
    public static func failureMessage(_ summary: ResultSummary) -> String {
        [summary.title, summary.detail].compactMap { $0 }.map(sentence).joined(separator: " ")
    }

    /// A detail shortened to fit the hub already ends in an ellipsis.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?\u{2026}".contains(last) else { return text }
        return text + "."
    }
}
