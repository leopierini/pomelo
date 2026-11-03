import AppKit
import Foundation
import PomeloCore
import PomeloEngines
import ImageIO
import PomeloUIModel
import SwiftUI
import Testing
@testable import Pomelo

private let anchor = CGPoint(x: -29_000, y: -29_000)

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-editor-session-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A file of `bytes` bytes that only needs a name and a size: the session never decodes it unless a test loads it.
private func bigFile(_ name: String, bytes: Int, in directory: URL) throws -> URL {
    let url = directory.appending(path: name)
    try Data(count: bytes).write(to: url)
    return url
}

/// What the Compress to size editor hands the job, through the real controller and the real session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct EditorSessionTests {
    private struct Performed {
        var preset: Preset
        var files: [URL]
    }

    private final class Jobs {
        var performed: [Performed] = []
    }

    private func request(_ files: [URL]) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .targetSize, settings: AppSettings()))
        return EditorRequest(kind: .targetSize, preset: preset, files: files, anchor: anchor, flags: [])
    }

    private func makeEditor(_ jobs: Jobs, _ settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()))
        -> EditorController {
        EditorController(
            settings: settings,
            perform: { preset, files, _, _ in
                jobs.performed.append(Performed(preset: preset, files: files))
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    private func session(_ editor: EditorController) throws -> TargetSizeSession {
        try #require(editor.session as? TargetSizeSession)
    }

    @Test func confirmRunsCompressToSizeWithTheBytesAndSuffix() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try session(editor)
        #expect(session.title == "Compress to size")
        // Nothing remembered: the 500 KB chip (P207).
        #expect(session.model.text == "500" && session.model.unit == .kb)

        editor.confirm()
        let performed = try #require(jobs.performed.first)
        #expect(performed.preset.id == "compress-to-size")
        #expect(performed.preset.options.targetBytes == 500_000)
        #expect(performed.preset.nameSuffix == "under-500kb")
        #expect(performed.files == [photo])
    }

    @Test func aTypedSizeInKilobytesGoesToTheJob() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try session(editor)
        session.model.text = "300"
        session.model.unit = .kb
        #expect(editor.chromeState.confirmTitle == "Save Smaller Copy")
        editor.confirm()
        #expect(jobs.performed.first?.preset.options.targetBytes == 300_000)
        #expect(jobs.performed.first?.preset.nameSuffix == "under-300kb")
    }

    @Test func aBlockedSizeCannotBeSaved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try bigFile("small.jpg", bytes: 400_000, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([small]))
        #expect(editor.chromeState.blocker == "It's already under 500 KB")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
        try session(editor).model.choose(100_000)
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == "Lowers the quality first, then the size in pixels")
    }

    @Test func returnInTheFieldSaves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([photo]))
        var confirmed = 0
        let host = NSHostingView(rootView: try session(editor).makeContent()
            .environment(\.editorConfirm, EditorConfirmAction(run: { confirmed += 1 })))
        let window = NSPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 340, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        let field = try #require(Self.firstTextField(in: host))
        window.makeFirstResponder(field)
        let editorView = try #require(field.currentEditor())
        editorView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(await eventually { confirmed == 1 })
        window.orderOut(nil)
    }

    @Test func theSizeIsRememberedPerKind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        let pdf = try bigFile("doc.pdf", bytes: 3_000_000, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let jobs = Jobs()
        let editor = makeEditor(jobs, settings)
        defer { editor.cancel() }

        editor.open(try request([photo]))
        try session(editor).model.text = "300"
        try session(editor).model.unit = .kb
        editor.confirm()
        editor.open(try request([pdf]))
        #expect(try session(editor).model.targetBytes == 2_000_000)
        // Both separators read as a decimal point.
        try session(editor).model.text = "1.5"
        editor.confirm()
        #expect(settings.settings.editorMemory.targetBytes == ["image": 300_000, "pdf": 1_500_000])

        editor.open(try request([photo]))
        #expect(try session(editor).model.targetBytes == 300_000 && session(editor).model.unit == .kb)
        editor.open(try request([pdf]))
        #expect(try session(editor).model.targetBytes == 1_500_000 && session(editor).model.unit == .mb)
    }

    /// The field writes its text back unchanged as it takes focus, from inside the hosting view's layout: that is no
    /// change, and reporting it made the controller measure the chrome mid-layout and shrink the panel to nothing.
    @Test func anUnchangedModelIsNoChange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        let session = TargetSizeSession(request: try request([photo]), memory: EditorMemory())
        var changes = 0
        session.onChange = { changes += 1 }

        session.model.text = session.model.text
        session.model.unit = session.model.unit
        #expect(changes == 0)
        session.model.text = "300"
        #expect(changes == 1)
    }

    /// Check 31: Compress to size… on an image's Tools page opens its panel, as the wheel opens it, and the panel
    /// keeps its size once the file is read and the field has focus.
    @Test func compressToSizeOpensForAnImageFromTheWheel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 4032, height: 3024, in: dir)
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        let content = AppEnvironment.makeContentBuilder(
            settings: AppSettings(), available: await registry.planner(),
            all: await registry.planner(includingMissing: true), installHints: [:], unsupportedReasons: [:],
            installable: [])
        let tools = try #require(content.pages(for: [photo]).first { $0.kind == .tools })
        let slice = try #require(tools.slices.first { $0.id == "editor.compress-to-size" })
        #expect(slice.isEnabled)
        let request = try #require(AppEnvironment.editorRequest(for: slice, on: [photo], at: anchor, content: content))
        #expect(request.kind == .targetSize)

        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(request)
        let session = try session(editor)
        #expect(session.model.text == "500" && session.model.unit == .kb)
        #expect(session.model.chips == [20_000, 50_000, 100_000, 500_000])
        #expect(session.model.chips.map { "Under \(TargetSize.label(bytes: $0, locale: session.model.locale))" }
                == ["Under 20 KB", "Under 50 KB", "Under 100 KB", "Under 500 KB"])
        let opened = editor.panel.frame
        #expect(opened.height > 0)

        // The load (an image's facts are its size, already known) and the field's focus, as the live panel's
        // display passes run them.
        try await Task.sleep(for: .milliseconds(700))
        #expect(editor.isOpen)
        // Within a point: a refit rounds the fitting height its own way.
        #expect(abs(editor.panel.frame.height - opened.height) <= 1)
        #expect(editor.panel.frame.width == EditorLayout.width(for: .targetSize))
    }

    @Test func theFirstFilesKindDecides() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try bigFile("clip.mov", bytes: 30_000_000, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([movie]))
        #expect(try session(editor).model.text == "20" && session(editor).model.unit == .mb)
        #expect(try session(editor).model.chips == [10_000_000, 20_000_000, 50_000_000, 100_000_000])
    }

    @Test func loadingAMovieFillsInThePlanAndTheNote() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, transform: quarterTurn, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([movie]))
        let session = try session(editor)
        session.model.text = "300"
        session.model.unit = .kb
        #expect(session.note == nil)
        #expect(await eventually { session.note != nil })
        let source = try #require(session.model.sources.first)
        #expect(abs((source.durationSeconds ?? 0) - 2) < 0.05)
        // The stored size, not the upright one: the engine plans from it.
        #expect(source.width == 320 && source.height == 240)
        #expect(source.hasAudio)
        #expect(session.note?.hasPrefix("About ") == true)
        #expect(editor.chromeState.note == session.note)
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = firstTextField(in: sub) { return found } }
        return nil
    }
}

