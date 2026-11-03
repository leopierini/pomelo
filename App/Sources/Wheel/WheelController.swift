// Opens, pages and closes the wheel. Opening is synchronous (the content builder is cached by AppEnvironment), so
// the wheel appears within a frame of the trigger tap; an `os_signpost` interval measures it. In click mode the
// keyboard drives the wheel through `WheelNavigator`, whose selection is the same highlight the mouse hover shows.
//
// The wheel is also where feedback lives (P23): its hub turns red for damaged files, found by a check that runs
// off the main thread once the wheel is up, and for a dropped job that fails while the wheel waits for it; a job's
// note shows in the accent colour. A job the wheel stops waiting for goes on in the progress pill (P25).
import AppKit
import PomeloUIModel
import os

/// How the wheel meets the real desktop. Tests use `.offScreen`, so a test run never covers the apps of whoever runs
/// it, swallows their clicks or takes their key focus, and the mouse monitors (which would see their real mouse) stay
/// off.
struct WheelDesktop {
    /// The frame the panel is clamped into, for the point it opens at; nil for the visible frame of the screen under
    /// the point.
    var visibleFrame: (@MainActor (CGPoint) -> CGRect)?
    var watchesMouse = true
    /// Whether a click-mode panel is made key (it still may become key).
    var takesKey = true

    static let live = WheelDesktop()
    /// Far outside every screen.
    static let offScreen = WheelDesktop(
        visibleFrame: { _ in CGRect(x: -30_000, y: -30_000, width: 1_000, height: 1_000) },
        watchesMouse: false, takesKey: false
    )
}

/// Drives the one reusable wheel panel.
@MainActor
final class WheelController {
    /// A drop (or click-mode click) on an enabled slice, with the panel's centre for the job's pill. Returns the
    /// job, whose outcome the wheel waits for briefly after a conversion or an engine tool (P23); nil when nothing
    /// runs.
    var onChoose: ((WheelSlice, [URL], CGPoint) -> JobHandle?)?
    /// A drop (or click-mode click) on an editor slice, with the files to edit and the panel's centre (P27): the
    /// editor opens there and the wheel closes; nothing runs yet.
    var onOpenEditor: ((WheelSlice, [URL], CGPoint) -> Void)?
    /// A drop (or click-mode click) on the Shelf slice, with the files and the panel's centre (S31): the Shelf
    /// takes them there and the wheel closes like a file tool's; no job runs.
    var onShelf: (([URL], CGPoint) -> Void)?
    /// Called once per followed job as the wheel lets go of it: true when the hub showed its outcome (it closed on
    /// a success, or showed a failure or note), false when the wheel stopped waiting first (P25).
    var onRelease: ((UUID, Bool) -> Void)?
    /// Builds the pages; nil until AppEnvironment has planned over the registry once. A new plan while the wheel is
    /// up and choosing (an engine got ready after it opened), or live again after a failure (P191), updates its
    /// slices in place.
    var contentBuilder: WheelContentBuilder? {
        didSet { replanOpenWheel() }
    }

    /// Internal so the tests can read the wheel's state.
    let model = WheelModel()
    private let settings: SettingsStore
    private let followUp: DropFollowUp
    /// Internal so the tests can click it.
    private(set) lazy var panel = makePanel()
    private var pendingClose: Task<Void, Never>?
    /// After a click closed the wheel (M3): orders out the hidden panel once a double-click interval has passed.
    private var pendingOrderOut: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// The readability check of the wheel on screen, run detached; cancelling it stops the check between files.
    private var readabilityTask: Task<Void, Never>?
    /// The re-check of engines whose availability changes at run time, run detached once the panel is up.
    private var availabilityTask: Task<Void, Never>?
    /// Click mode only: the keyboard's view of the pages, kept in step with the model's page and hover.
    private var navigator: WheelNavigator?
    /// The drop whose job the wheel is waiting for (or showing the failure or note of); nil otherwise.
    private var followedDrop: UUID?
    /// The followed job, until the wheel releases it.
    private var heldJob: UUID?
    /// Mouse monitors that close the wheel while it waits or shows an outcome: on a click elsewhere, or (an
    /// outcome) when the mouse moves well away.
    private var dismissMonitors: [Any] = []

