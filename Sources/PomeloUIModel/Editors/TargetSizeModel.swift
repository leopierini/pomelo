// What the Compress to size editor's field says and what that means for the files (P27): the target in bytes, the
// chips, why Save is disabled and what the result will be like. No AppKit; the app's session wraps it in a view.
import Foundation
import PomeloCore

public enum SizeUnit: String, CaseIterable, Sendable {
    case kb = "KB", mb = "MB"

    public var bytes: Int64 {
        switch self {
        case .kb: 1_000
        case .mb: 1_000_000
        }
    }
}

/// What the model needs to know about one file. Until the file has been read, everything but `bytes` is nil and
/// `hasAudio` false.
public struct SourceSize: Equatable, Sendable {
    public var bytes: Int64
    public var durationSeconds: Double?
    /// The encoded (stored) size of a video, as the engine plans it, not the upright one.
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var hasAudio: Bool

    public init(bytes: Int64, durationSeconds: Double? = nil, width: Int? = nil, height: Int? = nil,
                frameRate: Double? = nil, hasAudio: Bool = false) {
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.hasAudio = hasAudio
    }
}

public struct TargetSizeModel: Equatable, Sendable {
    public private(set) var category: FormatCategory
    public private(set) var sources: [SourceSize]
    public let locale: Locale
    public var text: String
    public var unit: SizeUnit

    public init(category: FormatCategory, sources: [SourceSize], remembered: Int64?, locale: Locale = .current) {
        self.category = category
        self.sources = sources
        self.locale = locale
        let (text, unit) = Self.fields(for: remembered ?? Self.defaultBytes(for: category), locale: locale)
        self.text = text
        self.unit = unit
    }

    public mutating func update(sources: [SourceSize]) {
        self.sources = sources
    }

    /// Fills the field with `bytes`, in the largest unit that keeps it whole (or to one decimal).
    public mutating func choose(_ bytes: Int64) {
        (text, unit) = Self.fields(for: bytes, locale: locale)
    }

    public var chips: [Int64] {
        switch category {
        case .pdf: [1_000_000, 2_000_000, 5_000_000, 10_000_000]
        case .video: [10_000_000, 20_000_000, 50_000_000, 100_000_000]
        default: [20_000, 50_000, 100_000, 500_000]
        }
    }

    /// nil while the field is empty or not a number.
    public var targetBytes: Int64? {
        guard let value = Self.parse(text) else { return nil }
        let bytes = (value * Double(unit.bytes)).rounded()
        return bytes < 9e15 ? Int64(bytes) : nil
    }

    public var blocker: String? {
        guard let target = targetBytes else { return "Enter a size" }
        let minimum = minimumBytes
        if target < minimum { return "At least \(TargetSize.label(bytes: minimum, locale: locale))" }
        let label = TargetSize.label(bytes: target, locale: locale)
        if sources.allSatisfy({ $0.bytes <= target }) {
            return sources.count == 1 ? "It's already under \(label)" : "They're all under \(label)"
        }
        if category == .video, sources.count == 1, let source = sources.first, hasVideoFacts(source),
           plan(for: source, target: target) == nil {
            return "It's too long to fit in \(label)"
        }
        return nil
    }

    public var note: String? {
        guard let target = targetBytes else { return nil }
        if sources.count > 1 { return "Each file under \(TargetSize.label(bytes: target, locale: locale))" }
        switch category {
        case .pdf:
            return "Shrinks the images inside; text stays sharp"
        case .video:
            guard let source = sources.first, hasVideoFacts(source), let plan = plan(for: source, target: target)
            else { return nil }
            return "About \(Self.megabitsText(plan.videoBitsPerSecond, locale: locale)) Mbps at \(plan.maxHeight)p"
        default:
            return "Lowers the quality first, then the size in pixels"
        }
    }

    public var confirmTitle: String {
        sources.count == 1 ? "Save Smaller Copy" : "Save \(sources.count) Smaller Copies"
    }

    /// "Now 3.4 MB", "Now 3.4 MB in total": Finder's own rounding, since the person compares it with the Finder.
    public var sourceLabel: String {
        let total = sources.reduce(Int64(0)) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return sources.count == 1 ? "Now \(size)" : "Now \(size) in total"
    }

    // MARK: - Private

    private var minimumBytes: Int64 {
        switch category {
        case .pdf: 100_000
        case .video: 1_000_000
        default: 10_000
        }
    }

    /// A chip, so the first choice is one people actually face (P207): Discord's free limit for a video, a form's
    /// upper limit for an image.
    private static func defaultBytes(for category: FormatCategory) -> Int64 {
        switch category {
        case .pdf: 2_000_000
        case .video: 20_000_000
        default: 500_000
        }
    }

    private func hasVideoFacts(_ source: SourceSize) -> Bool {
        source.durationSeconds != nil && (source.width ?? 0) > 0 && (source.height ?? 0) > 0
    }

    private func plan(for source: SourceSize, target: Int64) -> TargetSize.VideoPlan? {
        TargetSize.videoPlan(
            targetBytes: target, durationSeconds: source.durationSeconds ?? 0, sourceWidth: source.width ?? 0,
            sourceHeight: source.height ?? 0, frameRate: source.frameRate ?? 30, hasAudio: source.hasAudio
        )
    }

    /// Digits with at most one separator, "." or "," whichever the keyboard has, so "1,5" and "1.5" both read 1.5
    /// in any locale; sizes are not typed with thousands separators.
    private static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let separators = trimmed.filter { $0 == "." || $0 == "," }
        guard !trimmed.isEmpty, separators.count <= 1,
              trimmed.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "," }),
              trimmed.contains(where: { ("0"..."9").contains($0) }) else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private static func fields(for bytes: Int64, locale: Locale) -> (String, SizeUnit) {
        if bytes >= 1_000_000, bytes % 100_000 == 0 { return (number(Double(bytes) / 1e6, locale: locale), .mb) }
        return (number(Double(bytes) / 1e3, locale: locale), .kb)
    }

    /// The field's text, which `parse` must read back: Latin digits (`numbers=latn`), since Arabic, Persian and
    /// Devanagari locales would write their own.
    private static func number(_ value: Double, locale: Locale, fractionDigits: Int = 1) -> String {
        var latin = Locale.Components(locale: locale)
        latin.numberingSystem = "latn"
        let formatter = NumberFormatter()
        formatter.locale = Locale(components: latin)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func megabitsText(_ bitsPerSecond: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: Double(bitsPerSecond) / 1e6)) ?? "\(bitsPerSecond / 1_000_000)"
    }
}
