// What the Engines pane shows: the registry's statuses, refreshable, and the user plugins folder.
import AppKit
import Foundation
import PomeloCore
import PomeloEngines

/// What an engine's install is doing, as the Engines pane shows it.
enum InstallState: Equatable {
    case working(InstallStage)
    case failed(String)
}

@MainActor
final class EnginesModel: ObservableObject {
    typealias Install = (EngineID, @escaping @Sendable (InstallStage) -> Void) async throws -> URL

    @Published private(set) var statuses: [EngineStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var installs: [EngineID: InstallState] = [:]
    @Published private(set) var cancelling: Set<EngineID> = []
    /// The spoken languages on this Mac, by name, for the Speech row (P155).
    @Published private(set) var spokenLanguages: [String] = []

    private let loadStatuses: () async -> [EngineStatus]
    private let loadSpokenLanguages: @Sendable () async -> [String]
    private let refreshAll: () async -> Void
    private let runInstall: Install
    private let installable: Set<EngineID>
    private let stageInterval: TimeInterval
    private var installTasks: [EngineID: Task<URL, any Error>] = [:]

    init(
        loadStatuses: @escaping () async -> [EngineStatus], refresh: @escaping () async -> Void,
        install: @escaping Install = { _, _ in throw InstallError.notAvailableForThisMac },
        installable: Set<EngineID> = [], stageInterval: TimeInterval = 0.1,
        loadSpokenLanguages: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.loadStatuses = loadStatuses
        self.loadSpokenLanguages = loadSpokenLanguages
        refreshAll = refresh
        runInstall = install
        self.installable = installable
        self.stageInterval = stageInterval
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            loadStatuses: { await environment.registry.statuses() },
            refresh: { await environment.refreshEngines() },
            install: { try await environment.installer.install($0, stage: $1) },
            installable: environment.installable,
            loadSpokenLanguages: { await SpeechLanguages.installedNames() }
        )
    }

    /// What an available engine's row says under its name: for Speech, the spoken languages this Mac has.
    func detail(for status: EngineStatus) -> String? {
        guard status.id == "speech", !spokenLanguages.isEmpty else { return nil }
        return "Spoken languages on this Mac: \(ListFormatter.localizedString(byJoining: spokenLanguages))."
    }

    static let installNote = "Pomelo downloads the publisher's build, checks it against a fingerprint kept in Pomelo, and installs it for Pomelo only."

    /// The pane's first footer line; the download sentence only when some engine shows an Install button.
    var footer: String {
        let optional = "Missing engines are optional."
        return statuses.contains(where: canInstall) ? optional + " " + Self.installNote : optional
    }

    func canInstall(_ status: EngineStatus) -> Bool {
        if case .missing = status.availability { return installable.contains(status.id) }
        return false
    }

    /// Installs `id` and shows its stages. The engine keeps its state until `runInstall` has returned, a cancel
    /// included: the installer answers a call that joins a cancelled install with `.cancelled`, so Install must not
    /// run again meanwhile (P132). Every outcome is followed by a refresh: a reinstall whose program won't start
    /// leaves the engine missing, and the wheel must know.
    func install(_ id: EngineID) async {
        guard installable.contains(id), !isWorking(id) else { return }
        installs[id] = .working(.downloading(fraction: nil))
        let relay = StageRelay(interval: stageInterval) { [weak self] stage in
            guard let self, case .working? = self.installs[id] else { return }
            self.installs[id] = .working(stage)
        }
        let run = runInstall
        let task = Task { try await run(id, relay.push) }
        installTasks[id] = task
        var failure: String?
        do {
            _ = try await task.value
        } catch let error as InstallError {
            failure = error.reason
        } catch {
            failure = InstallError.downloadFailed.reason
        }
        relay.close()
        installTasks[id] = nil
        while isRefreshing { try? await Task.sleep(for: .milliseconds(20)) }
        await refresh()
        cancelling.remove(id)
        installs[id] = failure.map { .failed($0) }
    }

    /// True while an install's call has not returned: quitting then waits for `cancelInstalls`.
    var isInstalling: Bool { !installTasks.isEmpty }

