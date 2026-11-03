// The Trim and Split editors (P27): the video over a timeline of its frames (or, for audio, a waveform), with grips
// for the part to keep or scissors where to cut, a playhead, and keys for all of it. The cut copies the samples
// (a FLAC alone is re-encoded, losslessly); the footer's note says when a lossy edge re-encodes.
import AppKit
import PomeloCore
import PomeloEngines
import PomeloUIModel
import SwiftUI

enum TimelineAction: Equatable {
    case setStart, setEnd, addPoint, playPause, removeSelectedPoint
    case nudge(Int, coarse: Bool)
    /// P83: Tab and ⇧Tab choose the handle the arrows move.
    case selectNext, selectPrevious
}

/// The timeline's keys, read while it has focus in the key panel (never through a key monitor).
enum TimelineKeys {
    static func action(for press: KeyPress) -> TimelineAction? {
        action(for: press.key, modifiers: press.modifiers)
    }

    static func action(for key: KeyEquivalent, modifiers: EventModifiers) -> TimelineAction? {
        // Arrow keys also carry the numeric-pad and function flags, which mean nothing here.
        let held = modifiers.intersection([.command, .option, .control, .shift])
        switch key {
        case .leftArrow, .rightArrow:
            guard held.isEmpty || held == .shift else { return nil }
            return .nudge(key == .leftArrow ? -1 : 1, coarse: held == .shift)
        case .space:
            return held.isEmpty ? .playPause : nil
        case .tab:
            if held.isEmpty { return .selectNext }
            return held == .shift ? .selectPrevious : nil
        // AppKit types ⇧Tab as the back-tab character.
        case KeyEquivalent("\u{19}"):
            return held.subtracting(.shift).isEmpty ? .selectPrevious : nil
        // SwiftUI's `delete` is U+0008, but AppKit's Delete key types U+007F: both, and forward delete, remove.
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"):
            return held.isEmpty ? .removeSelectedPoint : nil
        default:
            guard held.subtracting(.shift).isEmpty else { return nil }
            switch String(key.character).lowercased() {
            case "i": return .setStart
            case "o": return .setEnd
            case "s": return .addPoint
            default: return nil
            }
        }
    }
}

/// What Trim and Split share: the file's facts, the timeline, the frames or waveform and the playback.
@MainActor
class TimelineSession: EditorSession, ObservableObject {
    enum Mode { case trim, split }

    static let stripFrames = 12
    static let waveformBuckets = 160
    static let contentWidth: CGFloat = 488

    let mode: Mode
    let file: URL
    var onChange: (() -> Void)?
    let playback: TimelinePlayback

    /// nil until the file's duration is known.
    var model: TimelineModel? {
        willSet { objectWillChange.send() }
        didSet { modelChanged(from: oldValue) }
    }

    @Published var selection = TimelineHandle.playhead
    /// From the file's kind until its tracks are read.
    @Published private(set) var showsVideo: Bool
    @Published private(set) var displaySize: CGSize?
    @Published private(set) var poster: CGImage?
    @Published private(set) var filmstrip: [CGImage] = []
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var loadFailed = false {
        didSet { onChange?() }
    }

    private let reencodes: Bool

    init(request: EditorRequest, mode: Mode) {
        self.mode = mode
        file = request.files[0]
        reencodes = request.flags.contains(.lossy)
        showsVideo = FormatRegistry.builtIn.format(for: request.files[0])?.category == .video
        playback = TimelinePlayback(url: request.files[0])
        playback.onTime = { [weak self] seconds in self?.model?.set(.playhead, to: seconds) }
        playback.onFinish = { [weak self] seconds in self?.model?.set(.playhead, to: seconds) }
    }

    var title: String { mode == .trim ? "Trim" : "Split" }
    var confirmTitle: String { mode == .trim ? "Save Trimmed Copy" : "Save Parts" }

    var blocker: String? {
        if loadFailed { return "The file may be damaged" }
        guard let model else { return "Reading the file\u{2026}" }
        return mode == .trim ? model.trimBlocker : model.splitBlocker
    }

    var note: String? {
        if reencodes { return "The cut re-encodes the file" }
        return mode == .trim ? "Cut without re-encoding" : "Each part is cut without re-encoding"
    }

    var readout: String {
        guard let model else { return " " }
        return mode == .trim ? model.trimReadout : model.splitReadout
    }

