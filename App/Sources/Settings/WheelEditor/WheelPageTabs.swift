import PomeloUIModel
import SwiftUI

/// The editor's page tabs, in place of the wheel's page pill: a click shows a page, a double-click renames it in
/// place, a drag along the row reorders, "+ Page" adds one (up to four), and a tab's menu renames or deletes it. A
/// slice or a chip dropped on a tab goes to the end of that page.
struct WheelPageTabs: View {
    @ObservedObject var model: WheelEditorPaneModel
    /// True while a name is being typed, so the pane leaves ⌘Z to the text.
    @Binding var isRenaming: Bool
    @State private var renaming: Int?
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool
    @State private var dragged: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var frames = TabFrames()
    @State private var dropTarget: Int?

    private static let space = "pageTabs"

    var body: some View {
        let isEditable = !model.isFormatFollowingKind
        HStack(spacing: 6) {
            ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                tab(index, title: page.title, isEditable: isEditable)
                    .offset(x: dragged == index ? dragOffset : 0)
                    .zIndex(dragged == index ? 1 : 0)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TabFrameKey.self,
                                               value: [index: proxy.frame(in: .named(Self.space))])
                    })
            }
            if isEditable && model.pages.count < CustomWheel.maxPages {
                Button { model.addPage() } label: {
                    Label("Page", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Page")
                .help("Add a page")
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(TabFrameKey.self) { frames.byIndex = $0 }
        .onChange(of: model.selection) { endRename(commit: false) }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused { endRename(commit: true) }
        }
    }

    @ViewBuilder private func tab(_ index: Int, title: String, isEditable: Bool) -> some View {
        if renaming == index {
            renameField
        } else {
            label(index, title: title, isEditable: isEditable)
        }
    }

    private var renameField: some View {
        TextField("Page name", text: $draft)
            .textFieldStyle(.plain)
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .focused($isFieldFocused)
            .frame(width: max(64, CGFloat(draft.count) * 8 + 16))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2))
            // Once the field exists: focusing it before it is in the hierarchy does nothing.
            .onAppear { isFieldFocused = true }
            .onSubmit { endRename(commit: true) }
            .onExitCommand { endRename(commit: false) }
    }

    private func label(_ index: Int, title: String, isEditable: Bool) -> some View {
        let isSelected = index == model.pageIndex
        return Text(title)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(dragged == index ? 0.2 : 0), radius: 4, y: 1)
            // White on the selected tab's accent fill, accent on the others.
            .overlay(Capsule().strokeBorder(isSelected ? Color.white : Color.accentColor, lineWidth: 2)
                .opacity(dropTarget == index ? 1 : 0))
            .contentShape(Capsule())
            .onDrop(of: [.wheelSlot], delegate: TabDrop(model: model, page: index, target: $dropTarget))
            .onTapGesture(count: 2) { if isEditable { beginRename(index) } }
            .simultaneousGesture(TapGesture().onEnded { model.selectPage(index) })
            .gesture(reorder(index), including: isEditable ? .all : .subviews)
            .contextMenu {
                if isEditable {
                    Button("Rename") { beginRename(index) }
                    // As the VoiceOver actions offer: reordering without dragging.
                    Button("Move Left") { model.movePage(from: index, to: index - 1) }
                        .disabled(index == 0)
                    Button("Move Right") { model.movePage(from: index, to: index + 1) }
                        .disabled(index >= model.pages.count - 1)
                    Divider()
                    Button("Delete Page") { model.deletePage(index) }
                        .disabled(model.pages.count < 2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("Page \(index + 1) of \(model.pages.count)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selectPage(index) }
            .accessibilityActions { pageActions(index, isEditable: isEditable) }
    }

    @ViewBuilder private func pageActions(_ index: Int, isEditable: Bool) -> some View {
        if isEditable {
            Button("Rename") { beginRename(index) }
            if index > 0 { Button("Move Left") { model.movePage(from: index, to: index - 1) } }
            if index < model.pages.count - 1 {
                Button("Move Right") { model.movePage(from: index, to: index + 1) }
            }
            if model.pages.count > 1 { Button("Delete") { model.deletePage(index) } }
        }
    }

    private func reorder(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragged = index
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let target = destination(of: index, movedBy: value.translation.width)
                dragged = nil
                dragOffset = 0
                if target != index { model.movePage(from: index, to: target) }
            }
    }

    /// The index the dragged tab lands at: past every other tab whose middle its own middle has crossed.
    private func destination(of index: Int, movedBy offset: CGFloat) -> Int {
        guard let frame = frames.byIndex[index] else { return index }
        let middle = frame.midX + offset
        return frames.byIndex.filter { $0.key != index && $0.value.midX < middle }.count
    }

    private func beginRename(_ index: Int) {
        guard model.pages.indices.contains(index) else { return }
        model.selectPage(index)
        draft = model.pages[index].title
        renaming = index
        isRenaming = true
    }

    private func endRename(commit: Bool) {
        guard let index = renaming else { return }
        renaming = nil
        isRenaming = false
        if commit { model.renamePage(index, to: draft) }
    }
}

/// A drop on a tab, lit while it can do something there: one that can't (a slice over its own page, a chip
/// already on that page) is forbidden, so the drag slides back.
private struct TabDrop: DropDelegate {
    let model: WheelEditorPaneModel
    let page: Int
    @Binding var target: Int?

    private var accepts: Bool {
        guard let drag = model.dragging else { return false }
        return model.acceptsTabDrop(slot: drag.slot, from: drag.source, page: page)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.wheelSlot]) && accepts
    }

    func dropEntered(info: DropInfo) {
        if accepts { target = page }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts else { return DropProposal(operation: .forbidden) }
        if case .slice = model.dragging?.source { return DropProposal(operation: .move) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if target == page { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if target == page { target = nil }
        guard accepts, let drag = model.dragging else { return false }
        model.dragging = nil
        model.dropOnTab(slot: drag.slot, from: drag.source, page: page)
        return true
    }
}

/// The tabs' frames in the row, read by a drag; a reference, so a layout pass never redraws the row.
private final class TabFrames {
    var byIndex: [Int: CGRect] = [:]
}

private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
