import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

/// A visible frame far outside every screen, large enough to hold a stack away from its edges.
private let farAway = CGRect(x: -30_000, y: -30_000, width: 2_000, height: 2_000)

/// The progress pill (P25), driven through a real coordinator over the gated engine, on an off-screen desktop with
/// announcements recorded (P16).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProgressPillControllerTests {
    private final class Announcements {
        var texts: [String] = []
    }

    /// The coordinator's and the pill's timers (each test gets its own suite instance, so its own clock).
    private let clock = ManualClock()

    private func makePill(
        noteStay: Duration = PillTiming.noteStay, destinations: DestinationResolver = .nextToSource,
        desktop: PillDesktop = .offScreen
    ) -> (ProgressPillController, JobCoordinator, Gates, Announcements) {
        let gates = Gates()
        let coordinator = makeCoordinator(engines: [GatedEngine(gates: gates)], destinations: destinations,
                                          noteStay: noteStay, clock: clock.timerClock)
        let announcements = Announcements()
        let controller = ProgressPillController(jobs: coordinator, desktop: desktop,
                                                announce: { announcements.texts.append($0) })
        return (controller, coordinator, gates, announcements)
    }

    /// Once a sleep of exactly `duration` waits, moves the virtual clock on by it (the suite waits for no real
    /// timer). The coordinator's half-second Finder delays share the clock, hence the exact duration.
    private func pass(_ duration: Duration) async {
        #expect(await eventually { clock.isWaiting(for: duration) })
        await clock.advance(by: duration)
    }

    /// The show timer's sleep can be shorter than `showAfter` (a job started earlier), so its task is what is awaited.
    private func passTheShowDelay(_ pill: ProgressPillController, by duration: Duration = PillTiming.showAfter) async {
        #expect(await eventually { pill.isWaitingToShow })
        await clock.advance(by: duration)
    }

    private func passTheFade() async { await pass(.seconds(ProgressPillStack.fade)) }

    /// The panel and its SwiftUI host are built when a pill first shows, not at launch (14 ms of launch).
    @Test func thePanelIsBuiltOnlyWhenAPillFirstShows() async throws {
        let (dir, files) = try pngs("quick", "slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()
        #expect(!pill.isPanelLoaded)

        let quick = coordinator.perform(jpgSlice(), on: [files[0]], anchor: .zero, isHeld: false)
        #expect(await quick.outcome.value == .succeeded)
        #expect(!pill.isPanelLoaded)

        let slow = coordinator.perform(jpgSlice(), on: [files[1]], anchor: CGPoint(x: -29_000, y: -29_000),
                                       isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.isPanelLoaded })
        #expect(pill.panel.isVisible)
        await gates.open("slow")
        _ = await slow.outcome.value
    }

    @Test func aJobOverHalfASecondAppears() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: CGPoint(x: -29_000, y: -29_000),
                                      isHeld: false)
        #expect(pill.model.jobs.isEmpty)
        #expect(!pill.panel.isVisible)

        await passTheShowDelay(pill, by: .milliseconds(499))
        #expect(!pill.panel.isVisible)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { pill.panel.isVisible })
        #expect(pill.model.jobs.map(\.id) == [job.id])
        #expect(pill.panel.frame.width == PillLayout.width)
        #expect(pill.panel.frame.height == PillLayout.collapsedHeight)

        await gates.open("slow")
        #expect(await job.outcome.value == .succeeded)
        // A success leaves no pill.
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })
        #expect(pill.model.jobs.isEmpty)
        #expect(!pill.isWaitingToShow)
    }

    @Test func aQuickJobNeverAppears() async throws {
        let (dir, files) = try pngs("quick")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, _, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        #expect(await job.outcome.value == .succeeded)
        await clock.advance(by: .milliseconds(700))

        #expect(!pill.panel.isVisible)
        #expect(pill.model.jobs.isEmpty)
        #expect(pill.appearances == 0)
        // The wake-up scheduled while it ran is gone with it.
        #expect(!pill.isWaitingToShow)
    }

    @Test func aHeldJobStaysHiddenUntilTheWheelLetsGo() async throws {
        let (dir, files) = try pngs("slow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: true)
        await clock.advance(by: .milliseconds(700))
        #expect(!pill.panel.isVisible)

        coordinator.release(job.id, outcomeShown: false)
        // Older than half a second already: it shows at once.
        #expect(pill.panel.isVisible)
        await gates.open("slow")
        _ = await job.outcome.value
    }

    @Test func concurrentJobsStackOldestFirst() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill(desktop: PillDesktop(visibleFrame: { _ in farAway }))
        let first = CGPoint(x: -29_000, y: -29_000)

        let older = coordinator.perform(jpgSlice(), on: [files[0]], anchor: first, isHeld: false)
        await clock.advance(by: .milliseconds(100))
        let newer = coordinator.perform(jpgSlice(), on: [files[1]], anchor: CGPoint(x: -28_500, y: -28_700),
                                        isHeld: false)

        await passTheShowDelay(pill)
        #expect(await eventually { pill.model.jobs.count == 2 })
        #expect(pill.model.jobs.map(\.id) == [older.id, newer.id])
        // Anchored at the oldest job's anchor: its pill is centred there, the newer one below it.
        let frame = pill.panel.frame
        #expect(frame.midX == first.x)
        #expect(frame.maxY == first.y + PillLayout.collapsedHeight / 2)
        #expect(frame.height == 2 * PillLayout.collapsedHeight + PillLayout.spacing)

        await gates.open("slow-a")
        await gates.open("slow-b")
        _ = await older.outcome.value
        _ = await newer.outcome.value
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })
    }

    @Test func theAnchorResetsOnceTheStackIsEmpty() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill(desktop: PillDesktop(visibleFrame: { _ in farAway }))

        let one = coordinator.perform(jpgSlice(), on: [files[0]], anchor: CGPoint(x: -29_000, y: -29_000),
                                      isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.panel.isVisible })
        await gates.open("slow-a")
        _ = await one.outcome.value
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })

        let second = CGPoint(x: -28_500, y: -28_700)
        let two = coordinator.perform(jpgSlice(), on: [files[1]], anchor: second, isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.panel.isVisible })
        #expect(pill.panel.frame.midX == second.x)
        await gates.open("slow-b")
        _ = await two.outcome.value
    }

    @Test func theCrossCancelsTheJob() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.model.jobs.count == 1 })
        pill.model.actions.close(job.id)
        #expect(await eventually { coordinator.jobs.isEmpty })
        // Opened only so a broken cancel fails below instead of waiting forever: a cancelled file publishes nothing.
        await gates.open("slow-a")
        await gates.open("slow-b")

        #expect(await job.outcome.value == .succeeded)
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["slow-a.png", "slow-b.png"])
    }

    @Test func aRowsCrossCancelsThatFileAlone() async throws {
        let (dir, files) = try pngs("slow-a", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.model.jobs.first?.files.allSatisfy { $0.state != .waiting } == true })
        let collapsed = pill.panel.frame.height
        pill.model.actions.toggleFiles(job.id)
        #expect(pill.model.isExpanded(job.id))
        #expect(pill.panel.frame.height >= collapsed + 2 * PillLayout.rowHeight)

        pill.model.actions.cancelFile(job.id, 1)
        #expect(await eventually { pill.model.jobs.first?.files[1].state == .cancelled })
        #expect(pill.model.jobs.first?.files[0].state == .running(fraction: nil))
        await gates.open("slow-a")
        await gates.open("slow-b")
        #expect(await job.outcome.value == .succeeded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["slow-a.jpg", "slow-a.png", "slow-b.png"])
    }

    @Test func aFailedPillStaysUntilClosed() async throws {
        let (dir, files) = try pngs("slow-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, announcements) = makePill(noteStay: .milliseconds(100))

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.panel.isVisible })
        await gates.open("slow-fail")
        let summary = try #require(await job.outcome.value.summary)
        #expect(pill.model.jobs.first?.phase == .failed(summary))
        #expect(announcements.texts == ["Couldn't convert slow-fail.png. The file may be damaged"])

        // Well past a note's stay: a failure is not a note.
        await clock.advance(by: .milliseconds(400))
        #expect(pill.panel.isVisible)
        #expect(pill.model.jobs.map(\.id) == [job.id])

        pill.model.actions.close(job.id)
        #expect(coordinator.jobs.isEmpty)
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })
        #expect(announcements.texts.count == 1)
    }

    @Test func aNotedPillLeavesOnItsOwn() async throws {
        let (dir, files) = try pngs("a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appending(path: "Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let readOnly = DestinationResolver(downloadsFolder: downloads, isWritable: { _ in false })
        let (pill, coordinator, _, announcements) = makePill(noteStay: .milliseconds(300), destinations: readOnly)

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        let outcome = await job.outcome.value
        #expect(outcome == .noted(JobCoordinator.savedToDownloads))
        // A note is news whatever the job's age: it shows at once.
        #expect(pill.panel.isVisible)
        #expect(announcements.texts == ["Saved to Downloads"])

        await pass(.milliseconds(300))
        await passTheFade()
        #expect(await eventually { !pill.panel.isVisible })
        #expect(pill.model.jobs.isEmpty)
    }

    @Test func moreThanFiveJobsShowAMoreLine() async throws {
        let names = (1...7).map { "slow-\($0)" }
        let (dir, files) = try pngs(names[0], names[1], names[2], names[3], names[4], names[5], names[6])
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let handles = files.map { coordinator.perform(jpgSlice(), on: [$0], anchor: .zero, isHeld: false) }
        await passTheShowDelay(pill)
        #expect(await eventually { pill.model.jobs.count == PillLayout.maxVisibleJobs })
        #expect(pill.model.jobs.map(\.id) == handles.prefix(5).map(\.id))
        #expect(pill.model.moreText == "2 more jobs")

        await gates.open(names[0])
        #expect(await eventually { pill.model.moreText == "1 more job" })
        for name in names { await gates.open(name) }
        for handle in handles { _ = await handle.outcome.value }
        await passTheFade()
        #expect(await eventually { pill.model.moreText == nil && !pill.panel.isVisible })
    }

    @Test func thePanelNeverTakesKey() {
        let panel = ProgressPillPanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .statusBar)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isOpaque)
        // P22: the first click on a pill's button acts, though the panel is never key.
        #expect(panel.host.acceptsFirstMouse(for: nil))
    }

    /// P22: a click on a row's ✕ is the panel's first click, so the view it lands in must accept the first mouse,
    /// though the rows sit in a scroll view.
    @Test func everyButtonTakesTheFirstClick() async throws {
        let names = (1...8).map { "slow-\($0)" }
        let (dir, files) = try pngs(names[0], names[1], names[2], names[3], names[4], names[5], names[6], names[7])
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill()

        let job = coordinator.perform(jpgSlice(), on: files, anchor: .zero, isHeld: false)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.panel.isVisible })
        pill.model.actions.toggleFiles(job.id)
        let content = try #require(pill.panel.contentView)
        content.layoutSubtreeIfNeeded()
        let height = content.bounds.height
        #expect(height > PillLayout.collapsedHeight + 6 * PillLayout.rowHeight)
        // From the top: the header's ✕, then each visible row's ✕ (below the header and its 1 pt divider).
        let crossX = PillLayout.width - 12 - 10
        let fromTop = [PillLayout.collapsedHeight / 2]
            + (0..<PillLayout.maxVisibleRows).map { PillLayout.collapsedHeight + 1 + (CGFloat($0) + 0.5) * PillLayout.rowHeight }
        for y in fromTop {
            let hit = try #require(content.hitTest(NSPoint(x: crossX, y: height - y)))
            #expect(hit.acceptsFirstMouse(for: nil), "\(type(of: hit)) at \(y) pt from the top")
        }
        for name in names { await gates.open(name) }
        _ = await job.outcome.value
    }

    /// A new stack forming while the last, taller one fades out shows at its own anchor at once: the shrink that
    /// waits for a fade must not keep it at the old anchor.
    @Test func aNewStackDuringTheFadeStartsAtItsOwnAnchor() async throws {
        let (dir, files) = try pngs("slow-a", "slow-c", "slow-b")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pill, coordinator, gates, _) = makePill(desktop: PillDesktop(visibleFrame: { _ in farAway }))
        let first = CGPoint(x: -29_000, y: -29_000)
        let second = CGPoint(x: -28_500, y: -28_700)

        let one = coordinator.perform(jpgSlice(), on: [files[0]], anchor: first, isHeld: false)
        let other = coordinator.perform(jpgSlice(), on: [files[1]], anchor: first, isHeld: false)
        let two = coordinator.perform(jpgSlice(), on: [files[2]], anchor: second, isHeld: true)
        await passTheShowDelay(pill)
        #expect(await eventually { pill.model.jobs.count == 2 })
        #expect(pill.panel.frame.midX == first.x)
        await gates.open("slow-a")
        await gates.open("slow-c")
        _ = await one.outcome.value
        _ = await other.outcome.value
        // Fading out, still on screen.
        #expect(pill.model.jobs.isEmpty)
        #expect(pill.panel.isVisible)

        coordinator.release(two.id, outcomeShown: false)
        #expect(pill.panel.isVisible)
        #expect(pill.panel.frame.midX == second.x)
        #expect(pill.panel.frame.maxY == second.y + PillLayout.collapsedHeight / 2)
        await clock.advance(by: .milliseconds(400))
        #expect(pill.panel.isVisible)
        #expect(pill.panel.frame.midX == second.x)

        await gates.open("slow-b")
        _ = await two.outcome.value
    }
}

