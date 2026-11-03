import Foundation

/// Finds the best encode of an image that fits a byte budget: quality first, then pixels. Each encode is a full
/// compression of the image, so the search spends at most 12 of them.
enum ImageSizeSearch {
    static let maxEncodes = 12
    static let firstQuality = 0.92
    static let lowestQuality = 0.3
    static let bisectionSteps = 7
    /// A fit this close to the target is good enough to stop bisecting.
    static let closeEnough = 0.9
    static let scaledQuality = 0.6
    static let lossyScaleSteps = 4
    static let losslessScaleSteps = 6
    static let smallestSide = 64.0

    /// The encode that fits `targetBytes` at the highest quality, then the largest scale, or nil when none fits
    /// before the image's `longestSide` would drop under 64 px. `encode` gets (quality 0...1, scale 0...1); a
    /// lossless format is always asked for quality 1. Never returns more than `targetBytes`.
    static func search(
        targetBytes: Int64, lossy: Bool, longestSide: Int,
        encode: (_ quality: Double, _ scale: Double) throws -> Data
    ) rethrows -> Data? {
        func fits(_ data: Data) -> Bool { Int64(data.count) <= targetBytes }
        guard targetBytes > 0 else { return nil }

        if !lossy {
            let full = try encode(1, 1)
            if fits(full) { return full }
            return try shrink(
                from: full.count, quality: 1, steps: losslessScaleSteps, targetBytes: targetBytes,
                longestSide: longestSide, encode: encode
            )
        }

        let first = try encode(firstQuality, 1)
        if fits(first) { return first }
        let lowest = try encode(lowestQuality, 1)
        guard fits(lowest) else {
            let reference = try encode(scaledQuality, 1)
            if fits(reference) { return reference }
            return try shrink(
                from: reference.count, quality: scaledQuality, steps: lossyScaleSteps, targetBytes: targetBytes,
                longestSide: longestSide, encode: encode
            )
        }
        var best = lowest
        var low = lowestQuality
        var high = firstQuality
        for _ in 0..<bisectionSteps where Double(best.count) < closeEnough * Double(targetBytes) {
            let quality = (low + high) / 2
            let data = try encode(quality, 1)
            if fits(data) {
                best = data
                low = quality
            } else {
                high = quality
            }
        }
        return best
    }

    /// Scales by 0.95 × √(target / size) per step: a byte count roughly follows the pixel area.
    private static func shrink(
        from size: Int, quality: Double, steps: Int, targetBytes: Int64, longestSide: Int,
        encode: (_ quality: Double, _ scale: Double) throws -> Data
    ) rethrows -> Data? {
        var scale = 1.0
        var size = size
        for _ in 0..<steps {
            scale = min(1, scale * 0.95 * (Double(targetBytes) / Double(max(1, size))).squareRoot())
            guard Double(longestSide) * scale >= smallestSide else { return nil }
            let data = try encode(quality, scale)
            if Int64(data.count) <= targetBytes { return data }
            size = data.count
        }
        return nil
    }
}