    /// Cancels every install and waits, at most until `deadline`, for each call to return: an install removes its
    /// work folder as it unwinds.
    func cancelInstalls(waitingUntil deadline: ContinuousClock.Instant) async {
        for id in installTasks.keys { cancelInstall(id) }
        while isInstalling, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func cancelInstall(_ id: EngineID) {
        guard isWorking(id), let task = installTasks[id] else { return }
        cancelling.insert(id)
        task.cancel()
    }

    private func isWorking(_ id: EngineID) -> Bool {
        if case .working? = installs[id] { return true }
        return false
    }

    /// "Or with Homebrew: brew install webp" under an installable engine's Install button.
    func homebrewLine(for status: EngineStatus) -> String? {
        homebrewCommand(for: status).map { "Or with Homebrew: \($0)" }
    }

    func homebrewCommand(for status: EngineStatus) -> String? {
        guard canInstall(status), case .missing(let hint) = status.availability, hint.hasPrefix("brew install") else {
            return nil
        }
        return hint
    }

    func load() async {
        statuses = await loadStatuses()
        await loadLanguages()
    }

    /// Off the main thread: the recognizer's list is an asynchronous system query.
    private func loadLanguages() async {
        let load = loadSpokenLanguages
        spokenLanguages = await Task.detached { await load() }.value
    }

    /// Re-queries every engine (and rebuilds the wheel's content), then shows the result.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await refreshAll()
        statuses = await loadStatuses()
        await loadLanguages()
        isRefreshing = false
    }

    static func copy(_ hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint, forType: .string)
    }

    /// Creates the plugins folder if it is missing. The one place the app creates it.
    @discardableResult
    static func ensurePluginsFolder(at url: URL = DefaultEngines.userPluginsFolder,
                                    fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates the plugins folder if needed and opens it in Finder.
    static func showPluginsFolderInFinder() throws {
        NSWorkspace.shared.open(try ensurePluginsFolder())
    }
}

#if DEBUG || POMELO_EVALS
extension EnginesModel {
    /// For `--snapshot-settings engines+sample` and `--eval-accessibility` only: engines in states no real install is in.
    static func sampleForSnapshot() -> EnginesModel {
        func missing(_ id: EngineID, _ name: String, _ hint: String) -> EngineStatus {
            EngineStatus(id: id, displayName: name, availability: .missing(installHint: hint))
        }
        let statuses = [
            EngineStatus(id: "ffmpeg", displayName: "FFmpeg", availability: .available(version: "ffmpeg version 9.0.2")),
            EngineStatus(id: "speech", displayName: "Speech", availability: .unsupported(reason: "Needs macOS 26.")),
            missing("cwebp", "WebP", "brew install webp"),
            missing("pandoc", "Pandoc", "brew install pandoc"),
            missing("pngquant", "pngquant", "brew install pngquant"),
            missing("unar", "The Unarchiver", "brew install unar"),
        ]
        let model = EnginesModel(
            loadStatuses: { statuses }, refresh: {}, installable: ["cwebp", "pandoc", "pngquant"]
        )
        model.installs = [
            "pandoc": .working(.downloading(fraction: 0.4)),
            "pngquant": .failed("The download failed"),
        ]
        return model
    }
}
#endif

/// Hands the installer's stages to the main actor at most once per `interval`, always ending with the latest one:
/// the downloader reports every chunk, which would otherwise redraw the pane thousands of times.
private final class StageRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private let deliver: @MainActor (InstallStage) -> Void
    private var latest: InstallStage?
    private var lastDelivery = Date.distantPast
    private var isScheduled = false
    private var isClosed = false

    init(interval: TimeInterval, deliver: @escaping @MainActor (InstallStage) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func push(_ stage: InstallStage) {
        lock.lock()
        latest = stage
        guard !isScheduled, !isClosed else { return lock.unlock() }
        isScheduled = true
        let wait = max(0, interval - Date().timeIntervalSince(lastDelivery))
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in flush() }
    }

    /// After this no stage is delivered, so a late one can't overwrite the outcome.
    func close() {
        lock.lock()
        isClosed = true
        latest = nil
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let stage = latest
        latest = nil
        isScheduled = false
        lastDelivery = Date()
        lock.unlock()
        if let stage { MainActor.assumeIsolated { deliver(stage) } }
    }
}

/// How the About pane words the app's version.
enum AppInfo {
    /// "Version 0.1.0 (1)" from the bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
    static func versionString(from info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        case let (nil, build?): return "Build \(build)"
        default: return "Version unknown"
        }
    }

    // TODO: placeholder until the repository is published under its final name.
    static let repositoryURL = URL(string: "https://github.com/leopierini/pomelo")!
}

