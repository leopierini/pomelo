// What the Resize editor's fields say and what that means for the files (P197): width and height in pixels, a lock
// that keeps proportions, the chips, why Save is disabled and what the result will be like. The rules are
// `ResizeEdit`'s, which the engines apply. No AppKit; the app's session wraps it in a view.
import Foundation
import PomeloCore

public enum ResizeChip: Hashable, Sendable {
    case percent(Int)
    case width(Int)
    case height(Int)
    case exact(width: Int, height: Int)

    public var title: String {
        switch self {
        case .percent(let percent): "\(percent) %"
        case .width(let width): "\(width) wide"
        case .height(let height): "\(height)p"
        case .exact(let width, let height): "\(width) \u{00D7} \(height)"
        }
    }

    /// VoiceOver reads "×" as "multiplied by".
    public var spokenTitle: String {
        switch self {
        case .exact(let width, let height): "\(width) by \(height)"
        default: title
        }
    }

    public var spec: ResizeSpec {
        switch self {
        case .percent(let percent): .scale(percent: Double(percent))
        case .width(let width): .width(width)
        case .height(let height): .height(height)
        case .exact(let width, let height): .exact(width: width, height: height)
        }
    }
}

public struct ResizeModel: Equatable, Sendable {
    /// One file's upright size, in pixels.
    public struct PixelSize: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    private enum Side: Equatable, Sendable {
        case width, height
    }

    public let category: FormatCategory
    /// The readable files' sizes: empty until they have been read.
    public private(set) var sources: [PixelSize]
    /// Every file the job will run on, read or not.
    public let fileCount: Int
    public private(set) var widthText = ""
    public private(set) var heightText = ""
    public private(set) var isLocked = true
    /// While locked, the side the person typed last: the one stored, the other following each file's proportions.
    private var typed = Side.width
    /// Set by a percentage chip until a field is typed in.
    private var percent: Double?

    /// `fileCount` defaults to the sources', for a model made once the files have been read.
    public init(category: FormatCategory, sources: [(width: Int, height: Int)], remembered: ResizeSpec?,
                fileCount: Int? = nil) {
        self.category = category
        self.sources = sources.map { PixelSize(width: $0.width, height: $0.height) }
        self.fileCount = fileCount ?? sources.count
        switch remembered {
        case .scale(let percent): self.percent = percent
        case .width(let width): widthText = String(width)
        case .height(let height):
            heightText = String(height)
            typed = .height
        case .exact(let width, let height):
            isLocked = false
            (widthText, heightText) = (String(width), String(height))
        case nil: break
        }
        follow()
    }

    public mutating func update(sources: [(width: Int, height: Int)]) {
        self.sources = sources.map { PixelSize(width: $0.width, height: $0.height) }
        follow()
    }

    /// A field that hands back its own text (as it ends editing) changes nothing: a chosen percentage stays.
    public mutating func typeWidth(_ text: String) {
        guard text != widthText else { return }
        widthText = text
        typed = .width
        percent = nil
        follow()
    }

    public mutating func typeHeight(_ text: String) {
        guard text != heightText else { return }
        heightText = text
        typed = .height
        percent = nil
        follow()
    }

    public mutating func choose(_ chip: ResizeChip) {
        percent = nil
        switch chip {
        case .percent(let value):
            isLocked = true
            percent = Double(value)
        case .width(let width):
            isLocked = true
            widthText = String(width)
            typed = .width
        case .height(let height):
            isLocked = true
            heightText = String(height)
            typed = .height
        case .exact(let width, let height):
            isLocked = false
            (widthText, heightText) = (String(width), String(height))
        }
        follow()
    }

    public mutating func toggleLock() {
        isLocked.toggle()
        percent = nil
        follow()
    }

    public var chips: [ResizeChip] {
        switch category {
        case .video: [.height(2160), .height(1080), .height(720), .height(480)]
        default: [.percent(50), .percent(25), .exact(width: 1080, height: 1080), .width(1920)]
        }
    }

    /// nil while a field it needs is empty or not a whole number.
    public var spec: ResizeSpec? {
        if let percent { return .scale(percent: percent) }
        let width = Self.parse(widthText), height = Self.parse(heightText)
        guard isLocked else {
            guard let width, let height else { return nil }
            return .exact(width: width, height: height)
        }
        switch typed {
        case .width: return width.map(ResizeSpec.width)
        case .height: return height.map(ResizeSpec.height)
        }
    }

