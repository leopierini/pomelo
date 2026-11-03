// The Trim editor's waveform for audio (P27): the loudest sample of each slice of the file. Decoded as one channel
// at 8,000 Hz, which is plenty for a 488 pt picture and an eleventh of the work of 44.1 kHz stereo.
import AVFoundation
import Foundation
import PomeloCore

public enum WaveformSampler {
    static let sampleRate = 8_000.0

    /// `buckets` peaks, 0…1, one per equal slice of the duration. Throws `CancellationError` when the task is cancelled
    /// (checked between reads) and "It has no sound" for a file without an audio track.
    public static func peaks(of url: URL, buckets: Int) async throws -> [Float] {
        try Task.checkCancellation()
        guard buckets > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.notApplicable(reason: "It has no sound")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError.notApplicable(reason: "It has no sound") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConversionError.notApplicable(reason: "It has no sound") }

        let expected = max(1, Int((duration.isFinite ? duration : 0) * sampleRate))
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        var samples: [Float] = []
        while true {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: repeatElement(0, count: count))
            // Copied out, since a block buffer's bytes need not be contiguous.
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in samples {
                // Samples past the duration (a rounding, an encoder's padding) count in the last bucket.
                let bucket = min(buckets - 1, index * buckets / expected)
                peaks[bucket] = max(peaks[bucket], min(1, abs(sample)))
                index += 1
            }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.notApplicable(reason: "It has no sound") }
        return peaks
    }
}
