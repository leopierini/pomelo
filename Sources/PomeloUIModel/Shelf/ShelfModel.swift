// The Shelf's items and selection (S11 to S15, S18), pure: the panel, bookmarks and thumbnails live in the app.
import Foundation
import PomeloCore

public enum ShelfItemState: Equatable, Sendable {
    case present, inTrash, missing

    public var reason: String? {
        switch self {
        case .present: nil
        case .inTrash: ShelfCopy.movedToTrash
        case .missing: ShelfCopy.cantBeFound
        }
    }
}

public struct ShelfItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: URL
    /// `fileResourceIdentifier` rendered as a string, else the canonical path (S11).
    public var identity: String
    public var bookmark: Data?
    public var name: String
    public var byteCount: Int64?
    public var state: ShelfItemState

    public init(
        id: UUID = UUID(), url: URL, identity: String, name: String, byteCount: Int64?, bookmark: Data? = nil,
        state: ShelfItemState = .present
    ) {
        self.id = id
        self.url = url
        self.identity = identity
        self.name = name
        self.byteCount = byteCount
        self.bookmark = bookmark
        self.state = state
    }

    /// The row's second label and VoiceOver value: why the file is greyed, else its size (S8, S22).
    public var detail: String? { state.reason ?? byteCount.map(ShelfCopy.size) }
}

public struct ShelfModel: Equatable, Sendable {
    public private(set) var items: [ShelfItem] = []
    public private(set) var selection: Set<UUID> = []
    /// Where a ⇧-click or ⇧-arrow extends from, and the item the arrow keys move from.
    private var anchor: UUID?
    private var focus: UUID?

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// The item the arrow keys move from, for the list to keep in view.
    public var focused: UUID? { focus }

    // MARK: Items

    /// `existing` lists the items that were already there (or came earlier in this batch), for the blink (S11).
    @discardableResult
    public mutating func add(_ new: [ShelfItem]) -> (added: [UUID], existing: [UUID]) {
        var added: [UUID] = []
        var existing: [UUID] = []
        for item in new {
            if let match = items.first(where: { $0.identity == item.identity }) {
                existing.append(match.id)
            } else {
                items.append(item)
                added.append(item.id)
            }
        }
        return (added, existing)
    }

    public mutating func remove(_ ids: Set<UUID>) {
        let before = items
        items.removeAll { ids.contains($0.id) }
        forget(ids, in: before)
    }

    public mutating func clear() {
        items = []
        selection = []
        anchor = nil
        focus = nil
    }