/// What the Trim and Split editors load and hand the job, through the real controller and the real sessions.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct TimelineSessionTests {
    private final class Jobs {
        var performed: [Preset] = []
    }

    private func request(_ kind: EditorKind, _ file: URL, flags: EdgeFlags = []) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: kind, settings: AppSettings()))
        return EditorRequest(kind: kind, preset: preset, files: [file], anchor: anchor, flags: flags)
    }

    private func makeEditor(_ jobs: Jobs) -> EditorController {
        EditorController(
            settings: SettingsStore(defaults: EphemeralDefaults()),
            perform: { preset, _, _, _ in
                jobs.performed.append(preset)
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    /// The session once its file's facts have loaded.
    private func loaded<S: TimelineSession>(_ editor: EditorController, as type: S.Type) async throws -> S {
        let session = try #require(editor.session as? S)
        #expect(await eventually { session.model != nil })
        return session
    }

    @Test func trimSessionLoadsDurationAndFilmstrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: true, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.trim, movie))
        let session = try #require(editor.session as? TrimSession)
        #expect(session.title == "Trim")
        #expect(editor.chromeState.blocker != nil, "nothing can be saved before the file is read")
        #expect(await eventually { session.filmstrip.count == 12 })
        let model = try #require(session.model)
        #expect(abs(model.duration - 6) < 0.1)
        #expect(abs(model.step - 1.0 / 30) < 1e-6)
        #expect(session.showsVideo)
        #expect(session.poster != nil)
        #expect(session.waveform.isEmpty)
        #expect(editor.chromeState.blocker == "Nothing to trim")
    }

    @Test func anAudioTrimLoadsAWaveform() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.wav(seconds: 2, amplitude: 0.5, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.trim, tone))
        let session = try await loaded(editor, as: TrimSession.self)
        #expect(!session.showsVideo)
        #expect(await eventually { !session.waveform.isEmpty })
        #expect(session.waveform.allSatisfy { $0 > 0.2 })
        #expect(session.filmstrip.isEmpty)
        #expect(session.model?.step == 0.01)
    }

    @Test func anUnreadableFileCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.mov")
        try Data("not a movie".utf8).write(to: broken)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(.trim, broken))
        let session = try #require(editor.session as? TrimSession)
        #expect(await eventually { session.loadFailed })
        #expect(editor.chromeState.blocker == "The file may be damaged")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }

    @Test func trimSessionSavesTheRange() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 4, withAudio: false, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(.trim, movie))
        let session = try await loaded(editor, as: TrimSession.self)
        session.drag(.start, to: 1)
        session.drag(.end, to: 3)
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.confirmTitle == "Save Trimmed Copy")
        #expect(session.model?.playhead == 3, "the playhead follows the grip being moved")
        editor.confirm()
        let preset = try #require(jobs.performed.first)
        #expect(preset.id == "trim")
        #expect(preset.options.edit == .trim(TimeRange(start: 1, end: 3)))
        #expect(preset.nameSuffix == "trimmed")
    }

    @Test func theKeysSetTheRangeAtThePlayhead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 4, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.trim, movie))
        let session = try await loaded(editor, as: TrimSession.self)
        session.scrub(to: 1)
        #expect(session.perform(.setStart))
        session.scrub(to: 2.5)
        #expect(session.perform(.setEnd))
        #expect(session.model?.start == 1 && session.model?.end == 2.5)
        // Arrows move the selected handle a frame, or a second with Shift; the playhead follows it.
        session.select(.end)
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.model?.end == 3.5 && session.model?.playhead == 3.5)
        session.select(.start)
        #expect(session.perform(.nudge(-1, coarse: false)))
        #expect(abs((session.model?.start ?? 0) - (1 - 1.0 / 30)) < 1e-9)
        // Split's keys do nothing in Trim.
        #expect(!session.perform(.addPoint))
        #expect(session.model?.points.isEmpty == true)
        // VoiceOver's increments are one step each.
        session.adjust(.start, by: 1)
        #expect(abs((session.model?.start ?? 0) - 1) < 1e-9)
    }

    @Test func splitSessionSavesThePoints() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(.split, movie))
        let session = try await loaded(editor, as: SplitSession.self)
        #expect(session.title == "Split")
        #expect(editor.chromeState.confirmTitle == "Save Parts")
        #expect(editor.chromeState.blocker == "Add a split point (S)")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
        for point in [4.0, 2.0, 5.0] {
            session.scrub(to: point)
            #expect(session.perform(.addPoint))
        }
        #expect(session.selection == .playhead, "P83: the selection stays on the playhead")
        session.select(.point(2))
        #expect(session.perform(.removeSelectedPoint))
        #expect(session.model?.points == [2, 4])
        #expect(session.selection == .playhead)
        #expect(!session.perform(.setStart))
        #expect(editor.chromeState.blocker == nil)
        editor.confirm()
        let preset = try #require(jobs.performed.first)
        #expect(preset.id == "split-video")
        #expect(preset.options.edit == .split([2, 4]))
        #expect(preset.nameSuffix == "parts")
    }

    /// P83: points placed, chosen and removed with the keys alone.
    @Test func splitPointsAreReachableFromTheKeyboard() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.split, movie))
        let session = try await loaded(editor, as: SplitSession.self)
        // S, ⇧→ twice, S: two points, the arrows still on the playhead.
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.perform(.addPoint))
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.perform(.addPoint))
        #expect(session.model?.points == [1, 3])
        #expect(session.selectableHandles == [.playhead, .point(0), .point(1)])
        // Tab to the first point, nudge it, ⌫ removes it; ⇧Tab wraps around.
        #expect(session.perform(.selectNext))
        #expect(session.selection == .point(0))
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.model?.points == [2, 3])
        #expect(session.perform(.removeSelectedPoint))
        #expect(session.model?.points == [3])
        #expect(session.selection == .playhead)
        #expect(session.perform(.selectPrevious))
        #expect(session.selection == .point(0))
        #expect(session.perform(.selectNext))
        #expect(session.selection == .playhead)
    }

    /// A point chosen with Tab stays the same point when S adds one before it, which shifts the indexes.
    @Test func aChosenPointStaysChosenWhenAnEarlierOneIsAdded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 6, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.split, movie))
        let session = try await loaded(editor, as: SplitSession.self)
        session.scrub(to: 4)
        #expect(session.perform(.addPoint))
        session.scrub(to: 1)
        #expect(session.perform(.selectNext))
        #expect(session.selection == .point(0))

        #expect(session.perform(.addPoint))
        #expect(session.model?.points == [1, 4])
        #expect(session.selection == .point(1))
        #expect(session.perform(.nudge(1, coarse: true)))
        #expect(session.model?.points == [1, 5], "the arrows still move the point at 4")
    }

    @Test func tabCyclesTheTrimHandles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.trim, movie))
        let session = try await loaded(editor, as: TrimSession.self)
        var visited: [TimelineHandle] = []
        for _ in 0..<3 {
            #expect(session.perform(.selectNext))
            visited.append(session.selection)
        }
        #expect(visited == [.start, .end, .playhead])
        #expect(session.perform(.selectPrevious))
        #expect(session.selection == .end)
    }

    /// An end moved behind the player stops playback at once; a boundary it would cross is armed.
    @Test func playbackStopsWhenTheEndIsReachedOrPassed() {
        var stop = PlaybackStop(end: 6)
        // Until the seek to the start finishes, the player's time is stale and decides nothing.
        #expect(stop.retarget(end: 5, now: 8) == .keepPlaying)
        #expect(stop.tick(8) == .keepPlaying)
        #expect(stop.start() == .armBoundary(5))
        #expect(stop.tick(4.9) == .keepPlaying)
        #expect(stop.tick(5) == .stop)
        #expect(stop.retarget(end: 4, now: 4.5) == .stop, "O pressed with the player already past the new end")
        #expect(stop.retarget(end: 4.5, now: 4.5) == .stop)
        #expect(stop.retarget(end: 7, now: 4.5) == .armBoundary(7))
        #expect(stop.retarget(end: 7, now: nil) == .armBoundary(7))
        #expect(stop.end == 7)
    }

    @Test func theNoteFollowsTheFlags() throws {
        let movie = URL(fileURLWithPath: "/nonexistent/clip.mov")
        #expect(TrimSession(request: try request(.trim, movie)).note == "Cut without re-encoding")
        #expect(TrimSession(request: try request(.trim, movie, flags: .lossy)).note == "The cut re-encodes the file")
        #expect(SplitSession(request: try request(.split, movie)).note == "Each part is cut without re-encoding")
        #expect(SplitSession(request: try request(.split, movie, flags: .lossy)).note == "The cut re-encodes the file")
    }

    @Test func playbackNeverStartsOffScreen() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(.trim, movie))
        let session = try await loaded(editor, as: TrimSession.self)
        editor.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(session.perform(.playPause))
        #expect(!session.playback.isPlaying)
        #expect(session.playback.player == nil)
    }

    /// The view's onDisappear is not the only way out: closing the editor tears the player down itself.
    @Test func closingTheEditorTearsThePlayerDown() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        editor.open(try request(.trim, movie))
        let session = try await loaded(editor, as: TrimSession.self)
        // Created but never played, as on a desktop that plays media before the first click.
        session.playback.enable()
        #expect(session.playback.player != nil)
        editor.cancel()
        #expect(session.playback.player == nil)
    }

    @Test func timelineKeysMapToActions() {
        #expect(TimelineKeys.action(for: "i", modifiers: []) == .setStart)
        #expect(TimelineKeys.action(for: "o", modifiers: []) == .setEnd)
        #expect(TimelineKeys.action(for: "s", modifiers: []) == .addPoint)
        #expect(TimelineKeys.action(for: .space, modifiers: []) == .playPause)
        #expect(TimelineKeys.action(for: .leftArrow, modifiers: []) == .nudge(-1, coarse: false))
        #expect(TimelineKeys.action(for: .rightArrow, modifiers: []) == .nudge(1, coarse: false))
        #expect(TimelineKeys.action(for: .leftArrow, modifiers: .shift) == .nudge(-1, coarse: true))
        #expect(TimelineKeys.action(for: .rightArrow, modifiers: .shift) == .nudge(1, coarse: true))
        // Arrow keys carry the numeric-pad flag.
        #expect(TimelineKeys.action(for: .rightArrow, modifiers: .numericPad) == .nudge(1, coarse: false))
        #expect(TimelineKeys.action(for: .delete, modifiers: []) == .removeSelectedPoint)
        #expect(TimelineKeys.action(for: .deleteForward, modifiers: []) == .removeSelectedPoint)
        #expect(TimelineKeys.action(for: KeyEquivalent("\u{7F}"), modifiers: []) == .removeSelectedPoint)
        #expect(TimelineKeys.action(for: "I", modifiers: .shift) == .setStart)
        // Command keys belong to the panel (⌘W, ⌘V…); Return and Esc to the chrome.
        #expect(TimelineKeys.action(for: "i", modifiers: .command) == nil)
        #expect(TimelineKeys.action(for: .leftArrow, modifiers: .command) == nil)
        #expect(TimelineKeys.action(for: .return, modifiers: []) == nil)
        #expect(TimelineKeys.action(for: .escape, modifiers: []) == nil)
        #expect(TimelineKeys.action(for: "x", modifiers: []) == nil)
        // P83: Tab and ⇧Tab choose the handle.
        #expect(TimelineKeys.action(for: .tab, modifiers: []) == .selectNext)
        #expect(TimelineKeys.action(for: .tab, modifiers: .shift) == .selectPrevious)
        #expect(TimelineKeys.action(for: KeyEquivalent("\u{19}"), modifiers: .shift) == .selectPrevious)
        #expect(TimelineKeys.action(for: .tab, modifiers: .command) == nil)
    }
}

