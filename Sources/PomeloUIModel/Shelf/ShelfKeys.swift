// The keys the Shelf takes while it is key (S17). They reach it only through its own panel's key handling, after a
// click made it key: no key monitor, no event tap.

/// What a key does on the Shelf.
public enum ShelfKey: Sendable, Equatable {
    case up, down, extendUp, extendDown, selectAll, quickLook, openWheel, remove, copy, escape

    /// The key for a key-down's `charactersIgnoringModifiers` and its modifiers, or nil for any other key or chord.
    /// ⌘⌫ stays unanswered: it is Finder's Move to Trash, and the Shelf only forgets (S14).
    public static func key(characters: String, modifiers: ModifierSet) -> ShelfKey? {
        switch modifiers {
        case []: plain[characters]
        case [.shift]: shifted[characters]
        case [.command]: command[characters.lowercased()]
        default: nil
        }
    }

    private static let upArrow = "\u{F700}"
    private static let downArrow = "\u{F701}"

    private static let plain: [String: ShelfKey] = [
        upArrow: .up, downArrow: .down, " ": .quickLook, "\r": .openWheel, "\u{7F}": .remove, "\u{1B}": .escape,
    ]
    private static let shifted: [String: ShelfKey] = [upArrow: .extendUp, downArrow: .extendDown]
    private static let command: [String: ShelfKey] = ["a": .selectAll, "c": .copy]
}
