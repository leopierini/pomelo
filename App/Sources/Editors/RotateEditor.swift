// The Rotate editor (P198): a large preview of the first file showing the result, four buttons and ← → to turn it.
// The preview is the upright picture drawn through `RotateSpec.transform`, the mapping the engines use, so what shows
// is what is saved.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

enum RotateAction: CaseIterable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var title: String {
        switch self {
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    var symbol: String {
        switch self {
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .flipHorizontal: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .flipVertical: "arrow.up.and.down.righttriangle.up.righttriangle.down"
        }
    }

    var help: String {
        switch self {
        case .rotateLeft: "Rotate Left (\u{2190})"
        case .rotateRight: "Rotate Right (\u{2192})"
        case .flipHorizontal, .flipVertical: title
        }
    }

    func applied(to spec: RotateSpec) -> RotateSpec {
        switch self {
        case .rotateLeft: spec.rotatedLeft()
        case .rotateRight: spec.rotatedRight()
        case .flipHorizontal: spec.flippedHorizontally()
        case .flipVertical: spec.flippedVertically()
        }
    }
}

/// The preview's keys, read while it has focus in the key panel (never through a key monitor).
enum RotateKeys {
    static func action(for press: KeyPress) -> RotateAction? {
        action(for: press.key, modifiers: press.modifiers)
    }

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> RotateAction? {
        // Arrow keys also carry the numeric-pad and function flags, which mean nothing here.
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch key {
        case .leftArrow: return .rotateLeft
        case .rightArrow: return .rotateRight
        default: return nil
        }
    }
}

@MainActor
final class RotateSession: EditorSession, ObservableObject {
    static let contentWidth: CGFloat = 488
    static let previewBounds = CGSize(width: contentWidth, height: 340)
    static let previewPixels = 1200

    let title = "Rotate"
    var onChange: (() -> Void)?

    @Published private(set) var spec = RotateSpec.identity {
        didSet { onChange?() }
    }

    /// The first file's upright size; nil until read.
    @Published private(set) var pixelSize: CGSize? {
        didSet { onChange?() }
    }
    @Published private(set) var preview: CGImage?
    @Published private(set) var loadFailed = false {
        didSet { onChange?() }
    }

    /// The last button or key, and how many there have been, so the preview animates from where it was.
    private(set) var lastAction: RotateAction?
    @Published private(set) var actionCount = 0

    private let files: [URL]
    private let hasVideo: Bool

    init(request: EditorRequest) {
        files = request.files
        hasVideo = request.files.contains { FormatRegistry.builtIn.format(for: $0)?.category == .video }
    }

    var confirmTitle: String {
        files.count > 1 ? "Save \(files.count) Rotated Copies" : "Save Rotated Copy"
    }

    var blocker: String? {
        if loadFailed { return "The file may be damaged" }
        // A turn is saved only once the picture it applies to has been shown.
        guard pixelSize != nil else { return "Reading the file\u{2026}" }
        return spec.isIdentity ? RotateEdit.nothingToRotateReason : nil
    }

    /// Quarter turns of a video only change its transform; a flip draws every frame again.
    var note: String? {
        hasVideo && spec.flipHorizontal ? "Re-encodes the video" : nil
    }

    /// Only the first file shows; a later file that can't be read is left to its job, which says why.
    func load() async {
        guard let file = files.first, let picture = await EditorMedia.picture(of: file) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        pixelSize = picture.size
        let preview = await EditorMedia.preview(of: file, maxPixelSize: Self.previewPixels)
        guard !Task.isCancelled else { return }
        self.preview = preview
    }

    func perform(_ action: RotateAction) {
        lastAction = action
        actionCount += 1
        spec = action.applied(to: spec)
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = .rotate(spec)
        return options
    }

    /// A turn belongs to its picture: the next file opens unturned.
    func remember(into memory: inout EditorMemory) {}

    func makeContent() -> AnyView {
        AnyView(RotateEditorView(session: self))
    }
}

/// Where the preview draws the picture: the result aspect-fit in the bounds, and the transform that puts the upright
/// picture there.
struct RotatePreview {
    static let label = "Preview"

    /// The result, as VoiceOver says it.
    static func value(_ spec: RotateSpec) -> String {
        let turn = switch spec.quarterTurns {
        case 1: "Turned right"
        case 2: "Upside down"
        case 3: "Turned left"
        default: "Not turned"
        }
        guard spec.flipHorizontal else { return turn }
        switch spec.quarterTurns {
        case 0: return "Flipped horizontally"
        // Two turns and a horizontal flip are a vertical flip.
        case 2: return "Flipped vertically"
        default: return "\(turn) and flipped horizontally"
        }
    }

    /// The result's size in the preview, in points.
    let shownSize: CGSize
    /// The upright picture's size in the preview, before the turn.
    let uprightSize: CGSize
    let transform: CGAffineTransform