/// What the Crop editor loads and hands the job, through the real controller and the real session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct CropSessionTests {
    private final class Jobs {
        var performed: [Preset] = []
    }

    private func request(_ file: URL) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .crop, settings: AppSettings()))
        return EditorRequest(kind: .crop, preset: preset, files: [file], anchor: anchor, flags: [.lossy])
    }

    private func makeEditor(_ jobs: Jobs, _ settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()))
        -> EditorController {
        EditorController(
            settings: settings,
            perform: { preset, _, _, _ in
                jobs.performed.append(preset)
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    /// The session once its picture's size and preview have loaded.
    private func loaded(_ editor: EditorController) async throws -> CropSession {
        let session = try #require(editor.session as? CropSession)
        #expect(await eventually { session.model != nil && session.preview != nil })
        return session
    }

    @Test func cropSessionUsesTheDisplayedSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 × 300 with orientation 6: shown 300 × 400.
        let photo = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(photo))
        let session = try #require(editor.session as? CropSession)
        #expect(session.title == "Crop")
        #expect(editor.chromeState.confirmTitle == "Save Cropped Copy")
        #expect(editor.chromeState.blocker == "Reading the file\u{2026}")
        _ = try await loaded(editor)
        #expect(session.model?.pixelSize == CGSize(width: 300, height: 400))
        #expect(session.model?.isPortrait == true)
        #expect(session.preview.map { $0.height > $0.width } == true, "the preview is upright")
        #expect(editor.chromeState.blocker == "Nothing to crop")
        #expect(editor.chromeState.note == "Saves a new file at the same quality")
    }

    @Test func cropSessionSavesTheRect() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(photo))
        let session = try await loaded(editor)
        editor.confirm()
        #expect(jobs.performed.isEmpty, "the whole picture is nothing to crop")
        session.setRatio(.square)
        #expect(editor.chromeState.blocker == nil)
        #expect(session.model?.readout == "300 \u{00D7} 300")
        editor.confirm()
        let preset = try #require(jobs.performed.first)
        #expect(preset.id == "crop")
        #expect(preset.options.edit == .crop(UnitRect(x: 50.0 / 400, y: 0, width: 0.75, height: 1)))
        #expect(preset.options.quality == 0.92)
        #expect(preset.nameSuffix == "cropped")
    }

    @Test func cropRatioIsRemembered() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let editor = makeEditor(Jobs(), settings)
        defer { editor.cancel() }

        editor.open(try request(photo))
        try await loaded(editor).setRatio(.sixteenNine)
        editor.confirm()
        #expect(settings.settings.editorMemory.cropRatio == "sixteenNine")

        editor.open(try request(photo))
        let session = try await loaded(editor)
        #expect(session.model?.ratio == .sixteenNine)
        #expect(session.model?.readout == "400 \u{00D7} 225")
        #expect(editor.chromeState.blocker == nil)
    }

    @Test func dragsFollowThePointerAndKeysNudge() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(photo))
        let session = try await loaded(editor)

        session.drag(.bottomRight, translation: CGSize(width: -0.5, height: -0.5))
        #expect(session.isDragging)
        session.endDrag()
        #expect(!session.isDragging)
        #expect(session.model?.readout == "200 \u{00D7} 150")
        // Past the edge and back: the area moves again as soon as the pointer does, from where it began.
        session.drag(.body, translation: CGSize(width: 3, height: 0))
        #expect(session.model?.rect.x == 0.5)
        session.drag(.body, translation: CGSize(width: 0.25, height: 0))
        #expect(session.model?.rect.x == 0.25)
        session.endDrag()

        #expect(session.perform(.move(dx: 1, dy: 0, coarse: true)))
        #expect(session.model?.rect.x == 110.0 / 400)
        #expect(session.perform(.resize(dx: 0, dy: 1, coarse: false)))
        #expect(session.model?.readout == "200 \u{00D7} 151")
        #expect(editor.chromeState.blocker == nil)
    }

    @Test func aVideoShowsAFrameAndSaysItReencodes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.quadrantMovie(width: 320, height: 180, seconds: 2, rotated90: true, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(movie))
        let session = try await loaded(editor)
        #expect(session.isVideo)
        #expect(session.model?.pixelSize == CGSize(width: 180, height: 320))
        #expect(abs((session.durationSeconds ?? 0) - 2) < 0.1)
        #expect(editor.chromeState.note == "Re-encodes the video")
        let first = try #require(session.preview)
        #expect(first.height > first.width, "the frame is upright")
        session.showFrame(at: 1.5)
        #expect(session.frameSeconds == 1.5)
        #expect(await eventually { session.preview !== first })
    }

    @Test func anUnreadableFileCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: broken)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(broken))
        let session = try #require(editor.session as? CropSession)
        #expect(await eventually { session.loadFailed })
        #expect(editor.chromeState.blocker == "The file may be damaged")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }

    @Test func cropKeysMapToActions() {
        #expect(CropKeys.action(for: .leftArrow, modifiers: []) == .move(dx: -1, dy: 0, coarse: false))
        #expect(CropKeys.action(for: .upArrow, modifiers: .shift) == .move(dx: 0, dy: -1, coarse: true))
        #expect(CropKeys.action(for: .downArrow, modifiers: .numericPad) == .move(dx: 0, dy: 1, coarse: false))
        #expect(CropKeys.action(for: .rightArrow, modifiers: .option) == .resize(dx: 1, dy: 0, coarse: false))
        #expect(CropKeys.action(for: .downArrow, modifiers: [.option, .shift]) == .resize(dx: 0, dy: 1, coarse: true))
        // Command keys belong to the panel; Return and Esc to the chrome.
        #expect(CropKeys.action(for: .leftArrow, modifiers: .command) == nil)
        #expect(CropKeys.action(for: .return, modifiers: []) == nil)
        #expect(CropKeys.action(for: .escape, modifiers: []) == nil)
        #expect(CropKeys.action(for: "a", modifiers: []) == nil)
    }
}

/// What the Resize editor reads and hands the job (P197), through the real controller and the real session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct ResizeSessionTests {
    private final class Jobs {
        var performed: [(preset: Preset, files: [URL])] = []
    }

    private func request(_ files: [URL]) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .resize, settings: AppSettings()))
        return EditorRequest(kind: .resize, preset: preset, files: files, anchor: anchor, flags: [.lossy])
    }

    private func makeEditor(_ jobs: Jobs, _ settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()))
        -> EditorController {
        EditorController(
            settings: settings,
            perform: { preset, files, _, _ in
                jobs.performed.append((preset, files))
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    /// The session once every file's size has been read.
    private func loaded(_ editor: EditorController) async throws -> ResizeSession {
        let session = try #require(editor.session as? ResizeSession)
        #expect(await eventually { session.isLoaded })
        return session
    }

    @Test func resizeSessionSavesSpec() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 × 300 with orientation 6: shown 300 × 400, the size the fields follow.
        let photo = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let jobs = Jobs()
        let editor = makeEditor(jobs, settings)
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try #require(editor.session as? ResizeSession)
        #expect(session.title == "Resize")
        #expect(editor.chromeState.confirmTitle == "Save Resized Copy")
        #expect(editor.chromeState.blocker == "Reading the file\u{2026}")
        _ = try await loaded(editor)
        #expect(session.model.sourceLabel == "Now 300 \u{00D7} 400")
        #expect(editor.chromeState.blocker == "Choose a size")
        editor.confirm()
        #expect(jobs.performed.isEmpty)

        session.model.typeWidth("1000")
        #expect(session.model.heightText == "1333")
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == "Larger than the original, so it may look soft")
        editor.confirm()
        let performed = try #require(jobs.performed.first)
        #expect(performed.preset.id == "resize")
        #expect(performed.preset.options.edit == .resize(.width(1000)))
        #expect(performed.preset.options.quality == 0.92)
        // The engine names each output after its own result (`photo-1000x1333.jpg`).
        #expect(performed.preset.nameSuffix == nil && performed.preset.outputNaming == .fromOutput)
        #expect(performed.files == [photo])
        #expect(settings.settings.editorMemory.resize == ["image": .width(1000)])

        editor.open(try request([photo]))
        let again = try await loaded(editor)
        #expect(again.model.spec == .width(1000) && again.model.heightText == "1333")
    }

    /// A photo's 1080 × 1080 is remembered for photos only: a video opens locked and empty, so one Return never
    /// square-crops it.
    @Test func eachKindRemembersItsOwnSize() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let jobs = Jobs()
        let editor = makeEditor(jobs, settings)
        defer { editor.cancel() }

        editor.open(try request([photo]))
        try await loaded(editor).model.choose(.exact(width: 1080, height: 1080))
        editor.confirm()
        #expect(jobs.performed.count == 1)

        editor.open(try request([movie]))
        let video = try await loaded(editor)
        #expect(video.model.isLocked && video.model.spec == nil)
        #expect(editor.chromeState.blocker == "Choose a size")
        editor.confirm()
        #expect(jobs.performed.count == 1)
        video.model.choose(.height(720))
        editor.confirm()
        #expect(settings.settings.editorMemory.resize
            == ["image": .exact(width: 1080, height: 1080), "video": .height(720)])

        editor.open(try request([photo]))
        let again = try await loaded(editor)
        #expect(!again.model.isLocked && again.model.spec == .exact(width: 1080, height: 1080))
    }

    @Test func severalFilesAreReadAndCounted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Fixtures.png(width: 400, height: 300, in: dir)
        let second = try Fixtures.png(width: 200, height: 100, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([first, second]))
        let session = try await loaded(editor)
        #expect(session.model.sources.count == 2)
        #expect(session.model.sourceLabel == "Now 400 \u{00D7} 300 and 1 more")
        #expect(editor.chromeState.confirmTitle == "Save 2 Resized Copies")
        session.model.choose(.percent(50))
        #expect(editor.chromeState.blocker == nil)
        editor.confirm()
        #expect(jobs.performed.first?.preset.options.edit == .resize(.scale(percent: 50)))
        #expect(jobs.performed.first?.files == [first, second])
    }

    @Test func aVideoOffersHeightsAndSaysItReencodes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, transform: quarterTurn, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([movie]))
        let session = try await loaded(editor)
        // Upright, as the engine turns it before scaling.
        #expect(session.model.sourceLabel == "Now 240 \u{00D7} 320")
        #expect(session.model.chips.first == .height(2160))
        session.model.typeHeight("160")
        #expect(session.model.widthText == "120")
        #expect(editor.chromeState.note == "Re-encodes the video")
    }

    @Test func anUnreadableFileCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: broken)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([broken]))
        let session = try #require(editor.session as? ResizeSession)
        #expect(await eventually { session.loadFailed })
        session.model.typeWidth("100")
        #expect(editor.chromeState.blocker == "The file may be damaged")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }

    @Test func returnInAFieldSaves() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([photo]))
        var confirmed = 0
        let host = NSHostingView(rootView: try #require(editor.session as? ResizeSession).makeContent()
            .environment(\.editorConfirm, EditorConfirmAction(run: { confirmed += 1 })))
        let window = NSPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 340, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        let field = try #require(Self.firstTextField(in: host))
        window.makeFirstResponder(field)
        let editorView = try #require(field.currentEditor())
        editorView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(await eventually { confirmed == 1 })
        window.orderOut(nil)
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = firstTextField(in: sub) { return found } }
        return nil
    }
}