    static let signposter = OSSignposter(subsystem: "io.github.pomelo-app.Pomelo", category: "wheel")
    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "wheel")
    /// How long the wheel stays up after the mouse button goes up when nothing was dropped on a conversion or an
    /// engine tool.
    nonisolated static let closeDelay: Duration = .milliseconds(350)

    /// Opens a URL (System Settings); a parameter so tests never open anything.
    private let openURL: (URL) -> Void
    private let desktop: WheelDesktop
    /// The readability check (P23); a parameter so tests can hold a verdict back.
    private let readabilityCheck: @Sendable ([URL], @Sendable () -> Bool) async -> FileReadability.Report
    /// Every stay and wait below runs on it; a parameter so tests step through them on a virtual clock.
    private let clock: TimerClock
    /// Asks the engines whose availability changes at run time again (the registry's re-check); a changed answer
    /// comes back as a new `contentBuilder`. A non-activating wheel is often the only sign of life a menu-bar app
    /// gets, so a dimmed "still getting ready" slice would otherwise never be asked again.
    private let recheckAvailability: @Sendable () async -> Void

    init(settings: SettingsStore, followUp: DropFollowUp = .standard,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }, desktop: WheelDesktop = .live,
         readabilityCheck: @escaping @Sendable ([URL], @Sendable () -> Bool) async -> FileReadability.Report = {
             await FileReadability.check($0, isCancelled: $1)
         }, clock: TimerClock = .live, recheckAvailability: @escaping @Sendable () async -> Void = {}) {
        self.settings = settings
        self.clock = clock
        self.recheckAvailability = recheckAvailability
        self.followUp = followUp
        self.openURL = openURL
        self.desktop = desktop
        self.readabilityCheck = readabilityCheck
        model.onHoverChange = { [weak self] index in self?.hoverChanged(to: index) }
        model.onActivatePrompt = { [weak self] in self?.activatePrompt() }
    }

    /// Creates the panel ahead of the first open, so that open only has to place and show it.
    func prepare() {
        // Laying out builds the SwiftUI graph now rather than on the first open.
        panel.dropTarget.layoutSubtreeIfNeeded()
    }

    /// False once a click has closed the wheel, while its hidden panel still takes clicks (M3).
    var isOpen: Bool { panel.isVisible && !model.isContentHidden }

    /// Shows the wheel for `files`, centred on `screenPoint` (AppKit screen coordinates) and clamped inside the
    /// visible frame of the screen under it. In click mode the panel becomes key and follows the mouse.
    func open(files: [URL], at screenPoint: CGPoint, clickMode: Bool) {
        let interval = Self.signposter.beginInterval("open")
        defer { Self.signposter.endInterval("open", interval) }

        guard let contentBuilder else {
            Self.log.error("wheel requested before the content builder was ready")
            return
        }
        // Nothing to show (no files): a wheel still up keeps its timer and monitors, so it closes as it would have.
        let pages = contentBuilder.pages(for: files)
        guard !pages.isEmpty else { return }
        pendingClose?.cancel()
        cancelPendingOrderOut()
        // Only when a previous wheel is still waiting for its job or showing its outcome.
        if followedDrop != nil { endFollowUp() }

        model.clickMode = clickMode
        model.trigger = settings.settings.trigger
        model.load(pages: pages, files: files, builder: contentBuilder, firstPage: settings.settings.firstPage)
        navigator = clickMode ? WheelNavigator(pages: pages, pageIndex: model.pageIndex, selected: nil) : nil
        loadThumbnail(for: files[0])
        show(at: screenPoint, clickMode: clickMode)
        checkReadability(of: files)
        recheckEngines()
    }

    /// Click mode when Pomelo may not control Finder (P23): the wheel opens at `screenPoint` with no slices and a
    /// red hub asking for the permission. Clicking the hub (or Return) opens the Automation pane and closes the
    /// wheel; Esc, a click outside or resigning key closes it.
    func showAutomationPrompt(at screenPoint: CGPoint) {
        pendingClose?.cancel()
        cancelPendingOrderOut()
        if followedDrop != nil { endFollowUp() }
        thumbnailTask?.cancel()
        readabilityTask?.cancel()
        readabilityTask = nil
        model.clickMode = true
        model.trigger = settings.settings.trigger
        model.load(prompt: .allowAutomation)
        navigator = WheelNavigator(pages: [])
        show(at: screenPoint, clickMode: true)
        announce(WheelAlert.allowAutomation.title)
    }

    /// Opens the Automation pane of System Settings and closes the prompt.
    func activatePrompt() {
        guard isOpen, model.prompt != nil else { return }
        openURL(FinderSelection.automationSettingsURL)
        close()
    }

    /// Advances to the next page, wrapping around and skipping pages without slices.
    func cyclePage() {
        guard isOpen, model.phase == .choosing, model.pages.count > 1 else { return }
        var index = model.pageIndex
        for _ in model.pages.indices {
            index = (index + 1) % model.pages.count
            if !model.pages[index].slices.isEmpty { break }
        }
        guard index != model.pageIndex else { return }
        model.setPage(index)
        announce(model.pages[index].title)
    }

    /// The mouse button went up: the wheel stays briefly (so a drop can land and be seen), then closes. After a drop
    /// on a conversion or an engine tool the wait for the job decides instead.
    func dragEnded() {
        guard isOpen, model.phase == .choosing else { return }
        pendingClose?.cancel()
        pendingClose = Task { [weak self, clock] in
            try? await clock.sleep(Self.closeDelay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Hides the wheel now. A job it was waiting for goes on in the progress pill.
    func close() {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil
        stop()
        if panel.isVisible { panel.orderOut(nil) }
        model.isContentHidden = false
    }

    /// M3: a click on the panel closed the wheel. Its content goes at once, but the panel stays in for a
    /// double-click interval, its 1% fill taking the second click of a double-click, which would otherwise land on
    /// (and open) the Finder item under the wheel. `open()` cancels the wait.
    func closeTakingClicks() {
        guard isOpen else { return }
        stop()
        model.isContentHidden = true
        pendingOrderOut = Task { [weak self, clock] in
            try? await clock.sleep(.seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self else { return }
            self.pendingOrderOut = nil
            self.panel.orderOut(nil)
            self.model.isContentHidden = false
        }
    }

    /// Shows the content again, for a wheel opening over a hidden panel.
    private func cancelPendingOrderOut() {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil
        model.isContentHidden = false
    }

    /// Everything closing does but ordering the panel out.
    private func stop() {
        pendingClose?.cancel()
        pendingClose = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        readabilityTask?.cancel()
        readabilityTask = nil
        endFollowUp()
        // Cleared first: ordering out resigns key, which in click mode would close again.
        model.clickMode = false
        panel.dropTarget.clickMode = false
        panel.allowsKey = false
        navigator = nil
        model.hover(at: nil)
    }

    /// A drop or click-mode activation on `slice`. Internal so the tests can drive it without a drag.
    func choose(_ slice: WheelSlice, files: [URL]) {
        // The navigator keeps the pages it was opened with, so the model, which a readability verdict may have
        // changed since, decides whether the slice is still enabled.
        guard model.isChoosable, model.slices.first(where: { $0.id == slice.id })?.isEnabled == true else { return }
        // A drag's wheel takes clicks once a failure has made it live again (P191): a choice then is a click.
        let wasClickMode = panel.dropTarget.clickMode
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        if case .editor = slice.kind {
            let toRun = model.files(toRun: slice, from: files)
            if wasClickMode {
                // M3: the emptied panel takes a double-click's second click, which would land in the editor opening
                // under it. First, so the editor taking key can't close the wheel outright.
                closeTakingClicks()
                onOpenEditor?(slice, toRun, center)
                return
            }
            onOpenEditor?(slice, toRun, center)
            // On the next turn, so a drop's performDragOperation returns (and Finder ends the drag) first.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.close() }
            }
            return
        }
        if case .action(.shelf) = slice.kind {
            // As for an editor (M3): the Shelf appears centred under the click (S7), so the emptied panel takes a
            // double-click's second click.
            if wasClickMode { closeTakingClicks() }
            onShelf?(model.files(toRun: slice, from: files), center)
            return
        }
        let job = onChoose?(slice, model.files(toRun: slice, from: files), center)
        if case .action = slice.kind {
            // A drag closes on its own after the button-up; a click has no button-up to wait for.
            if wasClickMode { close() }
            return
        }
        guard let job else {
            if wasClickMode { close() }
            return
        }
        follow(job, clickMode: wasClickMode)
    }

    // MARK: - Private

    /// Places the panel centred on `screenPoint`, clamped inside the visible frame of the screen under it, and shows
    /// it; in click mode it becomes key.
    private func show(at screenPoint: CGPoint, clickMode: Bool) {
        panel.allowsKey = clickMode
        panel.dropTarget.clickMode = clickMode
        let visibleFrame = desktop.visibleFrame?(screenPoint) ?? {
            let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
            return screen?.visibleFrame ?? CGRect(origin: .zero, size: WheelPanel.size)
        }()
        panel.setFrameOrigin(WheelGeometry.panelOrigin(cursor: screenPoint, panelSize: WheelPanel.size,
                                                       visibleFrame: visibleFrame))
        panel.orderFrontRegardless()
        if clickMode && desktop.takesKey {
            panel.makeKey()
            panel.makeFirstResponder(panel.dropTarget)
        }
    }

    private func makePanel() -> WheelPanel {
        let panel = WheelPanel(model: model)
        panel.dropTarget.onChoose = { [weak self] slice, files in self?.choose(slice, files: files) }
        panel.dropTarget.onDismiss = { [weak self] in self?.close() }
        panel.dropTarget.onClickClose = { [weak self] in self?.closeTakingClicks() }
        panel.dropTarget.onActivatePrompt = { [weak self] in self?.activatePrompt() }
        panel.dropTarget.onKey = { [weak self] key in self?.handle(key) }
        panel.onResignKey = { [weak self] in
            guard let self, self.model.clickMode else { return }
            self.close()
        }
        return panel
    }

    // MARK: Waiting for a dropped job (P23)

    /// Waits up to `resultWait` for `job`. Meanwhile, and while an outcome shows, a click elsewhere closes the
    /// wheel and reaches its app as usual; a click on the wheel itself goes to the panel and no further (it must not
    /// land on whatever lies under it, P23), which closes the wheel unless a failure made it live again (P191). A
    /// click-mode panel stays key, where Esc closes it too.
    private func follow(_ job: JobHandle, clickMode: Bool) {
        pendingClose?.cancel()
        let drop = UUID()
        followedDrop = drop
        heldJob = job.id
        model.beginWaiting()
        startDismissMonitors()
        let droppedAt = clock.now()
        Task { [weak self] in
            let outcome = await job.outcome.value
            self?.jobEnded(outcome, drop: drop, droppedAt: droppedAt, clickMode: clickMode)
        }
        pendingClose = Task { [weak self, followUp, clock] in
            try? await clock.sleep(followUp.resultWait)
            guard !Task.isCancelled, let self, self.followedDrop == drop, self.model.phase == .waiting else { return }
            // Still running: closing releases the job unshown, so the pill takes it over.
            self.close()
        }
    }

    /// Whichever comes first, this or the wait's end, releases the job: the outcome shows in the hub or in the
    /// pill, never in both and never in neither. A failure stays until dismissed, with the wheel live again (P191).
    private func jobEnded(_ outcome: JobOutcome, drop: UUID, droppedAt: ContinuousClock.Instant, clickMode: Bool) {
        guard followedDrop == drop else { return }
        guard model.phase == .waiting, isOpen else {
            releaseHeldJob(outcomeShown: false)
            return
        }
        pendingClose?.cancel()
        releaseHeldJob(outcomeShown: true)
        switch DropFollowUp.decision(for: outcome) {
        case .close:
            // As before a drag's wheel stays until 0.35 s after the drop; a click's closes at once.
            let deadline = droppedAt + (clickMode ? .zero : followUp.minimumStay)
            pendingClose = Task { [weak self, clock] in
                try? await clock.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                self?.close()
            }
            return
        case .showFailure(let alert):
            model.showFailure(alert)
            announce(alert.title)
            // The drop has ended, so a drag's wheel now hovers and chooses by mouse as click mode's does. Its panel
            // is never made key (it would take focus from Finder), so only the mouse dismisses it.
            panel.dropTarget.clickMode = true
        case .showNote(let alert):
            model.showNote(alert)
            announce(alert.title)
            pendingClose = Task { [weak self, clock, followUp] in
                try? await clock.sleep(followUp.noteStay)
                guard !Task.isCancelled else { return }
                self?.close()
            }
        }
    }

    private func releaseHeldJob(outcomeShown: Bool) {
        guard let id = heldJob else { return }
        heldJob = nil
        onRelease?(id, outcomeShown)
    }

    /// Global monitors see clicks and moves in other apps, local ones in Pomelo's own windows (the wheel's panel
    /// included). Mouse events only: no key monitors (so Esc closes only a click-mode wheel, whose panel is key).
    private func startDismissMonitors() {
        stopDismissMonitors()
        guard desktop.watchesMouse else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isMove = event.type == .mouseMoved
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.dismissEvent(isMove: isMove, at: location, center: center) }
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isMove = event.type == .mouseMoved
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.dismissEvent(isMove: isMove, at: location, center: center) }
            return event
        }) {
            dismissMonitors.append(local)
        }
    }

    /// A click elsewhere closes the wheel; one on the panel keeps it taking clicks (M3), unless a failure made the
    /// wheel live again, when the panel itself decides (P191). Moving well away closes only an outcome (while
    /// waiting, moving off is natural). Internal so the tests can drive it without the real mouse.
    func dismissEvent(isMove: Bool, at location: CGPoint, center: CGPoint) {
        if isMove {
            guard model.showsOutcome, DropFollowUp.movedWellAway(location, from: center) else { return }
            close()
        } else if panel.frame.contains(location) {
            if !model.isChoosable { closeTakingClicks() }
        } else {
            close()
        }
    }

    private func stopDismissMonitors() {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }

    /// Forgets the followed drop and stops watching the mouse for it; a job still unreleased goes to the pill.
    private func endFollowUp() {
        followedDrop = nil
        releaseHeldJob(outcomeShown: false)
        stopDismissMonitors()
    }

    // MARK: Keys, hover, checks

    /// Click mode: applies a key through the navigator and mirrors the outcome in the model, so a keyboard
    /// selection shows the same highlight and hub preview as a hover; activation takes the click path. While a
    /// choice is waited for or a note shows only Esc does anything (it closes the wheel); after a failure the keys
    /// work again (P191); a prompt takes Return (activate) and Esc. Internal so the tests can press keys.
    func handle(_ key: NavKey) {
        guard model.clickMode, var navigator else { return }
        guard model.isChoosable, model.prompt == nil else {
            if key == .escape { close() }
            if key == .enter, model.prompt != nil { activatePrompt() }
            return
        }
        let outcome = navigator.handle(key)
        self.navigator = navigator
        switch outcome {
        case .none:
            break
        case .moved:
            model.setHovered(navigator.selected)
            if let hovered = model.hovered {
                let slice = model.slices[hovered]
                announce(slice.disabledReason.map { "\(slice.title), dimmed. \($0)" } ?? slice.title)
            }
        case .pageChanged:
            // Re-hovers the slice under the mouse, if any, which hoverChanged hands back to the navigator.
            model.setPage(navigator.pageIndex)
            if let page = model.page { announce(page.title) }
        case .activate(let slice):
            choose(slice, files: model.files)
        case .dismiss:
            close()
        }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func hoverChanged(to index: Int?) {
        // The mouse takes over from the keys: the next arrow continues from the hovered slice.
        navigator?.select(index)
        guard index != nil, settings.settings.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Checks the files off the main thread (P23). It starts after the panel is on screen and the open never waits
    /// for it; closing or reopening the wheel cancels it, which stops it before the next file. The verdict (ready
    /// within milliseconds for images and documents, up to 2 s per video or audio file) is applied only to the wheel
    /// it was started for, and only while its slices can be chosen: before a choice, or after a failure (P191), where
    /// a verdict that lands late must still grey damaged slices and keep a retry off the damaged files.
    private func checkReadability(of files: [URL]) {
        readabilityTask?.cancel()
        let opening = model.openCount
        let check = readabilityCheck
        readabilityTask = Task.detached(priority: .userInitiated) { [weak self] in
            let report = await check(files, { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await self?.apply(report, opening: opening)
        }
    }

    /// After the panel is up, never before it (the 50 ms rule): the open never waits for it.
    private func recheckEngines() {
        availabilityTask?.cancel()
        let recheck = recheckAvailability
        availabilityTask = Task.detached(priority: .userInitiated) { await recheck() }
    }

    /// The open wheel's pages planned again over `contentBuilder`, keeping its page, hover and readability verdict.
    /// Only while it offers its slices (before a choice, or after a failure, P191): a wheel waiting for a job or
    /// showing a note stays as it is.
    private func replanOpenWheel() {
        guard let contentBuilder, !model.files.isEmpty, model.prompt == nil, model.isChoosable, isOpen else { return }
        let pages = contentBuilder.pages(for: model.files)
        guard !pages.isEmpty else { return }
        let selectedID = navigator.flatMap { old in old.selected.map { old.pages[old.pageIndex].slices[$0].id } }
        model.replan(pages: pages, builder: contentBuilder)
        if navigator != nil {
            let selected = selectedID.flatMap { id in model.slices.firstIndex { $0.id == id } }
            navigator = WheelNavigator(pages: model.pages, pageIndex: model.pageIndex, selected: selected)
        }
    }

    private func apply(_ report: FileReadability.Report, opening: Int) {
        guard model.openCount == opening, model.isChoosable, isOpen,
              !report.damaged.isEmpty || !report.facts.isEmpty else { return }
        model.apply(report)
        // The keyboard carries on over the new pages, where conversions may now be disabled.
        if let old = navigator {
            navigator = WheelNavigator(pages: model.pages, pageIndex: old.pageIndex, selected: old.selected)
        }
        // Announced even while an enabled slice is hovered (when the hub shows its preview instead), so VoiceOver
        // users hear that the damaged files will be skipped.
        if let damage = model.damageAlert { announce(damage.title) }
    }

    private func loadThumbnail(for url: URL) {
        thumbnailTask?.cancel()
        model.thumbnail = WheelThumbnail.placeholder(for: url)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnailTask = Task { [model] in
            guard let image = await WheelThumbnail.load(for: url, scale: scale),
                  !Task.isCancelled, model.files.first == url else { return }
            model.thumbnail = image
        }
    }
}
