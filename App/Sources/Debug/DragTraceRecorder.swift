// DEBUG only: `Pomelo --record-drags <folder>` runs as a drag recorder and nothing else (S34): no wheel, no Shelf, no
// jobs. Each file drag becomes `<folder>/<yyyyMMdd-HHmmss-SSS>-<label>.json`, a `DragTrace` with no file names, paths
// or app names, so the shake presets can be tuned on real drags. Mouse monitors only: no permission.
#if DEBUG
import AppKit
import PomeloUIModel
import SwiftUI

/// One drag's points, relative to the mouse-down snapshot. Holds the files' count, never their URLs.
struct DragTraceBuilder {
    private let origin: CGPoint
    private let start: TimeInterval
    private let baselineChangeCount: Int
    private let screen: CGRect
    private var poll: [TracePoint]
    private var events: [TracePoint] = []
    private var filesSeenAt: Double?
    private var fileCount = 0

    init(down: DragSnapshot, screen: CGRect) {
        origin = down.location
        start = down.time
        baselineChangeCount = down.changeCount
        self.screen = screen.offsetBy(dx: -down.location.x, dy: -down.location.y)
        poll = [TracePoint(t: 0, x: 0, y: 0)]
    }

    /// A poll while the button is down. The button-up poll is left out, as `DragSession` never feeds it to the detector.
    mutating func add(_ s: DragSnapshot) {
        poll.append(point(s.location, s.time))
        // `DragSession`'s rule, so the replay arms where the live session would.
        if filesSeenAt == nil, s.changeCount != baselineChangeCount, !s.fileURLs.isEmpty {
            filesSeenAt = s.time - start
        }
        if filesSeenAt != nil { fileCount = max(fileCount, s.fileURLs.count) }
    }

    mutating func addEvent(at location: CGPoint, time: TimeInterval) {
        events.append(point(location, time))
    }

    /// Nil for a drag that never held files. `wouldFire` is replayed on the rounded points, so a fixture replays
    /// exactly as it was recorded.
    func trace(label: DragTrace.Label) -> DragTrace? {
        guard filesSeenAt != nil else { return nil }
        var trace = DragTrace(label: label, poll: poll, events: events, filesSeenAt: filesSeenAt, fileCount: fileCount,
                              screen: screen, wouldFire: [:]).rounded()
        for preset in DragTraceRecorder.presets {
            trace.wouldFire[preset.rawValue] = ShakeReport.replay(trace, sensitivity: preset).fired
        }
        return trace
    }

    private func point(_ location: CGPoint, _ time: TimeInterval) -> TracePoint {
        TracePoint(t: time - start, x: location.x - origin.x, y: location.y - origin.y)
    }
}

@MainActor
final class DragTraceRecorder: ObservableObject {
    nonisolated static let flag = "--record-drags"
    static let usage = "usage: Pomelo --record-drags <folder>"
    nonisolated static let presets: [ShakeSensitivity] = [.careful, .normal, .easy]

    /// Drags a preset would have fired on, by label: on ordinary drags they are false fires.
    struct Fires: Equatable {
        var ordinary = 0
        var shakes = 0
    }

    /// The label the next drag is written with.
    @Published var label = DragTrace.Label.ordinary
    @Published private(set) var counts: [DragTrace.Label: Int] = [:]
    @Published private(set) var shadowFires: [ShakeSensitivity: Fires] = [:]
    @Published private(set) var lastError: String?

    let folder: URL
    private let now: () -> Date
    private let screenFrame: @MainActor (CGPoint) -> CGRect
    private let watchesMouse: Bool
    private let monitor = DragMonitor()
    private var draggedMonitor: Any?
    private var builder: DragTraceBuilder?

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    /// `watchesMouse: false` (tests) installs no monitor; the recorder is then fed through `sample` and `dragged`.
    init(folder: URL, now: @escaping () -> Date = Date.init,
         screenFrame: @escaping @MainActor (CGPoint) -> CGRect = { DragTraceRecorder.screenFrame(containing: $0) },
         watchesMouse: Bool = true) {
        self.folder = folder
        self.now = now
        self.screenFrame = screenFrame
        self.watchesMouse = watchesMouse
    }

