// Pure state machine for one Finder drag. The app's DragMonitor feeds it 60 Hz snapshots of the drag pasteboard
// and the modifier keys; it decides when the wheel opens, when to cycle pages, when a shake summons the Shelf (S35)
// and when the drag ends.
// Only Foundation and CoreGraphics: no AppKit.
import CoreGraphics
import Foundation

/// The modifier key whose tap summons the wheel.
public enum TriggerKey: String, Codable, Sendable, CaseIterable {
    case shift, option, control, command
}

/// The modifier keys the session cares about (a framework-free mirror of `NSEvent.ModifierFlags`).
public struct ModifierSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)
}

extension TriggerKey {
    /// The modifier flag this trigger watches.
    public var modifier: ModifierSet {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        }
    }
}

/// One poll of the world: mouse button, drag pasteboard and modifiers.
public struct DragSnapshot: Sendable, Equatable {
    public var buttonDown: Bool
    /// `NSPasteboard(name: .drag).changeCount`.
    public var changeCount: Int
    /// File URLs currently on the drag pasteboard (empty for a non-file drag).
    public var fileURLs: [URL]
    public var modifiers: ModifierSet
    public var location: CGPoint
    /// Seconds on any monotonic clock (the monitor uses system uptime); only differences matter.
    public var time: TimeInterval

    public init(buttonDown: Bool, changeCount: Int, fileURLs: [URL], modifiers: ModifierSet, location: CGPoint,
                time: TimeInterval = 0) {
        self.buttonDown = buttonDown
        self.changeCount = changeCount
        self.fileURLs = fileURLs
        self.modifiers = modifiers
        self.location = location
        self.time = time
    }
}

/// What the app should do in response to a poll.
public enum DragSessionEvent: Sendable, Equatable {
    /// The trigger was tapped during a file drag; `at` is the snapshot's location at the rising edge.
    case openWheel(files: [URL], at: CGPoint)
    /// The trigger was tapped again while the wheel is open.
    case cyclePage
    /// A shake completed during a file drag; `at` is the snapshot's location at the completing point.
    case showShelf(at: CGPoint)
    /// The button went up after a file drag. `dropExpected` is whether the wheel was open.
    case dragEnded(dropExpected: Bool)
}

/// Tracks one mouse-down to mouse-up gesture. Only a rising edge of the trigger *after* the drag started counts.
public struct DragSession: Sendable {
    public var trigger: TriggerKey
    public private(set) var isWheelOpen = false
    /// Off turns the shake off: the detector isn't fed.
    public var shake: ShakeSensitivity {
        didSet { detector = shake.parameters.map(ShakeDetector.init) }
    }

    /// Seconds after the drag is first seen holding files before the detector is fed (S35).
    public static let shakeArming: TimeInterval = 0.3

    /// True between `mouseDown` and the button-up poll; polls outside a gesture are ignored.
    private var isActive = false
    private var baselineChangeCount = 0
    private var triggerWasDown = false
    private var isDraggingFiles = false
    private var detector: ShakeDetector?
    private var armedAt: TimeInterval = 0
    private var startedInPomelo = false
    private var shakeFired = false

    public init(trigger: TriggerKey, shake: ShakeSensitivity = .off) {
        self.trigger = trigger
        self.shake = shake
        detector = shake.parameters.map(ShakeDetector.init)
    }

    /// Starts a new gesture: remembers the pasteboard baseline and whether the trigger is already held (a
    /// Finder copy drag holds ⌥ from the start, which must not count as a tap when ⌥ is the trigger).
    /// `startedInPomelo` is a drag out of the Shelf or a wheel: it never shakes.
    public mutating func mouseDown(_ s: DragSnapshot, startedInPomelo: Bool = false) {
        isActive = true
        baselineChangeCount = s.changeCount
        triggerWasDown = s.modifiers.contains(trigger.modifier)
        isDraggingFiles = false
        isWheelOpen = false
        self.startedInPomelo = startedInPomelo
        shakeFired = false
        detector?.reset()
    }

    /// Feeds one snapshot and returns the events it causes, in order.
    public mutating func poll(_ s: DragSnapshot) -> [DragSessionEvent] {
        guard isActive else { return [] }
        if s.changeCount != baselineChangeCount && !s.fileURLs.isEmpty && !isDraggingFiles {
            isDraggingFiles = true
            armedAt = s.time + Self.shakeArming
        }
        return [triggerEvent(s), shakeEvent(s), buttonUpEvent(s)].compactMap { $0 }
    }

    private mutating func triggerEvent(_ s: DragSnapshot) -> DragSessionEvent? {
        let triggerDown = s.modifiers.contains(trigger.modifier)
        defer { triggerWasDown = triggerDown }
        guard isDraggingFiles && !triggerWasDown && triggerDown else { return nil }
        if isWheelOpen { return .cyclePage }
        isWheelOpen = true
        return .openWheel(files: s.fileURLs, at: s.location)
    }

    private mutating func shakeEvent(_ s: DragSnapshot) -> DragSessionEvent? {
        // The wheel wins a tie (R12), and a shake can't complete on the button-up poll: the drop has gone elsewhere.
        let feedsShake = s.buttonDown && isDraggingFiles && !isWheelOpen && !startedInPomelo && !shakeFired
            && s.time >= armedAt
        guard feedsShake, detector?.feed(TracePoint(t: s.time, x: s.location.x, y: s.location.y)) == true else {
            return nil
        }
        shakeFired = true
        return .showShelf(at: s.location)
    }

    private mutating func buttonUpEvent(_ s: DragSnapshot) -> DragSessionEvent? {
        guard !s.buttonDown else { return nil }
        let event: DragSessionEvent? = isDraggingFiles ? .dragEnded(dropExpected: isWheelOpen) : nil
        isActive = false
        isDraggingFiles = false
        isWheelOpen = false
        shakeFired = false
        detector?.reset()
        return event
    }
}