/// What the Rotate editor shows and hands the job (P198), through the real controller and the real session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct RotateSessionTests {
    private final class Jobs {
        var performed: [(preset: Preset, files: [URL])] = []
    }

    private func request(_ files: [URL]) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .rotate, settings: AppSettings()))
        return EditorRequest(kind: .rotate, preset: preset, files: files, anchor: anchor, flags: [.lossy])
    }

    private func makeEditor(_ jobs: Jobs, _ settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()))
        -> EditorController {
        EditorController(
            settings: settings,
            perform: { preset, files, _, _ in
                jobs.performed.append((preset, files))
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    /// The session once the first file's upright size is known.
    private func loaded(_ editor: EditorController) async throws -> RotateSession {
        let session = try #require(editor.session as? RotateSession)
        #expect(await eventually { session.pixelSize != nil })
        return session
    }

    @Test func rotateButtonsUpdateSpec() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 × 300 with orientation 6: shown 300 × 400, the picture the turns act on.
        let photo = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let before = settings.settings.editorMemory
        let jobs = Jobs()
        let editor = makeEditor(jobs, settings)
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try await loaded(editor)
        #expect(session.title == "Rotate")
        #expect(session.pixelSize == CGSize(width: 300, height: 400))
        #expect(editor.chromeState.confirmTitle == "Save Rotated Copy")
        #expect(session.spec == .identity)
        #expect(editor.chromeState.blocker == RotateEdit.nothingToRotateReason)
        editor.confirm()
        #expect(jobs.performed.isEmpty)

        session.perform(.rotateRight)
        session.perform(.rotateRight)
        session.perform(.flipHorizontal)
        #expect(session.spec == RotateSpec(quarterTurns: 2, flipHorizontal: true))
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == nil)
        session.perform(.flipVertical)
        #expect(session.spec == .identity)
        #expect(editor.chromeState.blocker == RotateEdit.nothingToRotateReason)

        session.perform(.rotateLeft)
        editor.confirm()
        let performed = try #require(jobs.performed.first)
        #expect(performed.preset.id == "rotate")
        #expect(performed.preset.options.edit == .rotate(RotateSpec(quarterTurns: 3, flipHorizontal: false)))
        #expect(performed.preset.nameSuffix == "rotated")
        #expect(performed.files == [photo])
        // A turn belongs to its picture: nothing is remembered for the next one.
        #expect(settings.settings.editorMemory == before)
    }

    @Test func severalFilesTurnTogether() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Fixtures.png(width: 400, height: 300, in: dir)
        let second = try Fixtures.png(width: 200, height: 100, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([first, second]))
        let session = try await loaded(editor)
        #expect(session.pixelSize == CGSize(width: 400, height: 300))
        #expect(editor.chromeState.confirmTitle == "Save 2 Rotated Copies")
        session.perform(.rotateRight)
        editor.confirm()
        #expect(jobs.performed.first?.preset.options.edit == .rotate(RotateSpec(quarterTurns: 1, flipHorizontal: false)))
        #expect(jobs.performed.first?.files == [first, second])
    }

    @Test func arrowKeysRotate() async throws {
        #expect(RotateKeys.action(for: .leftArrow, modifiers: []) == .rotateLeft)
        #expect(RotateKeys.action(for: .rightArrow, modifiers: []) == .rotateRight)
        // Arrow keys also carry the numeric-pad and function flags.
        #expect(RotateKeys.action(for: .rightArrow, modifiers: [.numericPad, .function]) == .rotateRight)
        #expect(RotateKeys.action(for: .upArrow, modifiers: []) == nil)
        #expect(RotateKeys.action(for: .leftArrow, modifiers: .command) == nil)
        #expect(RotateKeys.action(for: .rightArrow, modifiers: .shift) == nil)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try await loaded(editor)
        session.perform(.flipHorizontal)
        let flipped = session.spec
        session.perform(try #require(RotateKeys.action(for: .leftArrow, modifiers: [])))
        #expect(session.spec == flipped.rotatedLeft())
        let left = session.spec
        session.perform(try #require(RotateKeys.action(for: .rightArrow, modifiers: [])))
        #expect(session.spec == left.rotatedRight())
        #expect(session.spec == flipped)
    }

    @Test func videoFlipNotesReencode() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request([movie]))
        let session = try await loaded(editor)
        #expect(editor.chromeState.note == nil)
        session.perform(.rotateRight)
        // Quarter turns alone are lossless.
        #expect(editor.chromeState.blocker == nil && editor.chromeState.note == nil)
        session.perform(.flipHorizontal)
        #expect(editor.chromeState.note == "Re-encodes the video")
        session.perform(.flipHorizontal)
        session.perform(.flipVertical)
        #expect(editor.chromeState.note == "Re-encodes the video")
        session.perform(.flipVertical)
        #expect(editor.chromeState.note == nil)

        let photo = try Fixtures.png(width: 40, height: 30, in: dir)
        editor.open(try request([photo]))
        let image = try await loaded(editor)
        image.perform(.flipHorizontal)
        #expect(editor.chromeState.blocker == nil && editor.chromeState.note == nil)
    }

    /// The preview is the upright picture drawn through `RotateSpec.transform`: for each of the eight results it fills
    /// the turned box exactly, with the picture's top-left pixel where the engines put it.
    @Test func thePreviewIsDrawnThroughTheSpecsTransform() {
        let bounds = CGSize(width: 488, height: 340)
        let pixels = CGSize(width: 400, height: 300)
        for turns in 0...3 {
            for flip in [false, true] {
                let spec = RotateSpec(quarterTurns: turns, flipHorizontal: flip)
                let preview = RotatePreview(pixelSize: pixels, spec: spec, bounds: bounds)
                let output = spec.outputSize(width: 400, height: 300)
                let shownPixels = CGSize(width: output.width, height: output.height)
                #expect(preview.shownSize == EditorPicture.fitted(shownPixels, into: bounds, until: pixels), "\(spec)")
                let drawn = CGRect(origin: .zero, size: preview.uprightSize).applying(preview.transform)
                #expect(abs(drawn.minX) < 0.01 && abs(drawn.minY) < 0.01, "\(spec)")
                #expect(abs(drawn.width - preview.shownSize.width) < 0.01, "\(spec)")
                #expect(abs(drawn.height - preview.shownSize.height) < 0.01, "\(spec)")
                // The source's top-left pixel, in points of the preview: within a point of where the engines put it
                // (the preview's size is rounded to whole points).
                let scale = preview.uprightSize.width / pixels.width
                let engine = CGPoint(x: 0.5, y: 0.5).applying(spec.transform(width: 400, height: 300))
                let shown = CGPoint(x: 0.5 * scale, y: 0.5 * scale).applying(preview.transform)
                #expect(abs(shown.x - engine.x * scale) < 1 && abs(shown.y - engine.y * scale) < 1, "\(spec)")
            }
        }
    }

    /// The animation starts on the picture as it was before the action, at the size it had, and settles on the result.
    @Test func thePreviewEasesFromThePictureBefore() {
        let bounds = CGSize(width: 488, height: 340)
        let turned = RotatePreview(pixelSize: CGSize(width: 400, height: 300),
                                   spec: RotateSpec(quarterTurns: 1, flipHorizontal: false), bounds: bounds)
        #expect(turned.shownSize == CGSize(width: 255, height: 340))
        let right = turned.start(before: .rotateRight, bounds: bounds)
        #expect(right.angle == -90 && right.flipX == 1 && right.flipY == 1)
        // Turned back a quarter, the 255 × 340 result covers the 453 × 340 picture it was.
        #expect(abs(turned.shownSize.height * right.scale - 453) < 0.01)
        #expect(turned.start(before: .rotateLeft, bounds: bounds).angle == 90)
        #expect(turned.start(before: .flipHorizontal, bounds: bounds) == RotateKick(angle: 0, flipX: -1, flipY: 1, scale: 1))
        #expect(turned.start(before: .flipVertical, bounds: bounds) == RotateKick(angle: 0, flipX: 1, flipY: -1, scale: 1))
        #expect(turned.start(before: nil, bounds: bounds) == .rest)

        #expect(RotateKickEffect(count: 4, target: 5, start: right).kick == right)
        #expect(RotateKickEffect(count: 4.5, target: 5, start: right).kick.angle == -45)
        #expect(RotateKickEffect(count: 5, target: 5, start: right).kick == .rest)
        // A press during the last one's animation starts the new one from its own beginning.
        #expect(RotateKickEffect(count: 3.5, target: 5, start: right).kick == right)
    }

    /// A turn is saved only once the person has seen the picture it applies to, as Resize… and Crop… wait for it.
    @Test func nothingIsSavedBeforeTheFileIsRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([photo]))
        let session = try #require(editor.session as? RotateSession)
        #expect(session.pixelSize == nil)
        session.perform(.rotateRight)
        #expect(editor.chromeState.blocker == "Reading the file\u{2026}")
        editor.confirm()
        #expect(jobs.performed.isEmpty)

        #expect(await eventually { session.pixelSize != nil })
        #expect(editor.chromeState.blocker == nil)
        editor.confirm()
        #expect(jobs.performed.first?.preset.options.edit == .rotate(RotateSpec(quarterTurns: 1, flipHorizontal: false)))
    }

    @Test func anUnreadableFileCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: broken)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request([broken]))
        let session = try #require(editor.session as? RotateSession)
        #expect(await eventually { session.loadFailed })
        session.perform(.rotateRight)
        #expect(editor.chromeState.blocker == "The file may be damaged")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }
}

