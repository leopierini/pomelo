import AppKit
import Foundation
import ImageIO
import PomeloCore
import PomeloUIModel
import Testing
import UniformTypeIdentifiers
@testable import Pomelo

/// A job for the wheel to follow; its id is fresh.
private func handle(_ outcome: @escaping @Sendable () async -> JobOutcome) -> JobHandle {
    JobHandle(id: UUID(), outcome: Task { await outcome() })
}

private let failure = ResultSummary.make(results: [
    .failed(source: URL(fileURLWithPath: "/tmp/a.png"),
            error: .engineFailed(engine: "imageio", message: "cannot open a.png as an image")),
])

@Suite struct DropFollowUpTests {
    @Test func aSuccessClosesAndAFailureShowsItsSummary() {
        #expect(DropFollowUp.decision(for: .succeeded) == .close)
        #expect(DropFollowUp.decision(for: .failed(failure))
                == .showFailure(WheelAlert(title: "Couldn't convert a.png", subtitle: "The file may be damaged")))
    }

    @Test func aNoteShowsInTheAccentStyle() {
        let note = ResultSummary(title: "Copied 1 code", detail: "https://example.com")
        #expect(DropFollowUp.decision(for: .noted(note)) == .showNote(WheelAlert(
            title: "Copied 1 code", subtitle: "https://example.com", symbol: "checkmark.circle.fill", style: .note
        )))
    }

    @Test func theStandardTimesAreTheRulingsOnes() {
        #expect(DropFollowUp.standard.resultWait == .seconds(1))
        #expect(DropFollowUp.standard.noteStay == .milliseconds(1500))
        #expect(DropFollowUp.standard.minimumStay == WheelController.closeDelay)
    }

    @Test func onlyMovingWellPastTheRingCountsAsAway() {
        let center = CGPoint(x: 500, y: 500)
        #expect(!DropFollowUp.movedWellAway(CGPoint(x: 500 + 170, y: 500), from: center))   // the rim
        #expect(!DropFollowUp.movedWellAway(CGPoint(x: 500 + 150, y: 500 + 150), from: center))
        #expect(DropFollowUp.movedWellAway(CGPoint(x: 500, y: 500 - 260), from: center))
    }
}

/// Holds a readability verdict back until the test opens the gate, so a verdict can arrive late on purpose.
final class ReadabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var looked = 0
    private var stoppedEarly = false

    func open() { lock.withLock { isOpen = true } }
    /// How many files the check looked at.
    var filesLooked: Int { lock.withLock { looked } }
    /// True once a check saw its cancellation and stopped before its last file.
    var sawCancellation: Bool { lock.withLock { stoppedEarly } }

    /// Blocks the checking thread until the gate opens (cancellation does not end the wait).
    func wait() {
        while !lock.withLock({ isOpen }) { Thread.sleep(forTimeInterval: 0.005) }
    }

    /// Looks at one file every 20 ms, as a slow disk would, asking about cancellation before each one.
    func slowCheck(_ files: [URL], isCancelled: () -> Bool) -> FileReadability.Report {
        for _ in files {
            if isCancelled() {
                lock.withLock { stoppedEarly = true }
                break
            }
            lock.withLock { looked += 1 }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileReadability.Report(damaged: files, allDamaged: true)
    }
}

/// An engine whose availability the test sets, standing in for Apple Intelligence getting ready.
private final class ReadyLater: ConversionEngine, @unchecked Sendable {
    static let notReady = "Apple Intelligence is still getting ready. Try again in a few minutes."
    let id: EngineID = "model"
    let displayName = "Model"
    let maxConcurrentJobs = 1
    let availabilityIsVolatile = true
    private let lock = NSLock()
    private var ready = false

    func becomeReady() { lock.withLock { ready = true } }

    func availability() async -> EngineAvailability {
        lock.withLock { ready } ? .available(version: nil) : .unsupported(reason: Self.notReady)
    }

    func edges() -> [ConversionEdge] { [ConversionEdge(from: "png", to: "jpg", engineID: id, cost: 1, flags: [])] }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        step.suggestedOutput
    }
}

private struct Release: Equatable {
    var id: UUID
    var outcomeShown: Bool
}

/// The wheel's 1.0 s wait for a dropped job (P23), with the times shortened. The panel really opens, but off-screen
/// and without becoming key, and the dismiss monitors stay off: nothing reaches whoever runs the tests.
@MainActor
@Suite(.serialized) struct WheelFollowUpTests {
    private let png = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-a.png")
    /// The wheel's stays and waits (each test gets its own suite instance, so its own clock).
    private let clock = ManualClock()

    /// Once the wheel's sleep of `timer` (by default `duration`) waits, moves the virtual clock on by `duration`
    /// (the suite waits for no real timer); the exact length tells it from the result wait it replaced.
    private func pass(_ duration: Duration, timer: Duration? = nil) async {
        #expect(await eventually { clock.isWaiting(for: timer ?? duration) })
        await clock.advance(by: duration)
    }

