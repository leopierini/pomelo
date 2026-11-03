import Foundation

public enum VideoCodec: String, Codable, Sendable {
    case h264, hevc
}

/// Tunable settings of a conversion. Plugin argument templates read them through `templateValue(for:)`.
public struct PresetOptions: Codable, Sendable, Equatable {
    /// 0...1
    public var quality: Double
    /// Resize factor for image tools; nil keeps the size.
    public var scale: Double?
    public var maxPixelSize: Int?
    public var stripMetadata: Bool
    public var videoCodec: VideoCodec
    public var videoMaxHeight: Int?
    public var audioBitrate: String
    public var pdfRenderDPI: Int
    /// Playback speed factor for the speed tools; nil keeps the speed.
    public var speed: Double?
    /// Integrated loudness target in LUFS.
    public var loudness: Int
    /// What an editor decided (Phase 4): trim range, split points, crop rectangle, redaction boxes, page list, new size or turn.
    public var edit: EditSpec?
    /// The size "Compress to size" must stay at or under, in bytes (decimal units, as Finder shows them).
    public var targetBytes: Int64?
    /// A BCP-47 identifier (P158): the spoken language for the speech tools, the target for Translate. Nil means the
    /// system's language.
    public var language: String?
    /// The target a tool's setting picks among the formats its edges allow (P159); nil keeps the preset's own.
    public var outputFormat: FormatID?
    /// Smart crop's Shape (P266): "1:1", "4:5", "4:3" or "16:9"; nil fits the subject.
    public var aspect: String?

    // Out of line: inlined, the calls in `Preset.builtIns` made its initializer 15 KB of code per architecture.
    @inline(never)
    public init(
        quality: Double = 0.85,
        scale: Double? = nil,
        maxPixelSize: Int? = nil,
        stripMetadata: Bool = false,
        videoCodec: VideoCodec = .h264,
        videoMaxHeight: Int? = nil,
        audioBitrate: String = "192k",
        pdfRenderDPI: Int = 150,
        speed: Double? = nil,
        loudness: Int = -16,
        edit: EditSpec? = nil,
        targetBytes: Int64? = nil,
        language: String? = nil,
        outputFormat: FormatID? = nil,
        aspect: String? = nil
    ) {
        self.quality = quality
        self.scale = scale
        self.maxPixelSize = maxPixelSize
        self.stripMetadata = stripMetadata
        self.videoCodec = videoCodec
        self.videoMaxHeight = videoMaxHeight
        self.audioBitrate = audioBitrate
        self.pdfRenderDPI = pdfRenderDPI
        self.speed = speed
        self.loudness = loudness
        self.edit = edit
        self.targetBytes = targetBytes
        self.language = language
        self.outputFormat = outputFormat
        self.aspect = aspect
    }

