// The Crop editor (P27): the picture upright, the area to keep over it with handles, a ratio picker and keys for
// all of it. The rectangle is `CropModel`'s, in the upright picture's pixels, so what the engines cut is what shows
// here (global constraints, Coordinates).
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

enum CropAction: Equatable {
    case move(dx: Int, dy: Int, coarse: Bool)
    /// From the bottom-right corner.
    case resize(dx: Int, dy: Int, coarse: Bool)
}

/// The crop area's keys, read while it has focus in the key panel (never through a key monitor).
enum CropKeys {
    static func action(for press: KeyPress) -> CropAction? {
        action(for: press.key, modifiers: press.modifiers)
    }

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> CropAction? {
        // Arrow keys also carry the numeric-pad and function flags, which mean nothing here.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        let (dx, dy): (Int, Int)
        switch key {
        case .leftArrow: (dx, dy) = (-1, 0)
        case .rightArrow: (dx, dy) = (1, 0)
        case .upArrow: (dx, dy) = (0, -1)
        case .downArrow: (dx, dy) = (0, 1)
        default: return nil
        }
        let coarse = held.contains(.shift)
        switch held.subtracting(.shift) {
        case []: return .move(dx: dx, dy: dy, coarse: coarse)
        case .option: return .resize(dx: dx, dy: dy, coarse: coarse)
        default: return nil
        }
    }
}

@MainActor
final class CropSession: EditorSession, ObservableObject {
    static let contentWidth: CGFloat = 488
    static let previewMaxSize = CGSize(width: contentWidth, height: 340)
    static let previewPixels = 1200

    let title = "Crop"
    let confirmTitle = "Save Cropped Copy"
    let file: URL
    let isVideo: Bool
    var onChange: (() -> Void)?
    var onChoicesChanged: (() -> Void)?

    /// nil until the picture's upright size is known.
    var model: CropModel? {
        willSet { objectWillChange.send() }
        didSet {
            if oldValue?.spec != model?.spec { onChoicesChanged?() }
            // The controller lays the whole chrome out again, so it hears of what the footer shows, not of each
            // pointer move.
            guard oldValue?.blocker != model?.blocker || (oldValue == nil) != (model == nil) else { return }
            onChange?()
        }
    }

    @Published private(set) var preview: CGImage?
    @Published private(set) var durationSeconds: Double?
    /// Where the video frame on show was taken.
    @Published var frameSeconds: Double = 0
    /// While a handle or the area is dragged, so the thirds show.
    @Published private(set) var isDragging = false
    @Published private(set) var loadFailed = false {
        didSet { onChange?() }
    }

    private let remembered: CropRatio
    private var dragStart: CropModel?
    private var frameTask: Task<Void, Never>?

    init(request: EditorRequest, memory: EditorMemory) {
        file = request.files[0]
        isVideo = FormatRegistry.builtIn.format(for: request.files[0])?.category == .video
        remembered = CropRatio(rawValue: memory.cropRatio) ?? .free
    }

    var blocker: String? {
        if loadFailed { return "The file may be damaged" }
        guard let model else { return "Reading the file\u{2026}" }
        return model.blocker
    }

    var note: String? {
        isVideo ? "Re-encodes the video" : "Saves a new file at the same quality"
    }

    func load() async {
        guard let picture = await EditorMedia.picture(of: file) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        durationSeconds = picture.info.durationSeconds
        model = CropModel(pixelSize: picture.size, ratio: remembered)
        let preview = await EditorMedia.preview(of: file, maxPixelSize: Self.previewPixels)
        guard !Task.isCancelled else { return }
        self.preview = preview
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = model?.spec
        return options
    }

    func remember(into memory: inout EditorMemory) {
        guard let model else { return }
        memory.cropRatio = model.ratio.rawValue
    }

    func makeContent() -> AnyView {
        AnyView(CropEditorView(session: self))
    }

    // MARK: Actions

    func setRatio(_ ratio: CropRatio) {
        model?.setRatio(ratio)
    }

