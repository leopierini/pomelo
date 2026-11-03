// The Shelf's key pill (R30): what ⌘ does to a drag out of it, drawn as the wheel's page pill is (the key, then the
// titles with the current one bright; P32: separate labels).

public struct ShelfPill: Equatable, Sendable {
    public let key = "⌘"
    /// macOS's own words for a drag (S33's move, never "cut").
    public let titles = [ShelfCopy.copy, ShelfCopy.move]
    /// The bright title: Move while ⌘ is held, else Copy.
    public let current: Int

    /// Nil where nothing can be dragged out: the empty drawer, the tab, a Shelf whose every file is missing.
    public init?(for model: ShelfModel, presentation: ShelfPresentation, commandHeld: Bool) {
        switch presentation {
        case .empty, .tucked: return nil
        case .collapsed, .expanded: break
        }
        guard model.items.contains(where: { $0.state == .present }) else { return nil }
        current = commandHeld ? 1 : 0
    }
}
