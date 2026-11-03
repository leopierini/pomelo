// The tool catalog (P31): every tool the wheel can show, in wheel order (the AI tools on the AI page, the rest on
// Tools, P177), with the kinds of file it applies to, where it is shown by default and what the user may tune. Engine
// tools run as presets (`Preset.builtIns`); file tools run through the app's `FileActions`. Only Foundation and
// PomeloCore: no AppKit.
import Foundation
import PomeloCore

/// A setting a tool offers in Settings, with the values it lets the user pick.
public enum ToolSetting: Sendable, Equatable {
    case imageQuality(range: ClosedRange<Double>, step: Double)
    case videoMaxHeight([Int])
    case audioBitrate([String])
    case speed([Double])
    case loudness([Int])
    /// The language Translate writes (P158), from the languages Translation offers; nil is the system's.
    case targetLanguage
    /// The language the speech tools listen for (P158), from the languages the recognizer offers; nil is the system's.
    case spokenLanguage
    /// The formats the tool's edges make, the first being the preset's own target (P159).
    case outputFormat([FormatID])
    /// Smart crop's Shape (P266), stored in `PresetOptions.aspect`: "" fits the subject (stored as nil), the first
    /// value is the default.
    case cropShape([String])
}

public struct ToolInfo: Sendable {
    public var id: String
    public var name: String
    /// An SF Symbol name that exists on macOS 14.
    public var symbol: String
    /// The present participle shown while the tool runs ("Compressing").
    public var verb: String
    /// The kinds of file the tool applies to; nil means every kind.
    public var kinds: Set<FormatCategory>?
    public var shownByDefault: Set<FormatCategory>
    /// An on-device intelligence tool: the wheel shows it on the AI page, never on Tools (P177).
    public var isAI: Bool
    /// Set for a file tool; nil for an engine tool.
    public var action: FileActionKind?
    public var settings: [ToolSetting]
    public var canReplaceOriginal: Bool
    /// Set for a tool that opens an editor instead of running (its name ends with "…").
    public var editor: EditorKind?
    /// The hub's subtitle for an editor, while its slice is hovered.
    public var hint: String?
    /// False for a tool that works on one file at a time (the single-file editors).
    public var acceptsSeveralFiles: Bool

    // Out of line: inlined, the calls in `ToolCatalog.all` made its initializer 13 KB of code per architecture.
    @inline(never)
    public init(
        id: String, name: String, symbol: String, verb: String, kinds: Set<FormatCategory>?,
        shownByDefault: Set<FormatCategory>, action: FileActionKind? = nil, settings: [ToolSetting] = [],
        canReplaceOriginal: Bool = false, editor: EditorKind? = nil, hint: String? = nil,
        acceptsSeveralFiles: Bool = true, isAI: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.verb = verb
        self.kinds = kinds
        self.shownByDefault = shownByDefault
        self.isAI = isAI
        self.action = action
        self.settings = settings
        self.canReplaceOriginal = canReplaceOriginal
        self.editor = editor
        self.hint = hint
        self.acceptsSeveralFiles = acceptsSeveralFiles
    }
}

/// Which tools a built-in wheel shows per kind of file: the user's overrides of each tool's `shownByDefault`. A
/// customized wheel shows its own slots instead (P176).
public struct ToolVisibility: Sendable, Equatable {
    /// Kind raw value → tool id → shown. Kinds and ids the catalog doesn't know are ignored.
    private let overrides: [String: [String: Bool]]

    public init(overrides: [String: [String: Bool]]) {
        self.overrides = overrides
    }

    public static let defaults = ToolVisibility(overrides: [:])

    public func isShown(_ id: String, for kind: FormatCategory) -> Bool {
        guard let info = ToolCatalog.info(id) else { return false }
        return overrides[kind.rawValue]?[id] ?? info.shownByDefault.contains(kind)
    }
}

public enum ToolCatalog {
    /// A built-in wheel's Tools or AI page shows at most this many tools, in catalog order (a shown Shelf last, R27),
    /// however many are enabled.
    public static let maxShownPerKind = 8

    private static let everyKind = Set(FormatCategory.allCases)

    /// Kinds with few engine tools: their Tools page also shows the clipboard and Finder tools so the wheel isn't bare.
    private static let sparseKinds: Set<FormatCategory> = [.document, .text, .archive, .data, .subtitle, .font, .other]

