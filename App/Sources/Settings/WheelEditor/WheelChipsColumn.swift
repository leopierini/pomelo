import PomeloUIModel
import SwiftUI

/// What can go on the wheel, grouped as the spec names them (P179). A chip adds itself to the end of the current
/// page, or where it is dragged to; one already there is faded with a check mark.
struct WheelChipsColumn: View {
    @ObservedObject var model: WheelEditorPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to this page")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Convert to", model.candidates.convert)
                    group("Tools", model.candidates.tools)
                    group("AI", model.candidates.ai)
                    group("File tools", model.candidates.fileTools)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(model.isFormatFollowingKind)
        .opacity(model.isFormatFollowingKind ? 0.5 : 1)
        .editorColumn()
    }

    @ViewBuilder private func group(_ title: String, _ chips: [WheelSlice]) -> some View {
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ChipFlow(spacing: 6) {
                    ForEach(chips) { chip in
                        WheelChip(slice: chip, isPlaced: model.isOnPage(chip.id)) { model.add(chip.id) }
                            .onDrag { model.beginDrag(chip.id, from: .chip) } preview: {
                                SlotChipLabel(slice: chip).lifted()
                            }
                    }
                }
            }
        }
    }
}

private struct WheelChip: View {
    let slice: WheelSlice
    let isPlaced: Bool
    let add: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: add) {
            SlotChipLabel(slice: slice, isPlaced: isPlaced, isHovering: isHovering && !isPlaced && isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(isPlaced)
        .opacity(isPlaced ? 0.5 : 1)
        .onHover { isHovering = $0 }
        .help(isPlaced ? "Already on this page" : "Add to this page")
        .contextMenu {
            Button("Add to this page", action: add)
                .disabled(isPlaced)
        }
        .accessibilityLabel(slice.title)
        .accessibilityValue(isPlaced ? "On this page" : "")
        .accessibilityActions {
            if !isPlaced { Button("Add to this page", action: add) }
        }
    }
}

/// A chip's face: its icon and title in a capsule. Also what a drag of a chip or a slice carries under the cursor.
struct SlotChipLabel: View {
    let slice: WheelSlice
    var isPlaced = false
    var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            // The chip's label and value say what these show.
            Image(systemName: slice.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(slice.title)
                .lineLimit(1)
            if isPlaced {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(isHovering ? 0.11 : 0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Capsule())
    }

    /// On an opaque capsule: the drag image floats over whatever lies under the cursor.
    func lifted() -> some View {
        background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// Chips left to right, wrapping onto as many rows as they need.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