    func load() async {
        guard let info = try? await EditorMedia.info(of: file), let duration = info.durationSeconds, duration > 0 else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        showsVideo = info.displaySize != nil
        displaySize = info.displaySize
        model = TimelineModel(duration: duration, frameRate: showsVideo ? info.frameRate : nil)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if showsVideo {
            let poster = await EditorMedia.frame(of: file, at: 0, maxPixelSize: Int(Self.contentWidth * scale))
            guard !Task.isCancelled else { return }
            self.poster = poster
            let frames = await Filmstrip.load(url: file, count: Self.stripFrames,
                                              height: TimelineTrack.videoHeight * scale)
            guard !Task.isCancelled else { return }
            filmstrip = frames
        } else {
            let peaks = (try? await WaveformSampler.peaks(of: file, buckets: Self.waveformBuckets)) ?? []
            guard !Task.isCancelled else { return }
            waveform = peaks
        }
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = mode == .trim ? model?.trimSpec : model?.splitSpec
        return options
    }

    func remember(into memory: inout EditorMemory) {}

    func makeContent() -> AnyView {
        AnyView(TimelineEditorView(session: self, playback: playback))
    }

    /// The view's onDisappear is not enough: replacing the panel's root view may run it late or not at all.
    func editorClosed() {
        playback.tearDown()
    }

    // MARK: Actions

    /// A key's action; false when it means nothing in this editor, so the key goes on to the panel.
    @discardableResult
    func perform(_ action: TimelineAction) -> Bool {
        guard model != nil else { return false }
        switch action {
        case .setStart, .setEnd:
            guard mode == .trim else { return false }
            // While playing, the playhead lags the picture by up to a periodic tick (1/30 s).
            if let now = playback.currentSeconds { model?.set(.playhead, to: now) }
            let playhead = model?.playhead ?? 0
            model?.set(action == .setStart ? .start : .end, to: playhead)
        case .addPoint:
            guard mode == .split else { return false }
            if let now = playback.currentSeconds { model?.set(.playhead, to: now) }
            // The selection stays on the playhead (P83), so S, arrows, S places several points. A point chosen with
            // Tab is found again by its time, since a point added before it shifts the indexes.
            let chosen = model?.value(of: selection)
            model?.addPoint()
            if case .point = selection, let chosen, let index = model?.points.firstIndex(of: chosen) {
                selection = .point(index)
            }
        case .removeSelectedPoint:
            guard mode == .split, case .point(let index) = selection else { return false }
            model?.removePoint(index)
            selection = .playhead
        case .playPause:
            playPause()
        case .selectNext, .selectPrevious:
            let cycle = selectableHandles
            let index = cycle.firstIndex(of: selection) ?? 0
            let step = action == .selectNext ? 1 : -1
            selection = cycle[(index + step + cycle.count) % cycle.count]
        case .nudge(let steps, let coarse):
            playback.pause()
            model?.nudge(selection, steps: steps, coarse: coarse)
            follow(selection)
        }
        return true
    }

    /// A click or a drag on the timeline's background.
    func scrub(to seconds: Double) {
        playback.pause()
        selection = .playhead
        model?.set(.playhead, to: seconds)
        follow(.playhead)
    }

    /// A grip or a split point dragged: the playhead follows it, so the picture shows the frame at the cut.
    func drag(_ handle: TimelineHandle, to seconds: Double) {
        playback.pause()
        selection = handle
        model?.set(handle, to: seconds)
        follow(handle)
    }

    func select(_ handle: TimelineHandle) {
        selection = handle
    }

    /// VoiceOver's increment and decrement: one step each.
    func adjust(_ handle: TimelineHandle, by steps: Int) {
        selection = handle
        perform(.nudge(steps, coarse: false))
    }

    /// What Tab cycles through (P83): the playhead, then the handles in time order.
    var selectableHandles: [TimelineHandle] {
        switch mode {
        case .trim: [.playhead, .start, .end]
        case .split: [.playhead] + (model?.points.indices.map { TimelineHandle.point($0) } ?? [])
        }
    }

    func playPause() {
        if playback.isPlaying {
            playback.pause()
        } else if let model {
            playback.play(model.playRange())
        }
    }

    private func follow(_ handle: TimelineHandle) {
        guard let value = model?.value(of: handle) else { return }
        if handle != .playhead { model?.set(.playhead, to: value) }
        playback.seek(to: value)
    }

    /// The controller hears of a change to the choices (and so to the blocker), not of the playhead's 30 moves a
    /// second while playing.
    private func modelChanged(from old: TimelineModel?) {
        guard old?.start != model?.start || old?.end != model?.end || old?.points != model?.points
            || (old == nil) != (model == nil) else { return }
        if let end = model?.end, end != old?.end { playback.retarget(end: end) }
        onChange?()
    }
}

final class TrimSession: TimelineSession {
    init(request: EditorRequest) {
        super.init(request: request, mode: .trim)
    }
}

final class SplitSession: TimelineSession {
    init(request: EditorRequest) {
        super.init(request: request, mode: .split)
    }
}

// MARK: - Views

