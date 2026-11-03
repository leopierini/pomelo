import AppKit
import PomeloUIModel
import SwiftUI

/// The app's own ring for the current page. Each slice has its menu (Control-click) and the same actions for
/// VoiceOver, and drags to move or remove it; the hub shows the page's name and how full it is. A drag over the ring
/// shows where it will land.
struct WheelEditorRing: View {
    @ObservedObject var model: WheelEditorPaneModel
    @State private var hovered: Int?
    @State private var highlightAngle = 0.0
    @State private var highlightAnimates = false
    @State private var dropOutcome: WheelEditorPaneModel.DropOutcome?
    @State private var hoverPause: HoverPause?
    @Environment(\.colorScheme) private var colorScheme

    /// Close to the live glass wheel over a window: a step lighter than the dark pane, a step darker than the light one.
    private static let fill = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.2 : 0.92, alpha: 1)
    })

    var body: some View {
        let slices = model.currentPage?.slices ?? []
        let geometry = WheelGeometry(sliceCount: slices.count)
        let hovered = hovered.flatMap { slices.indices.contains($0) ? $0 : nil }
        let preview = DropPreview(slices: slices, outcome: dropOutcome)
        let shown = WheelGeometry(sliceCount: preview.slices.count)
        let lit = preview.lit ?? hovered
        return ZStack {
            // The solid look the wheel has under Reduce Transparency: glass over a plain pane would barely show, and
            // a snapshot can't draw it. The window's own colour would melt into the pane in Dark, so the ring takes a
            // raised fill, and a shadow dark enough to show there too.
            Circle()
                .fill(Self.fill)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 12, y: 3)
                .accessibilityHidden(true)
            WheelRing(slices: preview.slices, hovered: lit,
                      highlightAngle: preview.lit.map(shown.centerAngle(ofSlice:)) ?? highlightAngle,
                      highlightAnimates: highlightAnimates && preview.lit == nil, dimmed: false, geometry: shown) {
                hub(hovered: lit.map { preview.slices[$0] }, geometry: shown)
            }
            .environment(\.wheelSolidBackground, true)
            .environment(\.wheelSolidFill, Self.fill)
            // Only a drag's preview animates: a page or wheel shown by a click snaps, as the wheel in use does.
            .animation(.easeOut(duration: 0.15), value: dropOutcome)
            .accessibilityHidden(true)
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                Color.clear
                    // The slice's area from the hub to the rim: the ring's frame is the wheel's diameter.
                    .contentShape(AnnularSector(sweep: 2 * .pi / Double(slices.count),
                                                innerRadius: geometry.hubDiameter / 2,
                                                centerAngle: geometry.centerAngle(ofSlice: index)))
                    .contextMenu { sliceMenu(index) }
                    .onDrag {
                        model.beginDrag(slice.id, from: .slice(page: model.pageIndex, index: index))
                    } preview: {
                        SlotChipLabel(slice: slice).lifted()
                    }
                    .accessibilityHidden(true)
                sliceElement(slice, index: index, geometry: geometry)
            }
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
        .onDrop(of: [.wheelSlot], delegate: RingDrop(model: model, geometry: geometry, outcome: $dropOutcome,
                                                     hovered: $hovered, hoverPause: $hoverPause))
        .disabled(model.isFormatFollowingKind)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let hit = geometry.hitTest(geometry.centred(fromTopLeft: location))
                if case .slice(let index) = hit { hover(index, geometry: geometry) } else { hover(nil, geometry: geometry) }
            case .ended:
                hover(nil, geometry: geometry)
            }
        }
        .onChange(of: model.pageIndex) { self.hovered = nil }
        .onChange(of: model.selection) { self.hovered = nil }
    }

    private func hover(_ index: Int?, geometry: WheelGeometry) {
        let index = model.isFormatFollowingKind ? nil : index
        switch hoverPause {
        case .pending?:
            hoverPause = .holding(index)
            return
        case .holding(let held)? where held == index:
            return
        case .holding?:
            hoverPause = nil
        case nil:
            break
        }
        guard index != hovered else { return }
        if let index {
            highlightAnimates = hovered != nil
            highlightAngle = geometry.highlightAngle(toSlice: index, from: highlightAnimates ? highlightAngle : nil)
        }
        hovered = index
    }

    /// Sized to the geometry's hub, as `WheelRing` leaves it to its host.
    private func hub(hovered slice: WheelSlice?, geometry: WheelGeometry) -> some View {
        let reason = slice?.disabledReason
        return VStack(spacing: 2) {
            Text(reason == nil ? model.currentPage?.title ?? "" : slice?.title ?? "")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(reason ?? model.hubCount)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .frame(width: geometry.hubDiameter - 24, height: geometry.hubDiameter)
    }

    /// VoiceOver's element for a slice, over its label.
    private func sliceElement(_ slice: WheelSlice, index: Int, geometry: WheelGeometry) -> some View {
        let radius = geometry.diameter / 2
        let center = geometry.labelCenter(ofSlice: index)
        let count = model.currentPage?.slices.count ?? 0
        return Color.clear
            .frame(width: 76, height: 48)
            .position(x: radius + center.x, y: radius - center.y)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(slice.title)
            .accessibilityValue("\(index + 1) of \(count)")
            .accessibilityHint(slice.disabledReason ?? "")
            .accessibilityActions {
                ForEach(actions(for: index).spoken) { action in
                    Button(action.title, action: action.perform)
                }
            }
    }

    @ViewBuilder private func sliceMenu(_ index: Int) -> some View {
        let actions = actions(for: index)
        ForEach(actions.moves) { action in
            Button(action.title, action: action.perform).disabled(!action.isEnabled)
        }
        Menu("Move to Page") {
            ForEach(actions.pages) { action in
                Button(action.title, action: action.perform)
            }
        }
        .disabled(actions.pages.isEmpty)
        Divider()
        Button(actions.remove.title, action: actions.remove.perform)
    }

    private func actions(for index: Int) -> SliceChoices {
        let count = model.currentPage?.slices.count ?? 0
        let model = model
        let pages = model.pages.enumerated().filter { $0.offset != model.pageIndex }.map { page, wheelPage in
            SliceChoices.Action(id: "page.\(page)", title: wheelPage.title) { model.move(at: index, toPage: page) }
        }
        return SliceChoices(
            moves: [
                SliceChoices.Action(id: "left", title: "Move Left", isEnabled: index > 0) {
                    model.move(from: index, to: index - 1)
                },
                SliceChoices.Action(id: "right", title: "Move Right", isEnabled: index < count - 1) {
                    model.move(from: index, to: index + 2)
                },
            ],
            pages: pages,
            remove: SliceChoices.Action(id: "remove", title: "Remove") { model.remove(at: index) }
        )
    }
}

