// What every editor (P27) plugs into the shared panel: its title and confirm button, why Save is disabled, its own
// controls, and how its choices become the preset's options. `EditorController` owns the panel, the job and the
// wait for its outcome; a session only edits.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

/// A drop on an editor slice: the tool, its configured preset, the files to run on and the wheel's centre.
struct EditorRequest {
    var kind: EditorKind
    var preset: Preset
    var files: [URL]
    var anchor: CGPoint
    /// The slice's route flags.
    var flags: EdgeFlags
    /// Where the saved job reports each finished file: the Shelf's, for an editor its wheel opened (S18).
    var onResult: (@MainActor (FileResult) -> Void)? = nil
}

@MainActor
protocol EditorSession: AnyObject {
    /// "Trim".
    var title: String { get }
    /// What the button does: "Save Trimmed Copy".
    var confirmTitle: String { get }
    /// Why Save is disabled, shown as the footer's note; nil when the choices can be saved.
    var blocker: String? { get }
    var note: String? { get }
    /// Set by the controller: the session calls it whenever its title, blocker or note change.
    var onChange: (() -> Void)? { get set }
    /// Set by the controller: a session that calls `onChange` only for the footer's line calls this whenever what
    /// Save would send changes, so an edit after a quick failure clears it (P78).
    var onChoicesChanged: (() -> Void)? { get set }

    /// Loads previews off the main thread; the task running it is cancelled when the editor closes.
    func load() async
    func options(base: PresetOptions) -> PresetOptions
    func nameSuffix(base: String?) -> String?
    func remember(into memory: inout EditorMemory)
    func makeContent() -> AnyView
    /// The editor closed or was replaced: stop anything the session started that outlives its views.
    func editorClosed()
}

extension EditorSession {
    func nameSuffix(base: String?) -> String? { base }
    func editorClosed() {}
    /// Sessions that call `onChange` on every change of their choices need no second hook.
    var onChoicesChanged: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// The footer's line, which some sessions report through `onChange` only when it changes.
struct EditorFooter: Equatable {
    var blocker: String?
    var note: String?
}

extension EditorFooter {
    @MainActor
    init(of session: some EditorSession) {
        blocker = session.blocker
        note = session.note
    }

    /// Becomes the session's line; true when that changed it.
    @MainActor
    mutating func update(from session: some EditorSession) -> Bool {
        let line = EditorFooter(of: session)
        guard line != self else { return false }
        self = line
        return true
    }
}

enum EditorPhase: Equatable {
    case editing
    /// Saved: the controls are disabled while the editor waits for the job (P23).
    case working(job: UUID)
    /// The job failed within the wait: the choices stay as they were, ready to adjust and save again.
    case failed(WheelAlert)
}

enum EditorSessions {
    @MainActor
    static func make(_ request: EditorRequest, _ settings: SettingsStore) -> any EditorSession {
        switch request.kind {
        case .targetSize:
            return TargetSizeSession(request: request, memory: settings.settings.editorMemory)
        case .trim:
            return TrimSession(request: request)
        case .split:
            return SplitSession(request: request)
        case .crop:
            return CropSession(request: request, memory: settings.settings.editorMemory)
        case .redact:
            return RedactSession(request: request, memory: settings.settings.editorMemory)
        case .organizePages:
            return PageOrganizerSession(request: request)
        case .resize:
            return ResizeSession(request: request, memory: settings.settings.editorMemory)
        case .rotate:
            return RotateSession(request: request)
        }
    }

    /// The catalog tool that opens `kind`, with the user's options.
    static func preset(for kind: EditorKind, settings: AppSettings) -> Preset? {
        guard let id = ToolCatalog.all.first(where: { $0.editor == kind })?.id else { return nil }
        return ToolCatalog.presets(settings: settings).first { $0.id == id }
    }
}

/// What a session's own controls call to save (a text field's `onSubmit`), as the confirm button does.
struct EditorConfirmAction: Sendable {
    let run: @MainActor @Sendable () -> Void

    @MainActor func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var editorConfirm = EditorConfirmAction(run: {})
    /// False on `EditorDesktop.offScreen`: tests and measurements never play media.
    @Entry var editorPlaysMedia = true
}
