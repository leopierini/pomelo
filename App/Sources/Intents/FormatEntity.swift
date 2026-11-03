import AppIntents
import Foundation
import PomeloCore
import PomeloUIModel

/// A format Shortcuts can convert to, shown by its display name ("JPEG").
struct FormatEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let defaultQuery = FormatQuery()

    /// The `FormatID` raw value.
    let id: String
    let name: String

    init(_ format: FileFormat) {
        id = format.id.rawValue
        name = format.displayName
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// Offers the formats the installed engines can make now.
struct FormatQuery: EntityQuery, EntityStringQuery {
    /// Any known format resolves, even one no installed engine makes any more: a saved shortcut then fails with a
    /// sentence ("Couldn't convert a.png. Can't become WebP.") instead of losing its choice.
    func entities(for identifiers: [String]) async throws -> [FormatEntity] {
        identifiers.compactMap { FormatRegistry.builtIn.format(id: FormatID($0)).map(FormatEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [FormatEntity] {
        await AppEnvironment.shared.intents.targetFormats().map(FormatEntity.init)
    }

    /// By name or extension, so "jpeg" and "jpg" both find JPEG.
    @MainActor
    func entities(matching string: String) async throws -> [FormatEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let formats = await AppEnvironment.shared.intents.targetFormats()
        guard !query.isEmpty else { return formats.map(FormatEntity.init) }
        return formats.filter { format in
            format.displayName.localizedCaseInsensitiveContains(query)
                || format.extensions.contains { $0.hasPrefix(query) }
        }.map(FormatEntity.init)
    }
}
