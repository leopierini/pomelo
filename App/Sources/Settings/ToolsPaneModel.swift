// The pure logic behind the Tools pane: which tools have options and how a control writes them. What a wheel shows
// is the wheel editor's business; `AppSettings.toolVisibility` stays stored for the built-in wheels (P179).
import Foundation
import PomeloCore
import PomeloUIModel

struct ToolsPaneModel: Equatable {
    /// A tool with settings, and what those settings are now.
    struct DefaultsEntry: Identifiable {
        let info: ToolInfo
        let name: String
        let options: PresetOptions

        var id: String { info.id }
    }

    private(set) var settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Reading

    private var presets: [String: Preset] {
        Dictionary(uniqueKeysWithValues: ToolCatalog.presets(settings: settings).map { ($0.id, $0) })
    }

    var defaults: [DefaultsEntry] {
        let presets = presets
        return ToolCatalog.all.filter { !$0.settings.isEmpty }.map { info in
            DefaultsEntry(info: info, name: presets[info.id]?.name ?? info.name, options: options(of: info.id))
        }
    }

    /// The tool's options as the wheel runs them: the user's, else the built-in ones.
    func options(of id: String) -> PresetOptions {
        settings.toolOptions[id] ?? Preset.builtIns.first { $0.id == id }?.options ?? PresetOptions()
    }

    // MARK: - Writing

    mutating func setQuality(_ quality: Double, for id: String) {
        edit(id) { $0.quality = (quality * 100).rounded() / 100 }
    }

    mutating func setVideoMaxHeight(_ height: Int, for id: String) {
        edit(id) { $0.videoMaxHeight = height }
    }

    mutating func setAudioBitrate(_ bitrate: String, for id: String) {
        edit(id) { $0.audioBitrate = bitrate }
    }

    mutating func setSpeed(_ speed: Double, for id: String) {
        edit(id) { $0.speed = speed }
    }

    mutating func setLoudness(_ loudness: Int, for id: String) {
        edit(id) { $0.loudness = loudness }
    }

    /// Nil is the system's language (P158).
    mutating func setLanguage(_ language: String?, for id: String) {
        edit(id) { $0.language = language }
    }

    /// The tool's own target is stored as nil, so the preset keeps deciding it (P159).
    mutating func setOutputFormat(_ format: FormatID, for id: String) {
        let own = ToolCatalog.info(id).map(ToolCatalog.outputFormats(of:))?.first
        edit(id) { $0.outputFormat = format == own ? nil : format }
    }

    /// The format a tool's output-format picker shows: the stored one when the tool offers it, else its own target.
    func outputFormat(of id: String) -> FormatID? {
        let offered = ToolCatalog.info(id).map(ToolCatalog.outputFormats(of:)) ?? []
        return options(of: id).outputFormat.flatMap { offered.contains($0) ? $0 : nil } ?? offered.first
    }

    /// "" is Fit the subject, stored as no shape (P266).
    mutating func setShape(_ shape: String, for id: String) {
        edit(id) { $0.aspect = shape.isEmpty ? nil : shape }
    }

    /// The shape a Shape picker shows: the stored one when the tool offers it, else its first, Fit the subject.
    func shape(of id: String) -> String {
        var offered: [String] = []
        for case .cropShape(let shapes) in ToolCatalog.info(id)?.settings ?? [] { offered = shapes }
        return options(of: id).aspect.flatMap { offered.contains($0) ? $0 : nil } ?? offered.first ?? ""
    }

    /// Stores the whole options value, starting from the current one: `ToolCatalog.presets` renames a speed tool
    /// only when the stored options carry a speed.
    private mutating func edit(_ id: String, _ change: (inout PresetOptions) -> Void) {
        var options = options(of: id)
        change(&options)
        settings.toolOptions[id] = options
    }

    mutating func setReplaceOriginal(_ replace: Bool) {
        settings.replaceOriginal = replace
    }

    /// Clears the options and Replace the original; the trigger, the wheel order, `toolVisibility` (it drives the
    /// built-in wheels, P179) and the other settings stay.
    mutating func restoreDefaults() {
        settings.toolOptions = [:]
        settings.replaceOriginal = false
    }

    // MARK: - Labels

    static func percentLabel(_ quality: Double) -> String { "\(Int((quality * 100).rounded()))%" }

    static func videoSizeLabel(_ height: Int) -> String { height == 2160 ? "4K" : "\(height)p" }

    static func bitrateLabel(_ bitrate: String) -> String { "\(bitrate.dropLast()) kbps" }

    static let systemLanguageLabel = "System language"

    /// "Excel", "CSV", "JSON": the format's name, as the Convert page shows it.
    static func formatLabel(_ format: FormatID) -> String {
        FormatRegistry.builtIn.format(id: format)?.displayName ?? format.rawValue.uppercased()
    }

    static func shapeLabel(_ shape: String) -> String {
        switch shape {
        case "": "Fit the subject"
        case "1:1": "Square"
        default: shape
        }
    }

    static func speedLabel(_ speed: Double) -> String { String(format: "%g", speed) + "\u{00D7}" }

    static func loudnessLabel(_ lufs: Int) -> String {
        let level = "\u{2212}\(abs(lufs)) LUFS"
        return switch lufs {
        case -16: "Voice and podcasts (\(level))"
        case -14: "Music streaming (\(level))"
        case -23: "Broadcast (\(level))"
        default: level
        }
    }

    /// The order the loudness choices are listed in, whatever order the catalog stores them in.
    static func loudnessChoices(_ values: [Int]) -> [Int] {
        let preferred = [-16, -14, -23]
        return preferred.filter(values.contains) + values.filter { !preferred.contains($0) }
    }
}
