// Turns an arrival into the job its folder's action asks for, or nothing when the action doesn't apply to it.
import Foundation
import PomeloCore

public enum WatchRules {
    /// The request for `file`, or nil when its format is unknown or already the target, the planner has no route, or
    /// the tool doesn't take the file's category or has no operation edge for its format. Always next to the arrival and
    /// never replacing it, whatever Settings › Tools says (P108).
    public static func request(
        for action: WatchAction, file: URL, formats: FormatRegistry, planner: RoutePlanner, tools: [Preset]
    ) -> ConversionRequest? {
        guard let format = formats.format(for: file) else { return nil }
        switch action {
        case .convert(let target):
            guard target != format.id, planner.route(from: format.id, to: target) != nil else { return nil }
            return ConversionRequest(inputs: [file], target: target)
        case .tool(let id):
            guard let preset = tools.first(where: { $0.id == id }), isWatchable(preset),
                  preset.categories?.contains(format.category) ?? true else { return nil }
            guard planner.route(from: format.id, operation: preset.operation, target: preset.target) != nil else {
                return nil
            }
            var request = ConversionRequest.from(preset, inputs: [file])
            request.replaceOriginal = false
            return request
        }
    }

    /// What the pane offers: every format something converts to, and the tools that run with no input and on one file
    /// at a time.
    public static func choices(
        formats: FormatRegistry, planner: RoutePlanner, tools: [Preset]
    ) -> (formats: [FileFormat], tools: [Preset]) {
        (IntentCatalog.targetFormats(formats: formats, planner: planner), tools.filter(isWatchable))
    }

    private static func isWatchable(_ preset: Preset) -> Bool {
        !preset.needsInput && !preset.combinesInputs && preset.delivery == .file
    }
}
