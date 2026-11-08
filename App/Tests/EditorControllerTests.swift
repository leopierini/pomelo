import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import SwiftUI
import Testing
@testable import Pomelo

/// A session whose choice is a trim start; its preview load waits until cancelled.
@MainActor
final class FakeEditorSession: EditorSession {
    var title = "Trim"
    var confirmTitle = "Save Trimmed Copy"
    var blocker: String? {
        didSet { onChange?() }
    }
    var note: String?
    var onChange: (() -> Void)?
    /// The person's choice, which a quick failure must leave as it was.
    var start = 1.5
    private(set) var loadStarted = false
    private(set) var loadCancelled = false

    func load() async {
        loadStarted = true
        do { try await Task.sleep(for: .seconds(60)) } catch { loadCancelled = true }
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = .trim(TimeRange(start: start, end: 2))
        return options
    }

    func remember(into memory: inout EditorMemory) {
        memory.targetBytes["video"] = 10_000_000
    }

    func makeContent() -> AnyView {
        AnyView(Text("Start \(start)").frame(height: 80))
    }
}

/// A session that reports a change from inside the hosting view's layout, as a text field does when it writes its
/// text back on taking focus.
@MainActor
private final class ChangesDuringLayoutSession: EditorSession {
    let title = "Compress to size"
    let confirmTitle = "Save Smaller Copy"
    let blocker: String? = nil
    let note: String? = "Lowers the quality first, then the size in pixels"
    var onChange: (() -> Void)?
    private(set) var reported = 0

    func load() async {}
    func options(base: PresetOptions) -> PresetOptions { base }
    func remember(into memory: inout EditorMemory) {}

    func makeContent() -> AnyView {
        AnyView(ReportsDuringLayout { [self] in
            reported += 1
            onChange?()
        })
    }
}

/// A field that, like `TargetSizeEditorView`'s, writes its text back as it takes focus: SwiftUI does that while it
/// renders inside the hosting view's layout.
private struct ReportsDuringLayout: View {
    let report: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Size", text: Binding(get: { "500" }, set: { _ in report() }))
            .focused($focused)
            .onAppear { focused = true }
    }
}

private struct Performed {
    var preset: Preset
    var files: [URL]
    var anchor: CGPoint
    var onResult: (@MainActor (FileResult) -> Void)?
}

private struct Release: Equatable {
    var id: UUID
    var outcomeShown: Bool
}

/// The jobs an editor starts, as recorded by its injected `perform` and `release` closures.
@MainActor
private final class Jobs {
    var performed: [Performed] = []
    var releases: [Release] = []
    var handles: [JobHandle] = []
    /// What the next job ends with, and after how long.
    var outcome: JobOutcome = .succeeded
    var duration: Duration = .zero

    func perform(
        _ preset: Preset, _ files: [URL], _ anchor: CGPoint, _ onResult: (@MainActor (FileResult) -> Void)?
    ) -> JobHandle {
        performed.append(Performed(preset: preset, files: files, anchor: anchor, onResult: onResult))
        let (outcome, duration) = (outcome, duration)
        let handle = JobHandle(id: UUID(), outcome: Task {
            try? await Task.sleep(for: duration)
            return outcome
        })
        handles.append(handle)
        return handle
    }
}

private let clip = URL(fileURLWithPath: "/tmp/pomelo-editor-test-clip.mov")
private let anchor = CGPoint(x: -29_000, y: -29_000)

private let trimFailure = ResultSummary(title: "Couldn't trim clip.mov", detail: "It has no sound", isFailure: true)

