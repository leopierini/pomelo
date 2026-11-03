// The Redact editor (P27): the picture upright, with the boxes that will be hidden drawn the way they will look
// (black, or pixelated by the engine's own block rule) and the ones left alone dashed. Detection proposes boxes
// after the panel is up; a click toggles one, a drag on the picture draws one by hand. Boxes are `UnitRect`s of the
// upright picture, so what is hidden here is what the engine hides (global constraints, Coordinates).
import AppKit
import PomeloCore
import PomeloEngines
import PomeloUIModel
import SwiftUI

// MARK: - Preview pixels

/// The preview as pixels, for drawing the boxes into a copy of it. Pixelation uses the engine's block rule on the
/// picture's full size and maps the blocks onto the preview, so the preview shows the blocks that will be saved.
struct RedactionRaster: Sendable {
    let width: Int
    let height: Int
    let fullWidth: Int
    let fullHeight: Int
    private let pixels: [UInt8]

    init?(image: CGImage, fullSize: CGSize) {
        let (width, height) = (image.width, image.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        fullWidth = max(1, Int(fullSize.width.rounded()))
        fullHeight = max(1, Int(fullSize.height.rounded()))
        pixels = buffer
    }

    /// The picture with every box in `boxes` replaced, in the order given (an overlap pixelates what an earlier box
    /// left, as the engine does).
    func image(hiding boxes: [UnitRect], style: RedactionStyle) -> CGImage? {
        var buffer = pixels
        for box in boxes {
            let full = box.pixels(width: fullWidth, height: fullHeight)
            guard full.width > 0, full.height > 0 else { continue }
            let blocks = style == .pixelate ? ImageIOEngine.pixelationBlocks(of: full) : nil
            if let blocks {
                for block in blocks {
                    let area = onPreview(block)
                    let rect = CGRect(x: area.x0, y: area.y0, width: area.x1 - area.x0, height: area.y1 - area.y0)
                    let colour = buffer.withUnsafeBufferPointer { pixels in
                        ImageIOEngine.mean(of: rect, in: pixels.baseAddress!, width: width, alpha: true)
                    }
                    paint(area, colour, in: &buffer)
                }
            } else {
                paint(onPreview(full), (0, 0, 0), in: &buffer)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// A rectangle of the full-size picture as whole preview pixels: neighbouring blocks share their edges, and a
    /// box that exists is at least one pixel.
    private func onPreview(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        func edge(_ value: CGFloat, full: Int, preview: Int) -> Int {
            Int((value * CGFloat(preview) / CGFloat(full)).rounded())
        }
        var x0 = edge(rect.minX, full: fullWidth, preview: width)
        var y0 = edge(rect.minY, full: fullHeight, preview: height)
        var x1 = edge(rect.maxX, full: fullWidth, preview: width)
        var y1 = edge(rect.maxY, full: fullHeight, preview: height)
        x0 = min(max(x0, 0), width - 1)
        y0 = min(max(y0, 0), height - 1)
        x1 = min(max(x1, x0 + 1), width)
        y1 = min(max(y1, y0 + 1), height)
        return (x0, y0, x1, y1)
    }

    private func paint(_ area: (x0: Int, y0: Int, x1: Int, y1: Int), _ colour: (UInt8, UInt8, UInt8), in buffer: inout [UInt8]) {
        for y in area.y0..<area.y1 {
            for x in area.x0..<area.x1 {
                let offset = (y * width + x) * 4
                (buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3]) = (colour.0, colour.1, colour.2, 255)
            }
        }
    }
}

// MARK: - Keys

enum RedactAction: Equatable {
    /// Tab and ⇧Tab choose the box; past the last or the first, focus goes on to the controls.
    case tab(forward: Bool)
    /// A drawn box moves; with `resize`, grows from its bottom-right corner. Sideways on a found box it chooses
    /// the previous or next one.
    case arrow(dx: Int, dy: Int, resize: Bool, coarse: Bool)
    case toggle
    case remove
}

/// The picture's keys, read while it has focus in the key panel (never through a key monitor).
enum RedactKeys {
    static func action(for press: KeyPress) -> RedactAction? {
        action(for: press.key, modifiers: press.modifiers)
    }

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> RedactAction? {
        // Arrow keys also carry the numeric-pad and function flags, which mean nothing here.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        switch key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            let (dx, dy): (Int, Int) = switch key {
            case .leftArrow: (-1, 0)
            case .rightArrow: (1, 0)
            case .upArrow: (0, -1)
            default: (0, 1)
            }
            let coarse = held.contains(.shift)
            switch held.subtracting(.shift) {
            case []: return .arrow(dx: dx, dy: dy, resize: false, coarse: coarse)
            case .option: return .arrow(dx: dx, dy: dy, resize: true, coarse: coarse)
            default: return nil
            }
        case .space:
            return held.isEmpty ? .toggle : nil
        case .tab:
            if held.isEmpty { return .tab(forward: true) }
            return held == .shift ? .tab(forward: false) : nil
        // AppKit types ⇧Tab as the back-tab character.
        case KeyEquivalent("\u{19}"):
            return held.subtracting(.shift).isEmpty ? .tab(forward: false) : nil
        // SwiftUI's `delete` is U+0008, but AppKit's Delete key types U+007F: both, and forward delete, remove.
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
            return held.isEmpty ? .remove : nil
        default:
            return nil
        }
    }
}

// MARK: - Session

@MainActor
final class RedactSession: EditorSession, ObservableObject {
    static let previewMaxSize = CGSize(width: 568, height: 360)
    static let shownPixels = 1600
    static let detectionPixels = 3072
    /// A key press moves a drawn box by this fraction of the picture, ten times as far with ⇧.
    static let keyStep = 0.005
    /// A pointer that moves less than this is a click.
    static let clickSlop: CGFloat = 4
    static let cornerGrab: CGFloat = 10

