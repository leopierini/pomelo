import Foundation
import Testing
@testable import PomeloEngines
import PomeloTestSupport

/// The Trim editor's waveform for audio (P27): one peak per bucket, read at a low rate.
@Suite struct WaveformSamplerTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-waveform-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aToneHasOnePeakPerBucket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.wav(seconds: 1, amplitude: 0.5, in: dir)
        let peaks = try await WaveformSampler.peaks(of: tone, buckets: 100)
        #expect(peaks.count == 100)
        #expect(peaks.allSatisfy { $0 > 0.2 && $0 <= 1 }, "\(peaks)")
    }

    @Test func silenceIsFlat() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let silence = try Fixtures.wav(seconds: 1, amplitude: 0, in: dir)
        let peaks = try await WaveformSampler.peaks(of: silence, buckets: 50)
        #expect(peaks.count == 50)
        #expect(peaks.allSatisfy { $0 < 0.01 })
    }

    @Test func theAmplitudeShowsInThePeaks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quiet = try await WaveformSampler.peaks(of: Fixtures.wav(seconds: 1, amplitude: 0.1, in: dir), buckets: 20)
        let loud = try await WaveformSampler.peaks(of: Fixtures.wav(seconds: 1, amplitude: 0.8, in: dir), buckets: 20)
        #expect(quiet.max()! < 0.2)
        #expect(loud.min()! > 0.6)
    }

    @Test func aMovieWithoutSoundIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        await #expect(throws: (any Error).self) { try await WaveformSampler.peaks(of: movie, buckets: 10) }
    }

    @Test func aCancelledReadStops() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.wav(seconds: 2, amplitude: 0.5, in: dir)
        let task = Task { try await WaveformSampler.peaks(of: tone, buckets: 10) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
