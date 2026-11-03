import Foundation
@testable import PomeloCore
@testable import PomeloUIModel

/// The edges and builders the wheel content suites share.
enum WheelFixtures {
    /// `"a>b"` is an edge from a to b on engine `x` at cost 10; `"a>b@eng"` sets the engine; `"a>b#5"` sets the cost;
    /// `"a>b:op"` makes it the operation edge `op`.
    static func edge(_ spec: String, flags: EdgeFlags = []) -> ConversionEdge {
        var rest = Substring(spec)
        var cost = 10
        if let hash = rest.firstIndex(of: "#") {
            cost = Int(rest[rest.index(after: hash)...])!
            rest = rest[..<hash]
        }
        var engine = "x"
        if let at = rest.firstIndex(of: "@") {
            engine = String(rest[rest.index(after: at)...])
            rest = rest[..<at]
        }
        var operation: String?
        if let colon = rest.firstIndex(of: ":") {
            operation = String(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        let ends = rest.split(separator: ">").map(String.init)
        return ConversionEdge(from: FormatID(ends[0]), to: FormatID(ends[1]), engineID: EngineID(engine), cost: cost,
                              flags: flags, operation: operation)
    }

    /// An edge for every engine tool and every sample format its kinds cover, the way real engines will offer them.
    static let everyToolEdges: [String] = {
        let sample: [(format: String, category: FormatCategory)] = [
            ("png", .image), ("jpg", .image), ("mp4", .video), ("mov", .video), ("m4a", .audio), ("pdf", .pdf),
        ]
        return ToolCatalog.presets(settings: AppSettings()).flatMap { preset -> [String] in
            sample.filter { preset.categories?.contains($0.category) ?? true }.map { format, _ in
                let target = preset.target?.rawValue ?? format
                return "\(format)>\(target)" + (preset.operation.map { ":\($0)" } ?? "") + "@ffmpeg"
            }
        }
    }()

    static func builder(availableEdges: [String], allEdges: [String]? = nil, hints: [EngineID: String] = [:],
                        unsupported: [EngineID: String] = [:], installable: Set<EngineID> = [],
                        layoutRisk: Set<String> = [], settings: AppSettings = AppSettings(),
                        order: [FormatCategory: [FormatID]] = WheelContentBuilder.defaultOrder,
                        visibility: ToolVisibility? = nil, replacesOriginals: Bool = false) -> WheelContentBuilder {
        func planner(_ specs: [String]) -> RoutePlanner {
            RoutePlanner(edges: specs.map { edge($0, flags: layoutRisk.contains($0) ? .layoutRisk : []) },
                         enginePriority: [])
        }
        return WheelContentBuilder(
            formats: .builtIn, available: planner(availableEdges), all: planner(allEdges ?? availableEdges),
            installHints: hints, unsupportedReasons: unsupported, installable: installable, order: order,
            tools: ToolCatalog.presets(settings: settings),
            visibility: visibility ?? ToolVisibility(overrides: settings.toolVisibility),
            replacesOriginals: replacesOriginals, wheels: settings.wheels
        )
    }
}