/// What the Redact editor proposes, shows and hands the job, through the real controller and the real session.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct RedactSessionTests {
    private final class Jobs {
        var performed: [Preset] = []
    }

    private func request(_ file: URL) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .redact, settings: AppSettings()))
        return EditorRequest(kind: .redact, preset: preset, files: [file], anchor: anchor, flags: [.lossy])
    }

    /// Holds a detector back until the test lets it go, and says whether it was reached.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private var isReached = false

        var reached: Bool { lock.withLock { isReached } }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                isReached = true
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    private struct DetectionFailed: Error {}

    private func makeEditor(
        _ jobs: Jobs, _ settings: SettingsStore = SettingsStore(defaults: EphemeralDefaults()),
        detector: RedactSession.Detector? = nil
    ) -> EditorController {
        EditorController(
            settings: settings,
            perform: { preset, _, _, _ in
                jobs.performed.append(preset)
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen,
            makeSession: { request, settings in
                guard let detector else { return EditorSessions.make(request, settings) }
                return RedactSession(request: request, memory: settings.settings.editorMemory, detector: detector)
            }
        )
    }

    /// The session once detection has finished.
    private func found(_ editor: EditorController) async throws -> RedactSession {
        let session = try #require(editor.session as? RedactSession)
        #expect(await eventually { session.model != nil && !session.isDetecting })
        return session
    }

    private func emailImage(in dir: URL) throws -> URL {
        try Fixtures.textImage("Write to ann@example.com today", in: dir)
    }

    private func ids(_ session: RedactSession, _ kind: RedactionKind) -> [Int] {
        session.model?.boxes.filter { $0.kind == kind }.map(\.id) ?? []
    }

    /// The preview's pixel at a point of the picture as unit fractions.
    private func pixel(_ image: CGImage, at point: CGPoint) throws -> [Int] {
        let all = try bytes(image)
        let offset = (Int(point.y * Double(image.height)) * image.width + Int(point.x * Double(image.width))) * 4
        return all[offset..<(offset + 4)].map(Int.init)
    }

    private func closely(_ a: UnitRect?, _ b: UnitRect, tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height].allSatisfy { abs($0) < tolerance }
    }

    @Test func redactSessionPreselectsWhatItFinds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try #require(editor.session as? RedactSession)
        #expect(session.title == "Redact")
        #expect(editor.chromeState.confirmTitle == "Save Redacted Copy")
        #expect(editor.chromeState.blocker == "Reading the file\u{2026}")
        _ = try await found(editor)
        let model = try #require(session.model)
        #expect(model.count(.email) == 1)
        #expect(model.boxes.first { $0.kind == .email }?.isOn == true)
        #expect(model.count(.text) >= 1)
        #expect(model.boxes.filter { $0.kind == .text }.allSatisfy { !$0.isOn }, "the line stays visible until chosen")
        #expect(session.status == RedactionModel.status(faces: 0, emails: 1, text: model.count(.text)))
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == "Location and other metadata are removed too")
    }

    @Test func theEmailIsDrawnBlackAndTheLineLeftAlone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        let model = try #require(session.model)
        let email = try #require(model.boxes.first { $0.kind == .email }?.rect)
        let shown = try #require(session.shown)
        let middle = CGPoint(x: email.x + email.width / 2, y: email.y + email.height / 2)
        #expect(try pixel(shown, at: middle) == [0, 0, 0, 255], "an address that is on shows as it will be saved")
        let line = try #require(model.boxes.first { $0.kind == .text }?.rect)
        let beforeTheLine = CGPoint(x: line.x / 2, y: line.y + line.height / 2)
        #expect(try pixel(shown, at: beforeTheLine) == [255, 255, 255, 255])
        let edgeOfTheLine = CGPoint(x: line.x + 0.005, y: line.y + line.height / 2)
        #expect(try pixel(shown, at: edgeOfTheLine) == [255, 255, 255, 255], "a line that is off is not drawn over")
        session.setOn(try #require(ids(session, .text).first), true)
        #expect(try pixel(try #require(session.shown), at: edgeOfTheLine) == [0, 0, 0, 255])
    }

    @Test func pixelatingTextShowsTheSafetyNote() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        session.setStyle(.pixelate)
        #expect(editor.chromeState.note == "Black boxes are safest for text")
        session.setStyle(.fill)
        #expect(editor.chromeState.note == "Location and other metadata are removed too")
        // With only the lines of text off and the address on it still warns; with nothing of text on it doesn't.
        session.setStyle(.pixelate)
        for id in ids(session, .email) { session.setOn(id, false) }
        #expect(session.note == "Location and other metadata are removed too")
    }

    @Test func theStyleIsRemembered() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(defaults: EphemeralDefaults())
        let editor = makeEditor(Jobs(), settings)
        defer { editor.cancel() }
        let photo = try emailImage(in: dir)
        editor.open(try request(photo))
        let first = try await found(editor)
        #expect(first.model?.style == .fill)
        first.setStyle(.pixelate)
        editor.confirm()
        #expect(settings.settings.editorMemory.redactionStyle == .pixelate)

        editor.open(try request(photo))
        let second = try #require(editor.session as? RedactSession)
        #expect(await eventually { second.model?.style == .pixelate })
    }

    @Test func saveSendsTheSpec() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        let email = try #require(session.model?.boxes.first { $0.kind == .email }?.rect)
        session.pointerChanged(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), in: CGSize(width: 400, height: 200))
        session.pointerEnded(from: CGPoint(x: 10, y: 10), in: CGSize(width: 400, height: 200))
        editor.confirm()
        let preset = try #require(jobs.performed.first)
        #expect(preset.id == "redact")
        #expect(preset.nameSuffix == "redacted")
        guard case .redact(let spec)? = preset.options.edit else { throw Fixtures.Failure("no redact edit") }
        #expect(spec.style == .fill)
        #expect(spec.boxes.count == 2, "the address that was found and the box that was drawn; the lines of text are not on")
        #expect(spec.boxes.first == email)
        #expect(closely(spec.boxes.last, UnitRect(x: 0.025, y: 0.05, width: 0.25, height: 0.25)))
    }

    @Test func nothingOnCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        let email = try #require(ids(session, .email).first)
        session.setOn(email, false)
        #expect(editor.chromeState.blocker == "Choose something to hide")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
        session.setOn(email, true)
        #expect(editor.chromeState.blocker == nil)
    }

    @Test func anUnreadableFileCannotBeSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.png")
        try Data("not an image".utf8).write(to: broken)
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        editor.open(try request(broken))
        let session = try #require(editor.session as? RedactSession)
        #expect(await eventually { session.loadFailed })
        #expect(editor.chromeState.blocker == "The file may be damaged")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }

    @Test func closingTheEditorStopsTheSearch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        editor.open(try request(try emailImage(in: dir)))
        let session = try #require(editor.session as? RedactSession)
        let load = try #require(editor.loadTask)
        editor.cancel()
        // The cancelled load has ended, so nothing can still fill the closed editor in.
        await load.value
        #expect(session.model == nil, "a closed editor is not filled in")
    }

    @Test func aPhotoIsReadUprightAndAnEditorOpensForRotatedOnes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 400 x 300 with orientation 6: shown 300 x 400.
        let photo = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(photo))
        let session = try await found(editor)
        #expect(session.pixelSize == CGSize(width: 300, height: 400))
        let shown = try #require(session.shown)
        #expect(shown.height > shown.width)
        #expect(session.status == "Nothing found. Drag over what to hide.")
        #expect(editor.chromeState.blocker == "Choose something to hide")
    }

    // MARK: Detection in flight

    nonisolated private static let foundFace = UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
    nonisolated private static let foundEmail = UnitRect(x: 0.4, y: 0.5, width: 0.3, height: 0.05)

    @Test func aDragInProgressKeepsWhatDetectionAddsMeanwhile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let found = [DetectedRegion(kind: .face, rect: Self.foundFace), DetectedRegion(kind: .email, rect: Self.foundEmail)]
        let editor = makeEditor(Jobs(), detector: { _ in
            await gate.wait()
            return found
        })
        defer { editor.cancel() }
        editor.open(try request(try Fixtures.png(width: 400, height: 300, in: dir)))
        let session = try #require(editor.session as? RedactSession)
        #expect(await eventually { session.model != nil && gate.reached })
        let size = CGSize(width: 400, height: 300)
        session.pointerChanged(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), in: size)
        session.pointerEnded(from: CGPoint(x: 100, y: 100), in: size)
        let drawn = try #require(ids(session, .manual).first)

        // Press inside the drawn box and move; detection ends between two moves of the same drag.
        session.pointerChanged(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 200, y: 150), in: size)
        gate.open()
        #expect(await eventually { !session.isDetecting })
        session.pointerChanged(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 150), in: size)
        session.pointerEnded(from: CGPoint(x: 150, y: 150), in: size)

        let model = try #require(session.model)
        #expect(model.boxes.map(\.kind) == [.face, .email, .manual], "what Vision found is still there")
        #expect(model.boxes.first { $0.kind == .face }?.isOn == true)
        #expect(closely(model.boxes.first { $0.id == drawn }?.rect, UnitRect(x: 0.5, y: 100.0 / 300, width: 0.25, height: 100.0 / 300)))
        #expect(session.status == "Found 1 face and 1 email address")
    }

    @Test func aCornerDragAlsoKeepsWhatDetectionAdds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let editor = makeEditor(Jobs(), detector: { _ in
            await gate.wait()
            return [DetectedRegion(kind: .face, rect: Self.foundFace)]
        })
        defer { editor.cancel() }
        editor.open(try request(try Fixtures.png(width: 400, height: 300, in: dir)))
        let session = try #require(editor.session as? RedactSession)
        #expect(await eventually { session.model != nil && gate.reached })
        let size = CGSize(width: 400, height: 300)
        session.pointerChanged(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), in: size)
        session.pointerEnded(from: CGPoint(x: 100, y: 100), in: size)
        session.pointerChanged(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 250, y: 250), in: size)
        gate.open()
        #expect(await eventually { !session.isDetecting })
        session.pointerChanged(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 240), in: size)
        session.pointerEnded(from: CGPoint(x: 200, y: 200), in: size)
        #expect(session.model?.count(.face) == 1)
        let drawn = session.model?.boxes.first { $0.kind == .manual }?.rect
        #expect(closely(drawn, UnitRect(x: 0.25, y: 100.0 / 300, width: 0.5, height: 140.0 / 300)))
    }

    @Test func closingWhileVisionWorksLeavesTheModelEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = Gate()
        let editor = makeEditor(Jobs(), detector: { _ in
            await gate.wait()
            return [DetectedRegion(kind: .face, rect: Self.foundFace)]
        })
        editor.open(try request(try Fixtures.png(width: 400, height: 300, in: dir)))
        let session = try #require(editor.session as? RedactSession)
        #expect(await eventually { session.model != nil && gate.reached })
        let load = try #require(editor.loadTask)
        editor.cancel()
        gate.open()
        // The load waits for the detector's answer, then ends: the answer had its chance to land.
        await load.value
        #expect(session.model?.boxes.isEmpty == true, "a late answer does not reach a closed editor")
        #expect(session.isDetecting)
    }

    @Test func saveWaitsForDetectionAndAFailureDoesNotStickTheBlocker() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        for fails in [false, true] {
            let gate = Gate()
            let jobs = Jobs()
            let editor = makeEditor(jobs, detector: { _ in
                await gate.wait()
                if fails { throw DetectionFailed() }
                return [DetectedRegion(kind: .face, rect: Self.foundFace)]
            })
            defer { editor.cancel() }
            editor.open(try request(photo))
            let session = try #require(editor.session as? RedactSession)
            #expect(await eventually { session.model != nil && gate.reached })
            // A drawn box is on, yet Save waits: the scan could still find a face.
            session.addCentredBox()
            #expect(session.model?.blocker == nil)
            #expect(editor.chromeState.blocker == "Looking for faces and text\u{2026}")
            editor.confirm()
            #expect(jobs.performed.isEmpty)

            gate.open()
            #expect(await eventually { !session.isDetecting })
            #expect(editor.chromeState.blocker == nil, fails ? "a failed scan frees Save" : "a finished scan frees Save")
            #expect(session.model?.count(.face) == (fails ? 0 : 1))
            editor.confirm()
            #expect(jobs.performed.count == 1)
        }
    }

    // MARK: Pointer and keys

    @Test func aClickTogglesTheBoxUnderItAndADragDrawsOne() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        let size = CGSize(width: 500, height: 100)
        let email = try #require(session.model?.boxes.first { $0.kind == .email })
        let click = CGPoint(x: (email.rect.x + email.rect.width / 2) * size.width,
                            y: (email.rect.y + email.rect.height / 2) * size.height)
        session.pointerChanged(from: click, to: click, in: size)
        session.pointerEnded(from: click, in: size)
        #expect(session.model?.boxes.first { $0.id == email.id }?.isOn == false)
        #expect(session.model?.selected == email.id)
        session.pointerEnded(from: click, in: size)
        #expect(session.model?.boxes.first { $0.id == email.id }?.isOn == true)

        // A press on empty space that moves draws a box, shown as a draft until it ends.
        let start = CGPoint(x: 5, y: 5)
        let end = CGPoint(x: 55, y: 25)
        session.pointerChanged(from: start, to: end, in: size)
        #expect(session.draft != nil)
        #expect(session.model?.count(.manual) == 0)
        session.pointerEnded(from: start, in: size)
        #expect(session.draft == nil)
        #expect(session.model?.count(.manual) == 1)
        #expect(session.model?.selected == ids(session, .manual).first)
        // A click on empty space chooses nothing.
        let empty = CGPoint(x: 5, y: 95)
        session.pointerEnded(from: empty, in: size)
        #expect(session.model?.selected == nil)
    }

    @Test func aDrawnBoxMovesAndResizesByTheMouse() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try Fixtures.png(width: 400, height: 300, in: dir)))
        let session = try await found(editor)
        let size = CGSize(width: 400, height: 300)
        session.pointerChanged(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), in: size)
        session.pointerEnded(from: CGPoint(x: 100, y: 100), in: size)
        let id = try #require(ids(session, .manual).first)
        func rect() -> UnitRect? { session.model?.boxes.first { $0.id == id }?.rect }
        #expect(closely(rect(), UnitRect(x: 0.25, y: 100.0 / 300, width: 0.25, height: 100.0 / 300)))

        // The press began inside the box: the box moves with the pointer, and follows it past an edge and back.
        session.pointerChanged(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 150), in: size)
        session.pointerChanged(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 1000, y: 150), in: size)
        #expect(rect()?.x == 0.75)
        session.pointerChanged(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 150), in: size)
        session.pointerEnded(from: CGPoint(x: 150, y: 150), in: size)
        #expect(rect()?.x == 0.5)
        #expect(session.model?.boxes.first { $0.id == id }?.isOn == true, "a drag is not a click")

        // The bottom-right corner is at (300, 200) now; dragging it resizes.
        #expect(session.corner(at: CGPoint(x: 303, y: 198), in: size) == .bottomRight)
        session.pointerChanged(from: CGPoint(x: 303, y: 198), to: CGPoint(x: 353, y: 248), in: size)
        session.pointerEnded(from: CGPoint(x: 303, y: 198), in: size)
        #expect(closely(rect(), UnitRect(x: 0.5, y: 100.0 / 300, width: 353.0 / 400 - 0.5, height: 248.0 / 300 - 100.0 / 300)))
        #expect(session.model?.boxes.first { $0.id == id }?.isOn == true)
    }

    @Test func redactKeysMapToActions() {
        #expect(RedactKeys.action(for: .tab, modifiers: []) == .tab(forward: true))
        #expect(RedactKeys.action(for: .tab, modifiers: .shift) == .tab(forward: false))
        #expect(RedactKeys.action(for: KeyEquivalent("\u{19}"), modifiers: .shift) == .tab(forward: false))
        #expect(RedactKeys.action(for: .space, modifiers: []) == .toggle)
        #expect(RedactKeys.action(for: .delete, modifiers: []) == .remove)
        #expect(RedactKeys.action(for: KeyEquivalent("\u{7F}"), modifiers: []) == .remove)
        #expect(RedactKeys.action(for: .leftArrow, modifiers: []) == .arrow(dx: -1, dy: 0, resize: false, coarse: false))
        #expect(RedactKeys.action(for: .downArrow, modifiers: .numericPad) == .arrow(dx: 0, dy: 1, resize: false, coarse: false))
        #expect(RedactKeys.action(for: .upArrow, modifiers: .shift) == .arrow(dx: 0, dy: -1, resize: false, coarse: true))
        #expect(RedactKeys.action(for: .rightArrow, modifiers: .option) == .arrow(dx: 1, dy: 0, resize: true, coarse: false))
        #expect(RedactKeys.action(for: .downArrow, modifiers: [.option, .shift]) == .arrow(dx: 0, dy: 1, resize: true, coarse: true))
        // Command keys belong to the panel; Return and Esc to the chrome.
        #expect(RedactKeys.action(for: .leftArrow, modifiers: .command) == nil)
        #expect(RedactKeys.action(for: .space, modifiers: .command) == nil)
        #expect(RedactKeys.action(for: .return, modifiers: []) == nil)
        #expect(RedactKeys.action(for: .escape, modifiers: []) == nil)
        #expect(RedactKeys.action(for: "a", modifiers: []) == nil)
    }

    @Test func keysChooseToggleMoveResizeAndRemove() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try emailImage(in: dir)))
        let session = try await found(editor)
        let all = try #require(session.model?.boxes.map(\.id))
        #expect(all.count >= 2)

        // Tab chooses the first box; past the last it lets focus go on.
        #expect(session.perform(.tab(forward: true)))
        #expect(session.model?.selected == all[0])
        #expect(!session.perform(.tab(forward: false)), "before the first, focus goes back to what precedes the picture")
        for id in all.dropFirst() {
            #expect(session.perform(.arrow(dx: 1, dy: 0, resize: false, coarse: false)), "sideways steps on a found box")
            #expect(session.model?.selected == id)
        }
        #expect(!session.perform(.tab(forward: true)))
        #expect(!session.perform(.arrow(dx: 0, dy: 1, resize: false, coarse: false)), "up and down mean nothing on a found box")
        #expect(!session.perform(.remove), "a found box is not removed")
        #expect(!session.perform(.arrow(dx: 1, dy: 0, resize: true, coarse: false)))

        // Space flips the chosen box.
        let last = try #require(session.model?.selected)
        let before = try #require(session.model?.boxes.first { $0.id == last }).isOn
        #expect(session.perform(.toggle))
        #expect(session.model?.boxes.first { $0.id == last }?.isOn == !before)

        // A box added by hand is chosen: arrows move it, Option-arrows resize it, Delete removes it.
        session.addCentredBox()
        let drawn = try #require(ids(session, .manual).first)
        func rect() -> UnitRect? { session.model?.boxes.first { $0.id == drawn }?.rect }
        let start = try #require(rect())
        #expect(session.perform(.arrow(dx: 1, dy: 0, resize: false, coarse: false)))
        #expect(abs((rect()?.x ?? 0) - (start.x + RedactSession.keyStep)) < 1e-9)
        #expect(session.perform(.arrow(dx: 0, dy: 1, resize: false, coarse: true)))
        #expect(abs((rect()?.y ?? 0) - (start.y + RedactSession.keyStep * 10)) < 1e-9)
        #expect(session.perform(.arrow(dx: 1, dy: 1, resize: true, coarse: false)))
        #expect(abs((rect()?.width ?? 0) - (start.width + RedactSession.keyStep)) < 1e-9)
        #expect(session.perform(.remove))
        #expect(ids(session, .manual).isEmpty)
    }

    @Test func addBoxMakesACentredQuarterOfTheShorterSide() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        editor.open(try request(try Fixtures.png(width: 400, height: 300, in: dir)))
        let session = try await found(editor)
        let requests = session.focusRequests
        session.addCentredBox()
        let box = try #require(session.model?.boxes.first { $0.kind == .manual })
        #expect(abs(box.rect.width * 400 - 75) < 1e-6 && abs(box.rect.height * 300 - 75) < 1e-6)
        #expect(abs(box.rect.x + box.rect.width / 2 - 0.5) < 1e-9 && abs(box.rect.y + box.rect.height / 2 - 0.5) < 1e-9)
        #expect(session.model?.selected == box.id)
        #expect(session.focusRequests == requests + 1)
        #expect(editor.chromeState.blocker == nil, "a box that was drawn is on")
    }

    // MARK: The preview shows what is saved

    @Test func thePreviewPixelatesWithTheEnginesBlocks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.noisyPNG(width: 400, height: 300, in: dir)
        let box = UnitRect(x: 0.1, y: 0.2, width: 0.7, height: 0.5)
        let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let raster = try #require(RedactionRaster(image: image, fullSize: CGSize(width: 400, height: 300)))
        let preview = try #require(raster.image(hiding: [box], style: .pixelate))

        // The same job the editor's Save runs.
        var preset = try #require(Preset.builtIns.first { $0.id == "redact" })
        preset.options.edit = .redact(RedactionSpec(boxes: [box], style: .pixelate))
        let runner = JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil),
            destinations: DestinationResolver(downloadsFolder: dir, isWritable: { _ in true }),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
        let result = try #require(await runner.run(ConversionRequest.from(preset, inputs: [source])).first)
        guard case .succeeded(_, let outputs, _) = result, let saved = outputs.first,
              let saved = CGImageSourceCreateWithURL(saved as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
        else { throw Fixtures.Failure("\(result)") }

        let (shown, written) = (try bytes(preview), try bytes(saved))
        #expect(shown.count == written.count)
        let worst = zip(shown, written).map { abs(Int($0) - Int($1)) }.max() ?? 255
        #expect(worst <= 1, "the preview at full size is the saved picture")
    }

    @Test func aScaledPreviewMapsTheSameBlocks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.noisyPNG(width: 200, height: 100, in: dir)
        let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // The picture is 2000 x 1000 pixels in all: the preview is a tenth of it.
        let raster = try #require(RedactionRaster(image: image, fullSize: CGSize(width: 2000, height: 1000)))
        let box = UnitRect(x: 0, y: 0, width: 1, height: 1)
        let preview = try bytes(try #require(raster.image(hiding: [box], style: .pixelate)))
        // side = max(16, ceil(2000 / 6)) = 334; 2000 / 334 = 5 columns of 400 px, 1000 / 334 = 2 rows of 500 px.
        func colour(_ x: Int, _ y: Int) -> [UInt8] { Array(preview[((y * 200) + x) * 4 ..< ((y * 200) + x) * 4 + 4]) }
        for (columns, rows) in [(0..<40, 0..<50), (40..<80, 0..<50), (160..<200, 50..<100)] {
            let first = colour(columns.lowerBound, rows.lowerBound)
            for y in rows { for x in columns { #expect(colour(x, y) == first) } }
        }
        #expect(colour(39, 0) != colour(40, 0), "neighbouring blocks differ")
        #expect(colour(0, 49) != colour(0, 50))
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}

// MARK: - Organize pages

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PageOrganizerSessionTests {
    private final class Jobs {
        var performed: [(preset: Preset, files: [URL])] = []
    }

    private func request(_ file: URL) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: .organizePages, settings: AppSettings()))
        return EditorRequest(kind: .organizePages, preset: preset, files: [file], anchor: anchor, flags: [])
    }

    private func makeEditor(_ jobs: Jobs) -> EditorController {
        EditorController(
            settings: SettingsStore(defaults: EphemeralDefaults()),
            perform: { preset, files, _, _ in
                jobs.performed.append((preset, files))
                return JobHandle(id: UUID(), outcome: Task {
                    try? await Task.sleep(for: .seconds(30))
                    return JobOutcome.succeeded
                })
            },
            release: { _, _ in }, desktop: .offScreen
        )
    }

    /// The editor open on `file`, once its pages are counted.
    private func opened(_ editor: EditorController, _ file: URL) async throws -> PageOrganizerSession {
        editor.open(try request(file))
        let session = try #require(editor.session as? PageOrganizerSession)
        #expect(await eventually { session.model != nil || session.unreadable != nil })
        return session
    }

    private func order(_ session: PageOrganizerSession) -> [Int] { session.model?.pages.map(\.page) ?? [] }

    // MARK: Thumbnails

    @Test func thumbnailsAreLazyAndCapped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thumbnails = PageThumbnails(url: try Fixtures.pdf(pages: 300, in: dir))

        #expect(await thumbnails.image(page: 0, maxSide: 64) != nil)
        #expect(await thumbnails.image(page: 299, maxSide: 64) != nil)
        #expect(await thumbnails.renderedCount == 2, "only the pages asked for are drawn")
        for page in 1...130 { _ = await thumbnails.image(page: page, maxSide: 64) }
        #expect(await thumbnails.renderedCount == 132)
        #expect(await thumbnails.cachedCount == 120, "the 120 most recent stay")
        #expect(await thumbnails.image(page: 299, maxSide: 64) != nil)
        #expect(await thumbnails.renderedCount == 133, "page 299 was among the oldest, so it is drawn again")
        #expect(await thumbnails.image(page: 300, maxSide: 64) == nil, "there is no page 301")
    }

    @Test func aPageUsedAgainStaysInTheCache() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thumbnails = PageThumbnails(url: try Fixtures.pdf(pages: 200, in: dir), capacity: 5)
        for page in 0..<5 { _ = await thumbnails.image(page: page, maxSide: 48) }
        _ = await thumbnails.image(page: 0, maxSide: 48)
        #expect(await thumbnails.renderedCount == 5, "a hit draws nothing")
        _ = await thumbnails.image(page: 5, maxSide: 48)
        _ = await thumbnails.image(page: 0, maxSide: 48)
        #expect(await thumbnails.renderedCount == 6, "page 1, the least recent, was dropped; page 0 was kept")
        _ = await thumbnails.image(page: 1, maxSide: 48)
        #expect(await thumbnails.renderedCount == 7)
    }

    @Test func aRotatedPageIsDrawnTurned() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(pageTexts: ["up", "sideways"], rotations: [0, 90], in: dir)
        let thumbnails = PageThumbnails(url: pdf)
        let upright = try #require(await thumbnails.image(page: 0, maxSide: 200))
        let sideways = try #require(await thumbnails.image(page: 1, maxSide: 200))
        #expect(upright.height == 200 && upright.width < upright.height)
        #expect(sideways.width == 200 && sideways.height < sideways.width)
    }

    @Test func aCancelledRequestDrawsNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thumbnails = PageThumbnails(url: try Fixtures.pdf(pages: 3, in: dir))
        let task = Task { () -> CGImage? in
            await Task.yield()
            return await thumbnails.image(page: 1, maxSide: 64)
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await thumbnails.renderedCount == 0)
    }

    // MARK: The session

    @Test func theEditorOpensOnItsPages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let pdf = try Fixtures.pdf(pages: 5, in: dir)
        editor.open(try request(pdf))
        let session = try #require(editor.session as? PageOrganizerSession)
        #expect(session.title == "Organize Pages")
        #expect(editor.chromeState.confirmTitle == "Save Edited Copy")
        #expect(editor.chromeState.blocker == "Reading the file\u{2026}")
        #expect(await eventually { session.model != nil })
        #expect(editor.chromeState.blocker == "No changes")
        #expect(order(session) == [0, 1, 2, 3, 4])
        #expect(EditorLayout.width(for: .organizePages) == 600)
    }

    @Test func saveSendsTheOrganizeSpec() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        let pdf = try Fixtures.pdf(pages: 5, in: dir)
        let session = try await opened(editor, pdf)

        editor.confirm()
        #expect(jobs.performed.isEmpty, "unchanged pages can't be saved")

        session.click(4)
        session.perform(.moveEarlier)
        session.perform(.rotateRight)
        session.click(0)
        session.perform(.delete)
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == "4 pages, 1 removed, 1 rotated")

        editor.confirm()
        let performed = try #require(jobs.performed.first)
        #expect(performed.preset.id == "organize-pages")
        #expect(performed.preset.nameSuffix == "edited")
        #expect(performed.files == [pdf])
        #expect(performed.preset.options.edit == .organize([
            PageEdit(page: 1, rotation: 0), PageEdit(page: 2, rotation: 0), PageEdit(page: 4, rotation: 90),
            PageEdit(page: 3, rotation: 0),
        ]))
    }

    @Test func removingEveryPageBlocksSaving() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = Jobs()
        let editor = makeEditor(jobs)
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 2, in: dir))
        session.perform(.selectAll)
        session.perform(.delete)
        #expect(editor.chromeState.blocker == "Keep at least one page")
        editor.confirm()
        #expect(jobs.performed.isEmpty)
    }

    @Test func aLockedOrDamagedPDFHasNoPages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let locked = try await opened(editor, try Fixtures.lockedPDF(in: dir))
        #expect(locked.model == nil)
        #expect(editor.chromeState.blocker == "It's password protected")

        let damaged = dir.appending(path: "damaged.pdf")
        try Data("not a pdf".utf8).write(to: damaged)
        let broken = try await opened(editor, damaged)
        #expect(broken.model == nil)
        #expect(editor.chromeState.blocker == "The file may be damaged")
        #expect(broken.options(base: PresetOptions()).edit == nil)
    }

    @Test func aKeyThatHasNothingToActOnGoesOn() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 3, in: dir))
        #expect(!session.perform(.delete), "nothing is chosen")
        #expect(!session.perform(.rotateLeft))
        #expect(session.perform(.select(1)), "an arrow chooses the first page")
        #expect(session.model?.selection == [0])
        #expect(session.perform(.delete))
        #expect(order(session) == [1, 2])
    }

    @Test func pageKeysMapToActions() {
        func action(_ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> PageAction? {
            PageKeys.action(for: key, modifiers: modifiers)
        }
        #expect(action(.delete) == .delete)
        #expect(action(.deleteForward) == .delete)
        #expect(action(KeyEquivalent("\u{7F}")) == .delete, "AppKit's Delete key")
        #expect(action(.delete, .command) == nil)
        #expect(action(KeyEquivalent("r"), .command) == .rotateRight)
        #expect(action(KeyEquivalent("l"), .command) == .rotateLeft)
        #expect(action(KeyEquivalent("r")) == nil, "a plain letter is not ours")
        #expect(action(KeyEquivalent("a"), .command) == .selectAll)
        #expect(action(.leftArrow, .command) == .moveEarlier)
        #expect(action(.rightArrow, .command) == .moveLater)
        #expect(action(.leftArrow) == .select(-1))
        #expect(action(.rightArrow) == .select(1))
        #expect(action(.upArrow) == .select(-4))
        #expect(action(.downArrow) == .select(4))
        #expect(action(.rightArrow, .shift) == .extend(1))
        #expect(action(.downArrow, .shift) == .extend(4))
        #expect(action(.rightArrow, [.numericPad, .function]) == .select(1), "the flags an arrow carries")
        #expect(action(.upArrow, .command) == nil)
        #expect(action(.rightArrow, .option) == nil)
        #expect(action(.escape) == nil, "Esc is the panel's")
    }

    // MARK: Undo

    @Test func undoRestoresTheOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        let undo = UndoManager()
        session.undoManager = undo

        session.click(0)
        session.perform(.moveLater)
        #expect(order(session) == [1, 0, 2, 3, 4])
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Move Pages")
        undo.undo()
        #expect(order(session) == [0, 1, 2, 3, 4])
        #expect(editor.chromeState.blocker == "No changes")
        #expect(undo.canRedo)
        undo.redo()
        #expect(order(session) == [1, 0, 2, 3, 4])
        #expect(editor.chromeState.blocker == nil)
    }

    @Test func undoBringsBackADeletedPageAndATurn() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 4, in: dir))
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo

        func change(_ action: PageAction, on position: Int) {
            undo.beginUndoGrouping()
            session.click(position)
            session.perform(action)
            undo.endUndoGrouping()
        }
        change(.rotateRight, on: 2)
        change(.delete, on: 1)
        #expect(order(session) == [0, 2, 3])
        undo.undo()
        #expect(order(session) == [0, 1, 2, 3])
        #expect(session.model?.pages[2].rotation == 90)
        undo.undo()
        #expect(session.model?.pages.allSatisfy { $0.rotation == 0 } == true)
        #expect(!undo.canUndo)
        undo.redo()
        undo.redo()
        #expect(order(session) == [0, 2, 3])
        #expect(session.model?.pages[1].rotation == 90)
    }

    @Test func choosingPagesIsNotUndoable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 3, in: dir))
        let undo = UndoManager()
        session.undoManager = undo
        session.click(1)
        session.perform(.selectAll)
        session.perform(.moveEarlier)
        session.perform(.rotateLeft)
        session.perform(.rotateRight)
        #expect(order(session) == [0, 1, 2], "everything is selected, so a move changes nothing")
        #expect(undo.canUndo, "the two turns did register")
        undo.undo()
        undo.undo()
        #expect(!undo.canUndo)
    }

    @Test func theViewsUndoManagerIsThePanels() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 3, in: dir))
        editor.panel.contentView?.layoutSubtreeIfNeeded()
        let panelUndo = try #require(editor.panel.undoManager)
        #expect(await eventually { session.undoManager === panelUndo })

        session.click(0)
        session.perform(.moveLater)
        #expect(order(session) == [1, 0, 2])
        // ⌘Z reaches the panel as `undo:`, which the panel answers with its manager.
        #expect(editor.panel.responds(to: Selector(("undo:"))))
        panelUndo.undo()
        #expect(order(session) == [0, 1, 2])
    }

    @Test func closingTheEditorClearsItsUndoSteps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        let session = try await opened(editor, try Fixtures.pdf(pages: 3, in: dir))
        editor.panel.contentView?.layoutSubtreeIfNeeded()
        let panelUndo = try #require(editor.panel.undoManager)
        #expect(await eventually { session.undoManager === panelUndo })
        session.click(0)
        session.perform(.rotateRight)
        #expect(panelUndo.canUndo)
        editor.cancel()
        #expect(!panelUndo.canUndo && !panelUndo.canRedo, "the next editor must not undo this one's pages")
    }

    // MARK: Pointer

    private let layout = PageGridLayout(count: 5)

    private func centre(_ position: Int) -> CGPoint {
        let frame = layout.frame(ofPosition: position)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test func theGridLayoutFindsCellsAndGaps() {
        #expect(layout.rows == 2)
        #expect(layout.position(at: centre(0)) == 0)
        #expect(layout.position(at: centre(3)) == 3)
        #expect(layout.position(at: centre(4)) == 4)
        #expect(layout.position(at: CGPoint(x: layout.frame(ofPosition: 0).maxX + 3, y: 80)) == 0,
                "a gap belongs to the page before it")
        #expect(layout.position(at: centre(4).applying(.init(translationX: 3 * PageGridLayout.columnPitch, y: 0))) == nil,
                "the empty places of the last row")
        #expect(layout.position(at: CGPoint(x: -1, y: 10)) == nil)
        #expect(PageGridLayout(count: 0).position(at: CGPoint(x: 20, y: 20)) == nil)
        #expect(layout.height == 2 * PageGridLayout.padding + 2 * PageGridLayout.cell.height + PageGridLayout.spacing)
    }

    @Test func theInsertionIsTheGapNearestThePointer() {
        func at(_ position: Int, _ half: CGFloat) -> PageGridLayout.Insertion {
            let frame = layout.frame(ofPosition: position)
            return layout.insertion(at: CGPoint(x: frame.minX + frame.width * half, y: frame.midY))
        }
        #expect(at(0, 0.2).index == 0)
        #expect(at(0, 0.8).index == 1, "the right half of a page is the gap after it")
        #expect(at(2, 0.2).index == 2)
        #expect(at(3, 0.8) == PageGridLayout.Insertion(index: 4, row: 0, column: 4), "the end of the first row")
        #expect(at(4, 0.2) == PageGridLayout.Insertion(index: 4, row: 1, column: 0))
        #expect(at(4, 0.8) == PageGridLayout.Insertion(index: 5, row: 1, column: 1))
        let past = layout.insertion(at: CGPoint(x: 500, y: layout.frame(ofPosition: 4).midY))
        #expect(past == PageGridLayout.Insertion(index: 5, row: 1, column: 1), "past the last page is the end")
        let full = PageGridLayout(count: 8).insertion(at: CGPoint(x: 540, y: 300))
        #expect(full == PageGridLayout.Insertion(index: 8, row: 1, column: 4))
        #expect(layout.insertion(at: CGPoint(x: -50, y: -50)) == PageGridLayout.Insertion(index: 0, row: 0, column: 0))
        let bar = layout.bar(for: PageGridLayout.Insertion(index: 0, row: 0, column: 0))
        #expect(bar.height == PageGridLayout.cell.height && bar.width == 3)
    }

    @Test func draggingAPageMovesItToTheGap() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        let undo = UndoManager()
        session.undoManager = undo
        let drop = CGPoint(x: layout.frame(ofPosition: 3).minX + 20, y: layout.frame(ofPosition: 3).midY)

        session.pointerChanged(from: centre(0), to: CGPoint(x: centre(0).x + 2, y: centre(0).y), in: layout)
        #expect(session.drag == nil, "within the click slop")
        session.pointerChanged(from: centre(0), to: drop, in: layout)
        #expect(session.drag?.pages == [0])
        #expect(session.drag?.insertion.index == 3)
        #expect(session.model?.selection == [0], "the page that is lifted is chosen")
        session.pointerEnded(from: centre(0), to: drop, in: layout, toggle: false, extend: false)

        #expect(session.drag == nil)
        #expect(order(session) == [1, 2, 0, 3, 4])
        #expect(session.model?.selection == [2])
        undo.undo()
        #expect(order(session) == [0, 1, 2, 3, 4])
    }

    @Test func draggingAChosenPageLiftsEveryChosenPage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        session.click(0)
        session.click(2, toggle: true)
        let end = CGPoint(x: layout.frame(ofPosition: 4).maxX, y: layout.frame(ofPosition: 4).midY)

        session.pointerChanged(from: centre(2), to: end, in: layout)
        #expect(session.drag?.pages == [0, 2])
        session.pointerEnded(from: centre(2), to: end, in: layout, toggle: false, extend: false)

        #expect(order(session) == [1, 3, 4, 0, 2])
        #expect(session.model?.selection == [3, 4])
    }

    @Test func droppingWhereItWasChangesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        let undo = UndoManager()
        session.undoManager = undo
        let away = CGPoint(x: centre(1).x + 30, y: centre(1).y)

        session.pointerChanged(from: centre(1), to: away, in: layout)
        session.pointerEnded(from: centre(1), to: away, in: layout, toggle: false, extend: false)

        #expect(order(session) == [0, 1, 2, 3, 4])
        #expect(!undo.canUndo)
        #expect(editor.chromeState.blocker == "No changes")
    }

    @Test func clicksChooseWithTheModifiers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        func click(_ position: Int, toggle: Bool = false, extend: Bool = false) {
            session.pointerChanged(from: centre(position), to: centre(position), in: layout)
            session.pointerEnded(from: centre(position), to: centre(position), in: layout, toggle: toggle, extend: extend)
        }
        click(1)
        #expect(session.model?.selection == [1])
        click(3, toggle: true)
        #expect(session.model?.selection == [1, 3])
        click(2, extend: true)
        #expect(session.model?.selection == [2, 3], "the ⌘-click moved the anchor to page 4")
        click(0)
        #expect(session.model?.selection == [0])
        let empty = CGPoint(x: layout.frame(ofPosition: 4).midX + 3 * PageGridLayout.columnPitch, y: centre(4).y)
        session.pointerEnded(from: empty, to: empty, in: layout, toggle: false, extend: false)
        #expect(session.model?.selection.isEmpty == true, "a click on nothing chooses nothing")
        #expect(session.drag == nil)
    }

    @Test func aDragNeverTouchesTheDragPasteboard() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        let count = NSPasteboard(name: .drag).changeCount
        session.pointerChanged(from: centre(0), to: centre(3), in: layout)
        session.pointerEnded(from: centre(0), to: centre(3), in: layout, toggle: false, extend: false)
        #expect(NSPasteboard(name: .drag).changeCount == count)
    }

    // MARK: Autoscroll

    @Test func closingTheEditorMidDragStopsTheAutoscroll() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        var ticks = 0
        session.pointerChanged(from: centre(0), to: centre(3), in: layout)
        #expect(session.drag != nil)
        // The hosted grid starts its own autoscroll when the drag begins; this one replaces it.
        #expect(await eventually { session.autoscroll != nil })
        session.startAutoscroll(every: .milliseconds(5)) { _ in ticks += 1 }
        let task = try #require(session.autoscroll)
        #expect(await eventually { ticks > 0 }, "the task runs while the drag is on")

        editor.cancel()

        #expect(session.drag == nil, "a drag whose end never comes is dropped")
        #expect(session.autoscroll == nil)
        #expect(task.isCancelled)
        let stopped = ticks
        try await Task.sleep(for: .milliseconds(100))
        #expect(ticks == stopped, "nothing wakes after the editor closed")
    }

    @Test func theAutoscrollEndsWithItsDrag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 5, in: dir))
        var ticks = 0
        session.pointerChanged(from: centre(0), to: centre(3), in: layout)
        #expect(await eventually { session.autoscroll != nil })
        session.startAutoscroll(every: .milliseconds(5)) { _ in ticks += 1 }
        #expect(await eventually { ticks > 0 })
        session.pointerEnded(from: centre(0), to: centre(3), in: layout, toggle: false, extend: false)
        #expect(session.autoscroll == nil)
        let stopped = ticks
        try await Task.sleep(for: .milliseconds(100))
        #expect(ticks == stopped)
    }

    @Test func theAutoscrollDoesNotKeepAClosedSessionAlive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        let pdf = try Fixtures.pdf(pages: 5, in: dir)
        weak var weakSession: PageOrganizerSession?
        do {
            let session = try await opened(editor, pdf)
            weakSession = session
            session.pointerChanged(from: centre(0), to: centre(3), in: layout)
            session.startAutoscroll(every: .milliseconds(5)) { _ in }
        }
        editor.cancel()
        #expect(await eventually { weakSession == nil })
    }

    // MARK: VoiceOver

    @Test func voiceOverActsOnThePageItIsOn() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = makeEditor(Jobs())
        defer { editor.cancel() }
        let session = try await opened(editor, try Fixtures.pdf(pages: 4, in: dir))
        session.click(0)
        session.click(1, toggle: true)

        session.act(on: 2, .moveEarlier)
        #expect(order(session) == [0, 2, 1, 3], "only that page moves, though two were chosen")
        #expect(session.model?.selection == [1])
        session.act(on: 1, .rotateRight)
        session.act(on: 3, .rotateLeft)
        #expect(session.model?.pages.map(\.rotation) == [0, 90, 0, 270])
        session.act(on: 0, .delete)
        #expect(order(session) == [2, 1, 3])
        #expect(session.model?.label(at: 0) == "Page 3, position 1 of 3, rotated 90\u{00B0}")
        session.act(on: 9, .delete)
        #expect(order(session) == [2, 1, 3], "there is no such page")
    }
}