    /// Every key is optional so that blobs saved by older versions keep decoding.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PresetOptions()
        quality = try container.decodeIfPresent(Double.self, forKey: .quality) ?? defaults.quality
        scale = try container.decodeIfPresent(Double.self, forKey: .scale)
        maxPixelSize = try container.decodeIfPresent(Int.self, forKey: .maxPixelSize)
        stripMetadata = try container.decodeIfPresent(Bool.self, forKey: .stripMetadata) ?? defaults.stripMetadata
        videoCodec = try container.decodeIfPresent(VideoCodec.self, forKey: .videoCodec) ?? defaults.videoCodec
        videoMaxHeight = try container.decodeIfPresent(Int.self, forKey: .videoMaxHeight)
        audioBitrate = try container.decodeIfPresent(String.self, forKey: .audioBitrate) ?? defaults.audioBitrate
        pdfRenderDPI = try container.decodeIfPresent(Int.self, forKey: .pdfRenderDPI) ?? defaults.pdfRenderDPI
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        loudness = try container.decodeIfPresent(Int.self, forKey: .loudness) ?? defaults.loudness
        edit = try container.decodeIfPresent(EditSpec.self, forKey: .edit)
        targetBytes = try container.decodeIfPresent(Int64.self, forKey: .targetBytes)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        outputFormat = try container.decodeIfPresent(FormatID.self, forKey: .outputFormat)
        aspect = try container.decodeIfPresent(String.self, forKey: .aspect)
    }

    /// The value substituted for a `{name}` placeholder in a plugin argument, or nil for unknown or unset keys.
    /// `quality` is rendered as a 0...100 integer; integral numbers carry no trailing `.0`.
    public func templateValue(for key: String) -> String? {
        switch key {
        case "quality": String(Int((quality * 100).rounded()))
        case "scale": scale.map(Self.render)
        case "maxPixelSize": maxPixelSize.map(String.init)
        case "videoMaxHeight": videoMaxHeight.map(String.init)
        case "audioBitrate": audioBitrate
        case "pdfRenderDPI": String(pdfRenderDPI)
        case "speed": speed.map(Self.render)
        case "loudness": String(loudness)
        case "targetBytes": targetBytes.map(String.init)
        case "trimStart": trimRange.map { Self.seconds($0.start) }
        case "trimEnd": trimRange.map { Self.seconds($0.end) }
        case "trimDuration": trimRange.map { Self.seconds($0.end - $0.start) }
        default: nil
        }
    }

    private var trimRange: TimeRange? {
        if case .trim(let range) = edit { range } else { nil }
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func render(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}

public enum PresetDelivery: String, Codable, Sendable {
    case file, clipboard
}

/// A named conversion recipe offered by the app and the CLI.
public struct Preset: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// nil means "same format as the source".
    public var target: FormatID?
    public var options: PresetOptions
    /// Used in the output name of same-format tools (`photo-half.jpg`).
    public var nameSuffix: String?
    /// The source categories the preset applies to (the wheel offers it only for those); nil means any category.
    public var categories: [FormatCategory]?
    /// The operation edge a tool runs; nil for a conversion.
    public var operation: String?
    /// One output for all the dragged files (a merge) instead of one per file.
    public var combinesInputs: Bool
    public var delivery: PresetDelivery
    /// A result that is not smaller than its source is not published.
    public var onlyIfSmaller: Bool
    public var outputNaming: OutputNaming
    /// An editor tool: it runs only once the person (or `--options`) supplies an `edit` or a `targetBytes`.
    public var needsInput: Bool

    // Out of line, like `PresetOptions.init`: `builtIns` calls it for every preset.
    @inline(never)
    public init(
        id: String, name: String, target: FormatID?, options: PresetOptions = PresetOptions(),
        nameSuffix: String? = nil, categories: [FormatCategory]? = nil, operation: String? = nil,
        combinesInputs: Bool = false, delivery: PresetDelivery = .file, onlyIfSmaller: Bool = false,
        outputNaming: OutputNaming = .fromSource, needsInput: Bool = false
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.options = options
        self.nameSuffix = nameSuffix
        self.categories = categories
        self.operation = operation
        self.combinesInputs = combinesInputs
        self.delivery = delivery
        self.onlyIfSmaller = onlyIfSmaller
        self.outputNaming = outputNaming
        self.needsInput = needsInput
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        target = try container.decodeIfPresent(FormatID.self, forKey: .target)
        options = try container.decode(PresetOptions.self, forKey: .options)
        nameSuffix = try container.decodeIfPresent(String.self, forKey: .nameSuffix)
        categories = try container.decodeIfPresent([FormatCategory].self, forKey: .categories)
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        combinesInputs = try container.decodeIfPresent(Bool.self, forKey: .combinesInputs) ?? false
        delivery = try container.decodeIfPresent(PresetDelivery.self, forKey: .delivery) ?? .file
        onlyIfSmaller = try container.decodeIfPresent(Bool.self, forKey: .onlyIfSmaller) ?? false
        outputNaming = try container.decodeIfPresent(OutputNaming.self, forKey: .outputNaming) ?? .fromSource
        needsInput = try container.decodeIfPresent(Bool.self, forKey: .needsInput) ?? false
    }

    public static let builtIns: [Preset] = [
        Preset(id: "jpg-80", name: "JPG 80%", target: "jpg", options: PresetOptions(quality: 0.8), categories: [.image]),
        Preset(id: "png", name: "PNG", target: "png", categories: [.image]),
        Preset(id: "heic", name: "HEIC", target: "heic", categories: [.image]),
        Preset(
            id: "webp-80", name: "WebP 80%", target: "webp", options: PresetOptions(quality: 0.8),
            categories: [.image]
        ),
        Preset(
            id: "compress", name: "Compress", target: nil,
            options: PresetOptions(quality: 0.7, videoCodec: .hevc, videoMaxHeight: 1080), nameSuffix: "compressed",
            categories: [.image, .pdf, .video], operation: "compress", onlyIfSmaller: true
        ),
        Preset(
            id: "compress-more", name: "Compress more", target: nil,
            options: PresetOptions(quality: 0.5, videoCodec: .hevc, videoMaxHeight: 720), nameSuffix: "compressed",
            categories: [.image, .video], operation: "compress", onlyIfSmaller: true
        ),
        Preset(
            id: "half-size", name: "Half size", target: nil, options: PresetOptions(scale: 0.5),
            nameSuffix: "half", categories: [.image]
        ),
        Preset(
            id: "remove-background", name: "Remove background", target: "png", nameSuffix: "cutout",
            categories: [.image], operation: "remove-background"
        ),
        Preset(
            id: "smart-crop", name: "Smart crop", target: nil, options: PresetOptions(quality: 0.92),
            nameSuffix: "cropped", categories: [.image], operation: "smart-crop"
        ),
        Preset(
            id: "straighten", name: "Straighten document", target: nil, options: PresetOptions(quality: 0.92),
            nameSuffix: "straightened", categories: [.image], operation: "straighten"
        ),
        Preset(id: "extract-audio", name: "Extract audio", target: "m4a", categories: [.video]),
        Preset(
            id: "remove-audio", name: "Remove audio", target: nil, nameSuffix: "no-audio", categories: [.video],
            operation: "remove-audio"
        ),
        Preset(
            id: "transcribe", name: "Transcribe", target: "txt", nameSuffix: "transcript", categories: [.audio, .video],
            operation: "transcribe"
        ),
        // No suffix: players pick up `clip.srt` next to `clip.mp4`.
        Preset(
            id: "make-subtitles", name: "Make subtitles", target: "srt", categories: [.audio, .video],
            operation: "subtitles"
        ),
        Preset(
            id: "snapshot", name: "Snapshot", target: "png", nameSuffix: "snapshot", categories: [.video],
            operation: "snapshot"
        ),
        Preset(
            id: "normalize-volume", name: "Normalize volume", target: nil, options: PresetOptions(loudness: -16),
            nameSuffix: "normalized", categories: [.audio, .video], operation: "normalize-volume"
        ),
        Preset(
            id: "speed-up", name: "Speed 2\u{00D7}", target: nil, options: PresetOptions(speed: 2), nameSuffix: "2x",
            categories: [.audio, .video], operation: "speed"
        ),
        Preset(
            id: "slow-down", name: "Speed 0.5\u{00D7}", target: nil, options: PresetOptions(speed: 0.5),
            nameSuffix: "0.5x", categories: [.audio, .video], operation: "speed"
        ),
        Preset(
            id: "mono", name: "Mono", target: nil, nameSuffix: "mono", categories: [.audio], operation: "mono"
        ),
        Preset(
            id: "strip-metadata", name: "Remove metadata", target: nil, nameSuffix: "no-metadata",
            categories: [.image, .video, .audio], operation: "strip-metadata"
        ),
        Preset(
            id: "read-codes", name: "Read codes", target: "txt", nameSuffix: "codes", categories: [.image, .pdf],
            operation: "read-codes", delivery: .clipboard
        ),
        Preset(
            id: "images-to-pdf", name: "Combine into PDF", target: "pdf", nameSuffix: "combined",
            categories: [.image], operation: "combine", combinesInputs: true
        ),
        Preset(
            id: "merge-pdfs", name: "Merge PDFs", target: "pdf", nameSuffix: "merged", categories: [.pdf],
            operation: "combine", combinesInputs: true
        ),
        Preset(
            id: "split-pdf", name: "Split PDF", target: nil, nameSuffix: "pages", categories: [.pdf],
            operation: "split"
        ),
        Preset(
            id: "extract-archive", name: "Extract", target: nil, categories: [.archive], operation: "extract",
            outputNaming: .fromOutput
        ),
        Preset(
            id: "trim", name: "Trim\u{2026}", target: nil, nameSuffix: "trimmed", categories: [.video, .audio],
            operation: "trim", needsInput: true
        ),
        Preset(
            id: "crop", name: "Crop\u{2026}", target: nil, options: PresetOptions(quality: 0.92), nameSuffix: "cropped",
            categories: [.image, .video], operation: "crop", needsInput: true
        ),
        Preset(
            id: "resize", name: "Resize\u{2026}", target: nil, options: PresetOptions(quality: 0.92),
            categories: [.image, .video], operation: "resize", outputNaming: .fromOutput, needsInput: true
        ),
        Preset(
            id: "rotate", name: "Rotate\u{2026}", target: nil, options: PresetOptions(quality: 0.92),
            nameSuffix: "rotated", categories: [.image, .video], operation: "rotate", needsInput: true
        ),
        Preset(
            id: "split-video", name: "Split\u{2026}", target: nil, nameSuffix: "parts", categories: [.video],
            operation: "split", needsInput: true
        ),
        Preset(
            id: "compress-to-size", name: "Compress to size\u{2026}", target: nil, nameSuffix: "smaller",
            categories: [.image, .pdf, .video], operation: "target-size", needsInput: true
        ),
        Preset(
            id: "redact", name: "Redact\u{2026}", target: nil, options: PresetOptions(quality: 0.92),
            nameSuffix: "redacted", categories: [.image], operation: "redact", needsInput: true
        ),
        Preset(
            id: "organize-pages", name: "Organize pages\u{2026}", target: "pdf", nameSuffix: "edited",
            categories: [.pdf], operation: "organize", needsInput: true
        ),
        Preset(
            id: "translate", name: "Translate", target: nil, nameSuffix: TranslationTarget.suffix(nil),
            categories: [.subtitle, .text, .document], operation: "translate"
        ),
        Preset(
            id: "scan-document", name: "Scan to Markdown", target: "md", categories: [.image, .pdf],
            operation: "scan-document"
        ),
        Preset(
            id: "extract-tables", name: "Extract tables", target: "xlsx", nameSuffix: "tables",
            categories: [.image, .pdf], operation: "extract-tables"
        ),
        Preset(
            id: "summarize", name: "Summarize", target: "md", nameSuffix: "summary",
            categories: [.document, .text, .pdf], operation: "summarize"
        ),
        Preset(
            id: "extract-data", name: "Extract data", target: "json", nameSuffix: "data", categories: [.image, .pdf],
            operation: "extract-data"
        ),
        Preset(
            id: "find-duplicates", name: "Find duplicates", target: "txt", nameSuffix: "duplicates", categories: [.image],
            operation: "find-duplicates", combinesInputs: true
        ),
    ]
}
