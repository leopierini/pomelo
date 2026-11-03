// Opens one editor at a time at the drop point (P27), runs its job on Save and waits for it as the wheel does
// (P23): a success or a note closes the editor, a failure within the wait stays in it with the choices untouched,
// and a job still running when the wait ends goes on in the progress pill (P25). The panel becomes key without
// activating Pomelo, and losing key changes nothing.
import AppKit
import PomeloCore
import PomeloUIModel
import os
import SwiftUI

/// How the editor meets the real desktop. Tests and measurements use `.offScreen`: the panel orders in far outside
/// every screen, is never made key and never plays media.
struct EditorDesktop {
    /// The frame the panel is clamped into, for its anchor; nil for the visible frame of the screen under it.
    var visibleFrame: (@MainActor (CGPoint) -> CGRect)?
    var takesKey = true
    var playsMedia = true

    static let live = EditorDesktop()
    static let offScreen = EditorDesktop(
        visibleFrame: { _ in CGRect(x: -30_000, y: -30_000, width: 2_000, height: 2_000) },
        takesKey: false, playsMedia: false
    )
}

@MainActor
final class EditorController {
    private(set) var phase = EditorPhase.editing
    /// Internal so the tests can check the session and what the chrome shows.
    private(set) var session: (any EditorSession)?
    private(set) var chromeState = EditorChromeState()
    private(set) lazy var panel = makePanel()

    var isOpen: Bool { session != nil && panel.isVisible }

    private let settings: SettingsStore
    private let perform: @MainActor (Preset, [URL], CGPoint, (@MainActor (FileResult) -> Void)?) -> JobHandle
    private let release: @MainActor (UUID, Bool) -> Void
    private let followUp: DropFollowUp
    private let desktop: EditorDesktop
    private let makeSession: @MainActor (EditorRequest, SettingsStore) -> any EditorSession

    private var request: EditorRequest?
    private var content = AnyView(EmptyView())
    /// The session's load; internal so a test can await a cancelled load's end instead of waiting real time.
    private(set) var loadTask: Task<Void, Never>?
    /// Ends the wait for the saved job (P23).
    private var waitTask: Task<Void, Never>?
    private var shadowTask: Task<Void, Never>?
    /// The saved job, until the editor releases it, exactly once.
    private var heldJob: UUID?

    static let signposter = OSSignposter(subsystem: "io.github.pomelo-app.Pomelo", category: "editor")

    init(
        settings: SettingsStore,
        perform: @escaping @MainActor (Preset, [URL], CGPoint, (@MainActor (FileResult) -> Void)?) -> JobHandle,
        release: @escaping @MainActor (UUID, Bool) -> Void, followUp: DropFollowUp = .standard,
        desktop: EditorDesktop = .live,
        makeSession: @escaping @MainActor (EditorRequest, SettingsStore) -> any EditorSession = EditorSessions.make
    ) {
        self.settings = settings
        self.perform = perform
        self.release = release
        self.followUp = followUp
        self.desktop = desktop
        self.makeSession = makeSession
    }

    /// Shows the editor for `request`, replacing any open one (its choices are dropped; a job it saved goes on in
    /// the pill). Only the chrome is laid out here: previews load in the session's `load`, after the panel is up.
    func open(_ request: EditorRequest) {
        let interval = Self.signposter.beginInterval("open")
        defer { Self.signposter.endInterval("open", interval) }

        if session != nil { close() }
        let session = makeSession(request, settings)
        self.request = request
        self.session = session
        phase = .editing
        chromeState = EditorChromeState(request: request, session: session)
        content = session.makeContent()
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onChoicesChanged = { [weak self] in self?.choicesChanged() }
        render()
        place(at: request.anchor)
        panel.orderFrontRegardless()
        if desktop.takesKey { panel.makeKey() }
        invalidateShadowOnceShown()
        announce(Self.announcement(title: session.title, files: request.files))
        loadTask = Task { await session.load() }
    }

    /// Saves (the button, Return or a field's submit): runs the job and waits up to `resultWait` for its outcome.
    func confirm() {
        guard isOpen, let session, let request, session.blocker == nil else { return }
        switch phase {
        case .editing, .failed: break
        case .working: return
        }
        var preset = request.preset
        preset.options = session.options(base: preset.options)
        preset.nameSuffix = session.nameSuffix(base: preset.nameSuffix)
        var memory = settings.settings.editorMemory
        session.remember(into: &memory)
        if memory != settings.settings.editorMemory { settings.settings.editorMemory = memory }

        let job = perform(preset, request.files, request.anchor, request.onResult)
        heldJob = job.id
        phase = .working(job: job.id)
        render()
        Task { [weak self] in
            let outcome = await job.outcome.value
            self?.jobEnded(job.id, outcome)
        }
        waitTask = Task { [weak self, followUp] in
            try? await Task.sleep(for: followUp.resultWait)
            guard !Task.isCancelled, let self, self.phase == .working(job: job.id) else { return }
            // Still running: closing releases the job unshown, so the pill takes it over.
            self.close()
        }
    }

