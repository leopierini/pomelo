// Keyboard navigation of the wheel in click mode: arrows move the selection around the current page, digits and
// Return activate a slice, Tab cycles pages, Escape dismisses. Pure state: the app maps NSEvents to `NavKey`.
// Only Foundation and PomeloCore: no AppKit.
import Foundation

public enum NavKey: Equatable, Sendable {
    case left, right, up, down, digit(Int), tab, enter, escape
}

public enum NavOutcome: Equatable, Sendable {
    /// The key did nothing (an empty page, an out-of-range digit, Return with no selection, a disabled slice).
    case none
    case moved
    /// Tab switched to another page (the selection is cleared).
    case pageChanged
    case activate(WheelSlice)
    case dismiss
}

public struct WheelNavigator: Sendable, Equatable {
    public let pages: [WheelPage]
    public private(set) var pageIndex: Int = 0
    /// The highlighted slice on the current page; nil until the first arrow key.
    public private(set) var selected: Int?

    public init(pages: [WheelPage]) {
        self.pages = pages
    }

    /// The navigator over `pages` on page `pageIndex` with `selected` highlighted, as far as they exist: for when
    /// the pages change under a navigator (a slice became disabled) and the keyboard should carry on where it was.
    public init(pages: [WheelPage], pageIndex: Int, selected: Int?) {
        self.pages = pages
        self.pageIndex = pages.indices.contains(pageIndex) ? pageIndex : 0
        select(selected)
    }

    private var slices: [WheelSlice] {
        pages.indices.contains(pageIndex) ? pages[pageIndex].slices : []
    }

    /// Selects `index` on the current page (nil, or an index off the page, clears the selection), so the next key
    /// continues from it. The app calls this when the mouse hovers a slice: the mouse takes over from the keys.
    public mutating func select(_ index: Int?) {
        selected = index.flatMap { slices.indices.contains($0) ? $0 : nil }
    }

    /// Applies a key and says what the app should do.
    ///
    /// - Right and down step clockwise, left and up counter-clockwise, wrapping around. The first step selects
    ///   slice 0 (clockwise) or the last slice (counter-clockwise). Disabled slices can be selected.
    /// - `digit(n)` activates slice n-1 (1...count); other digits, and disabled slices, give `.none`.
    /// - Return activates the selected slice; `.none` with no selection or a disabled slice.
    /// - Tab goes to the next page, wrapping (a single page wraps to itself), and clears the selection.
    /// - Escape always dismisses.
    public mutating func handle(_ key: NavKey) -> NavOutcome {
        let count = slices.count
        switch key {
        case .right, .down:
            guard count > 0 else { return .none }
            selected = selected.map { ($0 + 1) % count } ?? 0
            return .moved
        case .left, .up:
            guard count > 0 else { return .none }
            selected = selected.map { ($0 - 1 + count) % count } ?? count - 1
            return .moved
        case .digit(let n):
            guard n >= 1, n <= count, slices[n - 1].isEnabled else { return .none }
            selected = n - 1
            return .activate(slices[n - 1])
        case .enter:
            guard let index = selected, index < count, slices[index].isEnabled else { return .none }
            return .activate(slices[index])
        case .tab:
            guard !pages.isEmpty else { return .none }
            pageIndex = (pageIndex + 1) % pages.count
            selected = nil
            return .pageChanged
        case .escape:
            return .dismiss
        }
    }
}
