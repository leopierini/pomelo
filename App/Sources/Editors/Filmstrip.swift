// The frames behind the Trim and Split timeline (P27), read after the panel is up. Each frame stands for an equal
// span of the video and is taken from its centre, within half a span, so the generator can use the nearest
// keyframe instead of decoding up to an exact time.
import AVFoundation
import CoreGraphics
import Foundation

enum Filmstrip {
    /// `count` upright frames, `height` pixels tall, in order; empty when the video can't be read (or the task was
    /// cancelled), so the timeline stays a plain bar.
    static func load(url: URL, count: Int, height: CGFloat) async -> [CGImage] {
        guard count > 0, let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
              duration.isFinite, duration > 0 else { return [] }
        let span = duration / Double(count)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // A zero width leaves it to the aspect ratio.
        generator.maximumSize = CGSize(width: 0, height: height)
        let tolerance = CMTime(seconds: span / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: span * (Double($0) + 0.5), preferredTimescale: 600) }

        // The generator may answer out of order.
        var frames = [CGImage?](repeating: nil, count: count)
        for await result in generator.images(for: times) {
            if Task.isCancelled { return [] }
            if let index = times.firstIndex(of: result.requestedTime) { frames[index] = try? result.image }
        }
        guard !Task.isCancelled else { return [] }
        let ordered = frames.compactMap { $0 }
        // A strip with gaps would show the wrong frame over part of the file.
        return ordered.count == count ? ordered : []
    }
}