    /// The recorder for a `--record-drags` launch, started on the next turn of the main run loop (once the application
    /// has finished launching), or nil for any other launch. Exits on a usage error.
    static func runIfRequested(arguments: [String]) -> DragTraceRecorder? {
        let folder: URL
        do {
            guard let requested = try Self.folder(in: arguments) else { return nil }
            folder = requested
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            DebugOutput.fail("\(error)", 64)
        }
        let recorder = DragTraceRecorder(folder: folder)
        DispatchQueue.main.async { MainActor.assumeIsolated { recorder.start() } }
        return recorder
    }

    /// The folder after `--record-drags`, resolved, and only under ~/Library/Caches or a temporary folder (R14):
    /// anywhere else could be a folder macOS guards, where even creating a folder asks a permission.
    static func folder(in arguments: [String]) throws -> URL? {
        guard let index = arguments.dropFirst().firstIndex(of: flag) else { return nil }
        guard index + 1 < arguments.count else { throw DebugOutput.Failure(description: usage) }
        let written = arguments[index + 1]
        guard let folder = allowedFolder(written) else {
            throw DebugOutput.Failure(description: "refusing \(written): the recorder writes only under "
                + "~/Library/Caches or a temporary folder\n\(usage)")
        }
        return folder
    }

    /// Resolves `written` one component at a time, following links and ignoring case as the file system does, and
    /// returns it if it lies under an allowed root. Only entries of a folder on the way to a root, or inside one, are
    /// ever looked at (`lstat`, never through a link), so nothing inside a protected folder is touched; the components
    /// that don't exist yet are taken as written.
    private static func allowedFolder(_ written: String) -> URL? {
        let roots = AllowedRoots()
        let expanded = (written as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded : PathWalk.join(FileManager.default.currentDirectoryPath, expanded)
        var walk = PathWalk(pending: absolute.split(separator: "/").map(String.init))
        while !walk.pending.isEmpty {
            guard walk.step(roots: roots) else { return nil }
        }
        let folder = walk.missing.reduce(walk.resolved, PathWalk.join)
        guard roots.contains(folder) else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// The folders the recorder may write under, compared ignoring case as the file system does.
    private struct AllowedRoots {
        private let roots: [String]

        init() {
            let home = DragTraceRecorder.realPath(FileManager.default.homeDirectoryForCurrentUser.path)
            roots = ([home.map { "\($0)/Library/Caches" }, DragTraceRecorder.realPath(NSTemporaryDirectory()),
                      "/private/var/folders", "/private/tmp"] as [String?]).compactMap { $0?.lowercased() }
        }

        func contains(_ path: String) -> Bool {
            let path = path.lowercased()
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        func isOnTheWay(to path: String) -> Bool {
            let path = path.lowercased()
            return roots.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
        }
    }

    private struct PathWalk {
        var pending: [String]
        /// Always a real folder (no link) on the way to a root or inside one.
        var resolved = "/"
        var missing: [String] = []
        var links = 0

        static func join(_ parent: String, _ name: String) -> String {
            parent == "/" ? "/\(name)" : "\(parent)/\(name)"
        }

        /// Takes the next component; false refuses the whole path.
        mutating func step(roots: AllowedRoots) -> Bool {
            let name = pending.removeFirst()
            if name == "." { return true }
            if name == ".." {
                if missing.isEmpty { resolved = (resolved as NSString).deletingLastPathComponent } else { missing.removeLast() }
                return true
            }
            if !missing.isEmpty {
                missing.append(name)
                return true
            }
            let candidate = Self.join(resolved, name)
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                guard errno == ENOENT else { return false }
                missing.append(name)
                return true
            }
            return enter(candidate, mode: info.st_mode & S_IFMT, roots: roots)
        }

        private mutating func enter(_ candidate: String, mode: mode_t, roots: AllowedRoots) -> Bool {
            switch mode {
            case S_IFLNK:
                links += 1
                guard links <= 32,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else { return false }
                if target.hasPrefix("/") { resolved = "/" }
                pending = target.split(separator: "/").map(String.init) + pending
                return true
            case S_IFDIR:
                guard roots.contains(candidate) || roots.isOnTheWay(to: candidate) else { return false }
                resolved = candidate
                return true
            default:
                return false
            }
        }
    }

    nonisolated private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func start() {
        guard watchesMouse else { return }
        monitor.onSample = { [weak self] snapshot, phase in self?.sample(snapshot, phase) }
        // The session only paces the poll: nothing listens to its events, and the shake is replayed per preset.
        monitor.start(trigger: .shift, shake: .off)
    }

    /// Feeds one drag monitor snapshot; the button-up writes the drag's trace and returns its file.
    @discardableResult
    func sample(_ snapshot: DragSnapshot, _ phase: DragMonitor.SamplePhase) -> URL? {
        switch phase {
        case .down:
            builder = DragTraceBuilder(down: snapshot, screen: screenFrame(snapshot.location))
            installDraggedMonitor()
            return nil
        case .tick:
            builder?.add(snapshot)
            return nil
        case .up:
            removeDraggedMonitor()
            defer { builder = nil }
            guard let trace = builder?.trace(label: label) else { return nil }
            return write(trace)
        }
    }

    /// One `.leftMouseDragged` event: its location (screen points, y up) and timestamp (system uptime, the poll's clock).
    func dragged(to location: CGPoint, at timestamp: TimeInterval) {
        builder?.addEvent(at: location, time: timestamp)
    }

    static func screenFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.frame ?? .zero
    }

    /// Only between mouse-down and button-up (S36): a global mouse monitor, no permission.
    private func installDraggedMonitor() {
        removeDraggedMonitor()
        guard watchesMouse else { return }
        draggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            // A global monitor's event has no window: its location is in screen coordinates.
            let location = event.locationInWindow
            let timestamp = event.timestamp
            MainActor.assumeIsolated { self?.dragged(to: location, at: timestamp) }
        }
    }

