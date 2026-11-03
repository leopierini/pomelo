// Measurement modes of the evals harness (P29), compiled into Debug builds and into the Release build that
// `evals/run.sh` makes with POMELO_EVALS:
//   Pomelo --eval-wheel-open <file> <count> <out.json> [<settings.json>]  opens and closes the wheel off-screen
//     `count` times and writes {"p50Ms","p95Ms","count"} from its own clock around `open`, then exits. The wheels of
//     the optional `AppSettings` blob are loaded first, so a customized wheel can be measured (P181).
//   Pomelo --eval-editor-open <kind> <file> <count> <out.json>  opens and closes the editor (P27) off-screen
//     `count` times and writes {"p50Ms","p95Ms","count"} from its own clock around `open` until the chrome is laid
//     out, then exits.
//   Pomelo --eval-shelf-open <file> <count> <out.json>  summons the Shelf by a shake off-screen `count` times, holding
//     `file`, and writes {"p50Ms","p95Ms","count"} from its own clock around the summon until its view is laid out
//     (S27), then exits.
//   Pomelo --eval-idle <seconds> <out.json>  launches normally (in-memory defaults, no hotkey, no
//     onboarding), waits 5 s, then samples `seconds` of CPU, footprint and wakeups and writes
//     {"cpuPercent","footprintMB","wakeupsPerSecond"}, then exits.
//   Pomelo --eval-shelf-idle <folder> <seconds> <out.json>  launches normally, makes 200 small files in `folder` (a
//     temporary folder), shows an off-screen collapsed Shelf holding them, then samples as --eval-idle does (S26,
//     S27); it fails if the Shelf has anything scheduled.
//   Pomelo --eval-launch <out.json>  launches normally (in-memory defaults, no hotkey, no onboarding) and writes
//     {"launchMs"}: from the process's start to the first main-queue turn after applicationDidFinishLaunching at
//     which the menu-bar item and the drag monitor exist, then exits.
//   Pomelo --eval-watch <folder> <file> <count> <out.json>  launches normally, watches `folder` with one rule
//     (convert to JPEG), waits 5 s, samples 10 s of quiet wakeups, then moves `count` copies of `file` in one at a
//     time (copied under a hidden name, then renamed, as a finished download is) and times each from its rename to
//     its output; writes {"latencyP50Ms","latencyP95Ms","idleWakeupsPerSecond","count"}, then exits.
//   Pomelo --eval-accessibility <corpus> <out.json>  opens the wheel, pill, editors, onboarding and every Settings pane
//     off-screen, audits each (AccessibilityAudit) and writes {"findings","count"}, then exits.
#if DEBUG || POMELO_EVALS
import AppKit
import Foundation
import PomeloUIModel

