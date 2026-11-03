// The hub's size estimate ("About 860 KB, 64% smaller"): a rough output size from facts the wheel gathers off the
// main thread, never from running the conversion. Pure; only Foundation and PomeloCore.
import Foundation
import PomeloCore

/// What the readability pass learned about one source file without decoding it.
public struct SourceFacts: Equatable, Sendable {
    public var bytes: Int64?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?

    public init(bytes: Int64? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, durationSeconds: Double? = nil) {
        self.bytes = bytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
    }
}

public enum SizeEstimate {
    /// More files than this get no estimate (the facts cover the first 50).
    public static let maxFiles = 50

    /// An estimate this close to the source can't say whether the result comes out smaller, and a compress result
    /// that isn't smaller is not published (`onlyIfSmaller`), so it has no estimate.
    private static let compressCeiling = 0.95

    /// Conversions use this quality; tools use their configured one.
    private static let conversionQuality = 0.85

    /// JPEG bytes per pixel by quality.
    private static let bytesPerPixel: [(quality: Double, bytes: Double)] = [
        (0.5, 0.10), (0.6, 0.12), (0.7, 0.15), (0.8, 0.20), (0.85, 0.25), (0.9, 0.35), (1.0, 0.50),
    ]

    private static let wavBytesPerSecond = 176_400.0
    private static let flacRatio = 0.55
    private static let conversionAudioKbps = 192.0

    /// The estimated total output and the total source bytes of the files that produce it, or nil when the slice
    /// has no estimate: another target or tool, or a file lacking a fact its rule needs, or more than `maxFiles`.
    /// For a compress tool a file whose estimate reaches 95% of its source is left out of both totals (it may well
    /// not be published); when every file is left out there is no estimate.
    public static func estimate(
        target: FormatID?, preset: Preset?, sources: [(format: FileFormat, facts: SourceFacts)]
    ) -> (estimate: Int64, source: Int64)? {
        guard !sources.isEmpty, sources.count <= maxFiles else { return nil }
        let isCompress = preset.map { $0.id == "compress" || $0.id == "compress-more" } ?? false
        var estimate = 0.0
        var source: Int64 = 0
        var counted = 0
        for (format, facts) in sources {
            guard let bytes = facts.bytes, bytes > 0,
                  let output = outputBytes(format: format, facts: facts, bytes: bytes, target: target, preset: preset)
            else { return nil }
            if isCompress && output >= compressCeiling * Double(bytes) { continue }
            estimate += output
            source += bytes
            counted += 1
        }
        return counted > 0 ? (Int64(estimate.rounded()), source) : nil
    }

    /// "About 860 KB, 64% smaller", "About 2.5 MB, 25% larger", or "About 1 MB" when the change rounds to 0%.
    public static func text(estimate: Int64, source: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)
        guard source > 0 else { return "About \(size)" }
        let change = Int((Double(source - estimate) / Double(source) * 100).rounded())
        if change > 0 { return "About \(size), \(change)% smaller" }
        if change < 0 { return "About \(size), \(-change)% larger" }
        return "About \(size)"
    }

    // MARK: Rules

    private static func outputBytes(format: FileFormat, facts: SourceFacts, bytes: Int64, target: FormatID?,
                                    preset: Preset?) -> Double? {
        if let preset {
            let options = preset.options
            switch preset.id {
            case "half-size":
                return format.category == .image ? 0.3 * Double(bytes) : nil
            case "compress", "compress-more":
                return compressed(format: format, facts: facts, bytes: bytes, options: options)
            case "extract-audio":
                guard format.category == .video, let kbps = kilobitsPerSecond(options.audioBitrate) else { return nil }
                return facts.durationSeconds.map { audioBytes(kbps: kbps, seconds: $0) }
            default:
                return nil
            }
        }
        guard let target else { return nil }
        switch format.category {
        case .image:
            return pixels(of: facts).flatMap { imageBytes(as: target, pixels: $0, quality: conversionQuality) }
        case .audio:
            return facts.durationSeconds.flatMap { audioBytes(as: target, seconds: $0) }
        default:
            return nil
        }
    }

    private static func compressed(format: FileFormat, facts: SourceFacts, bytes: Int64, options: PresetOptions)
        -> Double? {
        switch format.category {
        case .image:
            if format.id == "png" { return 0.35 * Double(bytes) }
            guard ["jpg", "heic", "avif"].contains(format.id.rawValue) else { return nil }
            return pixels(of: facts).flatMap { imageBytes(as: format.id, pixels: $0, quality: options.quality) }
        case .video:
            guard let seconds = facts.durationSeconds, let height = options.videoMaxHeight,
                  let megabits = videoMegabitsPerSecond(maxHeight: height) else { return nil }
            return min((megabits + 0.128) * seconds / 8 * 1_000_000, Double(bytes))
        default:
            return nil
        }
    }

    private static func videoMegabitsPerSecond(maxHeight: Int) -> Double? {
        switch maxHeight {
        case 2160: 16
        case 1080: 6
        case 720: 3
        default: nil
        }
    }

    private static func pixels(of facts: SourceFacts) -> Double? {
        guard let width = facts.pixelWidth, let height = facts.pixelHeight, width > 0, height > 0 else { return nil }
        return Double(width) * Double(height)
    }

    private static func imageBytes(as target: FormatID, pixels: Double, quality: Double) -> Double? {
        switch target.rawValue {
        case "jpg": pixels * jpegBytesPerPixel(quality: quality)
        case "heic": 0.5 * pixels * jpegBytesPerPixel(quality: quality)
        case "avif": 0.45 * pixels * jpegBytesPerPixel(quality: quality)
        case "webp": 0.7 * pixels * jpegBytesPerPixel(quality: 0.8)
        case "jp2": 0.6 * pixels * jpegBytesPerPixel(quality: quality)
        case "bmp", "tga": 3 * pixels + 54
        default: nil
        }
    }

    /// Linear between the table's points, held flat outside them.
    private static func jpegBytesPerPixel(quality: Double) -> Double {
        let table = bytesPerPixel
        if quality <= table[0].quality { return table[0].bytes }
        for (lower, upper) in zip(table, table.dropFirst()) where quality <= upper.quality {
            let fraction = (quality - lower.quality) / (upper.quality - lower.quality)
            return lower.bytes + fraction * (upper.bytes - lower.bytes)
        }
        return table[table.count - 1].bytes
    }

    private static func audioBytes(as target: FormatID, seconds: Double) -> Double? {
        switch target.rawValue {
        case "m4a", "mp3", "ogg", "opus", "wma": audioBytes(kbps: conversionAudioKbps, seconds: seconds)
        case "wav", "aiff", "caf": wavBytesPerSecond * seconds
        case "flac": flacRatio * wavBytesPerSecond * seconds
        default: nil
        }
    }

    private static func audioBytes(kbps: Double, seconds: Double) -> Double {
        kbps * seconds / 8 * 1000
    }

    /// "192k" as 192.
    private static func kilobitsPerSecond(_ bitrate: String) -> Double? {
        Double(bitrate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "k")))
    }
}