    /// ✕, Esc, ⌘W or ⌘.: closes without running anything. A job already saved goes on in the pill.
    func cancel() {
        close()
    }

    static func announcement(title: String, files: [URL]) -> String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        return "\(title) editor, \(what)"
    }

    // MARK: - Private

    /// Whichever comes first, this or the wait's end, releases the job: its outcome shows in the editor or in the
    /// pill, never in both and never in neither.
    private func jobEnded(_ id: UUID, _ outcome: JobOutcome) {
        guard phase == .working(job: id), heldJob == id else { return }
        waitTask?.cancel()
        waitTask = nil
        heldJob = nil
        switch outcome {
        case .succeeded:
            release(id, true)
            close()
        case .noted:
            // The pill shows the note: the editor has no room for one once it has closed.
            release(id, false)
            close()
        case .failed(let summary):
            release(id, true)
            let alert = WheelAlert(title: summary.title, subtitle: summary.detail)
            phase = .failed(alert)
            render()
            announce([alert.title, alert.subtitle].compactMap { $0 }.joined(separator: ". "))
        }
    }

    private func close() {
        guard session != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        waitTask?.cancel()
        waitTask = nil
        shadowTask?.cancel()
        shadowTask = nil
        if let id = heldJob {
            heldJob = nil
            release(id, false)
        }
        session?.onChange = nil
        session?.onChoicesChanged = nil
        session?.editorClosed()
        session = nil
        request = nil
        phase = .editing
        panel.freezesUndo = false
        content = AnyView(EmptyView())
        chromeState = EditorChromeState()
        if panel.isVisible { panel.orderOut(nil) }
        panel.host.rootView = EditorChrome()
        // The panel outlives its editors, and its undo steps belong to the one that registered them.
        panel.undoManager?.removeAllActions()
    }

    private func sessionChanged() {
        guard let session else { return }
        // P78: a change after a quick failure makes the failure stale; the footer goes back to the blocker or note.
        if case .failed = phase { phase = .editing }
        chromeState.update(from: session)
        render()
        refit()
    }

    /// Only a failure needs to hear of each edit, so a pointer moving a crop handle never lays the chrome out again.
    private func choicesChanged() {
        guard case .failed = phase else { return }
        sessionChanged()
    }

    private func render() {
        chromeState.phase = phase
        panel.freezesUndo = if case .working = phase { true } else { false }
        panel.host.rootView = EditorChrome(
            state: chromeState, content: content,
            actions: EditorChromeActions(confirm: { [weak self] in self?.confirm() },
                                         cancel: { [weak self] in self?.cancel() }),
            playsMedia: desktop.playsMedia
        )
    }

    private func fittingSize() -> CGSize {
        panel.host.layoutSubtreeIfNeeded()
        let size = panel.host.fittingSize
        return CGSize(width: EditorLayout.width(for: chromeState.kind), height: min(size.height, EditorLayout.maxHeight))
    }

    private func visibleFrame(for point: CGPoint) -> CGRect {
        if let visibleFrame = desktop.visibleFrame { return visibleFrame(point) }
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: point.x - 720, y: point.y - 450, width: 1440, height: 900)
    }

    private func place(at anchor: CGPoint) {
        let frame = EditorLayout.frame(contentSize: fittingSize(), anchor: anchor,
                                       visibleFrame: visibleFrame(for: anchor))
        panel.setFrame(frame, display: true)
    }

    /// A session whose content grew or shrank keeps the panel's top edge where it is (the person may have moved
    /// it), inside the screen.
    private func refit() {
        guard isOpen else { return }
        let size = fittingSize()
        // Measured while the chrome is mid-layout (a change sent from SwiftUI's render), the skipped reentrant pass
        // reads 0: such a height would leave an invisible panel.
        guard size.height > 0, size.height != panel.frame.height else { return }
        let current = panel.frame
        let resized = CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
        let centre = CGPoint(x: current.midX, y: current.midY)
        panel.setFrame(ScreenFit.clamp(resized, into: visibleFrame(for: centre), margin: EditorLayout.margin),
                       display: true)
        panel.invalidateShadow()
    }

    /// The window server takes the shadow from the first, still transparent frame of the fade: it is taken again
    /// once the chrome is fully in.
    private func invalidateShadowOnceShown() {
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.shadowTask = nil
            self.panel.invalidateShadow()
        }
    }

    private func makePanel() -> EditorPanel {
        let panel = EditorPanel()
        panel.onCancel = { [weak self] in self?.cancel() }
        return panel
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
