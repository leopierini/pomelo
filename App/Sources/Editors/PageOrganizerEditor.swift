// The Organize pages editor (P27): the PDF's pages as a grid to reorder by dragging, turn and remove, with every
// change on the panel's undo stack. Pages are shown one after the other and drawn by `PageThumbnails` as they
// scroll into view. Dragging stays inside the panel (a gesture, never the system drag), so the drag pasteboard is
// untouched and the wheel can't open.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

// MARK: - Layout

/// Where each cell of the grid is, in the grid's own coordinates (padding included).
struct PageGridLayout: Equatable {
    static let columns = 4
    static let cell = CGSize(width: 128, height: 164)
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 8
    static let maxHeight: CGFloat = 420

    var count: Int

    var rows: Int { (count + Self.columns - 1) / Self.columns }
    var width: CGFloat {
        2 * Self.padding + CGFloat(Self.columns) * Self.cell.width + CGFloat(Self.columns - 1) * Self.spacing
    }
    var height: CGFloat {
        2 * Self.padding + CGFloat(max(rows, 1)) * Self.cell.height + CGFloat(max(rows, 1) - 1) * Self.spacing
    }
    static var columnPitch: CGFloat { cell.width + spacing }
    static var rowPitch: CGFloat { cell.height + spacing }

    func frame(ofPosition position: Int) -> CGRect {
        let (row, column) = (position / Self.columns, position % Self.columns)
        return CGRect(x: Self.padding + CGFloat(column) * Self.columnPitch,
                      y: Self.padding + CGFloat(row) * Self.rowPitch,
                      width: Self.cell.width, height: Self.cell.height)
    }

    /// The cell under `point`; in a gap, the cell before it (the first one in the leading padding); nil past the last
    /// page or outside.
    func position(at point: CGPoint) -> Int? {
        guard count > 0, point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return nil }
        let column = min(max(Int((point.x - Self.padding) / Self.columnPitch), 0), Self.columns - 1)
        let row = min(max(Int((point.y - Self.padding) / Self.rowPitch), 0), max(rows - 1, 0))
        let position = row * Self.columns + column
        return position < count ? position : nil
    }

    /// Where a page dropped at `point` goes: before the page whose half the point is in. `row` and `column` place
    /// the insertion bar, `column` running to `columns` for the end of a row.
    struct Insertion: Equatable {
        var index: Int
        var row: Int
        var column: Int
    }

    func insertion(at point: CGPoint) -> Insertion {
        let lastRow = max(rows - 1, 0)
        let row = min(max(Int(((point.y - Self.padding) / Self.rowPitch).rounded(.down)), 0), lastRow)
        // Each cell's left half is the gap before it, its right half the gap after.
        let column = min(max(Int(((point.x - Self.padding + Self.spacing / 2) / Self.columnPitch).rounded()), 0), Self.columns)
        let index = row * Self.columns + column
        guard index <= count else {
            let end = count % Self.columns
            return Insertion(index: count, row: lastRow, column: end == 0 ? Self.columns : end)
        }
        return Insertion(index: index, row: row, column: column)
    }

    func bar(for insertion: Insertion) -> CGRect {
        let x = Self.padding + CGFloat(insertion.column) * Self.columnPitch - Self.spacing / 2
        return CGRect(x: x - 1.5, y: Self.padding + CGFloat(insertion.row) * Self.rowPitch, width: 3,
                      height: Self.cell.height)
    }
}

// MARK: - Keys

enum PageAction: Equatable {
    case delete, rotateRight, rotateLeft, moveEarlier, moveLater, selectAll
    /// The arrow keys: by this many pages, going on from where the last key reached.
    case select(Int)
    case extend(Int)
}

/// The grid's keys, read while it has focus in the key panel (never through a key monitor).
enum PageKeys {
    static func action(for press: KeyPress) -> PageAction? {
        action(for: press.key, modifiers: press.modifiers)
    }

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> PageAction? {
        // Arrow keys also carry the numeric-pad and function flags, which mean nothing here.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        switch key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            let step = switch key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -PageGridLayout.columns
            default: PageGridLayout.columns
            }
            switch held {
            case []: return .select(step)
            case .shift: return .extend(step)
            case .command where abs(step) == 1: return step < 0 ? .moveEarlier : .moveLater
            default: return nil
            }
        // SwiftUI's `delete` is U+0008, but AppKit's Delete key types U+007F: both, and forward delete, remove.
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
            return held.isEmpty ? .delete : nil
        case KeyEquivalent("r"):
            return held == .command ? .rotateRight : nil
        case KeyEquivalent("l"):
            return held == .command ? .rotateLeft : nil
        case KeyEquivalent("a"):
            return held == .command ? .selectAll : nil
        default:
            return nil
        }
    }
}

