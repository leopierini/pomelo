import AppKit
import Combine
import Foundation
import PomeloCore
import PomeloEngines
import PomeloUIModel
import os

/// The app's shared services, created once at launch.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// The built-in engines plus the bundled and user plugin manifests.
    let registry: EngineRegistry
    /// The one installer: it serializes installs per instance, so a second one would not know of a cancel still
    /// unwinding (P132).
    let installer: EngineInstaller
    /// The engines Pomelo can download for this Mac.
    let installable: Set<EngineID>
    let settingsStore: SettingsStore
    let dragMonitor = DragMonitor()
    let wheel: WheelController
    /// Runs the chosen slice. The wheel shows an outcome while it is up (P23); `jobs` is the progress pill's model
    /// (P25).
    let jobs: JobCoordinator
    /// Shows `jobs` near the drop point once a job has run half a second (P25).
    let pill: ProgressPillController
    /// The editor a drop on an editor slice opens at the drop point (P27); it holds its job as the wheel does.
    let editors: EditorController
    /// The click-mode wheel, opened without a drag: by the ⌥⌘K hotkey, the Services menu entry, and files Pomelo is
    /// asked to open (the Quick Action, `open -a Pomelo`, a drop on its icon).
    let clickMode: ClickModeController
    /// The welcome window: shown on first launch and from the menu's "Show Welcome".
    let onboarding: OnboardingController
    /// Opens Settings on a pane: the menu's Settings… item and the welcome's Open Settings.
    let settingsNavigation = SettingsNavigation()
    /// The Shelf: holds file references for a moment (S3), prepared at the first mouse-down (S24).
    let shelf: ShelfController
    /// What Shortcuts runs (App Intents), through `jobs`' unattended path (P106).
    let intents: IntentRunner
    /// Settings › Watch Folders, run through `jobs`' unattended path (P106).
    let watchFolders: WatchFolderManager
    /// What the Engines pane shows, an install's progress included: held here so it outlives the Settings window,
    /// whose content SwiftUI may make again (P133). Made the first time Settings asks for it.
    var engines: EnginesModel {
        if let madeEngines { return madeEngines }
        let made = EnginesModel(environment: self)
        madeEngines = made
        return made
    }
    private var madeEngines: EnginesModel?

    /// True while a job or an engine install runs: quitting then waits for `stopAllWork`.
    var hasRunningWork: Bool { jobs.hasRunningWork || madeEngines?.isInstalling == true }

    /// Cancels every job and install and waits for them together, at most `JobCoordinator.quitWait` (P24).
    func stopAllWork() async {
        let deadline = ContinuousClock.now + JobCoordinator.quitWait
        let engines = madeEngines
        async let installsStopped: Void? = engines?.cancelInstalls(waitingUntil: deadline)
        await jobs.cancelAll(waitingAtMost: deadline - .now)
        _ = await installsStopped
    }

    /// The wheel's content, planned over the registry. Cached so opening the wheel never waits on the registry
    /// actor; rebuilt by `refreshEngines()`, when a setting it shows changes and when an engine's availability does.
    /// Published for Settings › Wheel, which draws over the same plans.
    @Published private(set) var contentBuilder: WheelContentBuilder? {
        didSet {
            wheel.contentBuilder = contentBuilder
            jobs.contentBuilder = contentBuilder
        }
    }

    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    private var isStarted = false
    private var appliedSettings: AppSettings
    private var settingsObserver: AnyCancellable?
    /// Bumped by each rebuild, so a slow older rebuild never overwrites a newer one.
    private var buildGeneration = 0
    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "launch")

    /// Which defaults a launch gets. Only a user's launch reads and writes the real domain: anything written there
    /// by a test or a snapshot would create a `settings.v1` and silently cancel the migration (P95, P100).
    enum LaunchDefaults: Equatable {
        /// `.standard`, after copying the pre-rename settings when it has none (P95).
        case user
        /// In memory, with the evals' quiet settings (P29).
        case evals
        /// In memory, with default settings: the app tests' host, the DEBUG snapshots and the drag recorder.
        case ephemeral
    }

    static func launchDefaults(
        arguments: [String], isRunningTests: Bool, bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> LaunchDefaults {
        let flags = arguments.dropFirst()
        if flags.contains(where: { $0.hasPrefix("--eval-") }) { return .evals }
        if isRunningTests || flags.contains(where: { $0.hasPrefix("--snapshot-") }) { return .ephemeral }
        #if DEBUG
        // The drag recorder exists only in DEBUG: a Release launch with its flag is a user's. Its bundle gets no
        // defaults of its own even when the system launches it without the flag (S34.1).
        if RecorderCopy.isActive(arguments: arguments, bundleIdentifier: bundleIdentifier) { return .ephemeral }
        #endif
        return .user
    }

    /// Only a user's launch asks for `.user`: it copies the pre-rename settings into the real domain (P95). A snapshot
    /// or the wheel-open measurement may name a settings file in `arguments`, whose wheels are loaded here: the wheel
    /// is planned over the settings `start()` applies, so writing the store later would change nothing.
    static func defaults(for kind: LaunchDefaults, arguments: [String]) -> UserDefaults {
        switch kind {
        case .evals:
            #if DEBUG || POMELO_EVALS
            return EvalHooks.ephemeralDefaults(arguments: arguments)
            #else
            return EphemeralDefaults()
            #endif
        case .ephemeral:
            #if DEBUG
            return EvalHooks.inMemoryDefaults(nil, arguments: arguments)
            #else
            return EphemeralDefaults()
            #endif
        case .user:
            if let legacy = UserDefaults(suiteName: SettingsMigration.legacyDomain) {
                SettingsMigration.copyLegacySettings(into: .standard, from: legacy)
            }
            return .standard
        }
    }

    /// The DEBUG PomeloTrace copy: its intents and opened files do nothing (S34.1). Never true in Release.
    static var runsAsRecorderCopy: Bool {
        #if DEBUG
        RecorderCopy.isActive
        #else
        false
        #endif
    }

    private init() {
        registry = DefaultEngines.makeRegistry()
        installer = EngineInstaller(
            enginesFolder: DefaultEngines.enginesFolder, downloader: URLSessionDownloader(),
            trashItem: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
        installable = PinnedDownloads.installable(on: .current)
        let arguments = CommandLine.arguments
        settingsStore = SettingsStore(
            defaults: Self.defaults(for: Self.launchDefaults(arguments: arguments, isRunningTests: Self.isRunningTests),
                                    arguments: arguments)
        )
        appliedSettings = settingsStore.settings
        let registry = registry
        wheel = WheelController(settings: settingsStore, recheckAvailability: { await registry.recheckVolatileEngines() })
        let jobs = JobCoordinator(
            registry: registry, settings: settingsStore, pasteboard: .general,
            playSound: { NSSound(named: $0)?.play() }, progressPublisher: FinderProgressPublisher(),
            trashItem: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
        self.jobs = jobs
        pill = ProgressPillController(jobs: jobs)
        editors = EditorController(
            settings: settingsStore,
            perform: { jobs.perform(preset: $0, on: $1, anchor: $2, isHeld: true, onResult: $3) },
            release: { jobs.release($0, outcomeShown: $1) }
        )
        clickMode = ClickModeController(wheel: wheel)
        onboarding = OnboardingController(settings: settingsStore, settingsNavigation: settingsNavigation)
        shelf = ShelfController(announce: { ProgressPillController.announceToVoiceOver($0) })
        // Made here, not in `start()`: an intent can be what launched the app, and the runner asks the registry,
        // never the wheel's content, so it works before the wheel is planned.
        intents = IntentRunner(
            registry: registry, settings: settingsStore, run: { await jobs.runUnattended($0, verb: $1) },
            workFolder: FileManager.default.temporaryDirectory
                .appending(path: "Pomelo Intents", directoryHint: .isDirectory),
            refusesWork: Self.runsAsRecorderCopy
        )
        watchFolders = WatchFolderManager(
            settings: settingsStore, registry: registry, run: { await jobs.runUnattended($0, verb: $1) }
        )
        onboarding.wheelContent = { [weak self] in self?.contentBuilder }
        #if DEBUG
        let bundled = DefaultEngines.bundledPluginsFolder
        let loaded = DefaultEngines.loadPlugins()
        Self.log.debug(
            "bundled plugins folder \(bundled.path, privacy: .public) exists=\(FileManager.default.fileExists(atPath: bundled.path), privacy: .public) loaded \(loaded.manifests.count, privacy: .public) plugin manifests, \(loaded.failures.count, privacy: .public) failures"
        )
        #endif
    }

    /// Starts the drag monitor, the wheel and click mode. Called once from the app's init; the service is provided
    /// at once (a service request may be what launched the app), the rest runs on the next turn of the main run
    /// loop, once the application has finished launching.
    func start() {
        guard !isStarted else { return }
        // The app tests run inside the app: a live drag monitor there would only make them flaky.
        guard !Self.isRunningTests else { return }
        isStarted = true
        Self.connect(wheel: wheel, jobs: jobs, shelf: shelf, clickMode: clickMode) { [weak self] in
            self?.openEditor($0, on: $1, at: $2, onResult: $3)
        }
        dragMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            Self.route(event, wheel: self.wheel, shelf: self.shelf)
        }
        // S24: a cold prepare is 20 to 25 ms of main thread (about 10 at launch), so it waits for the first
        // mouse-down, which comes well before a shake can (the shake arms 0.3 s after files are seen). On the next
        // turn, so the drag monitor's poll starts first.
        dragMonitor.onMouseDown = { [weak self] in
            self?.dragMonitor.onMouseDown = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.shelf.prepare() } }
        }
        settingsObserver = settingsStore.$settings.dropFirst().sink { [weak self] settings in
            MainActor.assumeIsolated { self?.settingsChanged(to: settings) }
        }
        clickMode.start(hotkeyEnabled: settingsStore.settings.clickModeHotkeyEnabled)
        watchFolders.start()
        if !settingsStore.settings.hasCompletedOnboarding {
            // On the next turn, once the application has finished launching, so the window can come to the front.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onboarding.show() }
            }
        }
        observeEngineChanges()
        Task {
            await rebuildWheelContent()
            wheel.prepare()
            dragMonitor.start(trigger: settingsStore.settings.trigger, shake: settingsStore.settings.shelfShake)
            clickMode.contentBecameReady()
        }
    }

    /// Re-queries engine availability and rebuilds the wheel's content from it.
    func refreshEngines() async {
        await registry.refresh()
        await rebuildWheelContent()
    }

    /// An engine whose availability changes at run time (Apple Intelligence getting ready after a login launch) is
    /// asked again when the app becomes active, after the wheel's panel is up (`WheelController`) and before each job
    /// (`JobRunner`), never inside `WheelController.open` and never on a timer; a changed answer plans the wheel again.
    private func observeEngineChanges() {
        let registry = registry
        let replan: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.rebuildWheelContent() }
        }
        Task { await registry.setChangeHandler(replan) }
        // For the app's lifetime, like the environment itself: never removed.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { await registry.recheckVolatileEngines() }
        }
    }

    /// Plans the wheel's content over the registry's current availability and the user's settings.
    func rebuildWheelContent() async {
        buildGeneration += 1
        let generation = buildGeneration
        let available = await registry.planner()
        let all = await registry.planner(includingMissing: true)
        let hints = await registry.installHints()
        let unsupported = await registry.unsupportedReasons()
        guard generation == buildGeneration else { return }
        contentBuilder = Self.makeContentBuilder(
            settings: appliedSettings, available: available, all: all, installHints: hints,
            unsupportedReasons: unsupported, installable: installable
        )
    }

    /// The wheel's content over the registry's plans and the user's order, tools and customized wheels.
    nonisolated static func makeContentBuilder(
        settings: AppSettings, available: RoutePlanner, all: RoutePlanner, installHints: [EngineID: String],
        unsupportedReasons: [EngineID: String], installable: Set<EngineID>
    ) -> WheelContentBuilder {
        WheelContentBuilder(
            formats: .builtIn, available: available, all: all, installHints: installHints,
            unsupportedReasons: unsupportedReasons, installable: installable,
            order: wheelOrder(from: settings.wheelOrder), tools: ToolCatalog.presets(settings: settings),
            visibility: ToolVisibility(overrides: settings.toolVisibility), replacesOriginals: settings.replaceOriginal,
            wheels: settings.wheels
        )
    }

    /// The defaults, with each category the user has ordered replaced by their order. An empty list means the
    /// default for that category.
    nonisolated static func wheelOrder(from stored: [String: [String]]) -> [FormatCategory: [FormatID]] {
        var order = WheelContentBuilder.defaultOrder
        for (key, ids) in stored where !ids.isEmpty {
            guard let category = FormatCategory(rawValue: key) else { continue }
            order[category] = ids.map { FormatID($0) }
        }
        return order
    }

    // MARK: - Private

    private func openEditor(
        _ slice: WheelSlice, on files: [URL], at center: CGPoint, onResult: (@MainActor (FileResult) -> Void)?
    ) {
        guard let request = Self.editorRequest(for: slice, on: files, at: center, content: contentBuilder,
                                               onResult: onResult) else {
            Self.log.error("cannot open an editor for \(slice.id, privacy: .public)")
            return
        }
        editors.open(request)
    }

    /// What an editor slice opens on `files`. Internal so the tests open an editor exactly as the wheel does.
    static func editorRequest(
        for slice: WheelSlice, on files: [URL], at center: CGPoint, content: WheelContentBuilder?,
        onResult: (@MainActor (FileResult) -> Void)? = nil
    ) -> EditorRequest? {
        guard case .editor(let id) = slice.kind, !files.isEmpty, let preset = content?.tool(id: id),
              let kind = ToolCatalog.info(id)?.editor else { return nil }
        return EditorRequest(kind: kind, preset: preset, files: files, anchor: center, flags: slice.flags,
                             onResult: onResult)
    }

    /// How the wheel's choices reach the jobs, the editors and the Shelf, and how the Shelf and click mode open the
    /// wheel. Internal so the tests wire their own controllers exactly as the app does. A wheel the Shelf opened (S37)
    /// hands its jobs and its editor the Shelf's result callback, so outputs take their sources' places (S18).
    static func connect(
        wheel: WheelController, jobs: JobCoordinator, shelf: ShelfController, clickMode: ClickModeController,
        openEditor: @escaping @MainActor (WheelSlice, [URL], CGPoint, (@MainActor (FileResult) -> Void)?) -> Void
    ) {
        wheel.onChoose = { [weak jobs, weak shelf] slice, files, center in
            #if DEBUG
            Self.log.debug("chose \(slice.id, privacy: .public) for \(files.count, privacy: .public) files")
            #endif
            // The wheel waits for a conversion or a tool (P23); a file tool's pill is its own from the start (P25).
            let isHeld = if case .action = slice.kind { false } else { true }
            shelf?.wheelChose()
            return jobs?.perform(slice, on: files, anchor: center, isHeld: isHeld, onResult: shelf?.wheelResults)
        }
        wheel.onRelease = { [weak jobs] id, outcomeShown in jobs?.release(id, outcomeShown: outcomeShown) }
        wheel.onOpenEditor = { [weak shelf] slice, files, center in
            shelf?.wheelChose()
            openEditor(slice, files, center, shelf?.wheelResults)
        }
        wheel.onShelf = { [weak shelf] files, center in shelf?.wheelChoseShelfSlice(files, at: center) }
        shelf.onOpenWheel = { [weak wheel] files, point in wheel?.open(files: files, at: point, clickMode: true) }
        clickMode.shelfTakesHotkey = { [weak shelf] in shelf?.takesClickModeHotkey() ?? false }
        clickMode.willOpenWheel = { [weak shelf] in shelf?.clickModeWheelOpened() }
    }

    /// Where the drag monitor's events go. Internal so the tests route them to their own controllers.
    static func route(_ event: DragSessionEvent, wheel: WheelController, shelf: ShelfController) {
        switch event {
        case .openWheel(let files, let point):
            shelf.wheelOpened(on: files)
            wheel.open(files: files, at: point, clickMode: false)
        case .cyclePage:
            wheel.cyclePage()
        case .showShelf(let point):
            shelf.summon(.shake(at: point))
        case .dragEnded:
            wheel.dragEnded()
            shelf.dragEnded()
        }
    }

    nonisolated static func restartsDragMonitor(from old: AppSettings, to new: AppSettings) -> Bool {
        old.trigger != new.trigger || old.shelfShake != new.shelfShake
    }

    /// `@Published` emits before the value is stored, so this compares against the settings last applied.
    private func settingsChanged(to settings: AppSettings) {
        let previous = appliedSettings
        appliedSettings = settings
        if Self.restartsDragMonitor(from: previous, to: settings) {
            dragMonitor.start(trigger: settings.trigger, shake: settings.shelfShake)
        }
        if settings.clickModeHotkeyEnabled != previous.clickModeHotkeyEnabled {
            clickMode.setHotkeyEnabled(settings.clickModeHotkeyEnabled)
        }
        if settings.watchFolders != previous.watchFolders {
            // On the next turn: the store holds the new value only once this sink returns.
            Task { watchFolders.reconcile() }
        }
        if Self.changesWheelContent(from: previous, to: settings) {
            Task { await rebuildWheelContent() }
        }
    }

    /// Whether the wheel's content depends on a setting that differs: the order, the tools, replace-original and the
    /// customized wheels.
    nonisolated static func changesWheelContent(from old: AppSettings, to new: AppSettings) -> Bool {
        old.wheelOrder != new.wheelOrder || old.toolVisibility != new.toolVisibility
            || old.toolOptions != new.toolOptions || old.replaceOriginal != new.replaceOriginal
            || old.wheels != new.wheels
    }
}
