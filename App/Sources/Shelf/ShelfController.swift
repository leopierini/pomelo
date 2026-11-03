// The Shelf (S3 to S17): owns its model and its one reusable panel, places it for each way in (S7), adds what is
// dropped on it (S11), lets it be dragged out (S12, S13), runs its list, keys and menu (S8, S17), tucks it into its tab
// and decides when it leaves (S9), and keeps its place across display changes (S10). Nothing here runs while the
// Shelf sits there (S26): bookmarks are made once after a drop and resolved only on interaction (S15), thumbnails
// once the panel is up, display changes arrive as a notification, and the only timers are the 0.35 s check after a
// shake's drag ends and the tab's spring-open while a drag hovers it.
import AppKit
import Combine
import PomeloCore
import PomeloUIModel
import QuickLookUI

/// How the Shelf meets the real desktop. Tests use `.offScreen`, so a test run never covers the apps of whoever
/// runs it, takes their key focus or sees their real mouse.
struct ShelfDesktop {
    /// The displays the drawer is kept on; nil for `NSScreen.screens`.
    var screens: (@MainActor () -> [ShelfScreen])?
    /// Where the pointer is; nil for `NSEvent.mouseLocation`.
    var pointer: (@MainActor () -> CGPoint)?
    var watchesMouse = true
    /// Whether a click may make the panel key.
    var takesKey = true
    /// Whether the panel is key; nil for the panel's own answer. Tests stand in for a key Shelf without taking focus.
    var isKey: (@MainActor () -> Bool)?
    /// The appear fade and scale, and the tuck's slide or fade (S9, S23); off where nothing would see them.
    var animates = true
    /// Whether another Pomelo window (Settings, an editor) is key; nil for AppKit's answer. Quick Look's hand-back
    /// waits on it (M8).
    var anotherWindowIsKey: (@MainActor () -> Bool)?
    /// Hears each time the panel is brought to the front: an off-screen panel's order can't be seen (S6).
    var raised: (@MainActor () -> Void)?
    /// Begins a drag out with these items; nil for AppKit's session. One begun on a made event would track the real
    /// mouse, so tests take the items instead.
    var beginsDrag: (@MainActor ([NSDraggingItem]) -> Void)?

    static let live = ShelfDesktop()
    /// Far outside every screen.
    static let farFrame = CGRect(x: -30_000, y: -30_000, width: 1_000, height: 1_000)
    static let offScreen: ShelfDesktop = {
        let far = farFrame
        return ShelfDesktop(screens: { [ShelfScreen(id: 0, frame: far, visibleFrame: far)] },
                            pointer: { CGPoint(x: far.midX, y: far.midY) }, watchesMouse: false, takesKey: false,
                            animates: false, anotherWindowIsKey: { false }, beginsDrag: { _ in })
    }()
}