    public var blocker: String? {
        let already = ResizeEdit.alreadyThatSizeReason
        guard let spec else {
            let needed = isLocked ? [typed == .width ? widthText : heightText] : [widthText, heightText]
            let empty = needed.contains { Self.trimmed($0).isEmpty }
            return empty ? ResizeEdit.chooseSizeReason : ResizeEdit.pixelRangeReason
        }
        // The range of what was typed, whatever the files.
        if let reason = Self.reason(spec, width: 1, height: 1), reason != already { return reason }
        // Then each file's: a side that follows can leave the range, and Save needs one file that would change.
        let reasons = sources.map { Self.reason(spec, width: $0.width, height: $0.height, video: category == .video) }
        if let range = reasons.compactMap({ $0 }).first(where: { $0 != already }) { return range }
        return !reasons.isEmpty && reasons.allSatisfy({ $0 == already }) ? already : nil
    }

    public var note: String? {
        if let spec, sources.contains(where: { source in
            guard let result = try? ResizeEdit.size(.resize(spec), width: source.width, height: source.height) else {
                return false
            }
            return result.width > source.width || result.height > source.height
        }) {
            return "Larger than the original, so it may look soft"
        }
        return category == .video ? "Re-encodes the video" : nil
    }

    public var confirmTitle: String {
        fileCount > 1 ? "Save \(fileCount) Resized Copies" : "Save Resized Copy"
    }

    /// "Now 4032 × 3024", "Now 4032 × 3024 and 2 more": the first file's upright size; empty until it has been read.
    public var sourceLabel: String {
        guard let first = sources.first else { return "" }
        let size = "Now \(first.width) \u{00D7} \(first.height)"
        return fileCount <= 1 ? size : "\(size) and \(fileCount - 1) more"
    }

    // MARK: - Private

    /// Fills the fields the person did not type from the first file's proportions: both for a percentage, the other
    /// side while locked. A field that cannot follow (no size read yet, nothing typed) is left empty.
    private mutating func follow() {
        guard let first = sources.first, first.width > 0, first.height > 0 else {
            if percent != nil {
                (widthText, heightText) = ("", "")
            } else if isLocked {
                if typed == .width { heightText = "" } else { widthText = "" }
            }
            return
        }
        if let percent {
            let written = videoSize(.scale(percent: percent), of: first)
            widthText = String(written?.width ?? Self.pixels(Double(first.width) * percent / 100))
            heightText = String(written?.height ?? Self.pixels(Double(first.height) * percent / 100))
            return
        }
        guard isLocked else { return }
        switch typed {
        case .width:
            heightText = Self.parse(widthText).map {
                String(videoSize(.width($0), of: first)?.height ?? Self.scaled(first.height, by: $0, over: first.width))
            } ?? ""
        case .height:
            widthText = Self.parse(heightText).map {
                String(videoSize(.height($0), of: first)?.width ?? Self.scaled(first.width, by: $0, over: first.height))
            } ?? ""
        }
    }

    /// For a video, the size the engine writes (even sides, `ResizeEdit.videoSize`), the file's own when it is
    /// already that size; nil for an image or a size out of range, which follow the nearest pixel.
    private func videoSize(_ spec: ResizeSpec, of first: PixelSize) -> (width: Int, height: Int)? {
        guard category == .video else { return nil }
        do {
            return try ResizeEdit.videoSize(.resize(spec), width: first.width, height: first.height)
        } catch ConversionError.notApplicable(let reason) where reason == ResizeEdit.alreadyThatSizeReason {
            return (first.width, first.height)
        } catch {
            return nil
        }
    }

    private static func scaled(_ side: Int, by target: Int, over other: Int) -> Int {
        pixels(Double(side) * Double(target) / Double(other))
    }

    /// Rounded, at least 1, and capped far past `ResizeEdit.maxSide`, so a pasted run of digits never traps `Int(_:)`.
    private static func pixels(_ length: Double) -> Int {
        guard length.isFinite else { return 1 }
        return max(1, Int(min(length, 1e12).rounded()))
    }

    /// Why the engine would refuse `spec` for a file of this size, as it says it; nil when it would resize it.
    private static func reason(_ spec: ResizeSpec, width: Int, height: Int, video: Bool = false) -> String? {
        do {
            if video {
                _ = try ResizeEdit.videoSize(.resize(spec), width: width, height: height)
            } else {
                _ = try ResizeEdit.size(.resize(spec), width: width, height: height)
            }
            return nil
        } catch ConversionError.notApplicable(let reason) {
            return reason
        } catch {
            return ResizeEdit.pixelRangeReason
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// A whole number of digits; one too large for `Int` reads as out of range rather than as nothing.
    private static func parse(_ text: String) -> Int? {
        let digits = trimmed(text)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits) ?? Int.max
    }
}
