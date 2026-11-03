// Watches the folders of Settings › Watch Folders and runs each one's action on what arrives, unattended (P106):
// Finder's progress only, outputs next to the arrival, never replacing it (P108). Only new arrivals count (P107): what
// a folder holds when its watch starts is its baseline. An arrival is taken once it has settled and no Finder copy is
// in progress (P110, P126). Loop safety is the output mark plus one memory of every output any run returned (P109,
// P127), for volumes that drop the mark.
import AppKit
import Combine
import Foundation
import PomeloCore
import PomeloUIModel
import os

enum WatchFolderState: Equatable, Sendable {
    /// Turned off in Settings.
    case off
    case watching
    /// Not found, not readable, or gone while watched: tried again on `reconcile` and on wake from sleep.
    case missing
}

@MainActor
final class WatchFolderManager: ObservableObject {
    /// What the manager asks about a file, apart from its listing.
    struct FileProbe: Sendable {
        /// Whether the content is on this Mac. Metadata only: a dataless file's bytes are never opened.
        var isLocal: @Sendable (URL) -> Bool
        var isMarked: @Sendable (URL) -> Bool
        /// Where a watched folder is now. Never asked on the main thread: on a network share that went away it can
        /// block for seconds.
        var place: @Sendable (WatchFolder) -> URL? = WatchFolderManager.resolve

        static let live = FileProbe(
            isLocal: { url in
                let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    .ubiquitousItemDownloadingStatus
                return FileReadability.isLocal(statFlags: FileReadability.statFlags(of: url), downloadingStatus: status)
            },
            isMarked: { OutputMark.isMarked($0) }
        )
    }

    @Published private(set) var states: [UUID: WatchFolderState] = [:]
    /// Each folder's last failure as a short sentence ("Couldn't convert IMG_1.heic. The file may be damaged."),
    /// cleared by its next success.
    @Published private(set) var problems: [UUID: String] = [:]

