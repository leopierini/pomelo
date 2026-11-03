import AppIntents
import Foundation
import PomeloCore
import PomeloUIModel

/// A tool Shortcuts can run, with its name and symbol from the tool catalog.
struct ToolEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tool"
    static let defaultQuery = ToolQuery()

    /// The preset's id.
    let id: String
    let name: String
    let symbol: String

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        symbol = ToolCatalog.symbol(ofPreset: preset.id)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbol))
    }
}

/// The tools that need nothing from the person: no editors (P103), no clipboard tools (P119).
struct ToolQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ToolEntity] {
        let tools = AppEnvironment.shared.intents.tools()
        return identifiers.compactMap { id in tools.first { $0.id == id }.map(ToolEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ToolEntity] {
        AppEnvironment.shared.intents.tools().map(ToolEntity.init)
    }
}