// MARK: - Session

/// Pages lifted by a drag in the grid. It keeps the source pages, never positions: they are looked up again when
/// the pointer is released.
struct PageDrag: Equatable {
    var pages: [Int]
    var location: CGPoint
    var insertion: PageGridLayout.Insertion
}

@MainActor
final class PageOrganizerSession: EditorSession, ObservableObject {
    static let thumbnailSide: CGFloat = 264
    /// A pointer that moves less than this is a click.
    static let clickSlop: CGFloat = 4

    let title = "Organize Pages"
    let confirmTitle = "Save Edited Copy"
    let file: URL
    let thumbnails: PageThumbnails
    var onChange: (() -> Void)?
    var onChoicesChanged: (() -> Void)?
    /// The panel's, given by the view: every change to the pages is registered with it.
    var undoManager: UndoManager?

    /// nil until the pages are counted. Changing it tells the controller only when the footer's line would change.
    var model: PageOrganizerModel? {
        willSet { objectWillChange.send() }
        didSet {
            if oldValue?.spec != model?.spec { onChoicesChanged?() }
            if lastFooter.update(from: self) { onChange?() }
        }
    }

    @Published private(set) var drag: PageDrag?
    @Published private(set) var unreadable: String? {
        didSet { onChange?() }
    }


    private var lastFooter = EditorFooter()

    init(request: EditorRequest) {
        file = request.files[0]
        thumbnails = PageThumbnails(url: request.files[0])
        lastFooter = EditorFooter(of: self)
    }

    var blocker: String? {
        if let unreadable { return unreadable }
        guard let model else { return "Reading the file\u{2026}" }
        return model.blocker
    }

    var note: String? { model?.summary }

    func load() async {
        let count = (try? await EditorMedia.info(of: file))?.pageCount ?? 0
        // A locked PDF still reports its pages, but PDFKit can neither draw nor copy them.
        let locked = await thumbnails.isLocked()
        guard !Task.isCancelled else { return }
        guard count > 0, !locked else {
            unreadable = locked ? "It's password protected" : "The file may be damaged"
            return
        }
        model = PageOrganizerModel(pageCount: count)
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = model?.spec
        return options
    }

    func remember(into memory: inout EditorMemory) {}

    func makeContent() -> AnyView {
        AnyView(PageOrganizerView(session: self))
    }

    // MARK: Choices

    /// A key's action; false when there is nothing for it to act on, so the key goes on.
    @discardableResult
    func perform(_ action: PageAction) -> Bool {
        guard let model else { return false }
        switch action {
        case .selectAll:
            select { $0.selectAll() }
            return true
        case .select(let offset):
            select { $0.step(by: offset, extend: false) }
            return true
        case .extend(let offset):
            select { $0.step(by: offset, extend: true) }
            return true
        case .delete, .rotateRight, .rotateLeft, .moveEarlier, .moveLater:
            guard !model.selection.isEmpty else { return false }
            edit(Self.name(of: action)) { change in
                switch action {
                case .delete: change.deleteSelected()
                case .rotateRight: change.rotateSelected(clockwise: true)
                case .rotateLeft: change.rotateSelected(clockwise: false)
                case .moveEarlier: change.moveSelected(by: -1)
                default: change.moveSelected(by: 1)
                }
            }
            return true
        }
    }

    /// VoiceOver's action on one page: it is chosen alone first, so the action is about it.
    func act(on position: Int, _ action: PageAction) {
        guard let before = model, before.pages.indices.contains(position) else { return }
        let page = before.pages[position].page
        select { $0.click(position) }
        perform(action)
        guard let after = self.model else { return }
        let now = after.pages.firstIndex { $0.page == page }
        let text: String? = switch action {
        case .delete: "Page \(page + 1) removed"
        case .moveEarlier, .moveLater: now.map { "Page \(page + 1) is now at position \($0 + 1) of \(after.pages.count)" }
        default: now.map { after.label(at: $0) }
        }
        announce(text)
    }