    private func removeDraggedMonitor() {
        if let draggedMonitor { NSEvent.removeMonitor(draggedMonitor) }
        draggedMonitor = nil
    }

    private func write(_ trace: DragTrace) -> URL? {
        // The name is a date and a label only, so it can't leave the folder.
        let name = "\(Self.fileDate.string(from: now()))-\(trace.label.rawValue).json"
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(trace).write(to: url, options: .withoutOverwriting)
        } catch {
            lastError = "Couldn't write \(name)"
            return nil
        }
        lastError = nil
        counts[trace.label, default: 0] += 1
        for preset in Self.presets where trace.wouldFire[preset.rawValue] == true {
            if trace.label.isShake {
                shadowFires[preset, default: Fires()].shakes += 1
            } else {
                shadowFires[preset, default: Fires()].ordinary += 1
            }
        }
        return url
    }
}

/// The recorder's menu-bar menu, in place of Pomelo's own.
struct DragTraceRecorderMenu: View {
    @ObservedObject var recorder: DragTraceRecorder

    var body: some View {
        Text("Recording file drags")
        Picker("Label", selection: $recorder.label) {
            ForEach(DragTrace.Label.allCases, id: \.self) { label in
                Text(Self.title(label)).tag(label)
            }
        }
        Divider()
        Section("Recorded") {
            ForEach(DragTrace.Label.allCases, id: \.self) { label in
                Text("\(Self.title(label)): \(recorder.counts[label, default: 0])")
            }
        }
        Section("Shadow fires") {
            ForEach(DragTraceRecorder.presets, id: \.self) { preset in
                let fires = recorder.shadowFires[preset, default: .init()]
                let ordinary = recorder.counts[.ordinary, default: 0]
                let shakes = recorder.counts[.shakeMouse, default: 0] + recorder.counts[.shakeTrackpad, default: 0]
                Text("\(preset.title): \(fires.ordinary) of \(ordinary) ordinary, \(fires.shakes) of \(shakes) shakes")
            }
        }
        if let error = recorder.lastError {
            Text(error)
        }
        Divider()
        Button("Open Traces Folder") {
            NSWorkspace.shared.open(recorder.folder)
        }
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    static func title(_ label: DragTrace.Label) -> String {
        switch label {
        case .ordinary: "Ordinary"
        case .shakeMouse: "Shake with a mouse"
        case .shakeTrackpad: "Shake with a trackpad"
        }
    }
}
#endif
