// User settings: a Codable value persisted as JSON in UserDefaults under `settings.v1`. Missing or unreadable keys
// decode to their defaults and unknown keys are ignored, so adding or removing a setting never invalidates what is
// already stored (P23 removed the result pill's `resultAutoHideSeconds`; older blobs still carry it).
// Only Foundation, Combine and PomeloCore (P6): no AppKit.
import Combine
import Foundation
import PomeloCore

/// What the editors remember between uses (P27): the next editor opens with the last choice.
public struct EditorMemory: Codable, Sendable, Equatable {
    /// Format category raw value → the last "compress to size" target, in bytes.
    public var targetBytes: [String: Int64]
    /// The crop ratio last chosen: a `CropRatio` raw value ("free", "square", "sixteenNine"…).
    public var cropRatio: String
    public var redactionStyle: RedactionStyle
    /// Format category raw value → the size last saved in the Resize editor (P197): a photo's square must never
    /// open a video's editor ready to crop it.
    public var resize: [String: ResizeSpec]

    public init(targetBytes: [String: Int64] = [:], cropRatio: String = "free", redactionStyle: RedactionStyle = .fill,
                resize: [String: ResizeSpec] = [:]) {
        self.targetBytes = targetBytes
        self.cropRatio = cropRatio
        self.redactionStyle = redactionStyle
        self.resize = resize
    }

    private enum CodingKeys: String, CodingKey {
        case targetBytes, cropRatio, redactionStyle, resize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        targetBytes = (try? c.decodeIfPresent([String: Int64].self, forKey: .targetBytes)) ?? targetBytes
        cropRatio = (try? c.decodeIfPresent(String.self, forKey: .cropRatio)) ?? cropRatio
        redactionStyle = (try? c.decodeIfPresent(RedactionStyle.self, forKey: .redactionStyle)) ?? redactionStyle
        resize = (try? c.decodeIfPresent([String: ResizeSpec].self, forKey: .resize)) ?? resize
    }

    /// Leaves `resize` out while it is empty, so a blob an older build wrote comes back unchanged.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetBytes, forKey: .targetBytes)
        try c.encode(cropRatio, forKey: .cropRatio)
        try c.encode(redactionStyle, forKey: .redactionStyle)
        if !resize.isEmpty { try c.encode(resize, forKey: .resize) }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// The modifier key whose tap summons the wheel.
    public var trigger: TriggerKey = .shift
    /// The page the wheel opens on when the files have it; otherwise the first page they have.
    public var firstPage: WheelPageKind = .convert
    public var hapticsEnabled = true
    public var soundsEnabled = false
    /// Whether the global Convert shortcut (click mode) is on.
    public var clickModeHotkeyEnabled = true
    /// Category raw value → format ids in the user's order; a missing category means the defaults.
    public var wheelOrder: [String: [String]] = [:]
    public var hasCompletedOnboarding = false
    /// Kind raw value → tool id → shown: overrides of each tool's `shownByDefault` only, like `wheelOrder`.
    public var toolVisibility: [String: [String: Bool]] = [:]
    /// Tool id → the options the user chose; a missing tool keeps its built-in options.
    public var toolOptions: [String: PresetOptions] = [:]
    /// Whether a tool that can replace its original puts the source in the Trash and takes its name.
    public var replaceOriginal = false
    public var editorMemory = EditorMemory()
    public var watchFolders: [WatchFolder] = []
    /// `WheelKey.rawValue` → the customized wheel for that kind or format; a missing key means the built-in wheel.
    public var wheels: [String: CustomWheel] = [:]
    /// How easily shaking files during a drag summons the Shelf (S29).
    public var shelfShake: ShakeSensitivity = .normal

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case trigger, firstPage, hapticsEnabled, soundsEnabled, clickModeHotkeyEnabled
        case wheelOrder, hasCompletedOnboarding, toolVisibility, toolOptions, replaceOriginal
        case editorMemory, watchFolders, wheels, shelfShake
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on each key so a value of the wrong type (or an unknown trigger name) falls back to the default
        // instead of discarding every other setting.
        trigger = (try? c.decodeIfPresent(TriggerKey.self, forKey: .trigger)) ?? trigger
        firstPage = (try? c.decodeIfPresent(WheelPageKind.self, forKey: .firstPage)) ?? firstPage
        hapticsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled)) ?? hapticsEnabled
        soundsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .soundsEnabled)) ?? soundsEnabled
        clickModeHotkeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .clickModeHotkeyEnabled)) ?? clickModeHotkeyEnabled
        wheelOrder = (try? c.decodeIfPresent([String: [String]].self, forKey: .wheelOrder)) ?? wheelOrder
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? hasCompletedOnboarding
        toolVisibility = (try? c.decodeIfPresent([String: [String: Bool]].self, forKey: .toolVisibility)) ?? toolVisibility
        toolOptions = (try? c.decodeIfPresent([String: PresetOptions].self, forKey: .toolOptions)) ?? toolOptions
        replaceOriginal = (try? c.decodeIfPresent(Bool.self, forKey: .replaceOriginal)) ?? replaceOriginal
        editorMemory = (try? c.decodeIfPresent(EditorMemory.self, forKey: .editorMemory)) ?? editorMemory
        shelfShake = (try? c.decodeIfPresent(ShakeSensitivity.self, forKey: .shelfShake)) ?? shelfShake
        // Element by element: a folder with an action this version doesn't know is dropped, the others are kept.
        watchFolders = (try? c.decodeIfPresent([Unreadable<WatchFolder>].self, forKey: .watchFolders))?
            .compactMap(\.value) ?? watchFolders
        // Entry by entry too: an unreadable wheel, an unknown key or one left with no slot (P178) is dropped alone.
        wheels = (try? c.decodeIfPresent([String: Unreadable<CustomWheel>].self, forKey: .wheels))?
            .compactMapValues(\.value)
            .filter { WheelKey(rawValue: $0.key) != nil && $0.value.slotCount > 0 } ?? wheels
    }
}