    func click(_ position: Int, toggle: Bool = false, extend: Bool = false) {
        select { $0.click(position, toggle: toggle, extend: extend) }
    }

    func clearSelection() {
        select { $0.clearSelection() }
    }

    // MARK: Pointer

    /// A drag's progress, in the grid's coordinates. Past the click slop it lifts the selected pages (the pressed
    /// one alone when it was not selected) and follows the pointer.
    func pointerChanged(from start: CGPoint, to location: CGPoint, in layout: PageGridLayout) {
        guard let model else { return }
        if drag == nil {
            guard hypot(location.x - start.x, location.y - start.y) >= Self.clickSlop,
                  let position = layout.position(at: start) else { return }
            if !model.selection.contains(position) { click(position) }
            guard let lifted = self.model else { return }
            let pages = lifted.selection.sorted().map { lifted.pages[$0].page }
            drag = PageDrag(pages: pages, location: location, insertion: layout.insertion(at: location))
        }
        drag?.location = location
        drag?.insertion = layout.insertion(at: location)
    }

    func pointerEnded(from start: CGPoint, to location: CGPoint, in layout: PageGridLayout, toggle: Bool, extend: Bool) {
        let lifted = drag
        endDrag()
        guard let model else { return }
        if let lifted {
            let positions = IndexSet(lifted.pages.compactMap { page in model.pages.firstIndex { $0.page == page } })
            let target = layout.insertion(at: location).index
            edit("Move Pages") { $0.move(from: positions, to: target) }
        } else if hypot(location.x - start.x, location.y - start.y) < Self.clickSlop {
            if let position = layout.position(at: start) {
                click(position, toggle: toggle, extend: extend)
            } else if !toggle, !extend {
                clearSelection()
            }
        }
    }

    // MARK: Autoscroll

    /// The task that scrolls the grid while a drag is on, so the tests can see it stop.
    private(set) var autoscroll: Task<Void, Never>?