/// The editor panel host (P27), on `EditorDesktop.offScreen`: the panel really orders in, but far off every screen
/// and never key, so nothing reaches whoever runs the tests.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct EditorControllerTests {
    private func trimPreset() throws -> Preset {
        try #require(Preset.builtIns.first { $0.id == "trim" })
    }

    private func request(_ files: [URL] = [clip]) throws -> EditorRequest {
        EditorRequest(kind: .trim, preset: try trimPreset(), files: files, anchor: anchor, flags: [])
    }

    private func makeEditor(
        _ jobs: Jobs, followUp: DropFollowUp = .standard, sessions: [FakeEditorSession] = [FakeEditorSession()]
    ) -> (EditorController, SettingsStore) {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        var queue = sessions
        let editor = EditorController(
            settings: settings, perform: { jobs.perform($0, $1, $2, $3) },
            release: { jobs.releases.append(Release(id: $0, outcomeShown: $1)) }, followUp: followUp,
            desktop: .offScreen, makeSession: { _, _ in queue.isEmpty ? FakeEditorSession() : queue.removeFirst() }
        )
        return (editor, settings)
    }

    @Test func panelIsNonActivatingFloatingAndNeverMain() throws {
        let (editor, _) = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request())
        let panel = editor.panel
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.level == .floating)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.hasShadow)
        // A key borderless panel's shadow rim follows the window's shape: rounded like the card, never a square.
        let layer = try #require(panel.contentView?.layer)
        #expect(layer.cornerRadius == EditorLayout.cornerRadius)
        #expect(layer.cornerCurve == .continuous)
        #expect(layer.masksToBounds)
        #expect(!panel.isMovableByWindowBackground)
        // Off-screen it is never made key, and nothing activated the app.
        #expect(!panel.isKeyWindow)
        #expect(editor.isOpen)
    }

    @Test func openPlacesThePanelAtTheKindsWidthCentredOnTheDrop() throws {
        let (editor, _) = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request())
        let frame = editor.panel.frame
        #expect(frame.width == EditorLayout.width(for: .trim))
        #expect(frame.height > 0 && frame.height <= EditorLayout.maxHeight)
        #expect(abs(frame.midX - anchor.x) < 1 && abs(frame.midY - anchor.y) < 1)
        #expect(editor.session is FakeEditorSession)
        #expect(editor.phase == .editing)
    }

    /// A change reported mid-layout is measured while SwiftUI skips the reentrant pass: the panel keeps its size
    /// rather than shrinking to nothing (check 31's invisible Compress to size panel).
    @Test func aChangeReportedDuringLayoutKeepsThePanelsSize() async throws {
        let session = ChangesDuringLayoutSession()
        let editor = EditorController(
            settings: SettingsStore(defaults: EphemeralDefaults()), perform: { Jobs().perform($0, $1, $2, $3) },
            release: { _, _ in }, desktop: .offScreen, makeSession: { _, _ in session }
        )
        defer { editor.cancel() }
        editor.open(EditorRequest(kind: .targetSize, preset: try trimPreset(), files: [clip], anchor: anchor, flags: []))
        let opened = editor.panel.frame
        #expect(opened.height > 0)
        #expect(await eventually { session.reported > 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(editor.panel.frame == opened)
        #expect(editor.isOpen)
    }

    @Test func openStartsTheSessionsLoad() async throws {
        let session = FakeEditorSession()
        let (editor, _) = makeEditor(Jobs(), sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        #expect(await eventually { session.loadStarted })
        editor.cancel()
        #expect(await eventually { session.loadCancelled })
    }

    @Test func theAnnouncementNamesTheEditorAndTheFiles() {
        #expect(EditorController.announcement(title: "Trim", files: [clip])
                == "Trim editor, pomelo-editor-test-clip.mov")
        #expect(EditorController.announcement(title: "Compress to size", files: [clip, clip, clip])
                == "Compress to size editor, 3 files")
    }

    @Test func theFileLabelIsShortenedInTheMiddle() {
        let long = URL(fileURLWithPath: "/tmp/a-very-long-holiday-video-from-the-beach.mov")
        #expect(EditorChromeState.fileLabel(for: [long]) == "a-very-long-holiday-vide\u{2026}ach.mov")
        #expect(EditorChromeState.fileLabel(for: [long]).count == 32)
        #expect(EditorChromeState.fileLabel(for: [clip]) == "pomelo-editor-test-clip.mov")
        #expect(EditorChromeState.fileLabel(for: [URL(fileURLWithPath: "/a/b.mov")]) == "b.mov")
        #expect(EditorChromeState.fileLabel(for: [clip, clip]) == "2 files")
    }

    @Test func escCancelsWithoutRunningAnything() throws {
        let jobs = Jobs()
        let (editor, _) = makeEditor(jobs)
        editor.open(try request())
        editor.panel.cancelOperation(nil)
        #expect(!editor.isOpen)
        #expect(!editor.panel.isVisible)
        #expect(editor.session == nil)
        #expect(jobs.performed.isEmpty)
        #expect(jobs.releases.isEmpty)
    }

    @Test func commandWAndPeriodCancel() throws {
        let jobs = Jobs()
        let (editor, _) = makeEditor(jobs, sessions: [FakeEditorSession(), FakeEditorSession()])
        editor.open(try request())
        #expect(editor.panel.performKeyEquivalent(with: key("w", [.command])))
        #expect(!editor.isOpen)
        editor.open(try request())
        #expect(editor.panel.performKeyEquivalent(with: key(".", [.command])))
        #expect(!editor.isOpen)
        #expect(jobs.performed.isEmpty)
    }

    @Test func returnSavesOnlyWhenNothingBlocks() throws {
        let jobs = Jobs()
        jobs.duration = .seconds(30)
        let session = FakeEditorSession()
        session.blocker = "Nothing to trim"
        let (editor, _) = makeEditor(jobs, sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        editor.confirm()
        #expect(jobs.performed.isEmpty)
        #expect(editor.phase == .editing)

        session.blocker = nil
        editor.confirm()
        #expect(jobs.performed.count == 1)
        let performed = try #require(jobs.performed.first)
        #expect(performed.preset.id == "trim")
        #expect(performed.preset.options.edit == .trim(TimeRange(start: 1.5, end: 2)))
        #expect(performed.preset.nameSuffix == "trimmed")
        #expect(performed.files == [clip])
        #expect(performed.anchor == anchor)
        #expect(editor.phase == .working(job: jobs.handles[0].id))
        // A second Return while saving does nothing.
        editor.confirm()
        #expect(jobs.performed.count == 1)
    }

    @Test func aSuccessClosesAndReleasesTheJobShown() async throws {
        let jobs = Jobs()
        let (editor, _) = makeEditor(jobs)
        editor.open(try request())
        editor.confirm()
        #expect(await eventually { !editor.isOpen })
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: true)])
    }

    @Test func aQuickFailureStaysInTheEditorWithTheChoices() async throws {
        let jobs = Jobs()
        jobs.outcome = .failed(trimFailure)
        jobs.duration = .milliseconds(10)
        let session = FakeEditorSession()
        session.start = 0.75
        let (editor, _) = makeEditor(jobs, sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        editor.confirm()

        let failed = EditorPhase.failed(WheelAlert(title: "Couldn't trim clip.mov", subtitle: "It has no sound"))
        #expect(await eventually { editor.phase == failed })
        #expect(editor.isOpen)
        #expect(editor.session === session)
        #expect(session.start == 0.75)
        #expect(!session.loadCancelled)
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: true)])

        jobs.outcome = .succeeded
        editor.confirm()
        #expect(jobs.performed.count == 2)
        #expect(jobs.performed[1].preset.options.edit == .trim(TimeRange(start: 0.75, end: 2)))
        #expect(await eventually { !editor.isOpen })
        #expect(jobs.releases.last == Release(id: jobs.handles[1].id, outcomeShown: true))
    }

    @Test func aSessionChangeAfterAFailureReturnsToEditing() async throws {
        let jobs = Jobs()
        jobs.outcome = .failed(trimFailure)
        jobs.duration = .milliseconds(10)
        let session = FakeEditorSession()
        let (editor, _) = makeEditor(jobs, sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        editor.confirm()
        #expect(await eventually { if case .failed = editor.phase { true } else { false } })
        #expect(editor.chromeState.phase != .editing)

        session.blocker = "Nothing to trim"
        #expect(editor.phase == .editing)
        #expect(editor.chromeState.phase == .editing)
        #expect(editor.chromeState.blocker == "Nothing to trim")
        // A change while saving does not end the wait.
        session.blocker = nil
        jobs.duration = .seconds(30)
        editor.confirm()
        session.note = "Still saving"
        session.blocker = "Changed"
        #expect(editor.phase == .working(job: jobs.handles[1].id))
    }

    @Test func aFailureWithABlockerCannotBeSavedAgain() async throws {
        let jobs = Jobs()
        jobs.outcome = .failed(trimFailure)
        let session = FakeEditorSession()
        let (editor, _) = makeEditor(jobs, sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        editor.confirm()
        #expect(await eventually { if case .failed = editor.phase { true } else { false } })
        session.blocker = "Nothing to trim"
        editor.confirm()
        #expect(jobs.performed.count == 1)
    }

    @Test func aSlowJobMovesToThePill() async throws {
        let jobs = Jobs()
        jobs.duration = .milliseconds(400)
        let (editor, _) = makeEditor(jobs, followUp: DropFollowUp(resultWait: .milliseconds(50)))
        editor.open(try request())
        let saved = ContinuousClock.now
        editor.confirm()
        #expect(await eventually { !editor.isOpen })
        #expect(ContinuousClock.now - saved < .milliseconds(380))
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: false)])
        // The job's end, later, releases nothing more.
        _ = await jobs.handles[0].outcome.value
        try await Task.sleep(for: .milliseconds(30))
        #expect(jobs.releases.count == 1)
    }

    @Test func aNoteClosesTheEditorAndShowsInThePill() async throws {
        let jobs = Jobs()
        jobs.outcome = .noted(ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only"))
        let (editor, _) = makeEditor(jobs)
        editor.open(try request())
        editor.confirm()
        #expect(await eventually { !editor.isOpen })
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: false)])
    }

    @Test func closingWhileSavingLetsTheJobGoOn() async throws {
        let jobs = Jobs()
        jobs.duration = .milliseconds(300)
        let (editor, _) = makeEditor(jobs)
        editor.open(try request())
        editor.confirm()
        editor.cancel()
        #expect(!editor.isOpen)
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: false)])
        #expect(!jobs.handles[0].outcome.isCancelled)
        #expect(await jobs.handles[0].outcome.value == .succeeded)
        try await Task.sleep(for: .milliseconds(30))
        #expect(jobs.releases.count == 1)
    }

    @Test func losingKeyKeepsTheEditorAndItsChoices() throws {
        let session = FakeEditorSession()
        session.start = 0.25
        let (editor, _) = makeEditor(Jobs(), sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        editor.panel.resignKey()
        #expect(editor.isOpen)
        #expect(editor.phase == .editing)
        #expect(editor.session === session)
        #expect(session.start == 0.25)
        #expect(EditorHostingView(rootView: EditorChrome()).acceptsFirstMouse(for: nil))
    }

    @Test func aSecondEditorReplacesTheFirst() async throws {
        let jobs = Jobs()
        let first = FakeEditorSession()
        let second = FakeEditorSession()
        let (editor, _) = makeEditor(jobs, sessions: [first, second])
        defer { editor.cancel() }
        editor.open(try request())
        #expect(await eventually { first.loadStarted })
        editor.open(try request([clip, clip]))
        #expect(editor.session === second)
        #expect(editor.isOpen)
        #expect(await eventually { first.loadCancelled })
        #expect(first.onChange == nil)
        #expect(jobs.performed.isEmpty)
    }

    @Test func replacingAnEditorThatIsSavingHandsItsJobToThePill() throws {
        let jobs = Jobs()
        jobs.duration = .seconds(30)
        let (editor, _) = makeEditor(jobs, sessions: [FakeEditorSession(), FakeEditorSession()])
        defer { editor.cancel() }
        editor.open(try request())
        editor.confirm()
        editor.open(try request())
        #expect(editor.phase == .editing)
        #expect(jobs.releases == [Release(id: jobs.handles[0].id, outcomeShown: false)])
    }

    @Test func commandKeysMapToStandardEditActions() {
        #expect(EditorPanel.standardAction(for: key("x", [.command])) == #selector(NSText.cut(_:)))
        #expect(EditorPanel.standardAction(for: key("c", [.command])) == #selector(NSText.copy(_:)))
        #expect(EditorPanel.standardAction(for: key("v", [.command])) == #selector(NSText.paste(_:)))
        #expect(EditorPanel.standardAction(for: key("a", [.command])) == #selector(NSText.selectAll(_:)))
        #expect(EditorPanel.standardAction(for: key("z", [.command])) == Selector(("undo:")))
        #expect(EditorPanel.standardAction(for: key("Z", [.command, .shift])) == Selector(("redo:")))
        #expect(EditorPanel.standardAction(for: key("k", [.command])) == nil)
        #expect(EditorPanel.standardAction(for: key("v", [])) == nil)
        #expect(EditorPanel.standardAction(for: key("v", [.command, .option])) == nil)
        #expect(EditorPanel.cancels(key("w", [.command])))
        #expect(EditorPanel.cancels(key(".", [.command])))
        #expect(!EditorPanel.cancels(key("w", [])))
    }

    /// While the saved job runs the choices it was given stay on show: ⌘Z and ⇧⌘Z are taken and do nothing, then
    /// work again once a quick failure brings the editor back.
    @Test func undoDoesNothingWhileSaving() async throws {
        let jobs = Jobs()
        jobs.outcome = .failed(trimFailure)
        jobs.duration = .milliseconds(300)
        let (editor, _) = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request())
        let undo = try #require(editor.panel.undoManager)
        var undone = 0
        undo.registerUndo(withTarget: editor.panel) { _ in undone += 1 }
        #expect(!editor.panel.freezesUndo)

        editor.confirm()
        #expect(editor.panel.freezesUndo)
        #expect(editor.panel.performKeyEquivalent(with: key("z", [.command])))
        #expect(editor.panel.performKeyEquivalent(with: key("Z", [.command, .shift])))
        #expect(undone == 0 && undo.canUndo)

        #expect(await eventually { if case .failed = editor.phase { true } else { false } })
        #expect(!editor.panel.freezesUndo)
    }

    @Test func theChosenSizeIsRememberedOnConfirm() throws {
        let jobs = Jobs()
        jobs.duration = .seconds(30)
        let (editor, settings) = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request())
        #expect(settings.settings.editorMemory.targetBytes.isEmpty)
        editor.confirm()
        #expect(settings.settings.editorMemory.targetBytes == ["video": 10_000_000])
    }

    /// S18: an editor a Shelf wheel opened hands its job the Shelf's callback; any other editor hands it none.
    @Test func saveFromAShelfWheelPassesOnResult() throws {
        let jobs = Jobs()
        let (editor, _) = makeEditor(jobs)
        defer { editor.cancel() }
        var taken: [FileResult] = []
        var fromShelf = try request()
        fromShelf.onResult = { taken.append($0) }
        editor.open(fromShelf)
        editor.confirm()
        let saved = try #require(jobs.performed.first)
        let output = URL(fileURLWithPath: "/tmp/pomelo-editor-test-clip-trimmed.mov")
        let result = FileResult.succeeded(source: clip, outputs: [output], note: nil)
        let onResult = try #require(saved.onResult)
        onResult(result)
        #expect(taken == [result])

        editor.open(try request())
        editor.confirm()
        #expect(jobs.performed.count == 2)
        #expect(jobs.performed[1].onResult == nil)
    }

    @Test func sessionChangesRedrawTheChrome() throws {
        let session = FakeEditorSession()
        let (editor, _) = makeEditor(Jobs(), sessions: [session])
        defer { editor.cancel() }
        editor.open(try request())
        #expect(editor.chromeState.blocker == nil)
        session.blocker = "Nothing to trim"
        #expect(editor.chromeState.blocker == "Nothing to trim")
        #expect(editor.chromeState.title == "Trim")
        #expect(editor.chromeState.confirmTitle == "Save Trimmed Copy")
    }
}

/// A key-down for the panel's key-equivalent mapping; the event is only built, never posted.
func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: 0)!
}