    let title = "Redact"
    let confirmTitle = "Save Redacted Copy"
    let file: URL
    var onChange: (() -> Void)?
    var onChoicesChanged: (() -> Void)?

    /// nil until the picture is read. Changing it redraws the picture when a box that is on or the style changed,
    /// and tells the controller only when the footer's line would change.
    var model: RedactionModel? {
        willSet { objectWillChange.send() }
        didSet {
            if oldValue?.style != model?.style || Self.hidden(oldValue) != Self.hidden(model) { redraw() }
            if oldValue?.spec != model?.spec { onChoicesChanged?() }
            if lastFooter.update(from: self) { onChange?() }
        }
    }

    @Published private(set) var shown: CGImage?
    @Published private(set) var pixelSize: CGSize?
    @Published private(set) var isDetecting = false
    @Published private(set) var draft: UnitRect?
    @Published private(set) var loadFailed = false {
        didSet { onChange?() }
    }
    /// Bumped when the keys should move to the picture (after Add Box).
    @Published private(set) var focusRequests = 0


    /// A drag in progress keeps the box's id and where it started, never a copy of the model: detection can add
    /// boxes while the pointer is down.
    private enum Pointer {
        case drawing
        case moving(id: Int, start: UnitRect)
        case corner(RedactionCorner, id: Int, start: UnitRect)
    }

    /// Finds the regions in a picture; tests give one they can hold back.
    typealias Detector = @Sendable (CGImage) async throws -> [DetectedRegion]

    private let remembered: RedactionStyle
    private let detector: Detector
    private var raster: RedactionRaster?
    private var lastFooter = EditorFooter()
    private var pointer: Pointer?

    init(
        request: EditorRequest, memory: EditorMemory,
        detector: @escaping Detector = { try await RedactionDetector.detect(in: $0) }
    ) {
        file = request.files[0]
        remembered = memory.redactionStyle
        self.detector = detector
        lastFooter = EditorFooter(of: self)
    }

    var blocker: String? {
        if loadFailed { return "The file may be damaged" }
        guard let model else { return "Reading the file\u{2026}" }
        // P88: a save before the scan ends could miss a face the person expected to be found.
        return isDetecting ? RedactionModel.lookingStatus : model.blocker
    }

    var note: String? {
        guard let model else { return nil }
        let hidesText = model.boxes.contains { $0.isOn && ($0.kind == .email || $0.kind == .text) }
        if model.style == .pixelate, hidesText { return "Black boxes are safest for text" }
        return "Location and other metadata are removed too"
    }

    var status: String {
        guard let model else { return " " }
        if isDetecting { return RedactionModel.lookingStatus }
        return RedactionModel.status(faces: model.count(.face), emails: model.count(.email), text: model.count(.text))
    }

