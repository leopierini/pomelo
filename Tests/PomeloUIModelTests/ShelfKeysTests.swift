import PomeloUIModel
import Testing

/// The keys the Shelf takes while it is key (S17), from a key-down's characters without modifiers.
struct ShelfKeysTests {
    private let up = "\u{F700}"
    private let down = "\u{F701}"

    @Test func mapping() {
        let expected: [(String, ModifierSet, ShelfKey)] = [
            (up, [], .up), (down, [], .down),
            (up, [.shift], .extendUp), (down, [.shift], .extendDown),
            ("a", [.command], .selectAll), ("A", [.command], .selectAll),
            (" ", [], .quickLook),
            ("\r", [], .openWheel),
            ("\u{7F}", [], .remove),
            ("c", [.command], .copy),
            ("\u{1B}", [], .escape),
        ]
        for (characters, modifiers, key) in expected {
            #expect(ShelfKey.key(characters: characters, modifiers: modifiers) == key, "\(characters.unicodeScalars)")
        }
    }

    @Test func nothingElse() {
        let refused: [(String, ModifierSet)] = [
            // Other modifiers on the plain keys.
            (up, [.command]), (up, [.option]), (down, [.control]), (up, [.shift, .command]),
            (" ", [.shift]), (" ", [.command]), ("\r", [.command]), ("\r", [.shift]), ("\u{1B}", [.shift]),
            // ⌘⌫ is Finder's Move to Trash: the Shelf never answers it (S14).
            ("\u{7F}", [.command]), ("\u{7F}", [.shift]),
            // The letters without ⌘, or with another modifier too.
            ("a", []), ("c", []), ("a", [.command, .shift]), ("c", [.command, .option]),
            // Keys the Shelf doesn't use.
            ("\u{F702}", []), ("\u{F703}", []), ("\t", []), ("\u{3}", []), ("\u{F728}", []), ("v", [.command]),
            ("x", [.command]), ("z", [.command]), ("k", [.command, .option]), ("", []), ("ab", [.command]),
        ]
        for (characters, modifiers) in refused {
            #expect(ShelfKey.key(characters: characters, modifiers: modifiers) == nil,
                    "\(characters.unicodeScalars) \(modifiers)")
        }
    }
}