    public mutating func update(_ id: UUID, url: URL, name: String, state: ShelfItemState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].url = url
        items[index].name = name
        items[index].state = state
    }

    /// `identity` is the file that was bookmarked: a replace original keeps the item's id for a new file, and the
    /// original's late bookmark would follow it into the Trash.
    public mutating func setBookmark(_ data: Data, for id: UUID, identity: String) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.identity == identity }) else { return }
        items[index].bookmark = data
    }

    /// A removed anchor or focus moves to the nearest selected item that stays (`before` is the order they had),
    /// so the next ⇧-click or ⇧-arrow still extends.
    private mutating func forget(_ ids: Set<UUID>, in before: [ShelfItem]) {
        selection.subtract(ids)
        func nearest(to id: UUID) -> UUID? {
            guard let origin = before.firstIndex(where: { $0.id == id }) else { return nil }
            return before.indices
                .filter { selection.contains(before[$0].id) }
                .min { (abs($0 - origin), $0) < (abs($1 - origin), $1) }
                .map { before[$0].id }
        }
        if let anchor, ids.contains(anchor) { self.anchor = nearest(to: anchor) }
        if let focus, ids.contains(focus) { self.focus = nearest(to: focus) }
    }

    // MARK: Results (S18)

    /// A succeeded result with outputs replaces its source by the outputs not already on the Shelf, in order. An
    /// output already there moves to the source's place when the source sits earlier (R6), so a combine's one output
    /// ends at its first source's place whatever order the results arrive. An output at the source's own path
    /// (replace original) keeps the source's item, id and selection, refreshed. Anything else changes nothing.
    /// Returns the announcement, nil when nothing was added or replaced.
    public mutating func apply(_ result: FileResult, makeItem: (URL) -> ShelfItem) -> String? {
        guard case .succeeded(let source, let outputs, _) = result, !outputs.isEmpty else { return nil }
        let sourcePath = source.standardizedFileURL.path
        guard let sourceIndex = items.firstIndex(where: { $0.url.standardizedFileURL.path == sourcePath }) else {
            return nil
        }
        let sourceItem = items[sourceIndex]
        let before = items
        let group = resultGroup(outputs, replacing: sourceItem, at: sourcePath, makeItem: makeItem)
        guard !group.items.isEmpty else { return nil }
        place(group, replacing: sourceItem, at: sourceIndex)
        if !group.keepsSource { carrySelection(from: sourceItem.id, to: group.items, before: before) }
        return announcement(of: group, replacing: sourceItem)
    }

    /// What a result puts in its source's place, and which of those items are new to the Shelf.
    private struct ResultGroup {
        var items: [ShelfItem] = []
        var newIDs: Set<UUID> = []
        /// An output at the source's own path keeps the source's item.
        var keepsSource = false
    }

    private func resultGroup(_ outputs: [URL], replacing sourceItem: ShelfItem, at sourcePath: String,
                             makeItem: (URL) -> ShelfItem) -> ResultGroup {
        var group = ResultGroup()
        var seen: Set<String> = []
        for url in outputs {
            let candidate = makeItem(url)
            guard seen.insert(candidate.identity).inserted else { continue }
            if url.standardizedFileURL.path == sourcePath {
                var refreshed = sourceItem
                refreshed.url = candidate.url
                refreshed.identity = candidate.identity
                refreshed.name = candidate.name
                refreshed.byteCount = candidate.byteCount
                // The old bookmark follows the source into the Trash: the app bookmarks the output instead.
                refreshed.bookmark = nil
                refreshed.state = .present
                group.keepsSource = true
                group.items.append(refreshed)
            } else if let match = items.first(where: { $0.identity == candidate.identity && $0.id != sourceItem.id }) {
                group.items.append(match)
            } else {
                group.items.append(candidate)
                group.newIDs.insert(candidate.id)
            }
        }
        return group
    }

    private mutating func place(_ group: ResultGroup, replacing sourceItem: ShelfItem, at sourceIndex: Int) {
        let existingIDs = Set(group.items.map(\.id)).subtracting(group.newIDs).subtracting([sourceItem.id])
        let existingIndexes = items.indices.filter { existingIDs.contains(items[$0].id) }
        let moveExisting = (existingIndexes.min() ?? Int.max) > sourceIndex

        let placed = moveExisting
            ? group.items : group.items.filter { group.newIDs.contains($0.id) || $0.id == sourceItem.id }
        var rest = items
        rest.removeAll { $0.id == sourceItem.id || (moveExisting && existingIDs.contains($0.id)) }
        rest.insert(contentsOf: placed, at: min(sourceIndex, rest.count))
        items = rest
    }

    /// A selected source hands its selection, anchor and focus to the items that replaced it.
    private mutating func carrySelection(from sourceID: UUID, to group: [ShelfItem], before: [ShelfItem]) {
        let wasSelected = selection.contains(sourceID)
        let wasAnchor = anchor == sourceID
        let wasFocus = focus == sourceID
        forget([sourceID], in: before)
        guard wasSelected else { return }
        selection.formUnion(group.map(\.id))
        if wasAnchor { anchor = group[0].id }
        if wasFocus { focus = group[0].id }
    }

    private func announcement(of group: ResultGroup, replacing sourceItem: ShelfItem) -> String? {
        let others = group.items.filter { $0.id != sourceItem.id }
        if group.keepsSource {
            let added = others.filter { group.newIDs.contains($0.id) }
            return added.isEmpty ? nil : ShelfCopy.added(added.map(\.name))
        }
        return ShelfCopy.became(sourceItem.name, others.count == 1 ? others[0].name : ShelfCopy.fileCount(others.count))
    }

    // MARK: Selection (the Organize pages editor's rules, S12)

    public mutating func click(_ id: UUID) {
        guard contains(id) else { return }
        selection = [id]
        anchor = id
        focus = id
    }

    public mutating func commandClick(_ id: UUID) {
        guard contains(id) else { return }
        if !selection.insert(id).inserted { selection.remove(id) }
        anchor = id
        focus = id
    }

    public mutating func shiftClick(_ id: UUID) {
        guard contains(id) else { return }
        guard let anchor, let from = index(of: anchor), let to = index(of: id) else {
            click(id)
            return
        }
        selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        focus = id
    }

    public mutating func selectAll() {
        selection = Set(items.map(\.id))
        anchor = items.first?.id
        focus = items.last?.id
    }

    /// The arrow keys. With nothing selected the first item (the last, going up) is chosen.
    public mutating func moveSelection(by offset: Int, extending: Bool) {
        guard !items.isEmpty, offset != 0 else { return }
        guard let current = focus.flatMap({ selection.contains($0) ? index(of: $0) : nil })
            ?? items.indices.first(where: { selection.contains(items[$0].id) })
        else {
            click(items[offset > 0 ? 0 : items.count - 1].id)
            return
        }
        let id = items[min(max(current + offset, 0), items.count - 1)].id
        if extending { shiftClick(id) } else { click(id) }
    }

    private func contains(_ id: UUID) -> Bool { index(of: id) != nil }
    private func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: Drag out (S12)

    /// Collapsed: every present item. Expanded: the selection when the pressed row is in it, else that row alone.
    public func dragOut(pressed: UUID?, expanded: Bool) -> [ShelfItem] {
        let present = items.filter { $0.state == .present }
        guard expanded else { return present }
        if let pressed, !selection.contains(pressed) {
            return present.filter { $0.id == pressed }
        }
        return present.filter { selection.contains($0.id) }
    }

    // MARK: Labels (S22)

    /// The three most recent present items, oldest first.
    public var stack: [ShelfItem] {
        Array(items.filter { $0.state == .present }.suffix(3))
    }

    public var title: String {
        switch items.count {
        case 0: ShelfCopy.shelf
        case 1: items[0].name
        default: ShelfCopy.fileCount(items.count)
        }
    }

    public var subtitle: String? { totalSize.map(ShelfCopy.size) }

    public var accessibilityValue: String {
        guard !items.isEmpty else { return ShelfCopy.empty }
        return [title, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    public var stackAccessibilityValue: String {
        guard !items.isEmpty else { return ShelfCopy.empty }
        let names = items.map(\.name)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// Present items only; nil as soon as one of them has no known size, so a partial sum is never shown as a total.
    private var totalSize: Int64? {
        let present = items.filter { $0.state == .present }
        let sizes = present.compactMap(\.byteCount)
        guard !sizes.isEmpty, sizes.count == present.count else { return nil }
        return sizes.reduce(0, +)
    }
}
