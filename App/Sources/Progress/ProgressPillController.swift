// Shows `JobCoordinator.jobs` as the progress pill (P25): a job appears once it has run `PillTiming.showAfter` (and
// nothing holds it), the stack sits at the oldest visible job's drop point, and the panel leaves once
// the last pill has faded. The coordinator decides when a job leaves the list (a success at once, a note after
// `PillTiming.noteStay`, a failure when closed); the pill is independent of the wheel, which never moves for it.
import AppKit
import Combine
import PomeloUIModel
import SwiftUI

/// Where the pill panel may go.
struct PillDesktop {
    /// The frame the stack is kept inside, for its anchor; nil for the visible frame of the screen under the anchor.
    var visibleFrame: (@MainActor (CGPoint) -> CGRect)?

    static let live = PillDesktop()
    /// Far outside every screen.
    static let offScreen = PillDesktop(visibleFrame: { _ in CGRect(x: -30_000, y: -30_000, width: 1_000, height: 1_000) })
}

/// The jobs the stack shows and what its buttons do.
@MainActor
final class ProgressPillModel {
    /// The visible jobs, oldest first, at most `PillLayout.maxVisibleJobs`.
    private(set) var jobs: [PillJob] = []
    /// "2 more jobs" for the visible jobs past the stack's.
    private(set) var moreText: String?
    private(set) var expanded: Set<UUID> = []
    /// Called when a change made here (expanding a pill) needs the stack redrawn.
    var onChange: (() -> Void)?

    private let coordinator: JobCoordinator

    init(coordinator: JobCoordinator) {
        self.coordinator = coordinator
    }

    func update(visible: [PillJob]) {
        jobs = Array(visible.prefix(PillLayout.maxVisibleJobs))
        moreText = ProgressPillText.more(hidden: visible.count - jobs.count)
        expanded.formIntersection(jobs.filter(\.canExpand).map(\.id))
    }

    /// The ✕: a running job is cancelled, an ended one (red, or a note) closed.
    func close(_ id: UUID) {
        if jobs.first(where: { $0.id == id })?.phase == .running {
            coordinator.cancel(job: id)
        } else {
            coordinator.dismiss(job: id)
        }
    }

    func cancel(file index: Int, of id: UUID) {
        coordinator.cancel(job: id, file: index)
    }

    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }

    func toggleExpanded(_ id: UUID) {
        guard jobs.contains(where: { $0.id == id && $0.canExpand }) else { return }
        if expanded.remove(id) == nil { expanded.insert(id) }
        onChange?()
    }

    var actions: ProgressPillActions {
        ProgressPillActions(
            close: { [weak self] in self?.close($0) },
            toggleFiles: { [weak self] in self?.toggleExpanded($0) },
            cancelFile: { [weak self] id, index in self?.cancel(file: index, of: id) }
        )
    }
}

@MainActor
final class ProgressPillController {
    /// Internal so the tests can press the buttons and read what shows.
    let model: ProgressPillModel
    /// Internal so the tests can check what is on screen. Built when the first pill shows: built at launch, its
    /// SwiftUI host was 14 of `main`'s 62 profiled ms, for a pill most launches never show.
    var panel: ProgressPillPanel {
        if let loadedPanel { return loadedPanel }
        let panel = ProgressPillPanel()
        loadedPanel = panel
        return panel
    }
    var isPanelLoaded: Bool { loadedPanel != nil }
    private var loadedPanel: ProgressPillPanel?
    /// How many times the panel came on screen; for the tests.
    private(set) var appearances = 0
    /// True while a job is waiting out `PillTiming.showAfter`; nothing is scheduled otherwise.
    var isWaitingToShow: Bool { showTask != nil }

    private let desktop: PillDesktop
    /// The coordinator's: a job's start time and the show timer are compared.
    private let clock: TimerClock
    private let announce: @MainActor (String) -> Void
    private var subscription: AnyCancellable?
    /// The coordinator's latest list, which `@Published` hands over before storing it.
    private var latest: [PillJob] = []
    /// Wakes once, when the next young job is old enough to show.
    private var showTask: Task<Void, Never>?
    /// Orders the panel out once the last pill has faded.
    private var hideTask: Task<Void, Never>?
    /// Shrinks the panel once a leaving pill has faded, so its fade is never cut off.
    private var shrinkTask: Task<Void, Never>?
    /// The oldest visible job's anchor when the stack formed; kept until the stack is empty.
    private var anchor: CGPoint?
    private var lastLayout: [Int]?
    private var generation = 0
    private var announced: Set<UUID> = []