/// P78 through each real session: a save that fails at once keeps the choices, and the next ordinary edit (one that
/// leaves the footer's line as it was) puts the footer back to the session's own line, ready to save again.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct QuickFailureTests {
    @MainActor
    private final class Saves {
        var count = 0
    }

    private static let failure = ResultSummary(title: "Couldn't save the file", detail: "It has no sound", isFailure: true)

    private func request(_ kind: EditorKind, _ file: URL, flags: EdgeFlags = []) throws -> EditorRequest {
        let preset = try #require(EditorSessions.preset(for: kind, settings: AppSettings()))
        return EditorRequest(kind: kind, preset: preset, files: [file], anchor: anchor, flags: flags)
    }

    /// Opens `request`, waits for `ready` to make the choices savable, saves into a quick failure, then `edit`s.
    private func expectAnEditClearsTheFailure<S: EditorSession>(
        _ request: EditorRequest, as type: S.Type,
        ready: @MainActor (S) async throws -> Void, edit: @MainActor (S) -> Void
    ) async throws {
        let saves = Saves()
        let editor = EditorController(
            settings: SettingsStore(defaults: EphemeralDefaults()),
            perform: { _, _, _, _ in
                saves.count += 1
                return JobHandle(id: UUID(), outcome: Task { JobOutcome.failed(Self.failure) })
            },
            release: { _, _ in }, desktop: .offScreen
        )
        defer { editor.cancel() }
        editor.open(request)
        let session = try #require(editor.session as? S)
        try await ready(session)
        #expect(editor.chromeState.blocker == nil)
        let footer = editor.chromeState.note

        editor.confirm()
        #expect(await eventually { if case .failed = editor.phase { true } else { false } })
        #expect(editor.chromeState.phase == .failed(WheelAlert(title: Self.failure.title, subtitle: Self.failure.detail)))

        edit(session)
        #expect(editor.phase == .editing)
        #expect(editor.chromeState.phase == .editing)
        #expect(editor.chromeState.blocker == nil)
        #expect(editor.chromeState.note == footer, "the edit leaves the footer's own line as it was")
        editor.confirm()
        #expect(saves.count == 2)
    }

    @Test func aCropEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.png(width: 400, height: 300, in: dir)
        try await expectAnEditClearsTheFailure(try request(.crop, photo, flags: [.lossy]), as: CropSession.self) { session in
            #expect(await eventually { session.model != nil })
            session.setRatio(.square)
        } edit: { session in
            #expect(session.perform(.move(dx: 1, dy: 0, coarse: false)))
        }
    }

    @Test func aRedactEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try Fixtures.textImage("Write to ann@example.com today", in: dir)
        try await expectAnEditClearsTheFailure(try request(.redact, image, flags: [.lossy]), as: RedactSession.self) { session in
            #expect(await eventually { session.model != nil && !session.isDetecting })
        } edit: { session in
            let line = session.model?.boxes.first { $0.kind == .text && !$0.isOn }
            #expect(line != nil)
            if let line { session.setOn(line.id, true) }
        }
    }

    @Test func anOrganizeEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(pages: 5, in: dir)
        try await expectAnEditClearsTheFailure(try request(.organizePages, pdf), as: PageOrganizerSession.self) { session in
            #expect(await eventually { session.model != nil })
            session.click(4)
            session.perform(.moveEarlier)
        } edit: { session in
            session.click(0)
            session.perform(.moveLater)
        }
    }

    @Test func aTrimEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 4, withAudio: false, in: dir)
        try await expectAnEditClearsTheFailure(try request(.trim, movie), as: TrimSession.self) { session in
            #expect(await eventually { session.model != nil })
            session.drag(.start, to: 1)
        } edit: { session in
            session.drag(.end, to: 3)
        }
    }

    @Test func aSplitEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 4, withAudio: false, in: dir)
        try await expectAnEditClearsTheFailure(try request(.split, movie), as: SplitSession.self) { session in
            #expect(await eventually { session.model != nil })
            session.scrub(to: 1)
            session.perform(.addPoint)
        } edit: { session in
            session.scrub(to: 3)
            session.perform(.addPoint)
        }
    }

    @Test func aTargetSizeEditClearsAQuickFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try bigFile("photo.jpg", bytes: 1_200_000, in: dir)
        try await expectAnEditClearsTheFailure(try request(.targetSize, photo), as: TargetSizeSession.self) { _ in
        } edit: { session in
            session.model.choose(900_000)
        }
    }
}