    func load() async {
        guard let size = await EditorMedia.picture(of: file)?.size,
              let preview = await EditorMedia.preview(of: file, maxPixelSize: Self.shownPixels),
              let raster = RedactionRaster(image: preview, fullSize: size) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        self.raster = raster
        pixelSize = size
        isDetecting = true
        model = RedactionModel(regions: [], style: remembered)
        redraw()

        let found = await Self.detect(file, with: detector)
        guard !Task.isCancelled else { return }
        edit { $0.insertDetected(found.map { (Self.kind(of: $0.kind), $0.rect) }) }
        isDetecting = false
        lastFooter = EditorFooter(of: self)
        onChange?()
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = model?.spec
        return options
    }

    func remember(into memory: inout EditorMemory) {
        guard let model else { return }
        memory.redactionStyle = model.style
    }

    func makeContent() -> AnyView {
        AnyView(RedactionEditorView(session: self))
    }

    // MARK: Choices

    func setStyle(_ style: RedactionStyle) {
        edit { $0.style = style }
    }

    func setOn(_ id: Int, _ on: Bool) {
        edit { $0.setOn(id, on) }
    }

    /// A click or VoiceOver's press: chooses the box and flips it.
    func toggle(_ id: Int) {
        edit {
            $0.select(id)
            $0.toggle(id)
        }
    }

    /// A box in the middle, 25% of the shorter side, chosen so the keys move it.
    func addCentredBox() {
        guard let size = pixelSize else { return }
        let side = 0.25 * min(size.width, size.height)
        let (width, height) = (side / size.width, side / size.height)
        edit { _ = $0.addManual(UnitRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)) }
        focusRequests += 1
    }

    /// A key's action; false when it isn't one for the picture's box, so the key goes on (Tab to the next control).
    @discardableResult
    func perform(_ action: RedactAction) -> Bool {
        guard let model else { return false }
        let drawn = model.boxes.first { $0.id == model.selected }?.kind == .manual
        switch action {
        case .tab(let forward):
            return edit { forward ? $0.selectNext() : $0.selectPrevious() } ?? false
        case .toggle:
            guard let id = model.selected else { return false }
            edit { $0.toggle(id) }
            return true
        case .remove:
            guard drawn else { return false }
            edit { $0.removeSelected() }
            return true
        case .arrow(let dx, let dy, let resize, let coarse):
            let amount = Self.keyStep * (coarse ? 10 : 1)
            if resize {
                guard drawn else { return false }
                edit { $0.resizeSelected(dw: Double(dx) * amount, dh: Double(dy) * amount) }
            } else if drawn {
                edit { $0.moveSelected(dx: Double(dx) * amount, dy: Double(dy) * amount) }
            } else {
                guard dy == 0 else { return false }
                return edit { dx < 0 ? $0.selectPrevious() : $0.selectNext() } ?? false
            }
            return true
        }
    }

    func step(_ id: Int, dx: Int, dy: Int, resize: Bool) {
        edit { $0.select(id) }
        perform(.arrow(dx: dx, dy: dy, resize: resize, coarse: true))
    }

    func remove(_ id: Int) {
        edit {
            $0.select(id)
            $0.removeSelected()
        }
    }

    // MARK: Pointer

    /// A drag's progress, in points of the picture `size`. A move shorter than the click slop waits; past it the
    /// press began on a corner handle (resize), on a drawn box (move) or elsewhere (draw a new box), found by
    /// where it began.
    func pointerChanged(from start: CGPoint, to location: CGPoint, in size: CGSize) {
        guard let model, size.width > 0, size.height > 0 else { return }
        if pointer == nil {
            guard hypot(location.x - start.x, location.y - start.y) >= Self.clickSlop else { return }
            if let corner = corner(at: start, in: size), let id = model.selected,
               let box = model.boxes.first(where: { $0.id == id }) {
                pointer = .corner(corner, id: id, start: box.rect)
            } else if let id = model.box(at: Self.unit(start, in: size)),
                      let box = model.boxes.first(where: { $0.id == id }), box.kind == .manual {
                edit { $0.select(id) }
                pointer = .moving(id: id, start: box.rect)
            } else {
                pointer = .drawing
            }
        }
        let from = Self.unit(start, in: size)
        let to = Self.unit(location, in: size)
        switch pointer {
        case .drawing:
            draft = RedactionModel.rect(from: from, to: to)
        case .moving(let id, let origin):
            let moved = RedactionModel.rect(moving: origin, dx: Double(to.x - from.x), dy: Double(to.y - from.y))
            edit { $0.setRect(of: id, to: moved) }
        case .corner(let corner, let id, let origin):
            if let moved = RedactionModel.rect(dragging: corner, of: origin, to: to) {
                edit { $0.setRect(of: id, to: moved) }
            }
        case nil:
            break
        }
    }