/// A display (S10). Its ID tells it apart when its frames change, so the Shelf keeps its place on it.
struct ShelfScreen: Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var visibleFrame: CGRect

    @MainActor static var live: [ShelfScreen] {
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return ShelfScreen(id: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

/// Items an add found already on the Shelf, for the view to blink once (S11); a new serial is a new blink.
struct ShelfBlink: Equatable {
    var ids: Set<UUID>
    var serial: Int
}

@MainActor
final class ShelfController: ObservableObject {
    enum Summon: Equatable {
        /// A shake during a file drag, at the cursor.
        case shake(at: CGPoint)
        /// The Tools page's Shelf slice: its files, at the wheel's centre.
        case tools(files: [URL], at: CGPoint)
        /// Show Shelf in the menu bar.
        case menu
    }

    @Published private(set) var model = ShelfModel()
    @Published private(set) var presentation: ShelfPresentation = .empty {
        didSet {
            panel.itemsView.headerBand = Self.headerBand(for: presentation)
            panel.itemsView.isTab = isTucked
            panel.itemsView.movesOffTheStack = presentation == .collapsed
            updateDragHint()
        }
    }
    /// The side edge the tab sits on, or would if tucked now (S8): which way its count reads and the chevron points.
    @Published private(set) var tabSide: ShelfSide = .right
    @Published private(set) var isShown = false
    @Published private(set) var isDropTargeted = false
    @Published private(set) var isPointerInside = false
    @Published private(set) var blink: ShelfBlink?
    /// The items' thumbnails once drawn; the view shows the file's icon until then.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// Bumped each time the Shelf comes on screen, so the view plays its appear animation (S9) again.
    @Published private(set) var appearances = 0
    /// How far the expanded list is scrolled, in points.
    @Published private(set) var scrollOffset: CGFloat = 0
    /// ⌘ is down during a drag out of the Shelf, or while its panel is key: the key pill says Move (R30).
    @Published private(set) var commandHeld = false

    /// Open the Wheel: the files and the point to centre the click-mode wheel on (S17).
    var onOpenWheel: (([URL], CGPoint) -> Void)?

    /// Internal so the tests can check the window and drive its drop target.
    private(set) lazy var panel = makePanel()

    private let desktop: ShelfDesktop
    private let files: ShelfFiles
    private let announce: (String) -> Void
    /// The leave check runs on it; a parameter so tests step through it on a virtual clock.
    private let clock: TimerClock
    /// Copy's pasteboard, Show in Finder and Quick Look: parameters so tests never touch the real ones.
    private let pasteboard: NSPasteboard
    private let reveal: ([URL]) -> Void
    private let preview: ShelfPreviewing
    private let thumbnailCache = ShelfThumbnails()
    /// The file icon shown until a thumbnail is ready, made once per item rather than on every redraw.
    private var icons: [UUID: NSImage] = [:]

    /// An empty Shelf a shake brought: it leaves if the drag ends without a drop on it (S9).
    private var leavesIfStillEmpty = false
    private var pendingLeave: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// The items the drag out in progress carries, and their paths as the drag pasteboard holds them.
    private var draggedOut: Set<UUID> = []
    private var draggedOutPaths: Set<String> = []
    /// That drag was dropped on Pomelo's own wheel or editor: a conversion, so its items stay (S13).
    private var dragOutLanded = false
    /// The wheel on screen opened on a drag out of the Shelf or from Open the Wheel: its jobs report to the Shelf
    /// (S37). Every wheel open sets it.
    private var wheelFromShelf = false
    /// The row under the mouse-down, for a drag that starts from it (S12).
    private var pressedRow: UUID?
    /// Where the drawer last was, for the menu (S7: its place is kept for the session).
    private var lastFrame: CGRect?
    private var blinks = 0
    /// The drawer the tab came from (S9): where a click brings it back, and whether it was the list.
    private var tuckedFrom: (drawer: CGRect, expanded: Bool)?
    /// Opens the tab while a drag hovers it (S9); it exists only during that hover (S26).
    private var springOpen: Task<Void, Never>?
    /// The display the Shelf was last placed on, whose visible frame it keeps its place in (S10).
    private var placedScreen: ShelfScreen?
    /// Where a running slide ends (S9): the panel reports its in-between frames until then.
    private var slideTarget: CGRect?
    /// The last frame given at once, which a slide still running must not overwrite.
    private var placedFrame: CGRect?
    private var moves = 0
    private var screenChanges: AnyCancellable?

    static let thumbnailSide: CGFloat = 64
    /// How long a drag hovers the tab before it springs open (S9).
    static let springDelay: Duration = .milliseconds(300)

    init(desktop: ShelfDesktop = .live, files: ShelfFiles = .live, announce: @escaping (String) -> Void = { _ in },
         clock: TimerClock = .live, pasteboard: NSPasteboard = .general,
         reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
         preview: ShelfPreviewing? = nil) {
        self.desktop = desktop
        self.files = files
        self.announce = announce
        self.clock = clock
        self.pasteboard = pasteboard
        self.reveal = reveal
        self.preview = preview ?? ShelfPreview()
        // Posted when a display is added, removed, rearranged or resized: an event, never a poll.
        screenChanges = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }
    }

    /// Creates the panel and its SwiftUI graph ahead of the first summon, so a summon only places and shows it.
    func prepare() {
        panel.itemsView.layoutSubtreeIfNeeded()
    }

    var animates: Bool { desktop.animates }

    private var hasKeyFocus: Bool { desktop.isKey?() ?? panel.isKeyWindow }

    var isExpanded: Bool {
        if case .expanded = presentation { true } else { false }
    }

    var isTucked: Bool { presentation == .tucked }

    /// The key pill (R30): what ⌘ does to a drag out, nil where nothing can be dragged.
    var pill: ShelfPill? { ShelfPill(for: model, presentation: presentation, commandHeld: commandHeld) }

    /// Nothing scheduled: no leave check and no spring-open (S26). The idle measurement checks it.
    var isAtRest: Bool { pendingLeave == nil && springOpen == nil }

    /// The drawer (or the tab), without the room the panel keeps around it for the shadow.
    var drawerFrame: CGRect {
        (slideTarget ?? panel.frame).insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
    }

    // MARK: Summoning (S5, S7)

    func summon(_ summon: Summon) {
        switch summon {
        case .shake(let point):
            pendingLeave?.cancel()
            pendingLeave = nil
            // A Shelf already up from the menu or holding files stays whatever this drag does.
            leavesIfStillEmpty = model.isEmpty && (!isShown || leavesIfStillEmpty)
            place(centredOn: point, keepingInside: point)
        case .tools(let urls, let point):
            add(urls)
            place(centredOn: point, keepingInside: nil)
        case .menu:
            leavesIfStillEmpty = false
            pendingLeave?.cancel()
            pendingLeave = nil
            if isTucked { return untuck() }
            guard !isShown else { return raise() }
            let frame = ShelfLayout.menuFrame(size: ShelfLayout.size(presentation), last: lastFrame,
                                              visibleFrames: allScreens().map(\.visibleFrame),
                                              pointerScreen: visibleFrame(at: pointer))
            show(drawer: frame)
        }
    }

    /// The mouse button of a drag went up. An empty Shelf that drag's shake brought leaves after the wheel's close
    /// delay unless files land on it meanwhile: the drop and the button-up poll arrive in either order.
    func dragEnded() {
        guard isShown, leavesIfStillEmpty else { return }
        pendingLeave?.cancel()
        pendingLeave = Task { [weak self, clock] in
            try? await clock.sleep(WheelController.closeDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingLeave = nil
            if self.leavesIfStillEmpty && self.model.isEmpty { self.close() }
        }
    }

    // MARK: Adding (S11)

    /// Adds `urls` in order; a file already on the Shelf blinks instead. Bookmarks are made off the main thread.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        leavesIfStillEmpty = false
        pendingLeave?.cancel()
        pendingLeave = nil
        let (added, existing) = model.add(urls.map(files.item))
        if !existing.isEmpty {
            blinks += 1
            blink = ShelfBlink(ids: Set(existing), serial: blinks)
        }
        guard !added.isEmpty else { return }
        let newItems = model.items.filter { added.contains($0.id) }
        announce(ShelfCopy.added(newItems.map(\.name)))
        refreshPresentation()
        makeBookmarks(for: newItems)
        loadThumbnails()
    }

    private func makeBookmarks(for items: [ShelfItem]) {
        let files = files
        let targets = items.map { ($0.id, $0.identity, $0.url) }
        Task.detached(priority: .utility) { [weak self] in
            let made = targets.compactMap { id, identity, url in files.bookmark(url).map { (id, identity, $0) } }
            await self?.setBookmarks(made)
        }
    }

    private func setBookmarks(_ made: [(UUID, String, Data)]) {
        for (id, identity, data) in made { model.setBookmark(data, for: id, identity: identity) }
    }

    // MARK: Dragging out (S12, S13)

    /// Starts a drag out: the items it carries are resolved first (S15), so a renamed file leaves under its new URL
    /// and a trashed or lost one is left out. Synchronous, as AppKit wants the items now; the bookmarks resolve
    /// without UI or mounting, so an unmounted share fails fast.
    private func beginDragOut() -> [(url: URL, image: NSImage)] {
        let pressed = pressedRow
        pressedRow = nil
        // The tab is clicked, or hovered by a drag; nothing is dragged out of it.
        guard !isTucked else { return [] }
        let candidates: Set<UUID> = if !isExpanded {
            Set(model.items.map(\.id))
        } else if let pressed, !model.selection.contains(pressed) {
            [pressed]
        } else {
            model.selection
        }
        resolveNow(model.items.filter { candidates.contains($0.id) })
        let items = model.dragOut(pressed: pressed, expanded: isExpanded)
        draggedOut = Set(items.map(\.id))
        draggedOutPaths = Set(items.map { Self.path($0.url) })
        dragOutLanded = false
        return items.map { ($0.url, thumbnails[$0.id] ?? icon(for: $0)) }
    }

    /// Whether `files` are what the drag out in progress carries: the wheel it opens is the Shelf's.
    func isDraggingOut(_ files: [URL]) -> Bool {
        !draggedOutPaths.isEmpty && Set(files.map(Self.path)) == draggedOutPaths
    }

    /// The drag out in progress was dropped on Pomelo's wheel or editor, which answer `.copy` like any destination.
    func dragOutLandedInPomelo() {
        guard !draggedOut.isEmpty else { return }
        dragOutLanded = true
    }

    /// The drag monitor's wheel opened, the Shelf's when on a drag out of it: a drop on it is a conversion, so the
    /// Shelf keeps the files although the drop answers `.copy` (S13), and its results come back here (S18).
    func wheelOpened(on files: [URL]) {
        wheelFromShelf = isDraggingOut(files)
    }

    /// A wheel `ClickModeController` opens (on Finder's selection, opened files or the service) is never the
    /// Shelf's, whatever wheel was open before it (S37); the Shelf's own Open the Wheel sets it in `openWheel`.
    func clickModeWheelOpened() {
        wheelFromShelf = false
    }

    /// What the jobs and the editor of the wheel on screen report each finished file to: the Shelf while that wheel
    /// is its own (S37), else nothing.
    var wheelResults: (@MainActor (FileResult) -> Void)? {
        guard wheelFromShelf else { return nil }
        return { [weak self] in self?.takeResult($0) }
    }

    /// A drop on the wheel's slice, called while the drop is performed, before the drag's source hears how it ended.
    func wheelChose() {
        if wheelFromShelf { dragOutLandedInPomelo() }
    }

    /// A drop on the wheel's Shelf slice (S31): a landing in Pomelo like any other slice, then the files are added
    /// again so the Shelf stays where the wheel was.
    func wheelChoseShelfSlice(_ files: [URL], at center: CGPoint) {
        wheelChose()
        summon(.tools(files: files, at: center))
    }

    /// Delivered items leave (S13), the Shelf with them once empty (S9); a cancelled or refused drag (`[]`), a drop
    /// back on the Shelf (which refuses its own drags) or one on Pomelo keeps them.
    func dragOutEnded(operation: NSDragOperation) {
        commandChanged(held: false)
        let ids = draggedOut
        let landed = dragOutLanded
        draggedOut = []
        draggedOutPaths = []
        dragOutLanded = false
        guard !operation.isEmpty, !landed else { return }
        forget(ids)
    }

    /// The items leave (S13, S14): only their references, their thumbnails and icons go; no file is touched.
    private func forget(_ ids: Set<UUID>) {
        let leaving = Set(model.items.lazy.map(\.id).filter(ids.contains))
        guard !leaving.isEmpty else { return }
        model.remove(leaving)
        thumbnails = thumbnails.filter { !leaving.contains($0.key) }
        icons = icons.filter { !leaving.contains($0.key) }
        Task { [thumbnailCache] in await thumbnailCache.forget(leaving) }
        announce(ShelfCopy.left(leaving.count))
        refreshPresentation()
        if model.isEmpty { close() } else { loadThumbnails() }
    }

    /// ⌘ as the drag out's mask request or the key panel's `flagsChanged` reports it (R30): never a key monitor.
    func commandChanged(held: Bool) {
        if commandHeld != held { commandHeld = held }
    }

    private static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Results (S18)

    /// A file a job from the Shelf's wheel finished: a success puts its outputs in its source's place; a failure, a
    /// skip, a cancel or a source no longer on the Shelf changes nothing. Nothing on disk is touched.
    func takeResult(_ result: FileResult) {
        guard case .succeeded(let source, let made, let note) = result, let item = shelved(source) else { return }
        // In the item's own spelling (the job may say `/private/var` for `/var`), so the model sees one path.
        let outputs = made.map { Self.samePlace($0, item.url) ? item.url : $0 }
        let before = model.items
        let announcement = model.apply(.succeeded(source: item.url, outputs: outputs, note: note), makeItem: files.item)
        guard model.items != before else { return }
        if let announcement { announce(announcement) }
        let now = Set(model.items.map(\.id))
        var stale = Set(before.map(\.id)).subtracting(now)
        // Replaced in place (replace original): the same item, a new file, so its picture is redrawn.
        if now.contains(item.id) { stale.insert(item.id) }
        thumbnails = thumbnails.filter { !stale.contains($0.key) }
        icons = icons.filter { !stale.contains($0.key) }
        Task { [thumbnailCache] in await thumbnailCache.forget(stale) }
        makeBookmarks(for: model.items.filter { $0.bookmark == nil && outputs.contains($0.url) })
        refreshPresentation()
        loadThumbnails()
    }

    /// The item `url` names, by path, else by its canonical path: the drag pasteboard and the runner may spell a
    /// shelved file's folder another way.
    private func shelved(_ url: URL) -> ShelfItem? {
        let path = Self.path(url)
        if let item = model.items.first(where: { Self.path($0.url) == path }) { return item }
        let canonical = ShelfFiles.canonicalPath(of: url)
        return model.items.first { ShelfFiles.canonicalPath(of: $0.url) == canonical }
    }

    private static func samePlace(_ a: URL, _ b: URL) -> Bool {
        path(a) == path(b) || ShelfFiles.canonicalPath(of: a) == ShelfFiles.canonicalPath(of: b)
    }

    // MARK: Originals that moved (S15)

    /// Where the items are now, resolved off the main thread: a renamed or moved file is followed, one in the Trash
    /// or gone is greyed. Only on interaction, never on a timer (S26).
    func resolve(_ ids: [UUID]) async {
        let wanted = Set(ids)
        let targets = model.items.filter { wanted.contains($0.id) }
        guard !targets.isEmpty else { return }
        let files = files
        let resolved = await Task.detached(priority: .userInitiated) { Self.resolutions(of: targets, files: files) }
            .value
        apply(resolved)
    }

    /// Synchronous, for what AppKit or the person wants now (a drag, Copy, the wheel); without UI or mounting, so an
    /// unmounted share fails fast.
    private func resolveNow(_ items: [ShelfItem]) {
        apply(Self.resolutions(of: items, files: files))
    }

    /// `from` is the item as the resolve found it: a newer resolve or result may have changed it meanwhile.
    private typealias Resolution = (id: UUID, from: ShelfItem, url: URL, name: String, state: ShelfItemState)

    private nonisolated static func resolutions(of items: [ShelfItem], files: ShelfFiles) -> [Resolution] {
        items.map { item in
            let found = files.resolve(item)
            return (item.id, item, found.url, found.name, found.state)
        }
    }

    /// Publishes only a change, so a hover over an unchanged Shelf redraws nothing. An answer for an item that changed
    /// in any way since its resolve started is older than what the Shelf shows, and is dropped.
    private func apply(_ resolved: [Resolution]) {
        var next = model
        for found in resolved {
            guard let current = model.items.first(where: { $0.id == found.id }), current == found.from else { continue }
            if current.url != found.url { icons[found.id] = nil }
            next.update(found.id, url: found.url, name: found.name, state: found.state)
        }
        guard next != model else { return }
        model = next
        updateDragHint()
        loadThumbnails()
    }

    // MARK: The list (S8, S12, S17)

    /// Widens the drawer into the list, resolving every item on the way (S15).
    func expand() {
        guard !model.isEmpty, !isExpanded, !isTucked else { return }
        setPresentation(.expanded(rows: model.items.count))
        let ids = model.items.map(\.id)
        Task { [weak self] in await self?.resolve(ids) }
        loadThumbnails()
    }

    func collapse() {
        guard isExpanded else { return }
        setPresentation(.collapsed)
        loadThumbnails()
    }

    /// The Organize pages editor's rules (S12): ⌘ toggles, ⇧ extends, else the row alone.
    func select(_ id: UUID, modifiers: ModifierSet = []) {
        if modifiers.contains(.command) {
            model.commandClick(id)
        } else if modifiers.contains(.shift) {
            model.shiftClick(id)
        } else {
            model.click(id)
        }
        selectionChanged()
    }

    /// A mouse-down at `point`, from the drawer's top-left corner, y down.
    func pressed(at point: CGPoint) {
        pressedRow = row(at: point)
    }

    /// A click that started no drag: on the tab it brings the drawer back, on the stack it opens the list, on a row
    /// it selects.
    func clicked(at point: CGPoint, modifiers: ModifierSet) {
        pressedRow = nil
        if isTucked { return untuck() }
        guard isExpanded else { return expand() }
        if let id = row(at: point) { select(id, modifiers: modifiers) }
    }

    func scrolled(by delta: CGFloat) {
        guard isExpanded else { return }
        let next = min(max(scrollOffset - delta, 0), ShelfLayout.maxScrollOffset(count: model.items.count))
        guard next != scrollOffset else { return }
        scrollOffset = next
        loadThumbnails()
    }

    private func row(at point: CGPoint) -> UUID? {
        guard isExpanded,
              let index = ShelfLayout.row(atDepth: point.y, scrollOffset: scrollOffset, count: model.items.count)
        else { return nil }
        return model.items[index].id
    }

    /// Keeps the focused row in view and a showing preview on the selection.
    private func selectionChanged() {
        if let focus = model.focused, let index = model.items.firstIndex(where: { $0.id == focus }) {
            let next = ShelfLayout.scrollOffset(revealing: index, from: scrollOffset, count: model.items.count)
            if next != scrollOffset {
                scrollOffset = next
                loadThumbnails()
            }
        }
        if preview.isShown { quickLook() }
    }

    // MARK: Keys (S17)

    /// A key that went down while the Shelf is key; false lets AppKit beep.
    @discardableResult
    func handle(_ key: ShelfKey) -> Bool {
        switch key {
        case .up, .down, .extendUp, .extendDown:
            guard !model.isEmpty, !isTucked else { return false }
            expand()
            model.moveSelection(by: key == .up || key == .extendUp ? -1 : 1,
                                extending: key == .extendUp || key == .extendDown)
            selectionChanged()
        case .selectAll:
            model.selectAll()
            selectionChanged()
        case .quickLook:
            if preview.isShown { preview.hide() } else { quickLook() }
        case .openWheel: openWheel()
        case .remove: removeSelection()
        case .copy: copySelection()
        case .escape: escape()
        }
        return true
    }

    /// Quick Look closes first, then the list collapses, then an empty Shelf closes and one with files gives the
    /// keys back to the app in front.
    private func escape() {
        if preview.isShown {
            preview.hide()
        } else if isExpanded {
            collapse()
        } else if model.isEmpty {
            close()
        } else if handBackActivation() {
            // Pomelo went active for the preview: the app before it gets the keys back, and the Shelf stops being key.
        } else if hasKeyFocus {
            // There is no call that makes a window resign key: ordered out and back in, the panel loses it.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// ⌥⌘K while the Shelf is key opens the wheel on its selection instead of reading Finder's (S17).
    func takesClickModeHotkey() -> Bool {
        guard isShown, hasKeyFocus else { return false }
        return openWheel()
    }

    // MARK: Actions (S14, S17, S22)

    /// What an action acts on: the selection while the list shows one, else every item.
    private var targets: [ShelfItem] {
        guard isExpanded, !model.selection.isEmpty else { return model.items }
        return model.items.filter { model.selection.contains($0.id) }
    }

    /// The targets found where they are now (S15): a trashed or lost one is left out.
    private func presentTargets() -> [URL] {
        let wanted = targets
        resolveNow(wanted)
        let ids = Set(wanted.map(\.id))
        return model.items.filter { ids.contains($0.id) && $0.state == .present }.map(\.url)
    }

    /// Runs `action` from the context menu or VoiceOver; on a row not in the selection, that row becomes it, as a
    /// right-click selects in Finder.
    func perform(_ action: ShelfAction, onRow row: UUID? = nil) {
        if let row, !model.selection.contains(row) { select(row) }
        switch action {
        case .openWheel: openWheel()
        case .quickLook: quickLook()
        case .showInFinder: revealSelection()
        case .copy: copySelection()
        case .remove: removeSelection()
        case .expand: expand()
        case .tuckAway: tuck()
        case .bringBack: untuck()
        case .clear: clear()
        }
    }

    private func canPerform(_ action: ShelfAction) -> Bool {
        switch action {
        case .openWheel, .quickLook, .showInFinder, .copy: targets.contains { $0.state == .present }
        case .remove: isExpanded && !model.selection.isEmpty
        case .tuckAway: !isTucked
        case .bringBack: isTucked
        case .expand, .clear: true
        }
    }

    /// The context menu at `point` (S17), from the drawer's top-left corner; none on an empty Shelf.
    func contextMenu(at point: CGPoint) -> NSMenu? {
        guard !model.isEmpty else { return nil }
        let row = row(at: point)
        if let row, !model.selection.contains(row) { select(row) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, group) in ShelfAction.menu(onRow: row != nil, tucked: isTucked).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group {
                let item = ShelfMenuItem(action.title) { [weak self] in self?.perform(action) }
                item.isEnabled = canPerform(action)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Writes the file URLs to the pasteboard, as Copy Files does; missing items are left out.
    func copySelection() {
        let urls = presentTargets()
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    func revealSelection() {
        let urls = presentTargets()
        guard !urls.isEmpty else { return }
        reveal(urls)
    }

    func quickLook() {
        let urls = presentTargets()
        guard !urls.isEmpty else { return }
        preview.show(urls)
    }

    /// Forgets the selected rows (S14); only the list has a selection to remove.
    func removeSelection() {
        guard isExpanded else { return }
        forget(model.selection)
    }

    /// The click-mode wheel on the present targets, beside the drawer (S17).
    /// True when a wheel opened: nothing opens when every target is missing.
    @discardableResult
    func openWheel() -> Bool {
        let urls = presentTargets()
        guard !urls.isEmpty, let onOpenWheel else { return false }
        wheelFromShelf = true
        let drawer = drawerFrame
        let screen = visibleFrame(at: CGPoint(x: drawer.midX, y: drawer.midY))
        onOpenWheel(urls, ShelfLayout.wheelCentre(beside: drawer, wheelSize: WheelPanel.size, visibleFrame: screen))
        return true
    }

    // MARK: Leaving (S9, S14)

    /// Forgets every reference and leaves: no file is touched (S14).
    func clear() {
        let ids = Set(model.items.map(\.id))
        model.clear()
        thumbnails = [:]
        icons = [:]
        Task { [thumbnailCache] in await thumbnailCache.forget(ids) }
        refreshPresentation()
        close()
    }

    /// Hides the Shelf, keeping what it holds for Show Shelf; a tab closes as the drawer it came from.
    func close() {
        let tuckedDrawer = tuckedFrom?.drawer
        leaveTab()
        pendingLeave?.cancel()
        pendingLeave = nil
        leavesIfStillEmpty = false
        thumbnailTask?.cancel()
        thumbnailTask = nil
        isDropTargeted = false
        isPointerInside = false
        commandChanged(held: false)
        pressedRow = nil
        preview.hide()
        _ = handBackActivation()
        guard isShown else { return }
        lastFrame = tuckedDrawer ?? drawerFrame
        panel.orderOut(nil)
        isShown = false
    }

    /// The app before Quick Look gets the keys back only while they are the Shelf's or the preview's, or nobody's:
    /// someone who moved on to Settings or an editor stays there (M8).
    private func handBackActivation() -> Bool {
        let elsewhere = desktop.anotherWindowIsKey?() ?? NSApp.keyWindow.map { $0 !== panel && !($0 is QLPreviewPanel) }
            ?? false
        guard !elsewhere else {
            preview.forgetActivation()
            return false
        }
        return preview.handBackActivation()
    }

    // MARK: The drop target's events

    /// A drag that hovers the tab for 0.3 s springs it open under the pointer, so it can drop on the drawer; a drop
    /// on the tab first adds without opening, and a drag that leaves cancels it (S9).
    func dropHoverChanged(_ hovering: Bool) {
        if isDropTargeted != hovering { isDropTargeted = hovering }
        guard hovering, isTucked else { return cancelSpringOpen() }
        guard springOpen == nil else { return }
        springOpen = Task { [weak self, clock] in
            try? await clock.sleep(Self.springDelay)
            guard !Task.isCancelled, let self else { return }
            self.springOpen = nil
            self.untuck(keepingInside: self.pointer)
        }
    }

    private func cancelSpringOpen() {
        springOpen?.cancel()
        springOpen = nil
    }

    func pointerInsideChanged(_ inside: Bool) {
        if isPointerInside != inside { isPointerInside = inside }
        guard inside, !model.isEmpty else { return }
        let ids = model.items.map(\.id)
        Task { [weak self] in await self?.resolve(ids) }
    }

    // MARK: Tucking (S9)

    /// Slides the drawer into its tab on the nearest side edge of its display; nothing tucks on its own.
    func tuck() {
        guard isShown, !model.isEmpty, !isTucked else { return }
        let drawer = drawerFrame
        let tab = ShelfLayout.tab(for: drawer, visibleFrame: visibleFrame(at: CGPoint(x: drawer.midX, y: drawer.midY)))
        tuckedFrom = (drawer, isExpanded)
        pressedRow = nil
        isPointerInside = false
        presentation = .tucked
        movePanel(to: tab.frame, animated: true)
    }

    /// Brings the drawer back from its tab where it was (a click, Bring Back, Show Shelf).
    func untuck() {
        untuck(keepingInside: nil)
    }

    /// A spring-open comes back holding `cursor`, so the drag in progress drops on the drawer.
    private func untuck(keepingInside cursor: CGPoint?) {
        guard let from = tuckedFrom else { return }
        leaveTab()
        let size = ShelfLayout.size(presentation)
        let drawer = if let cursor {
            ShelfLayout.frame(centredOn: CGPoint(x: from.drawer.midX, y: from.drawer.midY), size: size,
                              visibleFrame: visibleFrame(at: cursor), keepingInside: cursor)
        } else {
            ShelfLayout.menuFrame(size: size, last: from.drawer, visibleFrames: allScreens().map(\.visibleFrame),
                                  pointerScreen: visibleFrame(at: pointer))
        }
        movePanel(to: drawer, animated: true)
    }

    /// The tab becomes the drawer it came from again; the caller places it.
    private func leaveTab() {
        guard let from = tuckedFrom else { return }
        tuckedFrom = nil
        cancelSpringOpen()
        presentation = model.isEmpty ? .empty : from.expanded ? .expanded(rows: model.items.count) : .collapsed
        scrollOffset = min(scrollOffset, ShelfLayout.maxScrollOffset(count: model.items.count))
        loadThumbnails()
    }

    // MARK: Moving (S7) and displays (S10)

    /// The header, or the collapsed drawer off its stack (R29), was dragged and let go: the drawer stays there, pulled
    /// into the visible frame holding its centre (else the nearest one).
    func headerDragEnded() {
        guard isShown, !isTucked else { return }
        // Where the person let go, not where a slide still running would end.
        let released = panel.frame.insetBy(dx: ShelfPanel.inset, dy: ShelfPanel.inset)
        movePanel(to: ShelfLayout.settled(released, visibleFrames: allScreens().map(\.visibleFrame)))
    }

    /// After a display change the Shelf keeps its place relative to its display's visible frame, or takes the same
    /// place on the pointer's display when its own is gone (S10).
    func screensChanged() {
        guard isShown, let old = placedScreen else { return }
        let screens = allScreens()
        guard let now = screens.first(where: { $0.id == old.id }) ?? screen(at: pointer, in: screens), now != old
        else { return }
        if let from = tuckedFrom {
            let drawer = ShelfLayout.replaced(from.drawer, from: old.visibleFrame, to: now.visibleFrame)
            tuckedFrom = (drawer, from.expanded)
            movePanel(to: ShelfLayout.tab(for: drawer, visibleFrame: now.visibleFrame).frame)
        } else {
            movePanel(to: ShelfLayout.replaced(drawerFrame, from: old.visibleFrame, to: now.visibleFrame))
        }
        placedScreen = now
    }

    // MARK: Placement

    private func place(centredOn point: CGPoint, keepingInside cursor: CGPoint?) {
        leaveTab()
        let drawer = ShelfLayout.frame(centredOn: point, size: ShelfLayout.size(presentation),
                                       visibleFrame: visibleFrame(at: point), keepingInside: cursor)
        show(drawer: drawer)
    }

    /// A Shelf already up comes to the front where it is (S6): an editor shares its level and may cover it.
    private func show(drawer: CGRect) {
        movePanel(to: drawer)
        raise()
        guard !isShown else { return }
        appearances += 1
        isShown = true
        loadThumbnails()
    }

    /// Never makes the panel key.
    private func raise() {
        panel.orderFrontRegardless()
        desktop.raised?()
    }

    /// Empty, collapsed or the list, by the model; a tab stays a tab until it is brought back or closed (S9).
    private func refreshPresentation() {
        updateDragHint()
        guard !isTucked else { return }
        let next: ShelfPresentation = if model.isEmpty {
            .empty
        } else if isExpanded {
            .expanded(rows: model.items.count)
        } else {
            .collapsed
        }
        setPresentation(next)
        scrollOffset = min(scrollOffset, ShelfLayout.maxScrollOffset(count: model.items.count))
    }

    /// A size change keeps the drawer's top-left corner (S8).
    private func setPresentation(_ next: ShelfPresentation) {
        guard next != presentation else { return }
        let oldSize = ShelfLayout.size(presentation)
        presentation = next
        let size = ShelfLayout.size(next)
        guard isShown, size != oldSize else { return }
        let drawer = drawerFrame
        show(drawer: ShelfLayout.resized(drawer, to: size,
                                         visibleFrame: visibleFrame(at: CGPoint(x: drawer.midX, y: drawer.midY))))
    }

    /// The tool tip is AppKit's, since the mouse lands in the items view (S12); with nothing that can be dragged
    /// there is nothing to say.
    private func updateDragHint() {
        panel.itemsView.toolTip = !isTucked && model.items.contains { $0.state == .present } ? ShelfCopy.dragHint : nil
    }

    /// The drawer's top band whose mouse-downs stay SwiftUI's: the header that moves it (S7) and holds its buttons.
    private static func headerBand(for presentation: ShelfPresentation) -> CGFloat {
        switch presentation {
        case .empty: ShelfView.emptyHeaderHeight
        case .expanded: ShelfLayout.headerHeight
        case .collapsed, .tucked: 0
        }
    }

    /// Gives the panel the frame around `drawer`. Tucking and bringing back slide, or fade under Reduce Motion (S23);
    /// everything else moves at once.
    private func movePanel(to drawer: CGRect, animated: Bool = false) {
        let frame = drawer.insetBy(dx: -ShelfPanel.inset, dy: -ShelfPanel.inset)
        let screens = allScreens()
        placedScreen = screen(at: CGPoint(x: drawer.midX, y: drawer.midY), in: screens)
        // A tab sits on the side of the drawer it came from.
        let reference = tuckedFrom?.drawer ?? drawer
        if let screen = screen(at: CGPoint(x: reference.midX, y: reference.midY), in: screens) {
            let side = ShelfLayout.tab(for: reference, visibleFrame: screen.visibleFrame).side
            if side != tabSide { tabSide = side }
        }
        moves += 1
        guard animated, desktop.animates, isShown else {
            slideTarget = nil
            placedFrame = frame
            panel.setFrame(frame, display: isShown)
            return
        }
        slideTarget = frame
        let move = moves
        let motion = ShelfMotion(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if !motion.slides {
            panel.alphaValue = 0
            panel.setFrame(frame, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.duration
            if motion.slides { panel.animator().setFrame(frame, display: true) } else { panel.animator().alphaValue = 1 }
        } completionHandler: { [weak self] in
            // AppKit calls it on the main thread.
            MainActor.assumeIsolated { self?.slideEnded(move) }
        }
    }

    /// A move made at once while the slide ran must keep the last word over the slide's final frame.
    private func slideEnded(_ move: Int) {
        if move == moves {
            slideTarget = nil
        } else if slideTarget == nil, let placedFrame, panel.frame != placedFrame {
            panel.setFrame(placedFrame, display: isShown)
        }
    }

    private var pointer: CGPoint { desktop.pointer?() ?? NSEvent.mouseLocation }

    private func allScreens() -> [ShelfScreen] {
        desktop.screens?() ?? ShelfScreen.live
    }

    /// The display under `point`, else the first one.
    private func screen(at point: CGPoint, in screens: [ShelfScreen]? = nil) -> ShelfScreen? {
        let screens = screens ?? allScreens()
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? screens.first
    }

    /// With no display at all (none attached, or a desktop that lists none) the Shelf goes far off-screen, never onto
    /// whatever sits at the origin.
    private func visibleFrame(at point: CGPoint) -> CGRect {
        screen(at: point)?.visibleFrame ?? ShelfDesktop.farFrame
    }

    // MARK: Thumbnails (S26)

    /// The stack's three or the visible rows, after the panel is up, never before it: a summon never waits for Quick
    /// Look.
    private func loadThumbnails() {
        let present = Set(model.items.map(\.id))
        let kept = thumbnails.filter { present.contains($0.key) }
        if kept.count != thumbnails.count { thumbnails = kept }
        let shown = isExpanded
            ? model.items[ShelfLayout.visibleRows(scrollOffset: scrollOffset, count: model.items.count)]
                .filter { $0.state == .present }
            : model.stack
        let wanted = shown.filter { thumbnails[$0.id] == nil }
        guard isShown, !isTucked, !wanted.isEmpty else { return }
        thumbnailTask?.cancel()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnailTask = Task { [weak self, thumbnailCache] in
            for item in wanted {
                let image = await thumbnailCache.image(for: item.id, url: item.url, side: Self.thumbnailSide,
                                                       scale: scale)
                guard !Task.isCancelled, let self else { return }
                if let image, self.model.items.contains(where: { $0.id == item.id }) {
                    self.thumbnails[item.id] = NSImage(cgImage: image, size: .zero)
                }
            }
        }
    }

    #if DEBUG
    /// For the snapshot: waits until the thumbnails being drawn are in.
    func thumbnailsLoaded() async {
        await thumbnailTask?.value
    }
    #endif

    /// The file's icon until its thumbnail is ready.
    func icon(for item: ShelfItem) -> NSImage {
        if let icon = icons[item.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = icon
        return icon
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(controller: self)
        panel.allowsKey = desktop.takesKey
        panel.itemsView.headerBand = Self.headerBand(for: presentation)
        if let live = preview as? ShelfPreview {
            live.window = panel
            panel.previewSource = live
        }
        panel.itemsView.onPress = { [weak self] point in self?.pressed(at: point) }
        panel.itemsView.onClick = { [weak self] point, modifiers in self?.clicked(at: point, modifiers: modifiers) }
        panel.itemsView.onScroll = { [weak self] delta in self?.scrolled(by: delta) }
        panel.itemsView.onKey = { [weak self] key in self?.handle(key) ?? false }
        panel.itemsView.onMenu = { [weak self] point in self?.contextMenu(at: point) }
        panel.itemsView.onDrop = { [weak self] urls in self?.add(urls) }
        panel.itemsView.onDropHover = { [weak self] hovering in self?.dropHoverChanged(hovering) }
        panel.itemsView.onPointerInside = { [weak self] inside in self?.pointerInsideChanged(inside) }
        panel.itemsView.onDragOut = { [weak self] in self?.beginDragOut() ?? [] }
        panel.itemsView.onDragOutEnded = { [weak self] operation in self?.dragOutEnded(operation: operation) }
        panel.itemsView.onCommandChanged = { [weak self] held in self?.commandChanged(held: held) }
        panel.itemsView.beginsDrag = desktop.beginsDrag
        panel.itemsView.pointer = { [weak self] in self?.pointer ?? NSEvent.mouseLocation }
        panel.itemsView.onMoveEnded = { [weak self] in self?.headerDragEnded() }
        return panel
    }
}
