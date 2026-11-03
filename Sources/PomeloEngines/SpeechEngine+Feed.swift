import AVFoundation
import Foundation
import PomeloCore

/// A file's first audio track, decoded to mono LPCM by `AVAssetReader` and converted by `AVAudioConverter` to the
/// recognizer's format. The stream is pulled: a buffer is read only when the recognizer asks for the next one, so a
/// two-hour file is never decoded ahead of the analysis into memory.
///
/// `@unchecked Sendable`: `next()` runs on `queue`, for one iteration at a time (the stream's single consumer), and the
/// state `cancel()` shares with it is behind the lock.
final class SpeechAudioFeed: @unchecked Sendable {
    /// Seconds, 0 when the file doesn't say.
    let duration: Double
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let name: String
    private let engine: EngineID

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.pomelo-app.speech-feed")
    private var reader: AVAssetReader?
    private var isCancelled = false
    private var readFailure: ConversionError?

    // Touched only by `next()`, on `queue`.
    private var output: AVAssetReaderTrackOutput?
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var isFinished = false

    /// Throws "It has no sound" for a file without an audio track.
    init(url: URL, engine: EngineID) async throws {
        name = url.lastPathComponent
        self.engine = engine
        asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let seconds: Double
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            seconds = try await asset.load(.duration).seconds
        } catch {
            throw ConversionError.engineFailed(engine: engine, message: "cannot read \(url.lastPathComponent)")
        }
        guard let first = tracks.first else { throw ConversionError.notApplicable(reason: SpeechEngine.noSound) }
        track = first
        duration = seconds.isFinite ? max(0, seconds) : 0
    }

    /// Why reading stopped before the end of the file, once the stream has ended.
    var failure: ConversionError? {
        lock.withLock { readFailure }
    }

    /// Starts reading; each element is one decoded buffer in `format`.
    func stream(as format: AVAudioFormat) throws -> AsyncStream<SpeechAudio> {
        let unreadable = ConversionError.engineFailed(engine: engine, message: "cannot read \(name)")
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw unreadable
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw unreadable }
        reader.add(output)
        guard reader.startReading() else { throw unreadable }
        self.output = output
        target = format
        lock.withLock { self.reader = reader }
        return AsyncStream(unfolding: { [self] in await nextOffThePool() }, onCancel: { [self] in cancel() })
    }

    /// `copyNextSampleBuffer` blocks until the reader has decoded more, and the reader's own pipeline stalls while
    /// every thread of the cooperative pool is blocked so (parallel tests hung that way): it waits on a queue instead.
    private func nextOffThePool() async -> SpeechAudio? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.next()) }
        }
    }

    /// Stops reading: the stream ends at its next element and the reader's background work stops.
    func cancel() {
        let reader = lock.withLock {
            isCancelled = true
            return self.reader
        }
        reader?.cancelReading()
    }

    private func next() -> SpeechAudio? {
        guard let output, let target, !isFinished else { return nil }
        while !lock.withLock({ isCancelled }) {
            guard let sample = output.copyNextSampleBuffer() else {
                isFinished = true
                if lock.withLock({ reader?.status == .failed && !isCancelled }) { fail() }
                return flush(into: target)
            }
            guard let buffer = convert(sample, into: target) else {
                isFinished = true
                fail()
                return nil
            }
            if buffer.frameLength > 0 { return SpeechAudio(buffer: buffer) }
        }
        isFinished = true
        return nil
    }

    private func fail() {
        lock.withLock { readFailure = .engineFailed(engine: engine, message: "cannot read \(name)") }
    }

    /// Nil when the sample can't be read or converted.
    private func convert(_ sample: CMSampleBuffer, into target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0 else { return AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1) }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        do {
            try sample.copyPCMData(fromRange: 0..<Int(frames), into: input.mutableAudioBufferList)
        } catch {
            return nil
        }
        if converter == nil { converter = AVAudioConverter(from: source, to: target) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(frames) * target.sampleRate / source.sampleRate).rounded(.up)) + 64
        return run(converter, into: target, capacity: capacity, input: input)
    }

    /// What the converter still holds once the file has ended (a resampler keeps a few frames back), or nil.
    private func flush(into target: AVAudioFormat) -> SpeechAudio? {
        guard let converter, let rest = run(converter, into: target, capacity: 4096, input: nil),
            rest.frameLength > 0
        else { return nil }
        return SpeechAudio(buffer: rest)
    }

    /// One conversion: `input` once and then no more for now, or with nil the end of the stream.
    private func run(
        _ converter: AVAudioConverter, into target: AVAudioFormat, capacity: AVAudioFrameCount, input: AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, state in
            guard let input, !given else {
                state.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return input
        }
        return status == .error ? nil : buffer
    }
}
