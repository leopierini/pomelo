// Settings › Wheel (P179): the wheel being edited, over the app's latest plans. Every edit goes through `WheelEditor`,
// is saved at once like every other setting and registers its inverse with the window's undo manager (⌘Z, ⇧⌘Z).
// Looking at a built-in wheel writes nothing; its first edit copies it (P179). A saved wheel always has a slot (P176).
import AppKit
import PomeloCore
import PomeloUIModel
import UniformTypeIdentifiers

extension UTType {
    /// A slot dragged in the wheel editor, declared in the app's Info.plist. The type is private to Pomelo's editor;
    /// another app that accepts any data would only see the slot id, which is harmless.
    static let wheelSlot = UTType(exportedAs: "io.github.pomelo-app.wheel-slot", conformingTo: .data)
}

@MainActor
final class WheelEditorPaneModel: ObservableObject {
    /// The kinds in the order the list shows them.
    static let kinds: [FormatCategory] = [
        .image, .video, .audio, .pdf, .document, .text, .subtitle, .data, .archive, .font, .other,
    ]
    /// How long a refusal's sentence stays under the wheel.
    static let messageDuration: Duration = .seconds(3)

    @Published private(set) var selection: WheelKey = .kind(.image)
    @Published private(set) var pageIndex = 0
    @Published private(set) var editor: WheelEditor
    @Published private(set) var customized: Set<WheelKey> = []
    /// A refusal's sentence, cleared after `messageDuration`.
    @Published private(set) var message: String?
    /// The editor's pages as the wheel draws them, with no files.
    @Published private(set) var pages: [WheelPage] = []
    @Published private(set) var candidates: WheelCandidates

    /// The window's, given by the view.
    var undoManager: UndoManager?
    /// Whether Settings shows the Wheel pane, set by the view. A new plan while it's hidden only marks the editor
    /// stale: laying out a kind's built-in wheel plans every format of the kind (about 30 ms for Images).
    var isVisible = false {
        didSet { if isVisible, isStale { reload() } }
    }
    private var isStale = false

    private let store: SettingsStore
    private var builder: WheelContentBuilder
    private var messageTask: Task<Void, Never>?

    init(store: SettingsStore, builder: WheelContentBuilder, undoManager: UndoManager?) {
        self.store = store
        self.builder = builder
        self.undoManager = undoManager
        editor = WheelEditor(key: .kind(.image), settings: store.settings, fallback: CustomWheel(pages: []))
        candidates = builder.candidates(for: .kind(.image))
        reload()
    }

    // MARK: - What the pane shows

    var currentPage: WheelPage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    /// A format without its own wheel: the editor shows its kind's wheel, faded, and takes no edits.
    var isFormatFollowingKind: Bool {
        if case .format = selection { !editor.isCustomized } else { false }
    }

    /// The kind whose wheel a format uses until it has its own.
    var kind: FormatCategory {
        switch selection {
        case .kind(let category): category
        case .format(let id): FormatRegistry.builtIn.format(id: id)?.category ?? .other
        }
    }

    var title: String {
        switch selection {
        case .kind(let category): category.wheelTitle
        case .format(let id): formatName(id)
        }
    }

    /// Something to reset: a customized wheel, or a kind's older format order or tool switches (P179).
    var canReset: Bool {
        if customized.contains(selection) { return true }
        guard case .kind(let category) = selection else { return false }
        return store.settings.wheelOrder[category.rawValue] != nil
            || store.settings.toolVisibility[category.rawValue] != nil
    }

    /// "5 of 8": the current page's slots against the cap.
    var hubCount: String {
        "\(currentPage?.slices.count ?? 0) of \(WheelContentBuilder.maxSlices)"
    }

    func formats(of kind: FormatCategory) -> [FileFormat] {
        builder.formats(of: kind)
    }

    func formatName(_ id: FormatID) -> String {
        FormatRegistry.builtIn.format(id: id)?.displayName ?? id.rawValue.uppercased()
    }