    private static func qualityAndHeight() -> [ToolSetting] {
        [.imageQuality(range: 0.4...0.9, step: 0.05), .videoMaxHeight([2160, 1080, 720])]
    }

    // Out of line, like `ToolInfo.init` and `editorTool`: `all` calls them for every tool.
    @inline(never)
    private static func fileTool(
        _ id: String, _ name: String, _ symbol: String, _ verb: String, _ action: FileActionKind,
        shownFor: Set<FormatCategory> = []
    ) -> ToolInfo {
        ToolInfo(id: id, name: name, symbol: symbol, verb: verb, kinds: nil, shownByDefault: shownFor, action: action)
    }

    /// An AI tool is shown by default for every kind it applies to (P177): its page has room for them all.
    @inline(never)
    private static func aiTool(
        _ id: String, _ name: String, _ symbol: String, _ verb: String, kinds: Set<FormatCategory>,
        settings: [ToolSetting] = []
    ) -> ToolInfo {
        ToolInfo(id: id, name: name, symbol: symbol, verb: verb, kinds: kinds, shownByDefault: kinds,
                 settings: settings, isAI: true)
    }

    /// Editors never replace the original, whatever the setting (Phase 4 safety rule).
    @inline(never)
    private static func editorTool(
        _ id: String, _ name: String, _ symbol: String, _ verb: String, _ editor: EditorKind, _ hint: String,
        kinds: Set<FormatCategory>, shownFor: Set<FormatCategory>, severalFiles: Bool = false
    ) -> ToolInfo {
        ToolInfo(id: id, name: name, symbol: symbol, verb: verb, kinds: kinds, shownByDefault: shownFor,
                 editor: editor, hint: hint, acceptsSeveralFiles: severalFiles)
    }