    func pointerEnded(from start: CGPoint, in size: CGSize) {
        defer {
            pointer = nil
            draft = nil
        }
        guard let model, size.width > 0, size.height > 0 else { return }
        switch pointer {
        case .drawing:
            if let draft { edit { _ = $0.addManual(draft) } }
        case .moving, .corner:
            break
        case nil:
            guard corner(at: start, in: size) == nil else { return }
            if let id = model.box(at: Self.unit(start, in: size)) {
                toggle(id)
            } else {
                edit { $0.select(nil) }
            }
        }
    }

    func corner(at point: CGPoint, in size: CGSize) -> RedactionCorner? {
        guard let model, let selected = model.selected,
              let box = model.boxes.first(where: { $0.id == selected }), box.kind == .manual else { return nil }
        let corners: [(RedactionCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: box.rect.x, y: box.rect.y)),
            (.topRight, CGPoint(x: box.rect.x + box.rect.width, y: box.rect.y)),
            (.bottomLeft, CGPoint(x: box.rect.x, y: box.rect.y + box.rect.height)),
            (.bottomRight, CGPoint(x: box.rect.x + box.rect.width, y: box.rect.y + box.rect.height)),
        ]
        return corners
            .map { ($0.0, hypot($0.1.x * size.width - point.x, $0.1.y * size.height - point.y)) }
            .filter { $0.1 <= Self.cornerGrab }
            .min { $0.1 < $1.1 }?.0
    }

    static func unit(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    // MARK: Private

    /// A change that leaves the model equal is not stored, so a key that does nothing redraws nothing.
    @discardableResult
    private func edit<T>(_ change: (inout RedactionModel) -> T) -> T? {
        guard var copy = model else { return nil }
        let result = change(&copy)
        if copy != model { model = copy }
        return result
    }

    private func redraw() {
        guard let raster, let model else { return }
        shown = raster.image(hiding: Self.hidden(model), style: model.style)
    }

    private static func hidden(_ model: RedactionModel?) -> [UnitRect] {
        model?.boxes.filter(\.isOn).map(\.rect) ?? []
    }

    private static func kind(of kind: DetectedRegion.Kind) -> RedactionKind {
        switch kind {
        case .face: .face
        case .email: .email
        case .text: .text
        }
    }

    /// Decodes a larger preview than the one shown and runs Vision on it, off the main thread; closing the editor
    /// cancels it. A failure proposes nothing: the person can still draw boxes.
    private static func detect(_ file: URL, with detector: @escaping Detector) async -> [DetectedRegion] {
        let work = Task.detached(priority: .userInitiated) { () -> [DetectedRegion] in
            guard let image = await EditorMedia.preview(of: file, maxPixelSize: detectionPixels) else { return [] }
            return (try? await detector(image)) ?? []
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}

// MARK: - Views

struct RedactionEditorView: View {
    @ObservedObject var session: RedactSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                RedactionCanvas(session: session)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                kindToggle("Faces", .face)
                kindToggle("Email addresses", .email)
                kindToggle("Other text", .text)
                Spacer(minLength: 8)
                Button("Add Box", action: session.addCentredBox)
                    .controlSize(.small)
                    .help("Adds a box in the middle; the arrow keys move it")
            }
            HStack(spacing: 8) {
                Picker("Style", selection: Binding(get: { session.model?.style ?? .fill }, set: session.setStyle)) {
                    Text("Black Box").tag(RedactionStyle.fill)
                    Text("Pixelate").tag(RedactionStyle.pixelate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityLabel("Style")
                Spacer(minLength: 8)
                Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .disabled(session.model == nil)
    }

    private func kindToggle(_ title: String, _ kind: RedactionKind) -> some View {
        let ids = session.model?.boxes.filter { $0.kind == kind }.map(\.id) ?? []
        let sources = ids.map { id in
            Binding(get: { session.model?.boxes.first { $0.id == id }?.isOn ?? false },
                    set: { session.setOn(id, $0) })
        }
        let label = "\(title) (\(ids.count))"
        // With no source a `Toggle(sources:)` draws as checked.
        return Group {
            if ids.isEmpty {
                Toggle(label, isOn: .constant(false)).disabled(true)
            } else {
                Toggle(label, sources: sources, isOn: \.self)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

/// The picture with its boxes. It takes the keys while focused and the mouse through in-panel drags only, which
/// never touch the drag pasteboard, so the wheel can't open.
struct RedactionCanvas: View {
    @ObservedObject var session: RedactSession
    @FocusState private var focused: Bool

    private static let space = "redact"
    private static let handleSize: CGFloat = 12

    var body: some View {
        let size = EditorPicture.fitted(session.pixelSize, into: RedactSession.previewMaxSize,
                                        until: CGSize(width: 3, height: 2))
        ZStack(alignment: .topLeading) {
            ZStack {
                Color(nsColor: .quaternaryLabelColor)
                if let shown = session.shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            if let model = session.model {
                outlines(model, in: size)
                if let draft = session.draft { dashed(Self.frame(of: draft, in: size)) }
                ForEach(model.boxes) { box in element(box, model, in: size) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { session.pointerChanged(from: $0.startLocation, to: $0.location, in: size) }
            .onEnded { session.pointerEnded(from: $0.startLocation, in: size) })
        .editorKeys($focused) { press in RedactKeys.action(for: press).map(session.perform) ?? false }
        .onChange(of: session.focusRequests) { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Redaction boxes")
        .accessibilityHint("Tab chooses a box, Space hides or shows it")
        .help("Click a box to hide or show it; drag to draw one. Tab and arrow keys choose a box, Space toggles it")
    }

    private static func frame(of rect: UnitRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width,
               height: rect.height * size.height)
    }

    /// White over a dark shadow, so a box left alone reads on any photo.
    private func outlines(_ model: RedactionModel, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.boxes) { box in
                let frame = Self.frame(of: box.rect, in: size)
                if !box.isOn { dashed(frame) }
                if box.id == model.selected {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    if box.kind == .manual {
                        ForEach(Array(corners(of: frame).enumerated()), id: \.offset) { handle($0.element) }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func corners(of frame: CGRect) -> [CGPoint] {
        [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
         CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
    }

    private func handle(_ point: CGPoint) -> some View {
        EditorKnob(diameter: Self.handleSize)
            .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
    }

    private func dashed(_ frame: CGRect) -> some View {
        Rectangle()
            .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .shadow(color: .black.opacity(0.7), radius: 1)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
    }

    private func element(_ box: RedactionBox, _ model: RedactionModel, in size: CGSize) -> some View {
        let frame = Self.frame(of: box.rect, in: size)
        return Color.clear
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(model.label(of: box.id))
            .accessibilityValue(box.isOn ? "will be hidden" : "will stay visible")
            .accessibilityAddTraits(box.id == model.selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.toggle(box.id) }
            .modifier(DrawnBoxActions(isDrawn: box.kind == .manual, id: box.id, session: session))
    }
}

private struct DrawnBoxActions: ViewModifier {
    let isDrawn: Bool
    let id: Int
    let session: RedactSession

    func body(content: Content) -> some View {
        if isDrawn {
            content
                .accessibilityAction(named: "Move Left") { session.step(id, dx: -1, dy: 0, resize: false) }
                .accessibilityAction(named: "Move Right") { session.step(id, dx: 1, dy: 0, resize: false) }
                .accessibilityAction(named: "Move Up") { session.step(id, dx: 0, dy: -1, resize: false) }
                .accessibilityAction(named: "Move Down") { session.step(id, dx: 0, dy: 1, resize: false) }
                .accessibilityAction(named: "Wider") { session.step(id, dx: 1, dy: 0, resize: true) }
                .accessibilityAction(named: "Narrower") { session.step(id, dx: -1, dy: 0, resize: true) }
                .accessibilityAction(named: "Taller") { session.step(id, dx: 0, dy: 1, resize: true) }
                .accessibilityAction(named: "Shorter") { session.step(id, dx: 0, dy: -1, resize: true) }
                .accessibilityAction(named: "Remove Box") { session.remove(id) }
        } else {
            content
        }
    }
}