struct TimelineEditorView: View {
    @ObservedObject var session: TimelineSession
    @ObservedObject var playback: TimelinePlayback
    @Environment(\.editorPlaysMedia) private var playsMedia

    static let playerMaxSize = CGSize(width: TimelineSession.contentWidth, height: 274)

    var body: some View {
        VStack(spacing: 8) {
            if session.showsVideo { player }
            TimelineTrack(session: session)
            readouts
            controls
        }
        .frame(width: TimelineSession.contentWidth)
        .frame(maxWidth: .infinity)
        // The player comes once the file's facts are in, so nothing of it runs while the panel opens.
        .onAppear(perform: enablePlayback)
        .onChange(of: session.model == nil) { enablePlayback() }
        .onDisappear { playback.tearDown() }
    }

    private func enablePlayback() {
        guard playsMedia, session.model != nil else { return }
        playback.enable()
    }

    private var player: some View {
        let size = Self.fitted(session.displaySize)
        return ZStack {
            Color.black
            if let poster = session.poster {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
            if playsMedia, let player = playback.player {
                PlayerSurface(player: player)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private var readouts: some View {
        HStack {
            Text(session.model.map { TimeFormat.clock($0.start) } ?? " ")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Text(session.readout)
            Spacer(minLength: 8)
            Text(session.model.map { TimeFormat.clock($0.end) } ?? " ")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: session.playPause) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .help("Play the selection (Space)")
            Spacer(minLength: 8)
            switch session.mode {
            case .trim:
                Button("Set Start") { session.perform(.setStart) }
                    .help("Start at the playhead (I)")
                Button("Set End") { session.perform(.setEnd) }
                    .help("End at the playhead (O)")
            case .split:
                Button("Add Split") { session.perform(.addPoint) }
                    .help("Split at the playhead (S)")
                Button("Remove") { session.perform(.removeSelectedPoint) }
                    .disabled(!session.selection.isPoint)
                    .help("Remove the selected split (Delete)")
            }
        }
        .buttonStyle(.bordered)
        .disabled(session.model == nil)
    }

    /// The video's upright size, aspect-fit into the player's largest size (16:9 until it is known).
    static func fitted(_ size: CGSize?) -> CGSize {
        let bounds = playerMaxSize
        guard let size, size.width > 0, size.height > 0 else {
            return CGSize(width: bounds.height * 16 / 9, height: bounds.height)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

extension TimelineHandle {
    var isPoint: Bool {
        if case .point = self { true } else { false }
    }
}

/// The timeline: the frames or the waveform, the part outside the trim dimmed, the grips, the split points and the
/// playhead. It takes the keys while focused and the mouse through in-panel drags only, which never touch the drag
/// pasteboard, so the wheel can't open.
struct TimelineTrack: View {
    @ObservedObject var session: TimelineSession
    @FocusState private var focused: Bool
    /// Where the dragged handle was when the drag began.
    @State private var dragOrigin: Double?

    static let videoHeight: CGFloat = 44
    static let audioHeight: CGFloat = 72
    static let gripWidth: CGFloat = 10
    private static let space = "timeline"

    private var width: CGFloat { TimelineSession.contentWidth }
    private var height: CGFloat { session.showsVideo ? Self.videoHeight : Self.audioHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
            if let model = session.model {
                picture(model)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if session.mode == .trim { selection(model) }
                ForEach(Array(model.points.enumerated()), id: \.offset) { index, point in
                    marker(index, at: point, model)
                }
                playhead(model)
            }
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: Self.space)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
            guard let model = session.model else { return }
            session.scrub(to: seconds(at: value.location.x, model))
        })
        // Room for the knobs above the track.
        .padding(.top, 8)
        .editorKeys($focused) { press in TimelineKeys.action(for: press).map(session.perform) ?? false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.model.map { "Timeline, \(TimeFormat.clock($0.duration))" } ?? "Timeline")
        .accessibilityHint("Tab chooses the handle the arrow keys move")
        .help("Tab chooses the handle the arrow keys move")
    }

    // MARK: Layers

    @ViewBuilder
    private func picture(_ model: TimelineModel) -> some View {
        if session.showsVideo {
            HStack(spacing: 0) {
                ForEach(Array(session.filmstrip.enumerated()), id: \.offset) { _, frame in
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(TimelineSession.stripFrames), height: height)
                        .clipped()
                }
            }
            .opacity(session.filmstrip.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: session.filmstrip.isEmpty)
            .accessibilityHidden(true)
        } else {
            WaveformView(peaks: session.waveform,
                         selection: session.mode == .trim ? (model.start / model.duration)...(model.end / model.duration)
                            : 0...1)
                .opacity(session.waveform.isEmpty ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: session.waveform.isEmpty)
                .accessibilityHidden(true)
        }
    }

    private func selection(_ model: TimelineModel) -> some View {
        let startX = x(of: model.start, model)
        let endX = x(of: model.end, model)
        return ZStack(alignment: .topLeading) {
            if session.showsVideo {
                // Black at 45 % over what the trim drops.
                Rectangle().fill(.black.opacity(0.45))
                    .frame(width: startX, height: height)
                Rectangle().fill(.black.opacity(0.45))
                    .frame(width: max(0, width - endX), height: height)
                    .offset(x: endX)
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: max(Self.gripWidth * 2, endX - startX), height: height)
                .offset(x: startX)
                .allowsHitTesting(false)
            grip(.start, model)
                .offset(x: startX)
            grip(.end, model)
                .offset(x: endX - Self.gripWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func grip(_ handle: TimelineHandle, _ model: TimelineModel) -> some View {
        let isStart = handle == .start
        let selected = session.selection == handle
        return UnevenRoundedRectangle(
            topLeadingRadius: isStart ? 4 : 0, bottomLeadingRadius: isStart ? 4 : 0,
            bottomTrailingRadius: isStart ? 0 : 4, topTrailingRadius: isStart ? 0 : 4
        )
        .fill(Color.accentColor)
        .overlay {
            Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .brightness(selected ? 0.12 : 0)
        .frame(width: Self.gripWidth, height: height)
        .contentShape(Rectangle().inset(by: -4))
        .gesture(handleDrag(handle))
        .adjustable(isStart ? "Start" : "End", value: model.value(of: handle)) { session.adjust(handle, by: $0) }
    }

    private func marker(_ index: Int, at point: Double, _ model: TimelineModel) -> some View {
        let selected = session.selection == .point(index)
        let knob: CGFloat = 16
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: height)
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0))
                .overlay {
                    Image(systemName: "scissors")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: knob, height: knob)
                .offset(y: -knob / 2)
        }
        .frame(width: knob, height: height)
        .contentShape(Rectangle().inset(by: -2))
        .offset(x: x(of: point, model) - knob / 2)
        .gesture(handleDrag(.point(index)))
        .adjustable("Split \(index + 1)", value: point) { session.adjust(.point(index), by: $0) }
    }

    private func playhead(_ model: TimelineModel) -> some View {
        let knob: CGFloat = 9
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .offset(y: -knob / 2)
        }
        .shadow(color: .black.opacity(0.4), radius: 1)
        .frame(width: knob, height: height)
        .offset(x: x(of: model.playhead, model) - knob / 2)
        // Clicks go through to the timeline, which moves the playhead where they land.
        .allowsHitTesting(false)
        .adjustable("Position", value: model.playhead) { session.adjust(.playhead, by: $0) }
    }

    // MARK: Input

    private func handleDrag(_ handle: TimelineHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let current = session.model else { return }
                let origin = dragOrigin ?? current.value(of: handle) ?? 0
                if dragOrigin == nil {
                    dragOrigin = origin
                    session.select(handle)
                }
                guard value.translation.width != 0 else { return }
                session.drag(handle, to: origin + Double(value.translation.width / width) * current.duration)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func x(of seconds: Double, _ model: TimelineModel) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(seconds / model.duration) * width
    }

    private func seconds(at x: CGFloat, _ model: TimelineModel) -> Double {
        Double(min(max(x, 0), width) / width) * model.duration
    }
}

private extension View {
    /// A timeline handle for VoiceOver: its name, its time as the value, one step per increment.
    func adjustable(_ label: String, value: Double?, adjust: @escaping (Int) -> Void) -> some View {
        accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value.map(TimeFormat.clock) ?? "")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(1)
                case .decrement: adjust(-1)
                @unknown default: break
                }
            }
    }
}

/// The peaks as bars: the secondary colour, the part the trim keeps in the accent colour.
struct WaveformView: View {
    let peaks: [Float]
    /// Fractions of the duration.
    let selection: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            // Quiet recordings still fill the height; silence stays a line.
            let loudest = max(peaks.max() ?? 0, 0.05)
            let slot = size.width / CGFloat(peaks.count)
            let barWidth = max(1, slot * 0.6)
            // Clear of the selection's 2 pt frame.
            let usable = size.height - 14
            for (index, peak) in peaks.enumerated() {
                let barHeight = max(1, CGFloat(peak / loudest) * usable)
                let centre = (CGFloat(index) + 0.5) * slot
                let rect = CGRect(x: centre - barWidth / 2, y: (size.height - barHeight) / 2,
                                  width: barWidth, height: barHeight)
                let fraction = Double(centre / size.width)
                let colour: Color = selection.contains(fraction) ? .accentColor : Color(nsColor: .secondaryLabelColor)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(colour))
            }
        }
    }
}