    func flip() {
        model?.flip()
    }

    /// A key's action; false when the file is not read yet, so the key goes on to the panel.
    @discardableResult
    func perform(_ action: CropAction) -> Bool {
        guard model != nil else { return false }
        switch action {
        case .move(let dx, let dy, let coarse): model?.nudge(.body, dx: dx, dy: dy, coarse: coarse)
        case .resize(let dx, let dy, let coarse): model?.nudge(.bottomRight, dx: dx, dy: dy, coarse: coarse)
        }
        return true
    }

    /// `translation` is the pointer's whole way since the drag began, in fractions of the picture, so the handle
    /// stays under the pointer even after the rectangle stopped at an edge.
    func drag(_ handle: CropHandle, translation: CGSize) {
        if dragStart == nil {
            dragStart = model
            isDragging = true
        }
        guard var moved = dragStart else { return }
        moved.drag(handle, by: translation)
        model = moved
    }

    func endDrag() {
        dragStart = nil
        isDragging = false
    }

    /// Shows the video's frame at `seconds`; a newer choice replaces one still loading.
    func showFrame(at seconds: Double) {
        frameSeconds = seconds
        frameTask?.cancel()
        frameTask = Task { [file] in
            let frame = await EditorMedia.frame(of: file, at: seconds, maxPixelSize: Self.previewPixels)
            guard !Task.isCancelled, let frame else { return }
            self.preview = frame
        }
    }

    func tearDown() {
        frameTask?.cancel()
        frameTask = nil
    }
}

// MARK: - Views

struct CropEditorView: View {
    @ObservedObject var session: CropSession

    var body: some View {
        VStack(spacing: 8) {
            CropCanvas(session: session)
            if session.isVideo { frameSlider }
            controls
        }
        .frame(width: CropSession.contentWidth)
        .frame(maxWidth: .infinity)
        .onDisappear { session.tearDown() }
    }

    private var frameSlider: some View {
        HStack(spacing: 8) {
            Text("Frame")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { session.frameSeconds }, set: { session.showFrame(at: $0) }),
                   in: 0...max(0.01, session.durationSeconds ?? 0.01))
                .controlSize(.small)
                .accessibilityLabel("Frame")
                .accessibilityValue(TimeFormat.clock(session.frameSeconds))
        }
        .disabled(session.durationSeconds == nil)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Ratio", selection: Binding(get: { session.model?.ratio ?? .free }, set: { session.setRatio($0) })) {
                ForEach(CropRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Ratio")
            if session.model?.ratio.canFlip == true {
                Button(action: session.flip) {
                    Image(systemName: Self.flipSymbol)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(session.model?.isPortrait == true ? "Make Landscape" : "Make Portrait")
                .help("Turn the ratio")
            }
            Spacer(minLength: 8)
            Text(session.model?.readout ?? " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                // The crop area says its size to VoiceOver.
                .accessibilityHidden(true)
        }
        // Regular-size segments leave no room for a readout such as "12000 × 9000" in the panel's width.
        .controlSize(.small)
        .disabled(session.model == nil)
    }

    /// macOS 14 has no `arrow.trianglehead…` symbols.
    static var flipSymbol: String {
        if #available(macOS 15, *) { "arrow.trianglehead.2.clockwise.rotate.90" } else { "rotate.right" }
    }
}

/// The picture with the area to keep over it: the rest dimmed, a white frame, handles, and the thirds while
/// dragging. It takes the keys while focused and the mouse through in-panel drags only, which never touch the drag
/// pasteboard, so the wheel can't open.
struct CropCanvas: View {
    @ObservedObject var session: CropSession
    @FocusState private var focused: Bool

    static let handleSize: CGFloat = 14
    private static let space = "crop"