    private let settings: SettingsStore
    private let registry: EngineRegistry
    private let run: @MainActor (ConversionRequest, String) async -> [FileResult]
    private let probe: FileProbe
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    private var isStarted = false
    private var watches: [UUID: Watch] = [:]
    /// Every output a run returned, as a canonical path: no rule takes another's output either (P127).
    private var outputs: Set<String> = []
    /// Runs going on per canonical folder path. While a folder has one, what settles there is held until it returns:
    /// it may be that run's output, published before the run hands its outputs back (P127).
    private var inFlight: [String: Int] = [:]
    /// Canonical folder path to the one it was renamed to while watched (P130): a run that started before the rename
    /// still finishes under its old name.
    private var moved: [String: String] = [:]
    /// Folders being found and opened off the main thread, by the generation their watch will have; the folder is
    /// the latest Settings gave while it was being opened.
    private var opening: [UUID: (generation: UUID, folder: WatchFolder)] = [:]
    /// The settle poll, and when its sleep ends.
    private var poll: (id: UUID, due: ContinuousClock.Instant, task: Task<Void, Never>)?
    private var wakeObserver: (any NSObjectProtocol)?
    private nonisolated static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "watch")

    /// `run` is `JobCoordinator.runUnattended` in the app. `now` and `sleep` are the settle poll's clock.
    init(
        settings: SettingsStore, registry: EngineRegistry,
        run: @escaping @MainActor (ConversionRequest, String) async -> [FileResult], probe: FileProbe = .live,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settings = settings
        self.registry = registry
        self.run = run
        self.probe = probe
        self.now = now
        self.sleep = sleep
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    /// Ends every watch. A run already started finishes on its own.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        for id in Array(watches.keys) { end(id) }
        opening = [:]
        poll?.task.cancel()
        poll = nil
        states = states.mapValues { _ in .off }
    }

    /// Brings the watches in line with Settings: folders added, removed, turned on or off, moved, or given another
    /// action; a missing folder is looked for again. A folder whose place changed starts over with a new baseline,
    /// unless it is the place already being watched (a folder renamed while watched, P130).
    func reconcile() {
        guard isStarted else { return }
        let configured = settings.settings.watchFolders
        let ids = Set(configured.map(\.id))
        for id in Set(watches.keys).union(opening.keys) where !ids.contains(id) { end(id) }
        states = states.filter { ids.contains($0.key) }
        problems = problems.filter { ids.contains($0.key) }
        for folder in configured {
            guard folder.isEnabled else {
                end(folder.id)
                states[folder.id] = .off
                continue
            }
            if let watch = watches[folder.id] {
                let isSamePlace = watch.folder.path == folder.path && watch.folder.bookmark == folder.bookmark
                watch.folder = folder
                if !isSamePlace { follow(folder, in: watch) }
                continue
            }
            if let pending = opening[folder.id], pending.folder.path == folder.path,
               pending.folder.bookmark == folder.bookmark {
                opening[folder.id]?.folder = folder
                continue
            }
            begin(folder)
        }
    }

    /// Looks at every folder again without waiting for a kernel event: a watched folder that is gone is followed or
    /// shown as missing, and a missing one is looked for again. The pane asks when it is shown, because the event of
    /// a folder deleted meanwhile may not have been handled yet (the app was in the background).
    func recheck() async {
        guard isStarted else { return }
        for (id, watch) in watches {
            let url = watch.url
            let isThere = await Task.detached(priority: .userInitiated) {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.value
            guard !isThere else { continue }
            await wentAway(id, watch.generation)
            // The folder's own event may have started that already: wait for it, so the state is final on return.
            for _ in 0..<400 where watch.isRelocating { try? await Task.sleep(for: .milliseconds(5)) }
        }
        reconcile()
    }

    /// Settings gave a watched folder another path or bookmark. The pane stores the new path of a renamed folder,
    /// which the watch has followed already (P130); any other place starts over.
    private func follow(_ folder: WatchFolder, in watch: Watch) {
        let resolve = probe.place
        Task {
            let place = await Task.detached(priority: .utility) { resolve(folder).map(Self.canonicalPath(of:)) }.value
            guard watches[folder.id] === watch, watch.folder == folder, place != watch.canonicalPath else { return }
            end(folder.id)
            begin(folder)
        }
    }

    // MARK: - Watches

    /// One watched folder. Every name the manager has decided about (the baseline, what it took or ignored) keeps the
    /// size and date it had then: the same name with other content is a new arrival.
    private final class Watch {
        var folder: WatchFolder
        /// Where the folder is now: they change when it is renamed or moved (P130).
        var url: URL
        /// Standardized with its links resolved, so two rules on one folder agree whatever path they were given.
        var canonicalPath: String
        /// Callbacks and listings of an earlier place or watcher carry an older one and are ignored.
        var generation: UUID
        var watcher: FolderWatcher?
        var hasBaseline = false
        var tracker = SettleTracker()
        var decided: [String: Decided] = [:]
        /// Settled while a run in this folder was going on: taken, or known as an output, once it returns.
        var held: [String: Key] = [:]
        /// The names of the last listing, so a name that disappears is forgotten.
        var names: Set<String> = []
        var isListing = false
        var needsListing = false
        var isRelocating = false

        init(folder: WatchFolder, url: URL, canonicalPath: String, generation: UUID) {
            self.folder = folder
            self.url = url
            self.canonicalPath = canonicalPath
            self.generation = generation
        }

        func file(_ name: String) -> URL { url.appending(path: name, directoryHint: .notDirectory) }
        func canonicalPath(of name: String) -> String { canonicalPath + "/" + name }
    }

    private nonisolated static func canonicalPath(of folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// An output's canonical path: its folder's, plus its name (the output itself is never resolved).
    private nonisolated static func canonicalPath(ofOutput output: URL) -> String {
        canonicalPath(of: output.deletingLastPathComponent()) + "/" + output.lastPathComponent
    }

    /// What a listing says about a file's content. The identity (its inode) tells a file renamed or replaced under
    /// the same name with the same size and date.
    private struct Key: Hashable {
        var size: Int64
        var modified: Date
        var identity: UInt64?
    }

    private struct Decided {
        var key: Key
        /// The file itself was dealt with (the baseline, taken, or held): the same file under a new name is no arrival.
        /// False for an entry passed over for its name, type or mark (a partial download is renamed when whole).
        var isHandled: Bool
    }

    /// A listed entry: metadata only.
    private struct Entry: Sendable {
        var name: String
        var isRegularFile: Bool
        var isSymbolicLink: Bool
        var size: Int64
        var modified: Date
        var created: Date?
        var identity: UInt64?

        var key: Key { Key(size: size, modified: modified, identity: identity) }
    }

    /// Finds the folder and opens its watcher off the main thread, then lists its baseline. The watcher comes first,
    /// so nothing arriving while the baseline is listed goes unseen.
    private func begin(_ folder: WatchFolder) {
        let id = folder.id
        let generation = UUID()
        opening[id] = (generation, folder)
        let resolve = probe.place
        Task {
            let opened = await Task.detached(priority: .utility) { [self] () -> (URL, String, FolderWatcher)? in
                guard let url = resolve(folder), let watcher = Self.watcher(at: url, id, generation, self) else {
                    return nil
                }
                return (url, Self.canonicalPath(of: url), watcher)
            }.value
            guard let pending = opening[id], pending.generation == generation else {
                opened?.2.cancel()
                return
            }
            opening[id] = nil
            guard let (url, canonicalPath, watcher) = opened else {
                states[id] = .missing
                return
            }
            let watch = Watch(folder: pending.folder, url: url, canonicalPath: canonicalPath, generation: generation)
            watch.watcher = watcher
            watches[id] = watch
            await refresh(id)
        }
    }

    /// A watcher whose events reach `manager` for this generation of the watch, or nil when the folder can't be
    /// opened. Off the main thread: opening a folder on a stale mount can block.
    private nonisolated static func watcher(
        at url: URL, _ id: UUID, _ generation: UUID, _ manager: WatchFolderManager?
    ) -> FolderWatcher? {
        do {
            return try FolderWatcher(
                folder: url,
                onChange: { [weak manager] in Task { @MainActor in await manager?.changed(id, generation) } },
                onGone: { [weak manager] in Task { @MainActor in await manager?.wentAway(id, generation) } }
            )
        } catch {
            log.info("cannot watch a folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func end(_ id: UUID) {
        watches.removeValue(forKey: id)?.watcher?.cancel()
        opening[id] = nil
    }

    private func current(_ id: UUID, _ generation: UUID) -> Watch? {
        guard let watch = watches[id], watch.generation == generation else { return nil }
        return watch
    }

    private func changed(_ id: UUID, _ generation: UUID) async {
        guard current(id, generation) != nil else { return }
        await refresh(id)
    }

    /// P130: a folder that was renamed or moved is found again through its bookmark and watched at its new place with
    /// everything the watch knew, so nothing is baselined again and nothing that arrives meanwhile is lost. It shows as
    /// missing when it is really gone, or has been made again at the same path (a new folder: it starts over).
    private func wentAway(_ id: UUID, _ generation: UUID) async {
        guard let watch = current(id, generation), !watch.isRelocating else { return }
        watch.isRelocating = true
        defer { watch.isRelocating = false }
        let folder = watch.folder
        let left = watch.canonicalPath
        let fresh = UUID()
        let resolve = probe.place
        let found = await Task.detached(priority: .utility) { [self] () -> (URL, String, FolderWatcher)? in
            guard let place = resolve(folder) else { return nil }
            let canonical = Self.canonicalPath(of: place)
            guard canonical != left, let watcher = Self.watcher(at: place, id, fresh, self) else { return nil }
            return (place, canonical, watcher)
        }.value
        guard current(id, generation) === watch else {
            found?.2.cancel()
            return
        }
        guard let (place, canonical, newWatcher) = found else {
            end(id)
            states[id] = .missing
            return
        }
        watch.watcher?.cancel()
        // The tracker's names are URLs of the old place: what is still settling is seen again at the new one.
        for name in watch.names { watch.tracker.forget(watch.file(name)) }
        watch.watcher = newWatcher
        watch.url = place
        watch.canonicalPath = canonical
        watch.generation = fresh
        moved[left] = canonical
        if let count = inFlight.removeValue(forKey: left) { inFlight[canonical, default: 0] += count }
        let prefix = left + "/"
        outputs = Set(outputs.map { $0.hasPrefix(prefix) ? canonical + "/" + $0.dropFirst(prefix.count) : $0 })
        Task { await refresh(id) }
    }

    /// `folder` as it is called now, once any renames of it since are followed.
    private func current(folder: String) -> String {
        var folder = folder
        var seen: Set<String> = []
        while let next = moved[folder], seen.insert(folder).inserted { folder = next }
        return folder
    }

    /// The bookmark's folder (it follows a rename or a move), else the stored path; never one in the Trash.
    nonisolated static func resolve(_ folder: WatchFolder) -> URL? {
        var candidates: [URL] = []
        if let bookmark = folder.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  bookmarkDataIsStale: &isStale) {
                candidates.append(url)
            }
        }
        candidates.append(URL(fileURLWithPath: folder.path, isDirectory: true))
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" })
        }
    }

    // MARK: - Listing

    /// Lists the folder off the main thread (a Downloads folder can hold thousands of entries) and takes in what
    /// changed. One listing at a time per folder; a change during one asks for another after it.
    private func refresh(_ id: UUID) async {
        guard let watch = watches[id] else { return }
        guard !watch.isListing else {
            watch.needsListing = true
            return
        }
        watch.isListing = true
        defer { watch.isListing = false }
        repeat {
            watch.needsListing = false
            let url = watch.url
            let generation = watch.generation
            let entries = await Task.detached(priority: .utility) { Self.list(url) }.value
            guard watches[id] === watch else { return }
            guard let entries else {
                // A listing of the place the folder just left says nothing about the new one.
                if watch.generation != generation {
                    watch.needsListing = true
                    continue
                }
                await wentAway(id, generation)
                return
            }
            if watch.hasBaseline {
                take(entries, in: watch)
            } else {
                watch.hasBaseline = true
                watch.names = Set(entries.map(\.name))
                for entry in entries {
                    let isHandled = ArrivalFilter.isCandidate(
                        name: entry.name, isRegularFile: entry.isRegularFile, isSymbolicLink: entry.isSymbolicLink,
                        isMarked: false
                    )
                    watch.decided[entry.name] = Decided(key: entry.key, isHandled: isHandled)
                }
                states[id] = .watching
            }
        } while watch.needsListing
        schedulePoll()
    }

    private nonisolated static func list(_ folder: URL) -> [Entry]? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .fileIdentifierKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: []
        ) else { return nil }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return Entry(
                name: url.lastPathComponent, isRegularFile: values.isRegularFile ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false, size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast, created: values.creationDate,
                identity: values.fileIdentifier
            )
        }
    }

    /// Forgets the names that vanished, passes new names and new content through `ArrivalFilter`, tracks them until
    /// they settle, and runs the folder's action on each that is ready (or holds it while a run there goes on).
    private func take(_ entries: [Entry], in watch: Watch) {
        let names = Set(entries.map(\.name))
        let vanished = watch.names.subtracting(names)
        // A file the watch dealt with that is renamed keeps its identity, size and date: it is no new arrival.
        let renamed = Set(vanished.compactMap { name in
            watch.decided[name].flatMap { $0.isHandled && $0.key.identity != nil ? $0.key : nil }
        })
        for name in vanished {
            watch.decided[name] = nil
            watch.held[name] = nil
            outputs.remove(watch.canonicalPath(of: name))
            watch.tracker.forget(watch.file(name))
        }
        watch.names = names
        let isBusy = inFlight[watch.canonicalPath, default: 0] > 0
        var ready: [URL] = []
        for entry in entries where watch.decided[entry.name]?.key != entry.key && watch.held[entry.name] != entry.key {
            let url = watch.file(entry.name)
            watch.held[entry.name] = nil
            if renamed.contains(entry.key) {
                watch.decided[entry.name] = Decided(key: entry.key, isHandled: true)
                watch.tracker.forget(url)
                continue
            }
            guard !outputs.contains(watch.canonicalPath(of: entry.name)) else {
                watch.tracker.forget(url)
                continue
            }
            guard ArrivalFilter.isCandidate(name: entry.name, isRegularFile: entry.isRegularFile,
                                            isSymbolicLink: entry.isSymbolicLink, isMarked: probe.isMarked(url)) else {
                watch.decided[entry.name] = Decided(key: entry.key, isHandled: false)
                watch.tracker.forget(url)
                continue
            }
            // A Finder copy that stalls keeps its size and date: its markers keep the clock from running (P126).
            let counts = probe.isLocal(url) && !Self.isBeingCopied(url, created: entry.created)
            // The tracker reports a state once, and again after an iCloud round trip with the same size and date:
            // `decided` is what keeps a taken file from running twice.
            guard watch.tracker.observe(url, size: entry.size, modified: entry.modified, isLocal: counts, at: now())
            else { continue }
            watch.tracker.forget(url)
            if isBusy {
                watch.held[entry.name] = entry.key
            } else {
                watch.decided[entry.name] = Decided(key: entry.key, isHandled: true)
                ready.append(url)
            }
        }
        dispatch(ready, in: watch)
    }

    /// Finder's marks of a copy in progress: a placeholder creation date (one of two days, in UTC), or the FinderInfo
    /// file type 'brok'. Metadata only: the file's bytes are never opened.
    private nonisolated static func isBeingCopied(_ url: URL, created: Date?) -> Bool {
        if let created {
            let day = utc.dateComponents([.year, .month, .day], from: created)
            if busyDays.contains(where: { $0 == (day.year, day.month, day.day) }) { return true }
        }
        var info = [UInt8](repeating: 0, count: 32)
        let count = getxattr(url.path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW)
        return count >= 4 && info.prefix(4).elementsEqual("brok".utf8)
    }

    private nonisolated static let busyDays: [(Int?, Int?, Int?)] = [(1946, 2, 14), (1984, 1, 24)]

    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    // MARK: - Settle poll

    private func nextLook(at now: ContinuousClock.Instant) -> Duration? {
        watches.values.compactMap { $0.tracker.nextLook(at: now) }.min()
    }

    /// A poll that runs only while some arrival is still settling (a file growing in place sends no folder event): once
    /// a second, and less and less often for files that can't settle (`SettleTracker.nextLook`), so a folder at rest
    /// costs no wakeups and one holding an empty or evicted file at most one a minute. A poll asleep for longer than a
    /// new arrival needs is started again.
    private func schedulePoll() {
        let start = now()
        guard let wait = nextLook(at: start) else { return }
        if let poll, poll.due <= start + wait { return }
        poll?.task.cancel()
        let id = UUID()
        poll = (id, start + wait, Task { [weak self] in await self?.polling(id, first: wait) })
    }

    private func polling(_ id: UUID, first: Duration) async {
        var wait = first
        while !Task.isCancelled {
            do { try await sleep(wait) } catch { break }
            for (folderID, watch) in watches where !watch.tracker.pending.isEmpty {
                await refresh(folderID)
            }
            let start = now()
            guard poll?.id == id, let next = nextLook(at: start) else { break }
            wait = next
            poll?.due = start + next
        }
        if poll?.id == id { poll = nil }
    }

    // MARK: - Running

    private func dispatch(_ files: [URL], in watch: Watch) {
        for file in files {
            let folder = watch.canonicalPath
            inFlight[folder, default: 0] += 1
            Task {
                await process(file, in: watch)
                finished(in: folder)
            }
        }
    }

    /// Once a folder's last run has returned, every output is known: what settled meanwhile is taken unless it is one.
    private func finished(in started: String) {
        let folder = current(folder: started)
        inFlight[folder, default: 1] -= 1
        guard inFlight[folder] == 0 else { return }
        inFlight[folder] = nil
        var released: [(URL, Watch)] = []
        for watch in watches.values where watch.canonicalPath == folder {
            for (name, key) in watch.held {
                watch.decided[name] = Decided(key: key, isHandled: true)
                if !outputs.contains(watch.canonicalPath(of: name)) { released.append((watch.file(name), watch)) }
            }
            watch.held = [:]
        }
        for (file, watch) in released { dispatch([file], in: watch) }
    }

    private func process(_ file: URL, in watch: Watch) async {
        let planner = await registry.planner()
        guard watches[watch.folder.id] === watch, !probe.isMarked(file),
              !outputs.contains(Self.canonicalPath(ofOutput: file)) else { return }
        let tools = IntentCatalog.tools(settings: settings.settings, includingCombines: false)
        guard let request = WatchRules.request(
            for: watch.folder.action, file: file, formats: .builtIn, planner: planner, tools: tools
        ) else { return }
        let verb = switch watch.folder.action {
        case .convert: "Converting"
        case .tool(let id): ToolCatalog.info(id)?.verb ?? tools.first { $0.id == id }?.name ?? "Converting"
        }
        let results = await run(request, verb)
        for case .succeeded(_, let made, _) in results {
            for output in made {
                let folder = current(folder: Self.canonicalPath(of: output.deletingLastPathComponent()))
                outputs.insert(folder + "/" + output.lastPathComponent)
                for other in watches.values where other.canonicalPath == folder {
                    other.tracker.forget(other.file(output.lastPathComponent))
                }
            }
        }
        guard watches[watch.folder.id] === watch else { return }
        record(results, for: watch.folder.id)
    }

    /// P120: a file the work doesn't apply to ("Already compressed") is skipped quietly, never shown as a problem.
    /// Matched on the case, never the text.
    private func record(_ results: [FileResult], for id: UUID) {
        let counted = results.filter { result in
            if case .failed(_, .notApplicable) = result { false } else { true }
        }
        if counted.contains(where: { if case .failed = $0 { true } else { false } }) {
            problems[id] = IntentCatalog.failureMessage(ResultSummary.make(results: counted))
        } else if counted.contains(where: { if case .succeeded = $0 { true } else { false } }) {
            problems[id] = nil
        }
    }
}

#if DEBUG
extension WatchFolderManager {
    /// For tests: whether the settle poll is running.
    var isPolling: Bool { poll != nil }
    /// For tests: where rule `id` is watched now, so a test waits for a rename to be followed, not for real time.
    func watchedURL(_ id: UUID) -> URL? { watches[id]?.url }
}
#endif

#if DEBUG || POMELO_EVALS
extension WatchFolderManager {
    /// For `--snapshot-settings watchFolders+sample` and `--eval-accessibility` only: states and problems no real
    /// watch produced.
    func showForSnapshot(states: [UUID: WatchFolderState], problems: [UUID: String]) {
        self.states = states
        self.problems = problems
    }
}
#endif
