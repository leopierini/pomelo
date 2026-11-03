// The frame every editor shares (P27): a header with the tool and the file, the session's controls, and a footer
// with the reason Save is disabled (or the failure that came back within the wait) and the confirm button.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

/// What the chrome shows, copied from the request and the session each time the session changes.
struct EditorChromeState: Equatable {
    /// A new value for each open, so the next editor starts from fresh view state and fades in again.
    var openID = UUID()
    var kind = EditorKind.trim
    var symbol = "slider.horizontal.3"
    var title = ""
    var fileLabel = ""
    var confirmTitle = ""
    var blocker: String?
    var note: String?
    var phase = EditorPhase.editing

    static let maxFileLabelLength = 32

    init() {}

    @MainActor
    init(request: EditorRequest, session: any EditorSession) {
        kind = request.kind
        symbol = ToolCatalog.symbol(ofPreset: request.preset.id)
        fileLabel = Self.fileLabel(for: request.files)
        update(from: session)
    }

    @MainActor
    mutating func update(from session: any EditorSession) {
        title = session.title
        confirmTitle = session.confirmTitle
        blocker = session.blocker
        note = session.note
    }

    var isWorking: Bool {
        if case .working = phase { true } else { false }
    }

    static func fileLabel(for files: [URL]) -> String {
        guard files.count == 1 else { return "\(files.count) files" }
        return ResultSummary.shortened(files[0].lastPathComponent, to: maxFileLabelLength)
    }
}

struct EditorChromeActions {
    var confirm: @MainActor @Sendable () -> Void = {}
    var cancel: @MainActor @Sendable () -> Void = {}
}

struct EditorChrome: View {
    var state = EditorChromeState()
    var content = AnyView(EmptyView())
    var actions = EditorChromeActions()
    /// False for the DEBUG snapshot, whose display is cached before any animation could run.
    var animatesIn = true
    var playsMedia = true

    var body: some View {
        EditorCard(state: state, content: content, actions: actions, animatesIn: animatesIn,
                   playsMedia: playsMedia)
            .id(state.openID)
    }
}

private struct EditorCard: View {
    let state: EditorChromeState
    let content: AnyView
    let actions: EditorChromeActions
    let animatesIn: Bool
    let playsMedia: Bool

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fadeIn = 0.15

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .disabled(state.isWorking)
                .environment(\.editorConfirm, EditorConfirmAction(run: actions.confirm))
                .environment(\.editorPlaysMedia, playsMedia)
            footer
        }
        .padding(14)
        .frame(width: EditorLayout.width(for: state.kind), alignment: .leading)
        .wheelBackground(in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.title) editor")
        // Under Reduce Motion only the opacity changes (global constraints, Look).
        .opacity(settled || !animatesIn ? 1 : 0)
        .scaleEffect(settled || !animatesIn || reduceMotion ? 1 : 0.97)
        .onAppear {
            guard animatesIn, !settled else { return }
            withAnimation(.easeOut(duration: Self.fadeIn)) { settled = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                Image(systemName: state.symbol)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(state.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(state.fileLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The drag area behind takes the mouse, so a drag on the title moves the panel too.
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            Button(action: actions.cancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")
            .help("Cancel")
        }
        .background(EditorDragArea())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .failed(let alert) = state.phase {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityHidden(true)
                // P32: the title over the reason, two labels.
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        // The title carries the file name, whose ending matters.
                        .truncationMode(.middle)
                    if let subtitle = alert.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            } else if let line = state.blocker ?? state.note {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if state.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Saving\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(state.confirmTitle, action: actions.confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.blocker != nil)
                    .help(state.blocker ?? "")
            }
        }
        // As tall as a failure's two lines, so the panel keeps its size from one phase to the next.
        .frame(minHeight: 34)
    }
}

enum EditorPicture {
    /// The picture's upright size aspect-fit into `bounds`, at least a pixel each way; the `placeholder` aspect fills
    /// the height until the size is known.
    static func fitted(_ size: CGSize?, into bounds: CGSize, until placeholder: CGSize) -> CGSize {
        guard let size, size.width > 0, size.height > 0 else {
            return CGSize(width: bounds.height * placeholder.width / placeholder.height, height: bounds.height)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}

/// The round grip the crop and redaction canvases draw at an area's corners.
struct EditorKnob: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 1)
            .frame(width: diameter, height: diameter)
    }
}

extension View {
    /// Focuses the view when it appears and again when its panel becomes key, which comes later and drops a focus set
    /// earlier.
    func focusedInPanel(_ focus: FocusState<Bool>.Binding) -> some View {
        onAppear { focus.wrappedValue = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                focus.wrappedValue = true
            }
    }

    /// An editor canvas takes the keys while focused; `perform` says whether it handled the press.
    func editorKeys(_ focus: FocusState<Bool>.Binding, perform: @escaping (KeyPress) -> Bool) -> some View {
        focusable()
            .focusEffectDisabled()
            .focused(focus)
            .onKeyPress(phases: [.down, .repeat]) { perform($0) ? .handled : .ignored }
            .focusedInPanel(focus)
    }
}