    var body: some View {
        let size = EditorPicture.fitted(session.model?.pixelSize, into: CropSession.previewMaxSize,
                                        until: CGSize(width: 4, height: 3))
        ZStack(alignment: .topLeading) {
            ZStack {
                Color(nsColor: .quaternaryLabelColor)
                if let preview = session.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }
                if let model = session.model { dimming(model, in: size) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            // Unclipped, so the knobs at the picture's corners show whole.
            if let model = session.model { overlay(model, in: size) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .editorKeys($focused) { press in CropKeys.action(for: press).map(session.perform) ?? false }
        .help("Arrow keys move the area; Option-arrow keys resize it")
    }

    private static func box(_ model: CropModel, in size: CGSize) -> CGRect {
        CGRect(x: model.rect.x * size.width, y: model.rect.y * size.height,
               width: model.rect.width * size.width, height: model.rect.height * size.height)
    }

    private func dimming(_ model: CropModel, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(Self.box(model, in: size))
        }
        .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func overlay(_ model: CropModel, in size: CGSize) -> some View {
        let box = Self.box(model, in: size)
        return ZStack(alignment: .topLeading) {
            if session.isDragging { thirds(in: box) }
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .allowsHitTesting(false)
            area(model, box: box, in: size)
            ForEach(model.handles().filter { $0 != .body }, id: \.self) { handle in
                knob(handle, at: Self.point(of: handle, in: box), in: size)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func thirds(in box: CGRect) -> some View {
        Path { path in
            for third in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: box.minX + box.width * third, y: box.minY))
                path.addLine(to: CGPoint(x: box.minX + box.width * third, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: box.minY + box.height * third))
                path.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * third))
            }
        }
        .stroke(.white.opacity(0.6), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    /// The area itself: dragged to move it, and VoiceOver's one element for it.
    private func area(_ model: CropModel, box: CGRect, in size: CGSize) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: max(1, box.width), height: max(1, box.height))
            .offset(x: box.minX, y: box.minY)
            .gesture(drag(.body, in: size))
            .accessibilityElement()
            .accessibilityLabel("Crop area")
            .accessibilityValue(model.readout)
            .accessibilityAction(named: "Move Left") { session.perform(.move(dx: -1, dy: 0, coarse: true)) }
            .accessibilityAction(named: "Move Right") { session.perform(.move(dx: 1, dy: 0, coarse: true)) }
            .accessibilityAction(named: "Move Up") { session.perform(.move(dx: 0, dy: -1, coarse: true)) }
            .accessibilityAction(named: "Move Down") { session.perform(.move(dx: 0, dy: 1, coarse: true)) }
            .accessibilityAction(named: "Wider") { session.perform(.resize(dx: 1, dy: 0, coarse: true)) }
            .accessibilityAction(named: "Narrower") { session.perform(.resize(dx: -1, dy: 0, coarse: true)) }
            .accessibilityAction(named: "Taller") { session.perform(.resize(dx: 0, dy: 1, coarse: true)) }
            .accessibilityAction(named: "Shorter") { session.perform(.resize(dx: 0, dy: -1, coarse: true)) }
    }

    private func knob(_ handle: CropHandle, at point: CGPoint, in size: CGSize) -> some View {
        EditorKnob(diameter: Self.handleSize)
            // A larger target than the knob, which is small for a pointer.
            .contentShape(Rectangle().inset(by: -4))
            .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
            .gesture(drag(handle, in: size))
            .accessibilityHidden(true)
    }

    private func drag(_ handle: CropHandle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                session.drag(handle, translation: CGSize(width: value.translation.width / size.width,
                                                         height: value.translation.height / size.height))
            }
            .onEnded { _ in session.endDrag() }
    }

    static func point(of handle: CropHandle, in box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: box.minX, y: box.minY)
        case .top: CGPoint(x: box.midX, y: box.minY)
        case .topRight: CGPoint(x: box.maxX, y: box.minY)
        case .right: CGPoint(x: box.maxX, y: box.midY)
        case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
        case .bottom: CGPoint(x: box.midX, y: box.maxY)
        case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
        case .left: CGPoint(x: box.minX, y: box.midY)
        case .body: CGPoint(x: box.midX, y: box.midY)
        }
    }
}