    /// Runs `tick` every 80 ms for as long as a drag is on. The task holds the session weakly: it must not keep a
    /// closed editor alive or wake the app after it.
    func startAutoscroll(
        every interval: Duration = .milliseconds(80), _ tick: @escaping @MainActor (PageOrganizerSession) -> Void
    ) {
        autoscroll?.cancel()
        autoscroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.drag != nil else { return }
                tick(self)
            }
        }
    }

    func stopAutoscroll() {
        autoscroll?.cancel()
        autoscroll = nil
    }

    /// Drops a drag whose end will never come (the editor closed with the button down).
    func endDrag() {
        drag = nil
        stopAutoscroll()
    }

    func editorClosed() {
        endDrag()
    }

    // MARK: Private

    private static func name(of action: PageAction) -> String {
        switch action {
        case .delete: "Delete Pages"
        case .rotateRight, .rotateLeft: "Rotate Pages"
        default: "Move Pages"
        }
    }

    /// A change of the selection alone: not stored when it leaves the model equal, and never undoable.
    private func select(_ change: (inout PageOrganizerModel) -> Void) {
        guard var copy = model else { return }
        change(&copy)
        if copy != model { model = copy }
    }

    /// A change to the pages, undoable. One that leaves the pages as they were is only a change of selection.
    private func edit(_ name: String, _ change: (inout PageOrganizerModel) -> Void) {
        guard let old = model else { return }
        var copy = old
        change(&copy)
        guard copy != old else { return }
        model = copy
        guard copy.pages != old.pages else { return }
        registerUndo(restoring: old, name)
    }

    private func registerUndo(restoring snapshot: PageOrganizerModel, _ name: String) {
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(snapshot, name) }
        }
        undoManager?.setActionName(name)
    }

    /// Undo and redo: the manager registers what this registers as the opposite while it runs.
    private func restore(_ snapshot: PageOrganizerModel, _ name: String) {
        guard let current = model else { return }
        model = snapshot
        registerUndo(restoring: current, name)
    }

    private func announce(_ text: String?) {
        guard let text else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

// MARK: - Views

struct PageOrganizerView: View {
    @ObservedObject var session: PageOrganizerSession
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            PageGrid(session: session)
        }
        .onAppear { session.undoManager = undoManager }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { session.undoManager = undoManager }
    }

    private var toolbar: some View {
        let hasSelection = !(session.model?.selection.isEmpty ?? true)
        return HStack(spacing: 6) {
            Button { session.perform(.rotateLeft) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                .help("Rotate Left (\u{2318}L)")
            Button { session.perform(.rotateRight) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                .help("Rotate Right (\u{2318}R)")
            Button { session.perform(.delete) } label: { Label("Delete", systemImage: "trash") }
                .help("Remove the chosen pages from the copy (Delete)")
            Spacer(minLength: 8)
            Text(session.model?.summary ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!hasSelection)
    }
}

private final class ScrollTracker {
    /// The grid's top edge in the viewport: 0, or negative once scrolled.
    var offset: CGFloat = 0
    /// Where the pointer is in the viewport during a drag; the autoscroll reads it without holding the view.
    var pointer: CGPoint?
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The pages. It takes the keys while focused; its drag gesture lives in the grid's own coordinates, so it works
/// wherever the grid is scrolled to.
private struct PageGrid: View {
    @ObservedObject var session: PageOrganizerSession
    @FocusState private var focused: Bool
    /// Read only by the drag, so scrolling does not redraw the grid.
    @State private var scroll = ScrollTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "page-grid"
    private static let viewport = "page-viewport"
    private static let edgeZone: CGFloat = 28

    var body: some View {
        let layout = PageGridLayout(count: session.model?.pages.count ?? 0)
        let height = min(layout.height, PageGridLayout.maxHeight)
        ScrollViewReader { proxy in
            ScrollView {
                grid(layout)
                    .frame(width: layout.width, height: layout.height)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self, value: geometry.frame(in: .named(Self.viewport)).minY)
                    })
                    .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.viewport)
            .onPreferenceChange(ScrollOffsetKey.self) { scroll.offset = $0 }
            .frame(height: session.model == nil ? PageGridLayout.cell.height : height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
            .editorKeys($focused) { press in PageKeys.action(for: press).map(session.perform) ?? false }
            .onChange(of: session.model?.focus) {
                guard let model = session.model, let focus = model.focus, model.pages.indices.contains(focus) else { return }
                proxy.scrollTo(model.pages[focus].page)
            }
            .onChange(of: session.drag != nil) { _, dragging in
                if dragging {
                    session.startAutoscroll(Self.autoscrollTick(proxy, height: height, scroll: scroll))
                } else {
                    session.stopAutoscroll()
                }
            }
        }
        // Closing the editor mid-drag never delivers the gesture's end.
        .onDisappear { session.endDrag() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
        .accessibilityHint("Arrow keys choose a page, Command with an arrow moves it")
    }

    @ViewBuilder
    private func grid(_ layout: PageGridLayout) -> some View {
        if let model = session.model {
            let lifted = Set(session.drag?.pages ?? [])
            ZStack(alignment: .topLeading) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(PageGridLayout.cell.width), spacing: PageGridLayout.spacing),
                                   count: PageGridLayout.columns),
                    spacing: PageGridLayout.spacing
                ) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.page) { position, edit in
                        PageCell(session: session, edit: edit, position: position, label: model.label(at: position),
                                 selected: model.selection.contains(position), lifted: lifted.contains(edit.page))
                    }
                }
                .padding(PageGridLayout.padding)
                // A reorder glides, unless Reduce Motion is on: then the pages just are where they are.
                .animation(reduceMotion ? nil : .spring(duration: 0.25), value: model.pages)
                if let drag = session.drag {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: PageGridLayout.cell.height)
                        .offset(x: layout.bar(for: drag.insertion).minX, y: layout.bar(for: drag.insertion).minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    ghost(drag, model: model)
                }
            }
            .frame(width: layout.width, height: layout.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged {
                    scroll.pointer = CGPoint(x: $0.location.x, y: $0.location.y + scroll.offset)
                    session.pointerChanged(from: $0.startLocation, to: $0.location, in: layout)
                }
                .onEnded {
                    scroll.pointer = nil
                    let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    session.pointerEnded(from: $0.startLocation, to: $0.location, in: layout,
                                         toggle: modifiers.contains(.command), extend: modifiers.contains(.shift))
                })
        } else if session.unreadable == nil {
            ProgressView().controlSize(.small).frame(width: layout.width, height: PageGridLayout.cell.height)
        } else {
            Image(systemName: "doc.badge.ellipsis")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .frame(width: layout.width, height: PageGridLayout.cell.height)
                .accessibilityHidden(true)
        }
    }

    /// The lifted pages under the pointer: the first one, with the count when there are more.
    private func ghost(_ drag: PageDrag, model: PageOrganizerModel) -> some View {
        let edit = drag.pages.first.flatMap { page in model.pages.first { $0.page == page } }
        return ZStack(alignment: .topTrailing) {
            if let edit {
                PageThumbnail(session: session, page: edit.page, rotation: edit.rotation, box: CGSize(width: 72, height: 80))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            }
            if drag.pages.count > 1 {
                Text("\(drag.pages.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 6, y: -6)
            }
        }
        .frame(width: 72, height: 80)
        .position(drag.location)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// While a drag is on, the grid scrolls a row at a time towards the edge the pointer is near, and the
    /// insertion follows the page now under it. It holds the proxy and the tracker, never the view or the session.
    private static func autoscrollTick(
        _ proxy: ScrollViewProxy, height: CGFloat, scroll: ScrollTracker
    ) -> @MainActor (PageOrganizerSession) -> Void {
        { session in
            guard let pointer = scroll.pointer, let model = session.model else { return }
            let layout = PageGridLayout(count: model.pages.count)
            let top = -scroll.offset / PageGridLayout.rowPitch
            var row: Int?
            if pointer.y < edgeZone, scroll.offset < 0 {
                row = max(0, Int(top.rounded(.up)) - 1)
            } else if pointer.y > height - edgeZone, -scroll.offset + height < layout.height - 1 {
                row = min(layout.rows - 1, Int(top.rounded(.down)) + 1)
            }
            if let row, model.pages.indices.contains(row * PageGridLayout.columns) {
                proxy.scrollTo(model.pages[row * PageGridLayout.columns].page, anchor: .top)
            }
            let point = CGPoint(x: pointer.x, y: pointer.y - scroll.offset)
            session.pointerChanged(from: point, to: point, in: layout)
        }
    }
}

private struct PageCell: View {
    let session: PageOrganizerSession
    let edit: PageEdit
    let position: Int
    let label: String
    let selected: Bool
    let lifted: Bool

    var body: some View {
        VStack(spacing: 4) {
            PageThumbnail(session: session, page: edit.page, rotation: edit.rotation,
                          box: CGSize(width: 116, height: 128))
                .frame(width: 120, height: 132)
            Text("\(edit.page + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: PageGridLayout.cell.width, height: PageGridLayout.cell.height)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(selected ? 0.16 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).opacity(selected ? 1 : 0))
        .opacity(lifted ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { session.click(position) }
        .accessibilityAction(named: "Move Earlier") { session.act(on: position, .moveEarlier) }
        .accessibilityAction(named: "Move Later") { session.act(on: position, .moveLater) }
        .accessibilityAction(named: "Rotate Right") { session.act(on: position, .rotateRight) }
        .accessibilityAction(named: "Rotate Left") { session.act(on: position, .rotateLeft) }
        .accessibilityAction(named: "Remove") { session.act(on: position, .delete) }
    }
}

/// A page drawn when it appears, turned by the rotation the person added and fitted into `box` once turned.
private struct PageThumbnail: View {
    let session: PageOrganizerSession
    let page: Int
    let rotation: Int
    let box: CGSize
    @State private var image: CGImage?

    var body: some View {
        let turned = rotation % 180 != 0
        // Letter portrait until the page is drawn.
        let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.77
        let shown = turned ? 1 / aspect : aspect
        let fitted = shown >= box.width / box.height
            ? CGSize(width: box.width, height: box.width / shown) : CGSize(width: box.height * shown, height: box.height)
        let drawn = turned ? CGSize(width: fitted.height, height: fitted.width) : fitted
        ZStack {
            Rectangle().fill(Color.white)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        .rotationEffect(.degrees(Double(rotation)))
        .frame(width: fitted.width, height: fitted.height)
        .animation(.easeOut(duration: 0.15), value: image == nil)
        .task(id: page) {
            image = await session.thumbnails.image(page: page, maxSide: PageOrganizerSession.thumbnailSide)
        }
    }
}