/// An array element or dictionary value that decodes to nil instead of failing the whole collection.
struct Unreadable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Holds the settings and writes them to UserDefaults on every change.
@MainActor
public final class SettingsStore: ObservableObject {
    /// The UserDefaults key the settings JSON lives under.
    public nonisolated static let key = "settings.v1"

    @Published public var settings: AppSettings {
        didSet { save() }
    }

    /// Where the settings are kept: the real domain only for a user's launch (P100).
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = stored
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The rename (P92) changed the bundle ID, so the settings start in a new defaults domain: the first launch copies the
/// pre-rename blob over (P95). The old domain is only read, never changed, so nothing is deleted.
public enum SettingsMigration {
    /// The defaults domain of the app before the rename.
    public static let legacyDomain = "io.github.kumquat-app.Kumquat"

    /// Copies `legacy`'s `settings.v1`, and only that key, into `defaults` when `defaults` has none. Returns whether
    /// it copied. Tests pass `EphemeralDefaults` for both sides; only the shipped app reads `legacyDomain`.
    @discardableResult
    public static func copyLegacySettings(into defaults: UserDefaults, from legacy: UserDefaults) -> Bool {
        guard defaults.object(forKey: SettingsStore.key) == nil,
              let data = legacy.data(forKey: SettingsStore.key) else { return false }
        defaults.set(data, forKey: SettingsStore.key)
        return true
    }
}

/// A `UserDefaults` whose values live only in this object: nothing reaches cfprefsd, so no plist is ever written.
/// For tests (P16, P40) and the evals' measured launches (P29). A real suite can't be cleaned up from inside the
/// process: cfprefsd writes an emptied domain's plist again when the process exits.
public final class EphemeralDefaults: UserDefaults, @unchecked Sendable {
    /// Unique, so an accessor that isn't overridden reaches only a fresh domain that nothing writes.
    public let suiteName = "io.github.pomelo-app.ephemeral.\(UUID().uuidString)"
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {
        super.init(suiteName: suiteName)!
    }

    public override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    public override func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }

    public override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    public override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}