    init(pixelSize: CGSize, spec: RotateSpec, bounds: CGSize) {
        let output = spec.outputSize(width: Int(pixelSize.width.rounded()), height: Int(pixelSize.height.rounded()))
        shownSize = EditorPicture.fitted(CGSize(width: output.width, height: output.height), into: bounds,
                                         until: pixelSize)
        uprightSize = spec.quarterTurns % 2 == 1
            ? CGSize(width: shownSize.height, height: shownSize.width) : shownSize
        // `fitted` gives whole points, so the engines' transform applies to the preview's own size.
        transform = spec.transform(width: Int(uprightSize.width), height: Int(uprightSize.height))
    }

    /// How the picture shown before `action` sits over this one: the animation starts there and settles on the
    /// result.
    func start(before action: RotateAction?, bounds: CGSize) -> RotateKick {
        switch action {
        case .rotateLeft, .rotateRight:
            let before = EditorPicture.fitted(CGSize(width: shownSize.height, height: shownSize.width),
                                              into: bounds, until: shownSize)
            return RotateKick(angle: action == .rotateRight ? -90 : 90, flipX: 1, flipY: 1,
                              scale: before.width / max(1, shownSize.height))
        case .flipHorizontal: return RotateKick(angle: 0, flipX: -1, flipY: 1, scale: 1)
        case .flipVertical: return RotateKick(angle: 0, flipX: 1, flipY: -1, scale: 1)
        case nil: return .rest
        }
    }
}

/// The preview's animation, on top of the result: it starts where the picture was and settles at rest.
struct RotateKick: Equatable {
    static let rest = RotateKick(angle: 0, flipX: 1, flipY: 1, scale: 1)

    var angle: Double
    var flipX: CGFloat
    var flipY: CGFloat
    var scale: CGFloat

    /// `progress` of the way from this kick to rest, clamped to 0…1.
    func settled(by progress: Double) -> RotateKick {
        let p = min(1, max(0, progress))
        func toward(_ value: Double, _ rest: Double) -> Double { value + (rest - value) * p }
        return RotateKick(angle: toward(angle, 0), flipX: toward(flipX, 1), flipY: toward(flipY, 1),
                          scale: toward(scale, 1))
    }
}

/// Animates the kick in one update: `count` is the animated action count, `target` the count it heads for, so the
/// picture eases from `start` (one action back) to rest. Without an animation `count` is `target` and it rests.
nonisolated struct RotateKickEffect: ViewModifier, Animatable {
    var count: Double
    let target: Double
    let start: RotateKick

    var animatableData: Double {
        get { count }
        set { count = newValue }
    }

    var kick: RotateKick { start.settled(by: count - (target - 1)) }

    func body(content: Content) -> some View {
        let kick = kick
        return content
            .scaleEffect(x: kick.flipX * kick.scale, y: kick.flipY * kick.scale)
            .rotationEffect(.degrees(kick.angle))
    }
}

// MARK: - Views

struct RotateEditorView: View {
    @ObservedObject var session: RotateSession

    var body: some View {
        VStack(spacing: 8) {
            RotateCanvas(session: session)
            HStack(spacing: 6) {
                ForEach(RotateAction.allCases, id: \.self) { action in
                    Button { session.perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                        .help(action.help)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.loadFailed)
        }
        .frame(width: RotateSession.contentWidth)
        .frame(maxWidth: .infinity)
    }
}

/// The result drawn in a box of fixed size, so the panel keeps its size as the picture turns. It takes ← → while
/// focused.
struct RotateCanvas: View {
    @ObservedObject var session: RotateSession
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bounds = RotateSession.previewBounds

    var body: some View {
        ZStack {
            if let pixelSize = session.pixelSize {
                picture(RotatePreview(pixelSize: pixelSize, spec: session.spec, bounds: Self.bounds))
            } else {
                let size = EditorPicture.fitted(nil, into: Self.bounds, until: CGSize(width: 4, height: 3))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: Self.bounds.width, height: Self.bounds.height)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(RotatePreview.label)
        .accessibilityValue(RotatePreview.value(session.spec))
        .editorKeys($focused) { press in
            guard let action = RotateKeys.action(for: press), !session.loadFailed else { return false }
            session.perform(action)
            return true
        }
        .help("Left and right arrow keys rotate the picture")
    }

    private func picture(_ layout: RotatePreview) -> some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let preview = session.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
            }
        }
        .frame(width: layout.uprightSize.width, height: layout.uprightSize.height)
        // About the view's top-left corner, in its y-down space: the engines' own mapping.
        .transformEffect(layout.transform)
        .frame(width: layout.shownSize.width, height: layout.shownSize.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // A white picture on a light panel still shows its edges.
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        // Only the kick animates: the transform and size are the result's at once, never interpolated.
        .animation(reduceMotion ? nil : .smooth(duration: 0.25)) { content in
            content.modifier(RotateKickEffect(count: Double(session.actionCount),
                                              target: Double(session.actionCount),
                                              start: layout.start(before: session.lastAction, bounds: Self.bounds)))
        }
    }
}