/// After a drop the cursor rests on the slice it just placed, and lighting it would read as a selection: hover stays
/// off until the pointer reaches another slice or leaves the ring. `pending` waits for the first hover after the drop.
private enum HoverPause: Equatable {
    case pending
    case holding(Int?)
}

/// Where a drag over the ring would land, worked out by the model from the cursor.
private struct RingDrop: DropDelegate {
    let model: WheelEditorPaneModel
    let geometry: WheelGeometry
    @Binding var outcome: WheelEditorPaneModel.DropOutcome?
    @Binding var hovered: Int?
    @Binding var hoverPause: HoverPause?

    func validateDrop(info: DropInfo) -> Bool {
        !model.isFormatFollowingKind && model.dragging != nil && info.hasItemsConforming(to: [.wheelSlot])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = currentOutcome(info)
        if next != outcome { outcome = next }
        switch next {
        case .insert, .replace: return DropProposal(operation: .copy)
        case .move, .remove: return DropProposal(operation: .move)
        case .nothing, nil: return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        outcome = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        outcome = nil
        guard let drag = model.dragging else { return false }
        model.dragging = nil
        hovered = nil
        hoverPause = .pending
        let point = geometry.centred(fromTopLeft: info.location)
        let landing = model.dropOutcome(slot: drag.slot, from: drag.source, at: point)
        if model.drop(slot: drag.slot, from: drag.source, at: point), case .remove = landing { poof() }
        return true
    }

    private func currentOutcome(_ info: DropInfo) -> WheelEditorPaneModel.DropOutcome? {
        guard let drag = model.dragging else { return nil }
        return model.dropOutcome(slot: drag.slot, from: drag.source, at: geometry.centred(fromTopLeft: info.location))
    }
}

/// The system's poof where a removed slice was let go (spec §3.10). `NSShowAnimationEffect` still animates but is
/// deprecated since macOS 14 for the disappearing-item cursor, which a SwiftUI drop can't show; it is looked up at run
/// time so the build stays free of warnings, and a macOS without it simply shows no poof.
@MainActor func poof() {
    typealias Show = @convention(c) (UInt, CGPoint, CGSize, UnsafeRawPointer?, UnsafeRawPointer?,
                                     UnsafeMutableRawPointer?) -> Void
    let disappearingItemDefault: UInt = 0
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "NSShowAnimationEffect") else { return }
    unsafeBitCast(symbol, to: Show.self)(disappearingItemDefault, NSEvent.mouseLocation, CGSize(width: 48, height: 48),
                                         nil, nil, nil)
}

/// The ring as a drop would leave it: a gap opening where a slot will go, or the slice a chip replaces lit. A chip
/// that can't fit (the hub of a full page) changes nothing.
private struct DropPreview {
    var slices: [WheelSlice]
    var lit: Int?

    static let gap = WheelSlice(id: "drop.gap", title: "", symbol: "circle.dashed", kind: .preset(id: "drop.gap"))

    init(slices: [WheelSlice], outcome: WheelEditorPaneModel.DropOutcome?) {
        self.slices = slices
        switch outcome {
        case .insert(let index) where slices.count < WheelContentBuilder.maxSlices:
            self.slices.insert(Self.gap, at: min(index, slices.count))
        case .replace(let index) where slices.indices.contains(index):
            lit = index
        case .move(let from, let to) where slices.indices.contains(from):
            self.slices.remove(at: from)
            self.slices.insert(Self.gap, at: min(to > from ? to - 1 : to, self.slices.count))
        default:
            break
        }
    }
}

/// A slice's edits, as its menu and as VoiceOver actions ("Move to Tools" for each other page).
private struct SliceChoices {
    struct Action: Identifiable {
        let id: String
        let title: String
        var isEnabled = true
        let perform: () -> Void
    }

    var moves: [Action]
    var pages: [Action]
    var remove: Action

    /// What VoiceOver offers: the moves that can happen, one per other page, and Remove.
    var spoken: [Action] {
        moves.filter(\.isEnabled)
            + pages.map { Action(id: $0.id, title: "Move to \($0.title)", perform: $0.perform) }
            + [remove]
    }
}
