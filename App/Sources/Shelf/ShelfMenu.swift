import SwiftUI

/// The menu-bar items between Show Welcome and Quit (S6).
enum ShelfMenu {
    enum Action { case show, clear }

    static func items(isEmpty: Bool) -> [(title: String, isEnabled: Bool)] {
        [("Show Shelf", true), ("Clear Shelf", !isEmpty)]
    }

    @MainActor static func perform(_ action: Action, on shelf: ShelfController) {
        switch action {
        case .show: shelf.summon(.menu)
        case .clear: shelf.clear()
        }
    }
}

/// Observes the Shelf so Clear Shelf enables as files arrive.
struct ShelfMenuItems: View {
    @ObservedObject var shelf: ShelfController

    var body: some View {
        let items = ShelfMenu.items(isEmpty: shelf.model.isEmpty)
        Button(items[0].title) { ShelfMenu.perform(.show, on: shelf) }
            .disabled(!items[0].isEnabled)
        Button(items[1].title) { ShelfMenu.perform(.clear, on: shelf) }
            .disabled(!items[1].isEnabled)
    }
}
