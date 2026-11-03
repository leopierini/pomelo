// Watches Finder drags without any permission: global and local mouse-down monitors start a 60 Hz poll of the
// mouse button, the drag pasteboard and the modifier keys, which `DragSession` turns into wheel and Shelf (shake) events.
// No key monitors and no event taps.
import AppKit
import PomeloUIModel

/// Feeds `DragSession` from the live system state and forwards the events it produces.
@MainActor
final class DragMonitor {
    /// Called on the main actor for every event the session produces, in order.
    var onEvent: ((DragSessionEvent) -> Void)?
    /// Called at every mouse-down the monitors see, before the poll starts.
    var onMouseDown: (() -> Void)?

    #if DEBUG
    /// Where a snapshot came from: the mouse-down, a poll while the button is down, or the button-up poll.
    enum SamplePhase {
        case down, tick, up
    }

    /// Every snapshot the session sees, for the drag recorder (S34).
    var onSample: ((DragSnapshot, SamplePhase) -> Void)?
    #endif

    private var session: DragSession?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?

    private let pasteboard = NSPasteboard(name: .drag)
    /// The `changeCount` the cached URLs were read at.
    private var readChangeCount: Int?
    private var cachedURLs: [URL] = []
    /// Ticks left during which an empty read is retried: the drag source clears the pasteboard (which bumps the
    /// `changeCount`) before it writes, so a read that lands in between sees nothing.
    private var emptyReadRetries = 0
    private static let emptyReadRetryTicks = 10

    /// True between `start` and `stop`.
    var isRunning: Bool { session != nil }

    /// Starts watching for drags that the `trigger` tap turns into a wheel and that a shake turns into the Shelf,
    /// replacing any running session.
    func start(trigger: TriggerKey, shake: ShakeSensitivity) {
        stop()
        session = DragSession(trigger: trigger, shake: shake)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.mouseDown(flags: flags, startedInPomelo: false) }
        }
        // Drags that start in Pomelo's own windows never reach the global monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.mouseDown(flags: flags, startedInPomelo: true) }
            return event
        }
    }

    /// Removes the monitors and the poll timer.
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        stopTimer()
        session = nil
    }

    // MARK: - Polling

    private func mouseDown(flags: NSEvent.ModifierFlags, startedInPomelo: Bool) {
        guard session != nil else { return }
        onMouseDown?()
        // The baseline uses the event's own modifiers: the trigger held at mouse-down (shift-click) never counts.
        let snapshot = DragSnapshot(buttonDown: true, changeCount: pasteboard.changeCount, fileURLs: [],
                                    modifiers: Self.modifierSet(flags), location: NSEvent.mouseLocation,
                                    time: ProcessInfo.processInfo.systemUptime)
        session?.mouseDown(snapshot, startedInPomelo: startedInPomelo)
        #if DEBUG
        onSample?(snapshot, .down)
        #endif
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let snapshot = snapshot()
        // The button-up snapshot is polled too, so the session can report the end of the drag.
        let events = session?.poll(snapshot) ?? []
        #if DEBUG
        onSample?(snapshot, snapshot.buttonDown ? .tick : .up)
        #endif
        if !snapshot.buttonDown { stopTimer() }
        for event in events { onEvent?(event) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func snapshot() -> DragSnapshot {
        let changeCount = pasteboard.changeCount
        if changeCount != readChangeCount {
            readChangeCount = changeCount
            emptyReadRetries = Self.emptyReadRetryTicks
            cachedURLs = readFileURLs()
        } else if cachedURLs.isEmpty && emptyReadRetries > 0 {
            emptyReadRetries -= 1
            cachedURLs = readFileURLs()
        }
        return DragSnapshot(
            buttonDown: NSEvent.pressedMouseButtons & 1 != 0,
            changeCount: changeCount,
            fileURLs: cachedURLs,
            modifiers: Self.modifierSet(NSEvent.modifierFlags),
            location: NSEvent.mouseLocation,
            time: ProcessInfo.processInfo.systemUptime
        )
    }

    private func readFileURLs() -> [URL] {
        pasteboard.fileURLs
    }

    /// `ModifierSet` has its own raw values, so each flag is mapped explicitly.
    static func modifierSet(_ flags: NSEvent.ModifierFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }
}
