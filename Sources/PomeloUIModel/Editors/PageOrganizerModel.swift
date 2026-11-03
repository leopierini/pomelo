// The Organize pages editor's choices (P27): the output's pages in order, each a source page with the rotation
// added to it, and which of them are selected. Positions are indexes into `pages`; `PageEdit.page` is the source's
// 0-based index and is unique, so a selection can follow its pages through a move.
import Foundation
import PomeloCore

public struct PageOrganizerModel: Equatable, Sendable {
    public let pageCount: Int
    public var pages: [PageEdit]
    /// Positions in `pages`.
    public var selection: Set<Int> = []
    /// Where a ⇧-click or ⇧-arrow extends from.
    public private(set) var anchor: Int?
    /// The page the arrow keys move from: the one last clicked or reached.
    public private(set) var focus: Int?

    public static let noChanges = "No changes"
    public static let keepOne = "Keep at least one page"

    public init(pageCount: Int) {
        self.pageCount = max(0, pageCount)
        pages = (0..<max(0, pageCount)).map { PageEdit(page: $0, rotation: 0) }
    }

    // MARK: Selection

    /// A click: replaces the selection, ⌘ toggles one page, ⇧ selects from the anchor.
    public mutating func click(_ position: Int, toggle: Bool = false, extend: Bool = false) {
        guard pages.indices.contains(position) else { return }
        if extend, let anchor, pages.indices.contains(anchor) {
            selection = Set(min(anchor, position)...max(anchor, position))
        } else if toggle {
            if !selection.insert(position).inserted { selection.remove(position) }
            anchor = position
        } else {
            selection = [position]
            anchor = position
        }
        focus = position
    }

    /// The arrow keys. Without a selection the first page (the last, going back) is chosen; with `extend` the
    /// selection grows from the anchor to the page `offset` away from the one the keys last reached.
    public mutating func step(by offset: Int, extend: Bool) {
        guard !pages.isEmpty, offset != 0 else { return }
        guard let current = focus.flatMap({ selection.contains($0) ? $0 : nil }) ?? selection.min() else {
            click(offset > 0 ? 0 : pages.count - 1)
            return
        }
        let target = min(max(current + offset, 0), pages.count - 1)
        click(target, extend: extend)
    }

    public mutating func selectAll() {
        selection = Set(pages.indices)
        anchor = pages.indices.first
        focus = pages.indices.last
    }

    public mutating func clearSelection() {
        selection = []
        anchor = nil
        focus = nil
    }

    // MARK: Changes

    /// SwiftUI's `move(fromOffsets:toOffset:)`: the pages at `source` go before the page that is at `destination`
    /// (`pages.count` for the end) and keep their order. The selection stays on the same pages.
    public mutating func move(from source: IndexSet, to destination: Int) {
        let moving = source.filter { pages.indices.contains($0) }
        guard !moving.isEmpty else { return }
        let marks = marks()
        let target = min(max(destination, 0), pages.count)
        let lifted = moving.map { pages[$0] }
        var rest = pages
        for position in moving.reversed() { rest.remove(at: position) }
        rest.insert(contentsOf: lifted, at: target - moving.filter { $0 < target }.count)
        pages = rest
        restore(marks)
    }

    /// Moves the selected pages `offset` places, one step at a time: pages at an edge stay, and the others go on.
    public mutating func moveSelected(by offset: Int) {
        guard offset != 0, !selection.isEmpty else { return }
        let marks = marks()
        let selected = Set(marks.selected)
        for _ in 0..<abs(offset) {
            var moved = false
            let order = offset < 0 ? Array(pages.indices) : pages.indices.reversed()
            for position in order where selected.contains(pages[position].page) {
                let next = position + (offset < 0 ? -1 : 1)
                guard pages.indices.contains(next), !selected.contains(pages[next].page) else { continue }
                pages.swapAt(position, next)
                moved = true
            }
            if !moved { break }
        }
        restore(marks)
    }

    /// The selection, anchor and focus as source pages, which a reorder doesn't change.
    private struct Marks {
        var selected: [Int]
        var anchor: Int?
        var focus: Int?
    }

    private func marks() -> Marks {
        Marks(selected: selection.compactMap { pages.indices.contains($0) ? pages[$0].page : nil },
              anchor: anchor.flatMap { pages.indices.contains($0) ? pages[$0].page : nil },
              focus: focus.flatMap { pages.indices.contains($0) ? pages[$0].page : nil })
    }

    private mutating func restore(_ marks: Marks) {
        func position(_ page: Int?) -> Int? { page.flatMap { page in pages.firstIndex { $0.page == page } } }
        let selected = Set(marks.selected)
        selection = Set(pages.indices.filter { selected.contains(pages[$0].page) })
        anchor = position(marks.anchor)
        focus = position(marks.focus)
    }

    public mutating func rotateSelected(clockwise: Bool) {
        for position in selection where pages.indices.contains(position) {
            pages[position].rotation = ((pages[position].rotation + (clockwise ? 90 : -90)) % 360 + 360) % 360
        }
    }

    /// Removes the selected pages; the page that takes the first one's place is selected, so a run of deletes keeps
    /// going from the same spot.
    public mutating func deleteSelected() {
        guard let first = selection.min() else { return }
        let removed = selection
        pages = pages.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        if pages.isEmpty {
            clearSelection()
        } else {
            click(min(first, pages.count - 1))
        }
    }

    // MARK: What is saved

    public var spec: EditSpec? { blocker == nil ? .organize(pages) : nil }

    public var blocker: String? {
        if pages.isEmpty { return Self.keepOne }
        return pages == (0..<pageCount).map({ PageEdit(page: $0, rotation: 0) }) ? Self.noChanges : nil
    }

    /// "12 pages, 2 removed, 1 rotated": the parts that are not zero.
    public var summary: String {
        var parts = [pages.count == 1 ? "1 page" : "\(pages.count) pages"]
        let removed = pageCount - pages.count
        if removed > 0 { parts.append("\(removed) removed") }
        let rotated = pages.filter { $0.rotation != 0 }.count
        if rotated > 0 { parts.append("\(rotated) rotated") }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for the page at `position`.
    public func label(at position: Int) -> String {
        guard pages.indices.contains(position) else { return "" }
        let edit = pages[position]
        var label = "Page \(edit.page + 1), position \(position + 1) of \(pages.count)"
        if edit.rotation != 0 { label += ", rotated \(edit.rotation)\u{00B0}" }
        return label
    }
}