    func isOnPage(_ slot: String) -> Bool {
        currentPage?.slices.contains { $0.id == slot } ?? false
    }

    // MARK: - Selection

    func select(_ key: WheelKey) {
        guard key != selection else { return }
        selection = key
        pageIndex = 0
        clearMessage()
        reload()
    }

    func selectPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pageIndex = index
    }

    /// New plans from the app (engines or settings changed): a built-in wheel is laid out again from them.
    func update(builder: WheelContentBuilder) {
        self.builder = builder
        if isVisible { reload() } else { isStale = true }
    }

    // MARK: - Edits

    /// At `index`, else at the end of the page.
    func add(_ slot: String, at index: Int? = nil) {
        let page = pageIndex
        let end = editor.wheel.pages.indices.contains(page) ? editor.wheel.pages[page].slots.count : 0
        edit("Add") { $0.add(slot, page: page, at: index ?? end) }
    }

    func replace(at index: Int, with slot: String) {
        let page = pageIndex
        edit("Replace") { $0.replace(page: page, at: index, with: slot) }
    }

    /// `to` is an insertion index into the page as it is before the move, as `WheelEditor.move` takes it.
    func move(from: Int, to: Int) {
        let page = pageIndex
        edit("Move") { $0.move(page: page, from: from, to: to) }
    }

    func move(at index: Int, toPage: Int) {
        let page = pageIndex
        edit("Move to Page") { $0.move(page: page, at: index, toPage: toPage) }
    }

    func remove(at index: Int) {
        let page = pageIndex
        edit("Remove") { $0.remove(page: page, at: index) }
    }

    func addPage() {
        var added: Int?
        edit("New Page", showing: { added ?? $0 }) { editor in
            added = editor.addPage()
            return nil
        }
    }

    func renamePage(_ page: Int, to name: String) {
        edit("Rename Page") { editor in
            editor.renamePage(page, to: name)
            return nil
        }
    }

    /// The page shown stays shown wherever it moved.
    func movePage(from: Int, to: Int) {
        edit("Move Page", showing: { shown in
            if shown == from { return to }
            if from < shown, to >= shown { return shown - 1 }
            if from > shown, to <= shown { return shown + 1 }
            return shown
        }) { editor in
            editor.movePage(from: from, to: to)
            return nil
        }
    }

    /// Deleting a page before the shown one keeps showing that page; deleting the shown one shows its neighbour.
    func deletePage(_ page: Int) {
        edit("Delete Page", showing: { shown in page < shown ? shown - 1 : shown }) { $0.deletePage(page) }
    }

    /// Gives a format its own wheel, a copy of the one its kind shows now. A kind's wheel with no slot isn't copied.
    func customizeFormat() {
        guard isFormatFollowingKind, editor.wheel.slotCount > 0 else { return }
        let wheel = editor.wheel
        let key = selection
        write("Customize") { $0.wheels[key.rawValue] = wheel }
    }

    /// Back to the built-in wheel, or for a format to its kind's (the view asks first).
    func reset() {
        guard canReset else { return }
        let key = selection
        write("Reset") { WheelEditor.reset(key, in: &$0) }
    }

    // MARK: - Drag and drop

    /// Where a dragged slot comes from: a chip, or a slice of the page shown.
    enum DragSource: Equatable {
        case chip
        case slice(page: Int, index: Int)
    }

    /// What a drop on the ring would do, worked out once for both the ring's feedback and the drop.
    enum DropOutcome: Equatable {
        case insert(Int)
        case replace(Int)
        /// `to` is an insertion index into the page as it is before the move.
        case move(from: Int, to: Int)
        case remove(Int)
        case nothing
    }

    /// The drag under way, recorded by `beginDrag`: the drop targets read its source here, since the system hands
    /// them only a pasteboard type until the drop.
    /// Never cleared on a cancelled drag: a drop target re-checks it (`isSlice`, the payload), never trusts it alone.
    var dragging: (slot: String, source: DragSource)?

    func beginDrag(_ slot: String, from source: DragSource) -> NSItemProvider {
        dragging = (slot, source)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.wheelSlot.identifier,
                                            visibility: .all) { completion in
            completion(Data(slot.utf8), nil)
            return nil
        }
        return provider
    }

    /// `point` is centre-relative and y-up, as `WheelGeometry` takes it. A source of nil is a slot from elsewhere,
    /// placed as a chip would be.
    func dropOutcome(slot: String, from source: DragSource?, at point: CGPoint) -> DropOutcome {
        let count = currentPage?.slices.count ?? 0
        let geometry = WheelGeometry(sliceCount: count)
        switch source {
        case .slice(let page, let index):
            guard isSlice(slot, page: page, index: index) else { return .nothing }
            if let to = geometry.insertionIndex(at: point) { return .move(from: index, to: to) }
            return geometry.hitTest(point) == .outside ? .remove(index) : .nothing
        case .chip, nil:
            if isOnPage(slot) { return .nothing }
            if count >= WheelContentBuilder.maxSlices {
                switch geometry.hitTest(point) {
                case .slice(let index): return .replace(index)
                // Refused as full, so the drop says why.
                case .hub: return .insert(count)
                case .outside: return .nothing
                }
            }
            if let index = geometry.insertionIndex(at: point) { return .insert(index) }
            return geometry.hitTest(point) == .hub ? .insert(count) : .nothing
        }
    }

    /// A drop on the ring: a chip inserts where it lands, or on a full page replaces the slice under it; a slice
    /// moves, or leaves the wheel when dropped past its rim. True when the wheel changed.
    @discardableResult
    func drop(slot: String, from source: DragSource?, at point: CGPoint) -> Bool {
        let before = editor
        switch dropOutcome(slot: slot, from: source, at: point) {
        case .insert(let index): add(slot, at: index)
        case .replace(let index): replace(at: index, with: slot)
        case .move(let from, let to): move(from: from, to: to)
        case .remove(let index): remove(at: index)
        case .nothing: break
        }
        return editor != before
    }

    /// A drop on page `page`'s tab: a slice moves to the end of that page, a chip joins it there.
    @discardableResult
    func dropOnTab(slot: String, from source: DragSource?, page: Int) -> Bool {
        let before = editor
        switch source {
        case .slice(let from, let index):
            if isSlice(slot, page: from, index: index) { move(at: index, toPage: page) }
        case .chip, nil:
            edit("Add") { $0.add(slot, page: page, at: .max) }
        }
        return editor != before
    }

    /// Whether a drop on page `page`'s tab can do anything: a slice from another page, or a chip not on that page. A
    /// full page still takes it, so the drop says why.
    func acceptsTabDrop(slot: String, from source: DragSource?, page: Int) -> Bool {
        guard !isFormatFollowingKind, pages.indices.contains(page) else { return false }
        switch source {
        case .slice(let from, let index): return from != page && isSlice(slot, page: from, index: index)
        case .chip, nil: return !pages[page].slices.contains { $0.id == slot }
        }
    }

    /// A slice dropped off the wheel is removed; a chip dropped there was never placed. True when it was removed.
    @discardableResult
    func dropOutside(slot: String, from source: DragSource) -> Bool {
        guard case .slice(let page, let index) = source, isSlice(slot, page: page, index: index) else { return false }
        let before = editor
        remove(at: index)
        return editor != before
    }

    /// The drag's slice is still where it was picked up: an edit (undo, a new plan) can change the page under it.
    private func isSlice(_ slot: String, page: Int, index: Int) -> Bool {
        page == pageIndex && editor.wheel.pages.indices.contains(page)
            && editor.wheel.pages[page].slots.indices.contains(index) && editor.wheel.pages[page].slots[index] == slot
    }

    // MARK: - Private

    /// The kind's wheel as it opens today: the user's, else the built-in one. Never without a page to fill.
    private func kindWheel(_ category: FormatCategory) -> CustomWheel {
        let wheel = store.settings.wheels[WheelKey.kind(category).rawValue] ?? builder.builtInLayout(for: category)
        return wheel.pages.isEmpty ? CustomWheel(pages: [CustomPage(name: "Page 1", slots: [])]) : wheel
    }

    private func reload() {
        isStale = false
        editor = WheelEditor(key: selection, settings: store.settings, fallback: kindWheel(kind))
        customized = Set(store.settings.wheels.keys.compactMap(WheelKey.init(rawValue:)))
        candidates = builder.candidates(for: selection)
        redraw()
    }

    private func redraw() {
        pages = builder.editorPages(for: editor.wheel)
        pageIndex = min(pageIndex, max(pages.count - 1, 0))
    }

    /// Applies `change` and saves it, then shows the page `showing` picks from the one shown before. A wheel left
    /// without a slot is never saved: a customized wheel keeps at least one (P176).
    private func edit(_ name: String, showing newPage: (Int) -> Int = { $0 },
                      _ change: (inout WheelEditor) -> WheelEditor.Refusal?) {
        guard !isFormatFollowingKind else { return }
        var edited = editor
        if let refusal = change(&edited) {
            show(refusal.message(for: selection))
            return
        }
        guard edited != editor, edited.wheel.slotCount > 0 else { return }
        var before = stored(selection)
        editor = edited
        var settings = store.settings
        edited.save(into: &settings)
        store.settings = settings
        customized.insert(selection)
        clearMessage()
        redraw()
        pageIndex = min(max(newPage(before.page), 0), max(pages.count - 1, 0))
        before.pageAfter = pageIndex
        registerUndo(restoring: before, name)
    }

    private func write(_ name: String, _ change: (inout AppSettings) -> Void) {
        var before = stored(selection)
        var settings = store.settings
        change(&settings)
        store.settings = settings
        clearMessage()
        reload()
        before.pageAfter = pageIndex
        registerUndo(restoring: before, name)
    }

    /// What an edit of `key` can change in the settings, the page shown before it and the page it left shown.
    private struct Stored {
        var key: WheelKey
        var wheel: CustomWheel?
        var order: [String]?
        var visibility: [String: Bool]?
        var page: Int
        var pageAfter: Int
    }

    private func stored(_ key: WheelKey) -> Stored {
        let settings = store.settings
        var stored = Stored(key: key, wheel: settings.wheels[key.rawValue], page: pageIndex, pageAfter: pageIndex)
        if case .kind(let category) = key {
            stored.order = settings.wheelOrder[category.rawValue]
            stored.visibility = settings.toolVisibility[category.rawValue]
        }
        return stored
    }

    private func registerUndo(restoring snapshot: Stored, _ name: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot, name) }
        }
        undoManager?.setActionName(name)
    }

    /// Undo and redo: the manager registers what this registers as the opposite while it runs. The wheel it changes
    /// comes back on screen: undo on the page shown before the edit, redo on the one the edit showed.
    private func restore(_ snapshot: Stored, _ name: String) {
        if snapshot.key != selection { selection = snapshot.key }
        var current = stored(snapshot.key)
        current.page = snapshot.pageAfter
        current.pageAfter = snapshot.page
        var settings = store.settings
        settings.wheels[snapshot.key.rawValue] = snapshot.wheel
        if case .kind(let category) = snapshot.key {
            settings.wheelOrder[category.rawValue] = snapshot.order
            settings.toolVisibility[category.rawValue] = snapshot.visibility
        }
        store.settings = settings
        pageIndex = snapshot.page
        clearMessage()
        registerUndo(restoring: current, name)
        reload()
    }

    private func show(_ text: String) {
        message = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func clearMessage() {
        messageTask?.cancel()
        message = nil
    }
}