    /// Every tool, in wheel order (clockwise from 12 o'clock). Each editor sits next to its instant relatives.
    public static let all: [ToolInfo] = [
        editorTool("trim", "Trim\u{2026}", "timeline.selection", "Trimming", .trim, "Choose the part to keep",
                   kinds: [.video, .audio], shownFor: [.video, .audio]),
        editorTool("split-video", "Split\u{2026}", "scissors", "Splitting", .split, "Choose where to cut",
                   kinds: [.video], shownFor: []),
        editorTool("crop", "Crop\u{2026}", "crop", "Cropping", .crop, "Choose the area to keep",
                   kinds: [.image, .video], shownFor: [.image, .video]),
        ToolInfo(
            id: "compress", name: "Compress", symbol: "rectangle.compress.vertical", verb: "Compressing",
            kinds: [.image, .pdf, .video], shownByDefault: [.image, .pdf, .video], settings: qualityAndHeight(),
            canReplaceOriginal: true
        ),
        ToolInfo(
            id: "compress-more", name: "Compress more", symbol: "arrow.down.to.line", verb: "Compressing",
            kinds: [.image, .video], shownByDefault: [], settings: qualityAndHeight(),
            canReplaceOriginal: true
        ),
        editorTool("compress-to-size", "Compress to size\u{2026}", "gauge.with.dots.needle.33percent", "Compressing",
                   .targetSize, "Choose a size", kinds: [.image, .pdf, .video], shownFor: [.image, .pdf, .video],
                   severalFiles: true),
        editorTool("resize", "Resize\u{2026}", "arrow.up.left.and.arrow.down.right", "Resizing", .resize,
                   "Choose a size", kinds: [.image, .video], shownFor: [.image], severalFiles: true),
        editorTool("rotate", "Rotate\u{2026}", "rotate.right", "Rotating", .rotate, "Choose a turn",
                   kinds: [.image, .video], shownFor: [.image, .video], severalFiles: true),
        ToolInfo(
            id: "half-size", name: "Half size", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing",
            kinds: [.image], shownByDefault: [], canReplaceOriginal: true
        ),
        aiTool("remove-background", "Remove background", "person.and.background.dotted", "Removing background",
               kinds: [.image]),
        aiTool("smart-crop", "Smart crop", "viewfinder", "Cropping", kinds: [.image],
               settings: [.cropShape(["", "1:1", "4:5", "4:3", "16:9"])]),
        aiTool("straighten", "Straighten document", "doc.viewfinder", "Straightening", kinds: [.image]),
        editorTool("redact", "Redact\u{2026}", "eye.slash", "Redacting", .redact, "Choose what to hide",
                   kinds: [.image], shownFor: [.image]),
        ToolInfo(
            id: "extract-audio", name: "Extract audio", symbol: "music.note", verb: "Extracting audio",
            kinds: [.video], shownByDefault: [.video], settings: [.audioBitrate(["128k", "192k", "256k"])]
        ),
        ToolInfo(
            id: "remove-audio", name: "Remove audio", symbol: "speaker.slash", verb: "Removing audio",
            kinds: [.video], shownByDefault: [.video], canReplaceOriginal: true
        ),
        aiTool("transcribe", "Transcribe", "text.bubble", "Transcribing", kinds: [.audio, .video],
               settings: [.spokenLanguage]),
        aiTool("make-subtitles", "Make subtitles", "captions.bubble", "Making subtitles", kinds: [.audio, .video],
               settings: [.spokenLanguage, .outputFormat(["srt", "vtt"])]),
        ToolInfo(
            id: "snapshot", name: "Snapshot", symbol: "camera", verb: "Taking a snapshot", kinds: [.video],
            shownByDefault: []
        ),
        ToolInfo(
            id: "normalize-volume", name: "Normalize volume", symbol: "speaker.wave.2", verb: "Normalizing volume",
            kinds: [.audio, .video], shownByDefault: [.audio], settings: [.loudness([-14, -16, -23])],
            canReplaceOriginal: true
        ),
        ToolInfo(
            id: "speed-up", name: "Speed 2\u{00D7}", symbol: "hare", verb: "Changing speed",
            kinds: [.audio, .video], shownByDefault: [.audio], settings: [.speed([1.25, 1.5, 2, 3])],
            canReplaceOriginal: true
        ),
        ToolInfo(
            id: "slow-down", name: "Speed 0.5\u{00D7}", symbol: "tortoise", verb: "Changing speed",
            kinds: [.audio, .video], shownByDefault: [.audio], settings: [.speed([0.5, 0.75])],
            canReplaceOriginal: true
        ),
        ToolInfo(
            id: "mono", name: "Mono", symbol: "speaker.wave.1", verb: "Making mono", kinds: [.audio],
            shownByDefault: [.audio], canReplaceOriginal: true
        ),
        ToolInfo(
            id: "strip-metadata", name: "Remove metadata", symbol: "tag.slash", verb: "Removing metadata",
            kinds: [.image, .video, .audio], shownByDefault: [.audio], canReplaceOriginal: true
        ),
        ToolInfo(
            id: "read-codes", name: "Read codes", symbol: "qrcode.viewfinder", verb: "Reading codes",
            kinds: [.image, .pdf], shownByDefault: [.pdf]
        ),
        aiTool("translate", "Translate", "character.bubble", "Translating", kinds: [.subtitle, .text, .document],
               settings: [.targetLanguage]),
        aiTool("summarize", "Summarize", "text.append", "Summarizing", kinds: [.document, .text, .pdf]),
        aiTool("scan-document", "Scan to Markdown", "doc.text.viewfinder", "Scanning", kinds: [.image, .pdf]),
        aiTool("extract-tables", "Extract tables", "tablecells", "Extracting tables", kinds: [.image, .pdf],
               settings: [.outputFormat(["xlsx", "csv"])]),
        aiTool("extract-data", "Extract data", "list.bullet.rectangle", "Extracting data", kinds: [.image, .pdf],
               settings: [.outputFormat(["json", "csv"])]),
        aiTool("find-duplicates", "Find duplicates", "square.on.square", "Looking for duplicates", kinds: [.image]),
        ToolInfo(
            id: "images-to-pdf", name: "Combine into PDF", symbol: "rectangle.stack", verb: "Making a PDF",
            kinds: [.image], shownByDefault: [.image]
        ),
        ToolInfo(
            id: "merge-pdfs", name: "Merge PDFs", symbol: "arrow.triangle.merge", verb: "Merging PDFs",
            kinds: [.pdf], shownByDefault: [.pdf]
        ),
        ToolInfo(
            id: "split-pdf", name: "Split PDF", symbol: "arrow.triangle.branch", verb: "Splitting PDF",
            kinds: [.pdf], shownByDefault: [.pdf]
        ),
        editorTool("organize-pages", "Organize pages\u{2026}", "square.grid.2x2", "Saving pages", .organizePages,
                   "Reorder, rotate or remove pages", kinds: [.pdf], shownFor: [.pdf]),
        ToolInfo(
            id: "extract-archive", name: "Extract", symbol: "archivebox", verb: "Extracting", kinds: [.archive],
            shownByDefault: [.archive]
        ),
        fileTool("make-zip", "Make Zip", "doc.zipper", "Zipping", .makeZip, shownFor: everyKind.subtracting([.archive, .video, .image])),
        fileTool("shelf", "Shelf", "tray.and.arrow.down", "Adding to the Shelf", .shelf, shownFor: everyKind),
        fileTool("copy-paths", "Copy Paths", "doc.on.clipboard", "Copying paths", .copyPaths, shownFor: sparseKinds),
        fileTool("copy-files", "Copy Files", "doc.on.doc", "Copying files", .copyFiles, shownFor: sparseKinds),
        fileTool("reveal-in-finder", "Show in Finder", "folder", "Showing in Finder", .revealInFinder, shownFor: sparseKinds),
        fileTool("open-in-terminal", "Open in Terminal", "terminal", "Opening Terminal", .openTerminal, shownFor: sparseKinds),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func info(_ id: String) -> ToolInfo? { byID[id] }

    public static func info(for action: FileActionKind) -> ToolInfo {
        guard let info = all.first(where: { $0.action == action }) else {
            preconditionFailure("no catalog entry for the file tool \(action)")
        }
        return info
    }

    /// The symbol of a preset: its tool's, else a generic one for presets the catalog doesn't know.
    public static func symbol(ofPreset id: String) -> String {
        info(id)?.symbol ?? "slider.horizontal.3"
    }

    /// Every engine tool as a preset, in catalog order, with the user's options. The speed tools are named after
    /// their speed, Translate after its target language (with its suffix, R-pre-3), and a tool's output-format setting
    /// becomes its target when the tool makes that format (P159, as the CLI does). Visibility is the wheel builder's
    /// business, per kind.
    public static func presets(
        settings: AppSettings, preferredLanguages: [String] = Locale.preferredLanguages, locale: Locale = .current
    ) -> [Preset] {
        let builtIns = Dictionary(uniqueKeysWithValues: Preset.builtIns.map { ($0.id, $0) })
        return all.compactMap { info in
            guard info.action == nil, var preset = builtIns[info.id] else { return nil }
            preset.options = settings.toolOptions[info.id] ?? preset.options
            if preset.operation == "speed", let speed = preset.options.speed {
                let label = formatted(speed)
                preset.name = "Speed \(label)\u{00D7}"
                preset.nameSuffix = "\(label)x"
            }
            if preset.operation == "translate" {
                // The system's language is fixed here, so the job translates into the language the name and the
                // suffix say, even when the system's changes before the wheel is planned again.
                let language = TranslationTarget.identifier(preset.options.language, preferred: preferredLanguages)
                preset.options.language = language
                preset.name = "Translate to \(TranslationTarget.name(language, locale: locale))"
                preset.nameSuffix = TranslationTarget.suffix(language)
            }
            if let wanted = preset.options.outputFormat {
                // A stored format the tool can't make (an older choice, a hand-edited blob) is dropped, not run.
                if outputFormats(of: info).contains(wanted) {
                    preset.target = wanted
                } else {
                    preset.options.outputFormat = nil
                }
            }
            return preset
        }
    }

    /// The formats a tool's output-format setting offers; empty for a tool without one.
    public static func outputFormats(of info: ToolInfo) -> [FormatID] {
        for case .outputFormat(let formats) in info.settings { return formats }
        return []
    }

    /// Why this Mac can't run `preset` at all, for Settings: when every route the tool has from a format of its kinds
    /// passes an engine this Mac can't run, the first such engine's reason. `planner` covers every engine
    /// (`includingMissing`). Nil when some route can run, or the tool has none.
    public static func unsupportedReason(
        of preset: Preset, formats: FormatRegistry, planner: RoutePlanner, reasons: [EngineID: String]
    ) -> String? {
        guard !reasons.isEmpty else { return nil }
        let kinds = Set(preset.categories ?? FormatCategory.allCases)
        var first: String?
        for format in formats.all where kinds.contains(format.category) {
            guard let route = planner.route(from: format.id, operation: preset.operation, target: preset.target) else {
                continue
            }
            guard let reason = route.edges.lazy.compactMap({ reasons[$0.engineID] }).first else { return nil }
            first = first ?? reason
        }
        return first
    }

    /// 2 as "2", 1.5 as "1.5".
    private static func formatted(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