    init(jobs: JobCoordinator, desktop: PillDesktop = .live,
         announce: @escaping @MainActor (String) -> Void = ProgressPillController.announceToVoiceOver) {
        model = ProgressPillModel(coordinator: jobs)
        self.desktop = desktop
        self.announce = announce
        self.clock = jobs.clock
        model.onChange = { [weak self] in self?.render() }
        subscription = jobs.$jobs.sink { [weak self] jobs in
            MainActor.assumeIsolated { self?.update(jobs) }
        }
    }

    // MARK: - Private

    private func update(_ jobs: [PillJob]) {
        latest = jobs
        let now = clock.now()
        let visible = jobs.filter { PillTiming.isVisible($0, now: now) }
        scheduleShow(of: jobs, now: now)
        announceOutcomes(of: visible, listed: jobs)
        model.update(visible: visible)
        render()
    }

    /// One wake-up, when the next waiting job comes of age; none while nothing waits (idle CPU stays flat).
    private func scheduleShow(of jobs: [PillJob], now: ContinuousClock.Instant) {
        showTask?.cancel()
        showTask = nil
        let due = jobs
            .filter { !$0.isHeld && $0.phase == .running && !PillTiming.isVisible($0, now: now) }
            .map { $0.startedAt + PillTiming.showAfter }
            .min()
        guard let due else { return }
        showTask = Task { [weak self, clock] in
            try? await clock.sleep(until: due)
            guard !Task.isCancelled, let self else { return }
            self.showTask = nil
            self.update(self.latest)
        }
    }

    private func announceOutcomes(of visible: [PillJob], listed: [PillJob]) {
        announced.formIntersection(listed.map(\.id))
        for job in visible where !announced.contains(job.id) {
            guard let text = ProgressPillText.announcement(for: job) else { continue }
            announced.insert(job.id)
            announce(text)
        }
    }

    private func render() {
        guard isPanelLoaded || !model.jobs.isEmpty else { return }
        if let first = model.jobs.first, anchor == nil {
            anchor = first.anchor
            if panel.isVisible {
                // The last stack is still fading out at its own anchor: it goes at once, so the new one never
                // shows there and jumps.
                generation += 1
                hideTask?.cancel()
                hideTask = nil
                panel.orderOut(nil)
            }
        }
        panel.host.rootView = ProgressPillStack(jobs: model.jobs, expanded: model.expanded, moreText: model.moreText,
                                                actions: model.actions, generation: generation)
        guard !model.jobs.isEmpty else {
            anchor = nil
            lastLayout = nil
            hideAfterFade()
            return
        }
        hideTask?.cancel()
        hideTask = nil
        let layout = model.jobs.map { model.isExpanded($0.id) ? min($0.files.count, PillLayout.maxVisibleRows) : 0 }
            + [model.moreText == nil ? 0 : 1]
        if layout != lastLayout || !panel.isVisible {
            lastLayout = layout
            place()
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            appearances += 1
        }
    }

    /// Sizes the panel to the stack and keeps it on the anchor's screen. A smaller stack waits for its fade.
    private func place() {
        guard let anchor else { return }
        panel.host.layoutSubtreeIfNeeded()
        let size = panel.host.fittingSize
        let visibleFrame = desktop.visibleFrame?(anchor) ?? Self.screenFrame(containing: anchor)
        let frame = PillLayout.frame(contentSize: size, anchor: anchor, visibleFrame: visibleFrame)
        shrinkTask?.cancel()
        shrinkTask = nil
        guard panel.isVisible, frame.height < panel.frame.height else {
            panel.setFrame(frame, display: true)
            return
        }
        shrinkTask = Task { [weak self, clock] in
            try? await clock.sleep(.seconds(ProgressPillStack.fade))
            guard !Task.isCancelled, let self else { return }
            self.shrinkTask = nil
            self.panel.setFrame(frame, display: true)
        }
    }

    private func hideAfterFade() {
        shrinkTask?.cancel()
        shrinkTask = nil
        guard panel.isVisible, hideTask == nil else { return }
        hideTask = Task { [weak self, clock] in
            try? await clock.sleep(.seconds(ProgressPillStack.fade))
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            self.panel.orderOut(nil)
        }
    }

    private static func screenFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: point.x - 720, y: point.y - 450, width: 1440, height: 900)
    }

    static func announceToVoiceOver(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