enum EvalHooks {
    static let wheelFlag = "--eval-wheel-open"
    static let editorFlag = "--eval-editor-open"
    static let shelfFlag = "--eval-shelf-open"
    static let idleFlag = "--eval-idle"
    static let idleWarmUp: Duration = .seconds(5)
    static let shelfIdleFlag = "--eval-shelf-idle"
    static let shelfIdleFiles = 200
    static let watchFlag = "--eval-watch"
    static let watchQuiet: Duration = .seconds(10)
    /// How long one arrival may take to become an output before the measurement fails.
    static let watchLimit: Duration = .seconds(30)
    static let wheelUsage = "usage: Pomelo --eval-wheel-open <file> <count> <out.json> [<settings.json>]"
    static let launchFlag = "--eval-launch"
    /// How long a measured launch may take to become ready before the measurement fails.
    static let launchLimit: Duration = .seconds(30)

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains(wheelFlag) || arguments.contains(editorFlag) || arguments.contains(shelfFlag)
            || arguments.contains(idleFlag) || arguments.contains(shelfIdleFlag)
            || arguments.contains(watchFlag) || arguments.contains(launchFlag)
            || arguments.contains(AccessibilityEval.flag)
    }

    /// Settings that keep a measured launch quiet and away from the user's real defaults, with the wheels of the
    /// launch's settings file.
    static func ephemeralDefaults(arguments: [String]) -> UserDefaults {
        var settings = AppSettings()
        settings.clickModeHotkeyEnabled = false
        settings.hasCompletedOnboarding = true
        return inMemoryDefaults(settings, arguments: arguments)
    }

    // MARK: Settings file

    static let settingsPrefix = "settings="

    /// In memory only: a real suite would leave its plist in ~/Library/Preferences (P40). Holds `base` (or the
    /// defaults) with the wheels of the settings file `arguments` name, and nothing at all when there is neither.
    /// Only the wheels are taken, so a measurement stays quiet whatever else the file holds.
    static func inMemoryDefaults(_ base: AppSettings?, arguments: [String]) -> EphemeralDefaults {
        let defaults = EphemeralDefaults()
        let file: URL?
        do { file = try settingsFile(in: arguments) } catch { DebugOutput.fail("\(error)", 64) }
        guard base != nil || file != nil else { return defaults }
        var settings = base ?? AppSettings()
        if let file {
            do {
                settings.wheels = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: file)).wheels
            } catch {
                DebugOutput.fail("cannot read the settings in \(file.path): \(error)", 65)
            }
        }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: SettingsStore.key) }
        return defaults
    }

    /// The settings file a launch names: `settings=<path>` after `--snapshot-wheel` or `--snapshot-settings`, or the
    /// fourth argument of `--eval-wheel-open`. Throws a usage error for a missing file, or one in a folder macOS
    /// guards (the measured app must never read one).
    static func settingsFile(in arguments: [String]) throws -> URL? {
        let path: String
        let usage: String
        if let flag = arguments.firstIndex(of: wheelFlag) {
            let rest = arguments[(flag + 1)...]
            guard rest.count >= 4 else { return nil }
            path = rest[rest.startIndex + 3]
            usage = wheelUsage
        } else if let flag = arguments.firstIndex(where: { $0 == "--snapshot-wheel" || $0 == SettingsSnapshot.flag }) {
            guard let argument = arguments[(flag + 1)...].first(where: { $0.hasPrefix(settingsPrefix) }) else { return nil }
            path = String(argument.dropFirst(settingsPrefix.count))
            usage = arguments[flag] == SettingsSnapshot.flag ? SettingsSnapshot.usage : wheelSnapshotUsage
        } else {
            return nil
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        // The written path first: resolving it would already look inside a protected folder.
        guard !isProtected(file), !isProtected(file.resolvingSymlinksInPath()) else {
            throw DebugOutput.Failure(description: "refusing \(file.path): it is in a protected folder\n\(usage)")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
            throw DebugOutput.Failure(description: "no settings file at \(file.path)\n\(usage)")
        }
        return file
    }

    private static var wheelSnapshotUsage: String {
        #if DEBUG
        WheelSnapshotRequest.usage
        #else
        "usage: Pomelo --snapshot-wheel"
        #endif
    }

    /// True when the process runs the wheel, an editor or the accessibility measurement (which exits and must not start
    /// the app); false for an idle or a watch measurement, which the normal launch goes on to serve, and for any other.
    @MainActor
    static func runIfRequested(arguments: [String], environment: AppEnvironment) -> Bool {
        if runsAndExits(arguments: arguments, environment: environment) { return true }
        startLaunchMeasurements(arguments: arguments, environment: environment)
        return false
    }

    @MainActor
    private static func runsAndExits(arguments: [String], environment: AppEnvironment) -> Bool {
        if let rest = DebugOutput.arguments(after: wheelFlag, in: arguments) {
            startWheel(rest, environment: environment)
        } else if let rest = DebugOutput.arguments(after: editorFlag, in: arguments) {
            startEditor(rest, environment: environment)
        } else if let rest = DebugOutput.arguments(after: shelfFlag, in: arguments) {
            startShelf(rest)
        } else if let rest = DebugOutput.arguments(after: AccessibilityEval.flag, in: arguments) {
            guard rest.count >= 2 else { DebugOutput.fail(AccessibilityEval.usage) }
            let corpus = URL(fileURLWithPath: rest[0], isDirectory: true)
            let output = URL(fileURLWithPath: rest[1])
            Task { await AccessibilityEval.run(corpus: corpus, output: output, environment: environment) }
        } else {
            return false
        }
        return true
    }

    @MainActor
    private static func startLaunchMeasurements(arguments: [String], environment: AppEnvironment) {
        if let rest = DebugOutput.arguments(after: idleFlag, in: arguments) {
            guard rest.count >= 2, let seconds = Double(rest[0]), seconds > 0 else {
                DebugOutput.fail("usage: Pomelo \(idleFlag) <seconds> <out.json>")
            }
            let output = URL(fileURLWithPath: rest[1])
            Task { await measureIdle(seconds: seconds, output: output) }
        }
        if let rest = DebugOutput.arguments(after: shelfIdleFlag, in: arguments) {
            startShelfIdle(rest)
        }
        if let rest = DebugOutput.arguments(after: watchFlag, in: arguments) {
            startWatch(rest, environment: environment)
        }
        if let rest = DebugOutput.arguments(after: launchFlag, in: arguments) {
            guard let path = rest.first else { DebugOutput.fail("usage: Pomelo \(launchFlag) <out.json>") }
            measureLaunch(output: URL(fileURLWithPath: path), environment: environment)
        }
    }

    @MainActor
    private static func startWheel(_ rest: [String], environment: AppEnvironment) {
        guard (3...4).contains(rest.count), let count = Int(rest[1]), count > 0 else { DebugOutput.fail(wheelUsage) }
        let file = URL(fileURLWithPath: rest[0])
        let output = URL(fileURLWithPath: rest[2])
        Task { await measureWheel(file: file, count: count, output: output, environment: environment) }
    }

    @MainActor
    private static func startEditor(_ rest: [String], environment: AppEnvironment) {
        let kinds = EditorKind.allCases.map(\.rawValue).joined(separator: "|")
        guard rest.count >= 4, let kind = EditorKind(rawValue: rest[0]), let count = Int(rest[2]), count > 0 else {
            DebugOutput.fail("usage: Pomelo \(editorFlag) <\(kinds)> <file> <count> <out.json>")
        }
        let file = URL(fileURLWithPath: rest[1])
        let output = URL(fileURLWithPath: rest[3])
        Task { await measureEditor(kind, file: file, count: count, output: output, environment: environment) }
    }

    @MainActor
    private static func startShelf(_ rest: [String]) {
        guard rest.count >= 3, let count = Int(rest[1]), count > 0 else {
            DebugOutput.fail("usage: Pomelo \(shelfFlag) <file> <count> <out.json>")
        }
        let file = URL(fileURLWithPath: rest[0])
        let output = URL(fileURLWithPath: rest[2])
        Task { await measureShelf(file: file, count: count, output: output) }
    }

    @MainActor
    private static func startShelfIdle(_ rest: [String]) {
        guard rest.count >= 3, let seconds = Double(rest[1]), seconds > 0 else {
            DebugOutput.fail("usage: Pomelo \(shelfIdleFlag) <folder> <seconds> <out.json>")
        }
        let given = URL(fileURLWithPath: rest[0], isDirectory: true).standardizedFileURL
        // An existing folder is resolved whole, symlinks included; a new one through its parent, so /var and /tmp read
        // as their /private targets either way.
        let folder = FileManager.default.fileExists(atPath: given.path)
            ? given.resolvingSymlinksInPath()
            : given.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: given.lastPathComponent, directoryHint: .isDirectory)
        guard !isProtected(given), !isProtected(folder), isTemporary(folder) else {
            DebugOutput.fail("refusing \(given.path): the Shelf's files go in a temporary folder")
        }
        let output = URL(fileURLWithPath: rest[2])
        let files = makeShelfIdleFiles(in: folder)
        let shelf = ShelfController(desktop: .offScreen)
        shelf.summon(.tools(files: files, at: CGPoint(x: -29_500, y: -29_500)))
        Task { await measureShelfIdle(shelf, seconds: seconds, output: output) }
    }

    @MainActor
    private static func startWatch(_ rest: [String], environment: AppEnvironment) {
        guard rest.count >= 4, let count = Int(rest[2]), count > 0 else {
            DebugOutput.fail("usage: Pomelo \(watchFlag) <folder> <file> <count> <out.json>")
        }
        let folder = URL(fileURLWithPath: rest[0], isDirectory: true).resolvingSymlinksInPath()
        // A watched folder is read again and again: one macOS guards would show a privacy prompt (P60).
        guard !isProtected(folder) else { DebugOutput.fail("refusing to watch \(folder.path): it is a protected folder") }
        let file = URL(fileURLWithPath: rest[1])
        let output = URL(fileURLWithPath: rest[3])
        Task { await measureWatch(folder: folder, file: file, count: count, output: output, environment: environment) }
    }

    // MARK: Wheel

    @MainActor
    private static func measureWheel(file: URL, count: Int, output: URL, environment: AppEnvironment) async {
        await environment.rebuildWheelContent()
        guard let builder = environment.contentBuilder else { DebugOutput.fail("no wheel content") }
        let controller = WheelController(settings: environment.settingsStore, desktop: .offScreen)
        controller.contentBuilder = builder
        controller.prepare()
        let point = CGPoint(x: -29_500, y: -29_500)
        await timeOpenings(count, to: output) {
            controller.open(files: [file], at: point, clickMode: false)
        } close: {
            controller.close()
        }
    }

    // MARK: Editor

    @MainActor
    private static func measureEditor(
        _ kind: EditorKind, file: URL, count: Int, output: URL, environment: AppEnvironment
    ) async {
        guard let preset = EditorSessions.preset(for: kind, settings: environment.settingsStore.settings) else {
            DebugOutput.fail("no tool opens the \(kind.rawValue) editor")
        }
        let controller = EditorController(
            settings: environment.settingsStore,
            perform: { _, _, _, _ in DebugOutput.fail("the measurement saved an edit") },
            release: { _, _ in }, desktop: .offScreen
        )
        let request = EditorRequest(kind: kind, preset: preset, files: [file], anchor: CGPoint(x: -29_000, y: -29_000),
                                    flags: [])
        await timeOpenings(count, to: output) {
            controller.open(request)
            controller.panel.contentView?.layoutSubtreeIfNeeded()
        } close: {
            guard controller.isOpen else { DebugOutput.fail("no \(kind.rawValue) editor") }
            controller.cancel()
        }
    }

    // MARK: Shelf

    /// A shake's summon over a Shelf holding `file`, as it would appear mid-drag (S27); closing keeps the file.
    @MainActor
    private static func measureShelf(file: URL, count: Int, output: URL) async {
        let shelf = ShelfController(desktop: .offScreen)
        shelf.prepare()
        shelf.add([file])
        let point = CGPoint(x: -29_500, y: -29_500)
        await timeOpenings(count, to: output) {
            shelf.summon(.shake(at: point))
            shelf.panel.itemsView.layoutSubtreeIfNeeded()
        } close: {
            guard shelf.isShown, !shelf.model.isEmpty else { DebugOutput.fail("no Shelf holding \(file.path)") }
            shelf.close()
        }
    }

    /// Times `open` `count` times and writes the p50, p95 and count. Between samples the closed wheel, editor or
    /// Shelf's background work settles, so one sample never pays for the previous one.
    @MainActor
    private static func timeOpenings(_ count: Int, to output: URL, open: () -> Void, close: () -> Void) async {
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<count {
            samples.append(milliseconds(clock.measure(open)))
            close()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let (p50, p95) = percentiles(samples)
        write(["p50Ms": p50, "p95Ms": p95, "count": Double(count)], to: output)
    }

    // MARK: Idle

    private static func measureIdle(seconds: Double, output: URL) async {
        try? await Task.sleep(for: idleWarmUp)
        write(await sampleIdle(seconds: seconds), to: output)
    }

    private static func sampleIdle(seconds: Double) async -> [String: Double] {
        let start = Sample.take()
        try? await Task.sleep(for: .seconds(seconds))
        let end = Sample.take()
        let wall = end.wall - start.wall
        return [
            "cpuPercent": (end.cpu - start.cpu) / wall * 100,
            "footprintMB": end.footprintMB,
            "wakeupsPerSecond": Double(end.wakeups - start.wakeups) / wall,
        ]
    }

    /// A Shelf sitting there costs no more than the app at rest (S26): nothing scheduled before or after the sample.
    @MainActor
    private static func measureShelfIdle(_ shelf: ShelfController, seconds: Double, output: URL) async {
        try? await Task.sleep(for: idleWarmUp)
        func check(_ when: String) {
            guard shelf.isShown, shelf.presentation == .collapsed, shelf.model.items.count == shelfIdleFiles,
                  shelf.isAtRest else {
                DebugOutput.fail("\(when) the sample, the Shelf is not a collapsed Shelf of \(shelfIdleFiles) files at rest")
            }
        }
        check("before")
        let values = await sampleIdle(seconds: seconds)
        check("after")
        write(values, to: output)
    }

    /// Distinct small files, never overwriting one.
    private static func makeShelfIdleFiles(in folder: URL) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try (0..<shelfIdleFiles).map { index in
                let file = folder.appending(path: String(format: "shelf-idle-%03d.txt", index), directoryHint: .notDirectory)
                try Data("Shelf idle file \(index)\n".utf8).write(to: file, options: .withoutOverwriting)
                return file
            }
        } catch {
            DebugOutput.fail("cannot make the Shelf's files in \(folder.path): \(error)")
        }
    }

    // MARK: Launch

    @MainActor
    private static func measureLaunch(output: URL, environment: AppEnvironment) {
        guard let started = processStart() else { DebugOutput.fail("cannot read the process's start time") }
        // Registered from the app's init, before AppKit finishes launching: a later observer would miss the one post.
        guard !NSRunningApplication.current.isFinishedLaunching else { DebugOutput.fail("the app finished launching before the hook") }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    writeLaunchIfReady(started: started, output: output, environment: environment)
                    // The drag monitor starts once the wheel's content is planned, a few turns later: polled at 1 ms.
                    Task {
                        let clock = ContinuousClock()
                        let waiting = clock.now
                        while clock.now - waiting < launchLimit {
                            try? await Task.sleep(for: .milliseconds(1))
                            writeLaunchIfReady(started: started, output: output, environment: environment)
                        }
                        DebugOutput.fail("not ready after \(launchLimit)")
                    }
                }
            }
        }
    }

    /// Writes the launch time and exits once the app is ready; returns otherwise.
    @MainActor
    private static func writeLaunchIfReady(started: Date, output: URL, environment: AppEnvironment) {
        guard environment.dragMonitor.isRunning, hasStatusItem() else { return }
        write(["launchMs": Date().timeIntervalSince(started) * 1000], to: output)
    }

    /// The `MenuBarExtra`'s status item: AppKit gives its button a window of this private class.
    @MainActor
    private static func hasStatusItem() -> Bool {
        NSApp.windows.contains { String(describing: type(of: $0)) == "NSStatusBarWindow" }
    }

    /// When the kernel started this process (`kp_proc.p_starttime`, wall clock), so the launch includes dyld and
    /// everything before `main`.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }

    // MARK: Watch

    @MainActor
    private static func measureWatch(folder: URL, file: URL, count: Int, output: URL, environment: AppEnvironment) async {
        let rule = WatchFolder(path: folder.path, action: .convert("jpg"))
        environment.settingsStore.settings.watchFolders = [rule]
        let clock = ContinuousClock()
        let watching = clock.now
        while environment.watchFolders.states[rule.id] != .watching {
            guard clock.now - watching < watchLimit else { DebugOutput.fail("\(folder.path) is not watched") }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: idleWarmUp)
        let start = Sample.take()
        try? await Task.sleep(for: watchQuiet)
        let end = Sample.take()
        let quietWakeups = Double(end.wakeups - start.wakeups) / (end.wall - start.wall)

        var samples: [Double] = []
        for index in 0..<count {
            let name = "arrival-\(index)"
            let hidden = folder.appending(path: ".\(name).\(file.pathExtension)", directoryHint: .notDirectory)
            let arrival = folder.appending(path: "\(name).\(file.pathExtension)", directoryHint: .notDirectory)
            let expected = folder.appending(path: "\(name).jpg", directoryHint: .notDirectory)
            do {
                try FileManager.default.copyItem(at: file, to: hidden)
            } catch {
                DebugOutput.fail("cannot copy \(file.path): \(error)")
            }
            let arrived = clock.now
            do {
                try FileManager.default.moveItem(at: hidden, to: arrival)
            } catch {
                DebugOutput.fail("cannot move \(hidden.path): \(error)")
            }
            while !FileManager.default.fileExists(atPath: expected.path) {
                guard clock.now - arrived < watchLimit else { DebugOutput.fail("no \(expected.lastPathComponent) after \(watchLimit)") }
                try? await Task.sleep(for: .milliseconds(5))
            }
            samples.append(milliseconds(clock.now - arrived))
        }
        let (p50, p95) = percentiles(samples)
        write(
            [
                "latencyP50Ms": p50, "latencyP95Ms": p95,
                "idleWakeupsPerSecond": quietWakeups, "count": Double(count),
            ], to: output)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Nearest-rank percentiles of a non-empty sample.
    private static func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[Int((p * Double(sorted.count - 1)).rounded())] }
        return (percentile(0.5), percentile(0.95))
    }

    /// Under the system's temporary folders, never where a person keeps files.
    private static func isTemporary(_ folder: URL) -> Bool {
        let roots = [FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path, "/private/tmp",
                     "/private/var/folders"]
        return roots.contains { folder.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The folders macOS asks before an app reads (as `evals/run.sh` refuses them).
    private static func isProtected(_ folder: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
        return protected.contains { folder.path == "\(home)/\($0)" || folder.path.hasPrefix("\(home)/\($0)/") }
    }

    private struct Sample {
        var wall: Double
        var cpu: Double
        var footprintMB: Double
        var wakeups: UInt64

        static func take() -> Sample {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }

            var vm = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &vm) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            var power = task_power_info_data_t()
            var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &power) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
                }
            }
            return Sample(
                wall: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9,
                cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime),
                footprintMB: Double(vm.phys_footprint) / 1_048_576,
                wakeups: power.task_interrupt_wakeups
            )
        }
    }

    // MARK: Output

    private static func write(_ values: [String: Double], to url: URL) {
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        do { try data.write(to: url, options: .atomic) } catch { DebugOutput.fail("cannot write \(url.path): \(error)") }
        exit(0)
    }
}
#endif
