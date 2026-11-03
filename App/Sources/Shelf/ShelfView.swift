// The drawer (S8): empty, one file, several as a fanned stack, the list, greyed missing files, the tab it tucks into,
// the key pill under files that can be dragged (R30), and the accent ring while files are over it. Same material as
// the wheel and the pill (`wheelBackground`); SF Symbols only. Drops, and every mouse-down but the top corners' and the
// header's, go to the AppKit items view holding it (its `hitTest`, S24), which tells the collapsed stack from the rest
// by `ShelfStackArea` (R29); VoiceOver gets the stack, rows and tab as elements with S22's labels and actions.
import AppKit
import PomeloUIModel
import SwiftUI

struct ShelfView: View {
    static let cornerRadius: CGFloat = 16
    /// The squares at the drawer's top corners holding the ✕ and the tuck chevron: mouse-downs there stay SwiftUI's.
    /// The empty drawer has no chevron; its left corner lies in its header, which moves the Shelf.
    static let closeCorner: CGFloat = 28
    /// The empty drawer's header, holding its ✕; dragging it moves the Shelf (S7).
    static let emptyHeaderHeight: CGFloat = 22

    @ObservedObject var controller: ShelfController

    var body: some View {
        ShelfDrawer(
            model: controller.model, presentation: controller.presentation, pill: controller.pill,
            isDropTargeted: controller.isDropTargeted, isPointerInside: controller.isPointerInside,
            blink: controller.blink, thumbnails: controller.thumbnails, scrollOffset: controller.scrollOffset,
            tabSide: controller.tabSide, animatesIn: controller.animates, controller: controller
        )
        // A new identity each time the Shelf comes on screen replays the appear animation (S9).
        .id(controller.appearances)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfDrawer: View {
    let model: ShelfModel
    let presentation: ShelfPresentation
    let pill: ShelfPill?
    let isDropTargeted: Bool
    let isPointerInside: Bool
    let blink: ShelfBlink?
    let thumbnails: [UUID: NSImage]
    let scrollOffset: CGFloat
    let tabSide: ShelfSide
    let animatesIn: Bool
    /// For actions and icons only; what is drawn comes from the values above.
    let controller: ShelfController

    @State private var settled = false
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// The tab is narrower than two corner radii: its ends are round.
    private var shape: RoundedRectangle {
        let width = ShelfLayout.size(presentation).width
        return RoundedRectangle(cornerRadius: min(ShelfView.cornerRadius, width / 2), style: .continuous)
    }

    var body: some View {
        let size = ShelfLayout.size(presentation)
        let motion = ShelfMotion(reduceMotion: reduceMotion)
        content
            .frame(width: size.width, height: size.height)
            .wheelBackground(in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
            }
            .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 2).opacity(isDropTargeted || flash ? 1 : 0) }
            .scaleEffect(isDropTargeted ? motion.dropHoverScale : 1)
            .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ShelfCopy.shelf)
            .accessibilityValue(model.accessibilityValue)
            .opacity(settled || !animatesIn ? 1 : 0)
            .scaleEffect(settled || !animatesIn ? 1 : motion.appearScale)
            .onAppear {
                guard animatesIn, !settled else { return }
                withAnimation(.easeOut(duration: motion.duration)) { settled = true }
            }
            .onChange(of: blink) { _, blink in
                guard blink != nil else { return }
                withAnimation(.easeIn(duration: 0.1)) { flash = true } completion: {
                    withAnimation(.easeOut(duration: 0.3)) { flash = false }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if presentation == .tucked {
            tab
        } else if model.isEmpty {
            empty
        } else if case .expanded = presentation {
            list
        } else if model.items.count == 1 {
            single(model.items[0])
        } else {
            several
        }
    }

    private var hasPresent: Bool { model.items.contains { $0.state == .present } }

    // MARK: States

    private var empty: some View {
        let tint = isDropTargeted ? Color.accentColor : Color.secondary
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                closeButton
            }
            .frame(height: ShelfView.emptyHeaderHeight)
            .padding(.horizontal, 6)
            .background(ShelfHeaderDrag { controller.headerDragEnded() })
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(isDropTargeted ? 1 : 0.6),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 26))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(ShelfCopy.dropHere)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .padding([.horizontal, .bottom], 10)
        }
    }

    /// One file: its thumbnail, its name over its size, or greyed with the reason (S8).
    private func single(_ item: ShelfItem) -> some View {
        filled(VStack(spacing: 6) {
            ShelfThumbnail(image: thumbnails[item.id] ?? controller.icon(for: item), side: ShelfController.thumbnailSide,
                           missing: item.state != .present)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                .overlay(ShelfStackArea())
            // Short enough for two caption lines, so SwiftUI never adds a second ellipsis.
            labels(title: ResultSummary.shortened(item.name, to: 24), subtitle: item.detail, weight: .regular)
                .opacity(item.state == .present ? 1 : 0.5)
        })
    }

    /// Several: the three most recent present items fanned; when none is present, the three most recent greyed.
    private var several: some View {
        let missing = model.stack.isEmpty
        let fan = missing ? Array(model.items.suffix(3)) : model.stack
        return filled(VStack(spacing: 10) {
            FannedStack(images: fan.map { thumbnails[$0.id] ?? controller.icon(for: $0) }, missing: missing)
                .overlay(ShelfStackArea())
            labels(title: model.title, subtitle: model.subtitle, weight: .semibold)
        })
    }

    /// The drawer holding files: one VoiceOver element with S22's actions, the drag hint while something can be
    /// dragged, the key pill under it, and on hover the ✕ and the tuck chevron; their corners around them move it, as
    /// the rest off the stack does (R29).
    private func filled(_ content: some View) -> some View {
        VStack(spacing: 0) {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.title)
                .accessibilityValue(ShelfSpoken.stackValue(of: model))
                .accessibilityHint(hasPresent ? ShelfCopy.dragHint : "")
                .accessibilityActions {
                    ForEach(ShelfAction.stack, id: \.self) { action in
                        Button(action.title) { controller.perform(action) }
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            pillBand
        }
        .background(ShelfHeaderDrag { controller.headerDragEnded() })
        .overlay(alignment: .topTrailing) { hoverCloseButton }
        .overlay(alignment: .topLeading) { hoverTuckButton }
    }

    /// The key pill centred in the drawer's bottom band (R30); the band stays when every file is missing, so the
    /// drawer keeps its size. VoiceOver hears the same in the stack's and rows' hint.
    private var pillBand: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: ShelfLayout.pillBand)
            .overlay {
                if let pill {
                    KeyPill(key: pill.key, titles: pill.titles, current: pill.current)
                        .accessibilityHidden(true)
                }
            }
    }

    /// The name or count over the size or reason (two labels, P32).
    private func labels(title: String, subtitle: String?, weight: Font.Weight) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption.weight(weight))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The list (S8)

    private var list: some View {
        VStack(spacing: 0) {
            header
            rows
                .padding(.vertical, ShelfLayout.listPadding / 2)
            pillBand
        }
    }

    /// The chevron that collapses the list, the count over the size, the tuck chevron and the ✕; dragging the rest
    /// moves the Shelf (S7).
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                controller.collapse()
            } label: {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShelfCopy.collapse)
            .help(ShelfCopy.collapse)
            Text(model.title)
                .font(.caption.weight(.semibold))
            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            tuckButton
            closeButton
        }
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: ShelfLayout.headerHeight)
        .background(ShelfHeaderDrag { controller.headerDragEnded() })
    }

    // MARK: The tab (S8, S9, S22)

    /// The count along the tab, reading away from the screen's edge; a click (on the items view) brings it back.
    private var tab: some View {
        Text(String(model.items.count))
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(tabSide == .left ? -90 : 90))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ShelfCopy.tab(model.items.count))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.untuck() }
            .accessibilityAction(named: ShelfCopy.bringBack) { controller.untuck() }
    }

    /// Only the rows that show are drawn, each placed by the controller's scroll offset.
    private var rows: some View {
        let count = model.items.count
        let visible = ShelfLayout.visibleRows(scrollOffset: scrollOffset, count: count)
        let height = ShelfLayout.size(.expanded(rows: count)).height - ShelfLayout.headerHeight
            - ShelfLayout.listPadding - ShelfLayout.pillBand
        return ZStack(alignment: .topLeading) {
            ForEach(visible.map { (index: $0, item: model.items[$0]) }, id: \.item.id) { row in
                ShelfRow(item: row.item, image: thumbnails[row.item.id] ?? controller.icon(for: row.item),
                         isSelected: model.selection.contains(row.item.id), controller: controller)
                    .offset(y: CGFloat(row.index) * ShelfLayout.rowHeight - scrollOffset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipped()
        // Only drawn rows are elements: VoiceOver pages to the others as a scroll view's would.
        .accessibilityScrollAction { edge in
            let page = height - ShelfLayout.rowHeight
            switch edge {
            case .top: controller.scrolled(by: page)
            case .bottom: controller.scrolled(by: -page)
            default: break
            }
        }
    }

    // MARK: ✕ and the tuck chevron

    /// On a Shelf with files, only while the pointer is over it (S8).
    @ViewBuilder private var hoverCloseButton: some View {
        if isPointerInside {
            closeButton.padding(6)
        }
    }

    @ViewBuilder private var hoverTuckButton: some View {
        if isPointerInside {
            tuckButton.padding(6)
        }
    }

    /// Points to the side edge the tab goes to (S9).
    private var tuckButton: some View {
        Button {
            controller.tuck()
        } label: {
            Image(systemName: tabSide == .left ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShelfCopy.tuckAway)
        .help(ShelfCopy.tuckAway)
    }

    /// Closes an empty Shelf; clears one with files (S14: only references are forgotten).
    private var closeButton: some View {
        let label = model.isEmpty ? ShelfCopy.close : ShelfCopy.clearShelf
        let empty = model.isEmpty
        return Button {
            if empty { controller.close() } else { controller.clear() }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A row of the list (S8): a 20 pt thumbnail, the name, the size at the trailing edge; a missing file greyed with its
/// reason under its name. One VoiceOver element with S22's row actions.
private struct ShelfRow: View {
    let item: ShelfItem
    let image: NSImage
    let isSelected: Bool
    let controller: ShelfController

    private static let thumbnail: CGFloat = 20

    private var present: Bool { item.state == .present }
    private var primary: Color { isSelected ? .white : .primary }
    private var secondary: Color { isSelected ? .white.opacity(0.8) : .secondary }

    var body: some View {
        content
            .opacity(present ? 1 : 0.55)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: ShelfLayout.rowHeight, maxHeight: ShelfLayout.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.detail ?? "")
            .accessibilityHint(present ? ShelfCopy.dragHint : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityActions {
                ForEach(ShelfAction.row, id: \.self) { action in
                    Button(action.title) { controller.perform(action, onRow: item.id) }
                }
            }
    }

    private var content: some View {
        HStack(spacing: 8) {
            ShelfThumbnail(image: image, side: Self.thumbnail, missing: !present)
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.25)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(primary)
                    .truncationMode(.middle)
                if let reason = item.state.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if present, let size = item.detail {
                Text(size)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondary)
            }
        }
    }
}

/// The three most recent items, oldest at the back, fanned −6°, +6° and the newest straight on top (S8).
private struct FannedStack: View {
    let images: [NSImage]
    /// Every item is missing: the fan is greyed.
    let missing: Bool

    private static let angles: [Double] = [-6, 6, 0]

    var body: some View {
        ZStack {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                ShelfThumbnail(image: image, side: ShelfController.thumbnailSide - 8, missing: missing && index == images.count - 1)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                    .rotationEffect(.degrees(Self.angles[Self.angles.count - images.count + index]))
            }
        }
        .opacity(missing ? 0.6 : 1)
        .frame(width: ShelfController.thumbnailSide, height: ShelfController.thumbnailSide)
    }
}

/// Its Quick Look thumbnail or the file's icon; a missing file's carries a warning triangle (S8).
private struct ShelfThumbnail: View {
    let image: NSImage
    let side: CGFloat
    var missing = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .opacity(missing ? 0.5 : 1)
            .overlay(alignment: .bottomTrailing) {
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: max(side * 0.3, 10)))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The Shelf's motion (S9, S23): under Reduce Motion only fades of 0.15 s, with no scale and no slide.
struct ShelfMotion: Equatable {
    /// The appear fade, and the tuck's slide or fade.
    let duration: Double
    /// The scale the drawer appears from.
    let appearScale: CGFloat
    /// While files are over the drawer or the tab.
    let dropHoverScale: CGFloat
    /// Whether tucking slides the panel to its tab and back; else it fades in at its new place.
    let slides: Bool

    init(reduceMotion: Bool) {
        duration = reduceMotion ? 0.15 : 0.2
        appearScale = reduceMotion ? 1 : 0.97
        dropHoverScale = reduceMotion ? 1 : 1.03
        slides = !reduceMotion
    }
}

/// Over the collapsed drawer's thumbnail stack: drags there take the files out, elsewhere they move the Shelf (R29).
/// An overlay, since SwiftUI's hit test stops at the images over a background; it draws nothing and the items view
/// only hit-tests it.
struct ShelfStackArea: NSViewRepresentable {
    final class Area: NSView {}

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {}
}

/// The header's background (S7), and the collapsed drawer's corners around its buttons (R29): dragging it moves the
/// Shelf, which settles inside the screen when let go.
private struct ShelfHeaderDrag: NSViewRepresentable {
    let ended: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.ended = ended
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.ended = ended
    }

    final class DragView: NSView {
        var ended: (() -> Void)?
        private var start: ShelfWindowDrag?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = ShelfWindowDrag(mouse: NSEvent.mouseLocation, origin: window.frame.origin)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            start.follow(window, to: NSEvent.mouseLocation)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            ended?()
        }
    }
}
