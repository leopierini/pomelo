import Foundation

/// The arithmetic of "Compress to size": how a target reads in the UI and in file names, and the bitrate and height
/// a video gets to fit it.
public enum TargetSize {
    /// The share of the budget the video plan spends, so rate-control overshoot and container overhead still fit.
    public static let margin = 0.94
    public static let minimumVideoBitsPerSecond = 100_000
    /// Below this many bits per pixel per frame a height is too starved to be worth keeping; the next one down wins.
    public static let minimumBitsPerPixel = 0.04
    public static let heights = [1080, 720, 540, 360]

    public struct VideoPlan: Equatable, Sendable {
        public var videoBitsPerSecond: Int
        public var audioBitsPerSecond: Int
        public var maxHeight: Int

        public init(videoBitsPerSecond: Int, audioBitsPerSecond: Int, maxHeight: Int) {
            self.videoBitsPerSecond = videoBitsPerSecond
            self.audioBitsPerSecond = audioBitsPerSecond
            self.maxHeight = maxHeight
        }
    }

    /// "10 MB", "1.5 MB", "500 KB": decimal units, as Finder shows them, with the locale's decimal separator. Rounded
    /// up like `nameSuffix`, so a label and a file name never disagree, and never "0 KB".
    public static func label(bytes: Int64, locale: Locale = .current) -> String {
        let bytes = max(1, bytes)
        let kilobytes = (bytes + 999) / 1_000
        if kilobytes < 1_000 { return "\(kilobytes) KB" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let megabytesTenths = (bytes + 99_999) / 100_000
        let (tenths, unit) = megabytesTenths < 10_000 ? (megabytesTenths, "MB") : ((bytes + 99_999_999) / 100_000_000, "GB")
        return "\(formatter.string(from: NSNumber(value: Double(tenths) / 10)) ?? "\(tenths / 10)") \(unit)"
    }

    /// "under-10mb", "under-1.5mb", "under-500kb". Rounded up, so the name never claims less than the target allows.
    public static func nameSuffix(bytes: Int64) -> String {
        let bytes = max(1, bytes)
        let kilobytes = (bytes + 999) / 1_000
        if kilobytes < 1_000 { return "under-\(kilobytes)kb" }
        let tenths = (bytes + 99_999) / 100_000
        let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        return "under-\(text)mb"
    }

    /// The bitrates and height that fit `targetBytes` over `durationSeconds`, or nil when even the lowest video
    /// bitrate does not fit. `sourceWidth` and `sourceHeight` are the encoded (natural) size; the height never grows.
    public static func videoPlan(
        targetBytes: Int64, durationSeconds: Double, sourceWidth: Int, sourceHeight: Int, frameRate: Double,
        hasAudio: Bool
    ) -> VideoPlan? {
        guard targetBytes > 0, durationSeconds > 0, durationSeconds.isFinite, sourceWidth > 0, sourceHeight > 0
        else { return nil }
        let budget = Double(targetBytes) * 8 * margin / durationSeconds
        let audio = !hasAudio ? 0 : budget >= 1_000_000 ? 128_000 : 64_000
        let video = budget - Double(audio)
        guard video >= Double(minimumVideoBitsPerSecond) else { return nil }
        let fps = frameRate.isFinite && frameRate > 0 ? frameRate : 30
        let candidates = [sourceHeight] + heights.filter { $0 < sourceHeight }
        let height = candidates.first { height in
            let width = Double(sourceWidth) * Double(height) / Double(sourceHeight)
            return video / (width * Double(height) * fps) >= minimumBitsPerPixel
        } ?? candidates[candidates.count - 1]
        return VideoPlan(videoBitsPerSecond: Int(video), audioBitsPerSecond: audio, maxHeight: height)
    }
}
