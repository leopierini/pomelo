// The wheel's ring: its background, the slice separators, the slice labels and the highlight of the hovered slice,
// around a hub its host supplies. It knows nothing about files, phases or drops, so the wheel in use and the
// Settings editor draw the very same ring.
import PomeloUIModel
import SwiftUI

struct WheelRing<Hub: View>: View {
    let slices: [WheelSlice]
    let hovered: Int?
    /// The highlight's rotation in radians, clockwise from 12 o'clock.
    let highlightAngle: Double
    /// False when the highlight jumps to `highlightAngle` instead of turning.
    let highlightAnimates: Bool
    /// Every label at reduced opacity, as a disabled slice's (the hub shows an outcome).
    let dimmed: Bool
    let geometry: WheelGeometry
    /// A slice label's accessibility hint; the wheel in use passes its model's preview of a drop.
    let accessibilityHint: (WheelSlice) -> String
    let hub: Hub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(slices: [WheelSlice], hovered: Int?, highlightAngle: Double, highlightAnimates: Bool, dimmed: Bool,
         geometry: WheelGeometry,
         accessibilityHint: @escaping (WheelSlice) -> String = { $0.disabledReason ?? $0.title },
         @ViewBuilder hub: () -> Hub) {
        self.slices = slices
        self.hovered = hovered
        self.highlightAngle = highlightAngle
        self.highlightAnimates = highlightAnimates
        self.dimmed = dimmed
        self.geometry = geometry
        self.accessibilityHint = accessibilityHint
        self.hub = hub()
    }

    var body: some View {
        let radius = geometry.diameter / 2
        return ZStack {
            Circle()
                .fill(.clear)
                .wheelBackground(in: Circle())
            highlight
            separators
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let center = geometry.labelCenter(ofSlice: index)
                sliceLabel(slice, isHovered: hovered == index)
                    .position(x: radius + center.x, y: radius - center.y)
            }
            hub
        }
        .frame(width: geometry.diameter, height: geometry.diameter)
    }

    private var highlight: some View {
        let isEnabled = hovered.map { slices[$0].isEnabled } ?? true
        return AnnularSector(
            sweep: geometry.sliceCount > 0 ? 2 * .pi / Double(geometry.sliceCount) : 0,
            innerRadius: geometry.hubDiameter / 2
        )
        .fill(isEnabled ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
        .rotationEffect(.radians(highlightAngle))
        .animation(highlightAnimates && !reduceMotion ? .spring(duration: 0.18) : nil, value: highlightAngle)
        .opacity(hovered == nil ? 0 : 1)
        .accessibilityHidden(true)
    }

    private var separators: some View {
        let geometry = geometry
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = geometry.diameter / 2
            let inner = geometry.hubDiameter / 2
            var path = Path()
            if geometry.sliceCount > 1 {
                let sweep = 2 * .pi / Double(geometry.sliceCount)
                for index in 0..<geometry.sliceCount {
                    // Boundaries sit half a slice counter-clockwise of each centre; y is flipped for SwiftUI.
                    let angle = geometry.centerAngle(ofSlice: index) - sweep / 2
                    path.move(to: CGPoint(x: center.x + inner * sin(angle), y: center.y - inner * cos(angle)))
                    path.addLine(to: CGPoint(x: center.x + outer * sin(angle), y: center.y - outer * cos(angle)))
                }
            }
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            context.stroke(path, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func sliceLabel(_ slice: WheelSlice, isHovered: Bool) -> some View {
        let onAccent = isHovered && slice.isEnabled
        return VStack(spacing: 3) {
            Image(systemName: slice.symbol)
                .font(.system(size: 18, weight: .medium))
            Text(slice.title)
                .font(.system(size: 11, weight: isHovered ? .semibold : .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 76)
        .foregroundStyle(onAccent ? Color.white : Color.primary)
        .opacity(slice.isEnabled && !dimmed ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slice.title)
        .accessibilityHint(accessibilityHint(slice))
        .accessibilityAddTraits(isHovered ? .isSelected : [])
    }
}

extension WheelGeometry {
    /// The highlight's rotation onto slice `index`: from `angle` the short way round (unwrapped, so it never spins
    /// back), or straight there when nothing was lit.
    func highlightAngle(toSlice index: Int, from angle: Double?) -> Double {
        let target = centerAngle(ofSlice: index)
        guard let angle else { return target }
        return angle + remainder(target - angle, 2 * .pi)
    }
}

/// An annular sector of `sweep` radians from `innerRadius` to the shape's edge, centred `centerAngle` radians clockwise
/// from 12 o'clock: the wheel's highlight, and a slice's hit area in the wheel editor.
struct AnnularSector: Shape {
    var sweep: Double
    var innerRadius: CGFloat
    var centerAngle = 0.0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        // SwiftUI angles start at 3 o'clock and grow clockwise on screen, so 12 o'clock is -90°.
        let start = Angle.radians(centerAngle - .pi / 2 - sweep / 2)
        var path = Path()
        path.addRelativeArc(center: center, radius: outer, startAngle: start, delta: .radians(sweep))
        path.addRelativeArc(center: center, radius: innerRadius, startAngle: start + .radians(sweep),
                            delta: .radians(-sweep))
        path.closeSubpath()
        return path
    }
}

extension EnvironmentValues {
    /// Forces the solid Reduce Transparency background: for the DEBUG snapshot, whose ImageRenderer draws neither
    /// glass nor materials, and for the Settings editor's ring, where glass over a plain pane would barely show.
    @Entry var wheelSolidBackground = false
    /// The solid background's fill. The editor's ring sits on the Settings pane, whose own colour is the window's.
    @Entry var wheelSolidFill = Color(nsColor: .windowBackgroundColor)
}

struct WheelBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.wheelSolidBackground) private var solidBackground
    @Environment(\.wheelSolidFill) private var solidFill

    func body(content: Content) -> some View {
        if reduceTransparency || solidBackground {
            content
                .background(solidFill, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Glass on macOS 26, a thin material before it, and solid window background under Reduce Transparency.
    func wheelBackground<S: Shape>(in shape: S) -> some View {
        modifier(WheelBackground(shape: shape))
    }
}