/// The pill's labels and VoiceOver strings (P32: no separator glyphs).
@MainActor
@Suite struct ProgressPillCopyTests {
    private func job(_ files: [PillFile], phase: PillPhase = .running) -> PillJob {
        PillJob(id: UUID(), verb: "Compressing", symbol: "rectangle.compress.vertical", files: files,
                isCombined: false, anchor: .zero, startedAt: .now, isHeld: false, phase: phase)
    }

    @Test func aRunningPillReadsItsVerbDetailAndPercentage() {
        let pill = job([PillFile(id: 0, name: "long-video.mov", state: .running(fraction: 0.16))])
        #expect(ProgressPillText.title(of: pill) == "Compressing")
        #expect(ProgressPillText.accessibilityLabel(of: pill) == "Compressing, long-video.mov")
        #expect(ProgressPillText.accessibilityValue(of: pill) == "16%")
        #expect(ProgressPillText.closeLabel(of: pill) == "Cancel Compressing")
    }

    @Test func aFailedPillReadsItsSummaryAndCloses() {
        let summary = ResultSummary(title: "Couldn't compress a.mov", detail: "The file may be damaged",
                                    isFailure: true)
        let pill = job([PillFile(id: 0, name: "a.mov", state: .failed(reason: "The file may be damaged"))],
                       phase: .failed(summary))
        #expect(ProgressPillText.title(of: pill) == "Couldn't compress a.mov")
        #expect(ProgressPillText.accessibilityLabel(of: pill) == "Couldn't compress a.mov, The file may be damaged")
        #expect(ProgressPillText.accessibilityValue(of: pill) == nil)
        #expect(ProgressPillText.closeLabel(of: pill) == "Close")
        #expect(ProgressPillText.announcement(for: pill) == "Couldn't compress a.mov. The file may be damaged")
    }

    @Test func aNoteAnnouncesItsTitle() {
        let pill = job([PillFile(id: 0, name: "a.png", state: .done)],
                       phase: .noted(ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")))
        #expect(ProgressPillText.announcement(for: pill) == "Saved to Downloads")
        #expect(ProgressPillText.announcement(for: job([PillFile(id: 0, name: "a.png", state: .waiting)])) == nil)
    }

    @Test func theMoreLineCountsTheHiddenJobs() {
        #expect(ProgressPillText.more(hidden: 0) == nil)
        #expect(ProgressPillText.more(hidden: 1) == "1 more job")
        #expect(ProgressPillText.more(hidden: 2) == "2 more jobs")
    }
}