    private func makeWheel(
        _ followUp: DropFollowUp,
        readabilityCheck: @escaping @Sendable ([URL], @Sendable () -> Bool) async -> FileReadability.Report = {
            await FileReadability.check($0, isCancelled: $1)
        }
    ) -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, followUp: followUp, desktop: .offScreen,
                                    readabilityCheck: readabilityCheck, clock: clock.timerClock)
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: [], visibility: makeZipOnImages)
        return wheel
    }

    private func slice(_ id: String, in wheel: WheelController) throws -> WheelSlice {
        let slices = wheel.model.pages.flatMap(\.slices)
        return try #require(slices.first { $0.id == id })
    }

    private func waitUntil(_ what: String, within limit: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }

    /// P191: no timer closes a failure; a click on the wheel's hub does.
    @Test func aFailureWithinTheWaitTurnsTheHubRedAndStays() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let job = handle { .failed(failure) }
        var anchors: [CGPoint] = []
        var releases: [Release] = []
        wheel.onChoose = { _, _, center in
            anchors.append(center)
            return job
        }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        #expect(wheel.model.phase == .waiting)
        #expect(anchors == [CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY)])
        // The panel keeps the mouse: a click on the wheel must not land on whatever lies under it.
        #expect(!wheel.panel.ignoresMouseEvents)
        try await waitUntil("the failure") { wheel.model.isFailed }

        #expect(wheel.isOpen)
        #expect(wheel.model.alert == WheelAlert(title: "Couldn't convert a.png", subtitle: "The file may be damaged"))
        #expect(wheel.model.hovered == nil)
        // The hub showed it, so the pill never will.
        #expect(releases == [Release(id: job.id, outcomeShown: true)])
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen)
        #expect(wheel.model.isFailed)
        try click(wheel)
        #expect(!wheel.isOpen)
        #expect(releases.count == 1)
    }

    @Test func aJobStillRunningWhenTheWaitEndsClosesTheWheelAndALaterFailureGoesToThePill() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .milliseconds(150)))
        defer { wheel.close() }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let job = handle {
            for await _ in gate { break }
            return .failed(failure)
        }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        await pass(.milliseconds(150))
        try await waitUntil("the wait to end") { !wheel.isOpen }
        #expect(!wheel.model.isFailed)

        open.yield()
        _ = await job.outcome.value
        await clock.advance(by: .milliseconds(50))
        #expect(!wheel.isOpen)
        #expect(!wheel.model.isFailed)
        // The pill shows the failure instead.
        #expect(releases == [Release(id: job.id, outcomeShown: false)])
    }

    @Test func aJobStillRunningWhenTheWaitEndsIsReleasedUnshown() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .milliseconds(150)))
        defer { wheel.close() }
        let job = handle {
            try? await Task.sleep(for: .seconds(30))
            return .succeeded
        }
        defer { job.outcome.cancel() }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        #expect(releases.isEmpty)
        await pass(.milliseconds(150))
        try await waitUntil("the wait to end") { !wheel.isOpen }
        #expect(releases == [Release(id: job.id, outcomeShown: false)])
    }

    /// A panel that went away without closing (nothing can show the outcome) still lets go of the job.
    @Test func anOutcomeTheHubCannotShowIsReleasedUnshown() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let job = handle {
            for await _ in gate { break }
            return .failed(failure)
        }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])

        wheel.panel.orderOut(nil)
        open.yield()
        try await waitUntil("the release") { !releases.isEmpty }
        #expect(releases == [Release(id: job.id, outcomeShown: false)])
        #expect(!wheel.model.isFailed)
    }

    @Test func aNoteWithinTheWaitShowsInTheHub() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5),
                                           noteStay: .milliseconds(300)))
        defer { wheel.close() }
        let note = ResultSummary(title: "Copied 1 code", detail: "https://example.com")
        let job = handle { .noted(note) }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        let start = clock.now
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the note") { wheel.model.showsOutcome }

        guard case .noted(let alert) = wheel.model.phase else {
            Issue.record("expected a note, got \(wheel.model.phase)")
            return
        }
        #expect(alert.style == .note)
        #expect(alert.symbol == "checkmark.circle.fill")
        #expect(wheel.model.alert == alert)
        #expect(alert.title == "Copied 1 code")
        #expect(alert.subtitle == "https://example.com")
        #expect(!wheel.model.isFailed)
        #expect(releases == [Release(id: job.id, outcomeShown: true)])
        await pass(.milliseconds(300))
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(clock.now - start >= .milliseconds(300))
        #expect(releases.count == 1)
    }

    @Test func aSuccessReleasesTheJobAsShown() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let job = handle { .succeeded }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(releases == [Release(id: job.id, outcomeShown: true)])
    }

    @Test func aSuccessClosesTheWheelNoSoonerThanTheMinimumStay() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .milliseconds(250), resultWait: .seconds(5)))
        defer { wheel.close() }
        wheel.onChoose = { _, _, _ in handle { .succeeded } }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        let start = clock.now
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        await pass(.milliseconds(249), timer: .milliseconds(250))
        #expect(wheel.isOpen)
        await clock.advance(by: .milliseconds(1))
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(clock.now - start >= .milliseconds(250))
        #expect(!wheel.model.isFailed)
    }

    @Test func anActionDropDoesNotWaitForItsOutcome() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        var chosen: [String] = []
        var releases: [Release] = []
        wheel.onChoose = { slice, _, _ in
            chosen.append(slice.id)
            return handle { .failed(failure) }
        }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))

        wheel.choose(try slice("action.makeZip", in: wheel), files: [png])
        #expect(chosen == ["action.makeZip"])
        #expect(wheel.model.phase == .choosing)
        // The button-up closes it 0.35 s later, as before.
        wheel.dragEnded()
        await pass(WheelController.closeDelay)
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(!wheel.model.isFailed)
        // A file tool's job was never held: its pill is its own.
        #expect(releases.isEmpty)
    }

    @Test func tappingTheTriggerAlternatesTheTwoPages() {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.pages.map(\.kind) == [.convert, .tools])
        #expect(wheel.model.pageIndex == 0)

        wheel.cyclePage()
        #expect(wheel.model.pageIndex == 1)
        #expect(wheel.model.page?.title == "Tools")
        wheel.cyclePage()
        #expect(wheel.model.pageIndex == 0)
        #expect(wheel.model.page?.title == "Convert")
    }

    @Test func tappingTheTriggerAlternatesThePagesOfAMovieWithEditors() {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let edges = [ConversionEdge(from: "mov", to: "mp4", engineID: "x", cost: 1, flags: []),
                     ConversionEdge(from: "mov", to: "mov", engineID: "x", cost: 1, flags: [], operation: "trim")]
        let planner = RoutePlanner(edges: edges, enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: ToolCatalog.presets(settings: AppSettings()))
        wheel.open(files: [URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-a.mov")], at: NSEvent.mouseLocation,
                   clickMode: false)
        #expect(wheel.model.pages.map(\.kind) == [.convert, .tools])
        #expect(wheel.model.pages[1].slices.map(\.id) == ["editor.trim", "action.shelf"])
        wheel.cyclePage()
        #expect(wheel.model.pageIndex == 1)
        wheel.cyclePage()
        #expect(wheel.model.pageIndex == 0)
    }

    @Test func anEditorSliceOpensTheEditorAndClosesTheWheel() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)),
                              readabilityCheck: { _, _ in .clean })
        defer { wheel.close() }
        let edges = [ConversionEdge(from: "mov", to: "mov", engineID: "x", cost: 1, flags: [], operation: "trim")]
        let planner = RoutePlanner(edges: edges, enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: ToolCatalog.presets(settings: AppSettings()))
        let movie = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-a.mov")
        var opened: [(slice: String, files: [URL], center: CGPoint)] = []
        var chosen = 0
        wheel.onOpenEditor = { opened.append(($0.id, $1, $2)) }
        wheel.onChoose = { _, _, _ in
            chosen += 1
            return nil
        }
        wheel.open(files: [movie], at: NSEvent.mouseLocation, clickMode: false)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))

        wheel.choose(try slice("editor.trim", in: wheel), files: [movie])
        #expect(opened.count == 1)
        #expect(opened.first?.slice == "editor.trim")
        #expect(opened.first?.files == [movie])
        #expect(opened.first?.center == CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY))
        #expect(chosen == 0)
        // Still up until the drop's performDragOperation has returned.
        #expect(wheel.isOpen)
        #expect(wheel.model.phase == .choosing)
        await Task.yield()
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(opened.count == 1)
    }

    @Test func shelfSliceGoesToOnShelfNotTheCoordinator() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)),
                              readabilityCheck: { _, _ in .clean })
        defer { wheel.close() }
        let png = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-shelf.png")
        var shelved: [(files: [URL], center: CGPoint)] = []
        var chosen = 0
        var edited = 0
        wheel.onShelf = { shelved.append(($0, $1)) }
        wheel.onChoose = { _, _, _ in
            chosen += 1
            return nil
        }
        wheel.onOpenEditor = { _, _, _ in edited += 1 }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))

        wheel.choose(try slice("action.shelf", in: wheel), files: [png])
        #expect(shelved.count == 1)
        #expect(shelved.first?.files == [png])
        #expect(shelved.first?.center == CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY))
        #expect(chosen == 0 && edited == 0)
        // A drag's wheel closes on its own after the button-up.
        #expect(wheel.isOpen)
        wheel.dragEnded()
        await pass(WheelController.closeDelay)
        try await waitUntil("the wheel to close") { !wheel.isOpen }
    }

    /// The Shelf appears centred under the click (S7): as for an editor (M3), the emptied panel takes a
    /// double-click's second click for the double-click interval, so it never lands on the Shelf.
    @Test func shelfSliceClosesTheClickModeWheel() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)),
                              readabilityCheck: { _, _ in .clean })
        defer { wheel.close() }
        let png = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-shelf.png")
        var shelved = 0
        var chosen = 0
        wheel.onShelf = { _, _ in
            shelved += 1
            // The Shelf came up: the panel was already emptied and still takes clicks.
            #expect(!wheel.isOpen && wheel.model.isContentHidden)
        }
        wheel.onChoose = { _, _, _ in
            chosen += 1
            return nil
        }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: true)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))

        wheel.choose(try slice("action.shelf", in: wheel), files: [png])
        #expect(shelved == 1 && chosen == 0)
        #expect(!wheel.isOpen)
        #expect(wheel.model.isContentHidden)
        #expect(wheel.panel.isVisible && !wheel.panel.ignoresMouseEvents)

        let interval = Duration.seconds(NSEvent.doubleClickInterval)
        await pass(interval - .milliseconds(1), timer: interval)
        #expect(wheel.panel.isVisible)
        await clock.advance(by: .milliseconds(1))
        try await waitUntil("the panel to go") { !wheel.panel.isVisible }
        #expect(shelved == 1)
    }

    /// M3 for editors: a click on an editor slice empties the wheel but keeps its panel in for a double-click
    /// interval, so the second click of a double-click never lands in the editor opening under it.
    @Test func aClickOnAnEditorSliceKeepsThePanelTakingClicks() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)),
                              readabilityCheck: { _, _ in .clean })
        defer { wheel.close() }
        let edges = [ConversionEdge(from: "mov", to: "mov", engineID: "x", cost: 1, flags: [], operation: "trim")]
        let planner = RoutePlanner(edges: edges, enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: ToolCatalog.presets(settings: AppSettings()))
        let movie = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-a.mov")
        var opened: [String] = []
        wheel.onOpenEditor = { slice, _, _ in
            opened.append(slice.id)
            // The editor becomes key, which the click-mode wheel hears as losing key.
            wheel.panel.onResignKey?()
        }
        wheel.open(files: [movie], at: NSEvent.mouseLocation, clickMode: true)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))

        let clicked = clock.now
        wheel.choose(try slice("editor.trim", in: wheel), files: [movie])
        #expect(opened == ["editor.trim"])
        #expect(!wheel.isOpen)
        #expect(wheel.model.isContentHidden)
        #expect(wheel.panel.isVisible && !wheel.panel.ignoresMouseEvents)

        let interval = Duration.seconds(NSEvent.doubleClickInterval)
        await pass(interval - .milliseconds(1), timer: interval)
        #expect(wheel.panel.isVisible)
        await clock.advance(by: .milliseconds(1))
        try await waitUntil("the panel to go") { !wheel.panel.isVisible }
        #expect(clock.now - clicked >= interval)
        #expect(opened.count == 1)
    }

    @Test func nothingMoreCanBeChosenOnceADropLanded() throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        var count = 0
        wheel.onChoose = { _, _, _ in
            count += 1
            return handle { .succeeded }
        }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        let jpg = try slice("convert.jpg", in: wheel)

        wheel.choose(jpg, files: [png])
        wheel.choose(jpg, files: [png])
        #expect(count == 1)
    }

    /// A conversion runs only on the readable files once the check has found a damaged one.
    @Test func aConversionSkipsTheDamagedFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pomelo-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "a.png")
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(good as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let bad = dir.appending(path: "bad.png")
        try Data("x".utf8).write(to: bad)

        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        var received: [URL] = []
        wheel.onChoose = { _, files, _ in
            received = files
            return handle { .succeeded }
        }
        wheel.open(files: [good, bad], at: NSEvent.mouseLocation, clickMode: false)
        try await waitUntil("the readability check") { !wheel.model.readability.damaged.isEmpty }
        #expect(wheel.model.alert?.title == "bad.png can't be read")

        wheel.choose(try slice("convert.jpg", in: wheel), files: [good, bad])
        #expect(received == [good])
    }

    /// A click on the panel, by default on its centre (the hub), in its window's coordinates.
    private func click(_ wheel: WheelController, at point: CGPoint? = nil) throws {
        let panel = wheel.panel
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point ?? CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2),
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        panel.dropTarget.mouseDown(with: event)
    }

    /// A drag's wheel takes a click on itself while it waits or shows a failure, and closes (P23).
    @Test func aClickOnTheWheelAfterADropClosesIt() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let job = handle {
            try? await Task.sleep(for: .seconds(30))
            return .succeeded
        }
        defer { job.outcome.cancel() }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        #expect(wheel.model.phase == .waiting)
        try click(wheel)
        #expect(!wheel.isOpen)
        // Closed while it waited: the pill takes the job over.
        #expect(releases == [Release(id: job.id, outcomeShown: false)])

        // The same while the failure shows.
        wheel.onChoose = { _, _, _ in handle { .failed(failure) } }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the failure") { wheel.model.isFailed }
        try click(wheel)
        #expect(!wheel.isOpen)
    }

    /// M3: a click that closes the wheel hides it but keeps the panel in for a double-click interval, so the second
    /// click of a double-click lands on the panel too, never on the Finder item under the wheel.
    @Test func aSecondClickJustAfterAClickCloseIsTakenByThePanel() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        var chosen = 0
        wheel.onChoose = { _, _, _ in
            chosen += 1
            return handle { .failed(failure) }
        }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the failure") { wheel.model.isFailed }

        let clicked = clock.now
        try click(wheel)
        #expect(!wheel.isOpen)
        #expect(wheel.model.isContentHidden)
        #expect(wheel.panel.isVisible && !wheel.panel.ignoresMouseEvents)
        try click(wheel)
        #expect(wheel.model.isContentHidden && wheel.panel.isVisible)
        #expect(chosen == 1)

        let interval = Duration.seconds(NSEvent.doubleClickInterval)
        await pass(interval)
        try await waitUntil("the panel to go") { !wheel.panel.isVisible }
        #expect(clock.now - clicked >= interval)
        #expect(!wheel.model.isContentHidden)

        // An open during the interval shows the new wheel at once, and the old timer leaves it up.
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the failure") { wheel.model.isFailed }
        try click(wheel)
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.isOpen && !wheel.model.isContentHidden)
        await clock.advance(by: interval + .milliseconds(150))
        #expect(wheel.isOpen && wheel.panel.isVisible)
    }

    /// P23 for video: a movie that is only garbage turns the hub red once the check has run.
    @Test func aBrokenMovieTurnsTheHubRedOnOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pomelo-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "broken.mov")
        try Data("garbage".utf8).write(to: movie)

        let wheel = makeWheel(DropFollowUp())
        defer { wheel.close() }
        // A movie gets no Make Zip by default, so the wheel opens only if some tool takes it.
        let planner = RoutePlanner(
            edges: [ConversionEdge(from: "mov", to: "mov", engineID: "x", cost: 1, flags: [], operation: "compress")],
            enginePriority: ["x"])
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: ToolCatalog.presets(settings: AppSettings()))
        wheel.open(files: [movie], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.alert == nil)
        try await waitUntil("the readability check") { wheel.model.alert != nil }
        #expect(wheel.model.alert == WheelAlert(title: "broken.mov can't be read", subtitle: "The file may be damaged"))
    }

    /// The old job's outcome belongs to the old wheel: a wheel opened meanwhile goes on choosing.
    @Test func aWheelReopenedWhileTheOldOneWaitsIgnoresTheOldJobsFailure() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        let (gate, open) = AsyncStream<Void>.makeStream()
        let job = handle {
            for await _ in gate { break }
            return .failed(failure)
        }
        var releases: [Release] = []
        wheel.onChoose = { _, _, _ in job }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        #expect(wheel.model.phase == .waiting)

        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.phase == .choosing)
        #expect(releases == [Release(id: job.id, outcomeShown: false)])
        open.yield()
        _ = await job.outcome.value
        await clock.advance(by: .milliseconds(100))
        #expect(wheel.isOpen)
        #expect(wheel.model.phase == .choosing)
        #expect(wheel.model.alert == nil)
    }

    /// The same once the old wheel shows its failure: reopening drops the failure.
    @Test func aWheelReopenedOverAFailureGoesBackToChoosing() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        wheel.onChoose = { _, _, _ in handle { .failed(failure) } }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the failure") { wheel.model.isFailed }
        // The failure turned the drag's wheel into a click wheel (P191), never a key one.
        #expect(wheel.panel.dropTarget.clickMode)
        #expect(!wheel.panel.canBecomeKey)

        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(!wheel.panel.dropTarget.clickMode)
        await clock.advance(by: .milliseconds(400))
        #expect(wheel.isOpen)
        #expect(wheel.model.phase == .choosing)
    }

    /// A request with nothing to show (no files) leaves a failure up, as it was.
    @Test func anOpenWithNothingToShowLeavesAFailureUp() async throws {
        let wheel = makeWheel(DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)))
        defer { wheel.close() }
        wheel.onChoose = { _, _, _ in handle { .failed(failure) } }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        wheel.choose(try slice("convert.jpg", in: wheel), files: [png])
        try await waitUntil("the failure") { wheel.model.isFailed }

        wheel.open(files: [], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.isFailed)
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen && wheel.model.isFailed)
    }

    // MARK: P191: a failure stays until dismissed, and the wheel is live again on the same files

    /// A wheel over the png with jpg and gif enabled and webp disabled (its engine is missing), whose first choice
    /// fails; `then` answers each later choice. Returns once the hub is red.
    /// The Tools page also offers the Crop editor and the file tools.
    private func failedWheel(clickMode: Bool, files: [URL]? = nil,
                             readabilityCheck: @escaping @Sendable ([URL], @Sendable () -> Bool) async
                                 -> FileReadability.Report = { _, _ in .clean },
                             chosen: @escaping (String, [URL]) -> Void = { _, _ in },
                             then later: @escaping () -> JobHandle? = { handle { .succeeded } })
        async throws -> WheelController {
        let files = files ?? [png]
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, followUp: DropFollowUp(minimumStay: .zero, resultWait: .seconds(5)),
                                    desktop: .offScreen, readabilityCheck: readabilityCheck, clock: clock.timerClock)
        let enabled = ["jpg", "gif"].map { ConversionEdge(from: "png", to: FormatID($0), engineID: "x", cost: 1, flags: []) }
            + [ConversionEdge(from: "png", to: "png", engineID: "x", cost: 1, flags: [], operation: "crop")]
        let missing = ConversionEdge(from: "png", to: "webp", engineID: "y", cost: 1, flags: [])
        wheel.contentBuilder = WheelContentBuilder(
            formats: .builtIn, available: RoutePlanner(edges: enabled, enginePriority: ["x"]),
            all: RoutePlanner(edges: enabled + [missing], enginePriority: ["x", "y"]),
            installHints: ["y": "cwebp|brew install webp"], order: [.image: ["jpg", "gif", "webp"]],
            tools: ToolCatalog.presets(settings: AppSettings()), visibility: makeZipOnImages)
        var first = true
        wheel.onChoose = { slice, files, _ in
            chosen(slice.id, files)
            defer { first = false }
            return first ? handle { .failed(failure) } : later()
        }
        wheel.open(files: files, at: NSEvent.mouseLocation, clickMode: clickMode)
        #expect(wheel.model.slices.map(\.id) == ["convert.jpg", "convert.gif", "convert.webp"])
        #expect(wheel.model.slices.map(\.isEnabled) == [true, true, false])
        wheel.choose(try slice("convert.jpg", in: wheel), files: files)
        try await waitUntil("the failure") { wheel.model.isFailed }
        return wheel
    }

    /// Where slice `id`'s label sits in the panel's window coordinates.
    private func point(ofSlice id: String, in wheel: WheelController) throws -> CGPoint {
        let index = try #require(wheel.model.slices.firstIndex { $0.id == id })
        let offset = wheel.model.geometry.labelCenter(ofSlice: index)
        let bounds = wheel.panel.dropTarget.bounds
        return CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
    }

    private func moveMouse(_ wheel: WheelController, to point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: wheel.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        wheel.panel.dropTarget.mouseMoved(with: event)
    }

    private var failureAlert: WheelAlert { WheelAlert(title: "Couldn't convert a.png", subtitle: "The file may be damaged") }

    @Test(arguments: [false, true])
    func aFailureStaysUntilTheMouseMovesWellAway(clickMode: Bool) async throws {
        let wheel = try await failedWheel(clickMode: clickMode)
        defer { wheel.close() }
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen && wheel.model.alert == failureAlert)

        let center = CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY)
        wheel.dismissEvent(isMove: true, at: CGPoint(x: center.x + 150, y: center.y + 150), center: center)
        #expect(wheel.isOpen)
        wheel.dismissEvent(isMove: true, at: CGPoint(x: center.x, y: center.y - 260), center: center)
        #expect(!wheel.isOpen)
    }

    @Test(arguments: [false, true])
    func aFailureStaysUntilAClickElsewhere(clickMode: Bool) async throws {
        let wheel = try await failedWheel(clickMode: clickMode)
        defer { wheel.close() }
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen)

        // A click on the panel is the panel's to handle (it may choose a slice), never the monitors'.
        let center = CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY)
        wheel.dismissEvent(isMove: false, at: CGPoint(x: center.x + 100, y: center.y), center: center)
        #expect(wheel.isOpen && wheel.model.isFailed)
        wheel.dismissEvent(isMove: false, at: CGPoint(x: wheel.panel.frame.maxX + 20, y: center.y), center: center)
        #expect(!wheel.isOpen)
    }

    @Test func escClosesAClickModeFailure() async throws {
        let wheel = try await failedWheel(clickMode: true)
        defer { wheel.close() }
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen && wheel.model.isFailed)
        wheel.handle(.escape)
        #expect(!wheel.isOpen)
    }

    /// In a drag the drop has ended, so the failed wheel takes clicks as click mode's does.
    @Test(arguments: [false, true])
    func afterAFailureAnotherSliceRunsOnTheSameFilesAndItsSuccessCloses(clickMode: Bool) async throws {
        var chosen: [(String, [URL])] = []
        var releases: [Release] = []
        let wheel = try await failedWheel(clickMode: clickMode, chosen: { chosen.append(($0, $1)) })
        defer { wheel.close() }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }

        try click(wheel, at: point(ofSlice: "convert.gif", in: wheel))
        #expect(chosen.map(\.0) == ["convert.jpg", "convert.gif"])
        #expect(chosen.map(\.1) == [[png], [png]])
        try await waitUntil("the wheel to close") { !wheel.isOpen }
        #expect(!wheel.model.isFailed)
        #expect(releases.map(\.outcomeShown) == [true])
    }

    @Test(arguments: [false, true])
    func aSecondFailureStaysToo(clickMode: Bool) async throws {
        var chosen: [String] = []
        let wheel = try await failedWheel(clickMode: clickMode, chosen: { id, _ in chosen.append(id) },
                                          then: { handle { .failed(failure) } })
        defer { wheel.close() }

        try click(wheel, at: point(ofSlice: "convert.gif", in: wheel))
        #expect(wheel.model.phase == .waiting)
        try await waitUntil("the second failure") { wheel.model.isFailed }
        await clock.advance(by: .seconds(3600))
        #expect(wheel.isOpen && wheel.model.alert == failureAlert)
        #expect(chosen == ["convert.jpg", "convert.gif"])
    }

    @Test(arguments: [false, true])
    func aRetryStillRunningWhenTheWaitEndsGoesToThePill(clickMode: Bool) async throws {
        let slow = handle {
            try? await Task.sleep(for: .seconds(30))
            return .succeeded
        }
        defer { slow.outcome.cancel() }
        var releases: [Release] = []
        let wheel = try await failedWheel(clickMode: clickMode, then: { slow })
        defer { wheel.close() }
        wheel.onRelease = { releases.append(Release(id: $0, outcomeShown: $1)) }

        try click(wheel, at: point(ofSlice: "convert.gif", in: wheel))
        await pass(.seconds(5))
        try await waitUntil("the wait to end") { !wheel.isOpen }
        #expect(releases == [Release(id: slow.id, outcomeShown: false)])
    }

    @Test(arguments: [false, true])
    func afterAFailureADisabledSliceDoesNothing(clickMode: Bool) async throws {
        var chosen: [String] = []
        let wheel = try await failedWheel(clickMode: clickMode, chosen: { id, _ in chosen.append(id) })
        defer { wheel.close() }

        try click(wheel, at: point(ofSlice: "convert.webp", in: wheel))
        wheel.choose(try slice("convert.webp", in: wheel), files: [png])
        #expect(chosen == ["convert.jpg"])
        #expect(wheel.isOpen && wheel.model.isFailed)
    }

    /// After a failure (the page changed as Tab would) an editor slice opens its editor on the same files and the
    /// wheel goes, keeping its panel for a double-click (M3); a file tool runs on them and the wheel closes.
    @Test(arguments: [false, true])
    func afterAFailureAnEditorOrAFileToolRunsOnTheSameFiles(clickMode: Bool) async throws {
        var chosen: [(String, [URL])] = []
        var opened: [(String, [URL])] = []
        var wheel = try await failedWheel(clickMode: clickMode, chosen: { chosen.append(($0, $1)) },
                                          then: { handle { .succeeded } })
        wheel.onOpenEditor = { slice, files, _ in opened.append((slice.id, files)) }
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))
        try click(wheel, at: point(ofSlice: "editor.crop", in: wheel))
        #expect(opened.map(\.0) == ["editor.crop"])
        #expect(opened.map(\.1) == [[png]])
        #expect(!wheel.isOpen && wheel.model.isContentHidden)
        #expect(chosen.map(\.0) == ["convert.jpg"])
        wheel.close()

        wheel = try await failedWheel(clickMode: clickMode, chosen: { chosen.append(($0, $1)) },
                                      then: { handle { .succeeded } })
        defer { wheel.close() }
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))
        try click(wheel, at: point(ofSlice: "action.makeZip", in: wheel))
        #expect(chosen.map(\.0) == ["convert.jpg", "convert.jpg", "action.makeZip"])
        #expect(chosen.last?.1 == [png])
        // A file tool's job is its own pill's: the wheel closes at once, a click having no button-up to wait for.
        #expect(!wheel.isOpen)
    }

    /// A verdict that lands after a quick failure still applies to the live wheel: every file damaged greys the
    /// conversions, under the failure, which ranks above the damage line while nothing is hovered.
    @Test(arguments: [false, true])
    func aVerdictAfterAFailureGreysTheDamagedSlices(clickMode: Bool) async throws {
        let gate = ReadabilityGate()
        var chosen: [String] = []
        let wheel = try await failedWheel(clickMode: clickMode, readabilityCheck: { files, _ in
            gate.wait()
            return FileReadability.Report(damaged: files, allDamaged: true)
        }, chosen: { id, _ in chosen.append(id) })
        defer { wheel.close() }
        #expect(wheel.model.slices.first { $0.id == "convert.gif" }?.isEnabled == true)

        gate.open()
        try await waitUntil("the verdict") { !wheel.model.readability.damaged.isEmpty }
        let gif = try slice("convert.gif", in: wheel)
        #expect(!gif.isEnabled && gif.disabledReason == "The file may be damaged")
        #expect(wheel.model.alert == failureAlert)
        #expect(wheel.model.damageAlert != nil)
        try click(wheel, at: point(ofSlice: "convert.gif", in: wheel))
        #expect(chosen == ["convert.jpg"])
        #expect(wheel.isOpen && wheel.model.isFailed)
    }

    /// With only some files damaged, a retry after a late verdict runs on the readable ones.
    @Test(arguments: [false, true])
    func aRetryAfterALateVerdictSkipsTheDamagedFiles(clickMode: Bool) async throws {
        let bad = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-bad.png")
        let gate = ReadabilityGate()
        var chosen: [(String, [URL])] = []
        let wheel = try await failedWheel(clickMode: clickMode, files: [png, bad], readabilityCheck: { _, _ in
            gate.wait()
            return FileReadability.Report(damaged: [bad], allDamaged: false)
        }, chosen: { chosen.append(($0, $1)) })
        defer { wheel.close() }
        #expect(chosen.first?.1 == [png, bad])

        gate.open()
        try await waitUntil("the verdict") { !wheel.model.readability.damaged.isEmpty }
        try click(wheel, at: point(ofSlice: "convert.gif", in: wheel))
        #expect(chosen.map(\.0) == ["convert.jpg", "convert.gif"])
        #expect(chosen.last?.1 == [png])
    }

    /// Hovering a slice shows its usual preview in place of the red hub; back on the hub the failure shows again.
    @Test(arguments: [false, true])
    func afterAFailureHoveringASliceShowsItsPreview(clickMode: Bool) async throws {
        let wheel = try await failedWheel(clickMode: clickMode)
        defer { wheel.close() }
        let gif = try #require(wheel.model.slices.firstIndex { $0.id == "convert.gif" })

        try moveMouse(wheel, to: point(ofSlice: "convert.gif", in: wheel))
        #expect(wheel.model.hovered == gif)
        #expect(wheel.model.alert == nil)
        let builder = try #require(wheel.model.builder)
        #expect(wheel.model.preview == builder.preview(for: wheel.model.slices[gif], files: [png]))

        // A disabled slice previews its reason, as it does before a choice.
        try moveMouse(wheel, to: point(ofSlice: "convert.webp", in: wheel))
        let webp = try slice("convert.webp", in: wheel)
        #expect(wheel.model.alert == nil)
        #expect(webp.disabledReason != nil && wheel.model.preview.subtitle == webp.disabledReason)

        let bounds = wheel.panel.dropTarget.bounds
        try moveMouse(wheel, to: CGPoint(x: bounds.midX, y: bounds.midY))
        #expect(wheel.model.hovered == nil)
        #expect(wheel.model.alert == failureAlert)
    }

    /// A menu-bar app's wheel is often the only thing that happens after a login launch: a slice dimmed by "still
    /// getting ready" is asked again once the panel is up, and enabled in place when the engine is ready, with the
    /// hovered slice's hub reason gone. The open itself never waits for the re-check.
    @Test func aSliceWhoseEngineGetsReadyAfterTheOpenIsEnabledInPlace() async throws {
        let engine = ReadyLater()
        let registry = EngineRegistry(engines: [engine], priority: [engine.id])
        let gate = ReadabilityGate()
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, desktop: .offScreen, readabilityCheck: { _, _ in .clean },
                                    clock: clock.timerClock, recheckAvailability: {
                                        await Task.detached { gate.wait() }.value
                                        await registry.recheckVolatileEngines()
                                    })
        defer { wheel.close() }
        // As AppEnvironment plans the wheel over the registry.
        let plan: @MainActor @Sendable () async -> Void = {
            wheel.contentBuilder = WheelContentBuilder(
                formats: .builtIn, available: await registry.planner(), all: await registry.planner(includingMissing: true),
                installHints: await registry.installHints(), unsupportedReasons: await registry.unsupportedReasons(),
                tools: [])
        }
        await registry.setChangeHandler { Task { @MainActor in await plan() } }
        await plan()

        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        let index = try #require(wheel.model.slices.firstIndex { $0.id == "convert.jpg" })
        wheel.model.setHovered(index)
        // The hub shows the hovered slice's reason.
        func hubReason() -> String? { wheel.model.hovered.flatMap { wheel.model.slices[$0].disabledReason } }
        #expect(!wheel.model.slices[index].isEnabled)
        #expect(hubReason() == ReadyLater.notReady)

        engine.becomeReady()
        gate.open()
        try await waitUntil("the slice to be enabled") { wheel.model.slices[index].isEnabled }
        #expect(hubReason() == nil)
        #expect(wheel.model.hovered == index)
        #expect(wheel.isOpen && wheel.model.phase == .choosing)
    }

    private func builder(targets: [(String, Int)]) -> WheelContentBuilder {
        let planner = RoutePlanner(
            edges: targets.map { ConversionEdge(from: "png", to: FormatID($0.0), engineID: "x", cost: $0.1, flags: []) },
            enginePriority: ["x"])
        return WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:],
                                   order: [:], tools: [])
    }

    /// A rebuild can insert a slice before the hovered one (an engine finished installing): the hover follows the
    /// slice by id, and clears when the slice is gone, instead of naming whatever now sits at its old index.
    @Test func aRebuildKeepsTheHoveredSliceByIdAndClearsItWhenGone() async throws {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, desktop: .offScreen, readabilityCheck: { _, _ in .clean },
                                    clock: clock.timerClock)
        defer { wheel.close() }
        wheel.contentBuilder = builder(targets: [("jpg", 2), ("gif", 3)])
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        #expect(wheel.model.slices.map(\.id) == ["convert.jpg", "convert.gif"])
        wheel.model.setHovered(0)

        wheel.contentBuilder = builder(targets: [("bmp", 1), ("jpg", 2), ("gif", 3)])
        #expect(wheel.model.slices.map(\.id) == ["convert.bmp", "convert.jpg", "convert.gif"])
        #expect(wheel.model.hovered == 1)
        #expect(wheel.model.hovered.map { wheel.model.slices[$0].id } == "convert.jpg")

        wheel.contentBuilder = builder(targets: [("bmp", 1), ("gif", 3)])
        #expect(wheel.model.hovered == nil)
    }

    /// A report with nothing damaged still reaches the model, for the size estimate.
    @Test func aCleanReportsFactsReachTheModel() async throws {
        let facts = [png: SourceFacts(bytes: 20_000_000, pixelWidth: 4000, pixelHeight: 3000)]
        let wheel = makeWheel(DropFollowUp(), readabilityCheck: { _, _ in
            FileReadability.Report(damaged: [], allDamaged: false, facts: facts)
        })
        defer { wheel.close() }
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        try await waitUntil("the facts") { !wheel.model.readability.facts.isEmpty }
        #expect(wheel.model.alert == nil)
        #expect(wheel.model.slices.allSatisfy { $0.isEnabled })
    }

    /// A verdict started for wheel A never lands on wheel B, opened before it arrived.
    @Test func aLateVerdictForAnEarlierWheelIsDropped() async throws {
        let gate = ReadabilityGate()
        let first = URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-first.png")
        let wheel = makeWheel(DropFollowUp(), readabilityCheck: { files, _ in
            guard files == [first] else { return .clean }
            gate.wait()
            return FileReadability.Report(damaged: files, allDamaged: true)
        })
        defer { wheel.close() }
        wheel.open(files: [first], at: NSEvent.mouseLocation, clickMode: false)
        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)
        gate.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(wheel.model.readability == .clean)
        #expect(wheel.model.alert == nil)
        #expect(wheel.model.slices.allSatisfy { $0.isEnabled })
    }

    /// Closing the wheel stops its check between files: 50 slow files are not all read.
    @Test func closingTheWheelStopsItsReadabilityCheck() async throws {
        let gate = ReadabilityGate()
        let wheel = makeWheel(DropFollowUp(), readabilityCheck: { gate.slowCheck($0, isCancelled: $1) })
        let files = (0..<50).map { URL(fileURLWithPath: "/tmp/pomelo-follow-up-test-\($0).png") }
        wheel.open(files: files, at: NSEvent.mouseLocation, clickMode: false)
        try await waitUntil("the check to start") { gate.filesLooked > 0 }
        wheel.close()
        try await waitUntil("the check to stop") { gate.sawCancellation }
        let looked = gate.filesLooked
        #expect(looked < files.count)
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.filesLooked == looked)
        #expect(wheel.model.readability == .clean)
    }
}
