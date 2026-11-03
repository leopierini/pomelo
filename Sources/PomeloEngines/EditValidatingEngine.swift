import AVFoundation
import Foundation
import PomeloCore

/// Wraps a plugin engine so a trim is checked against the file's real length before its tool starts (P76). The
/// manifest's `-ss {trimStart} -to {trimEnd}` would otherwise copy the whole file for an end past the duration.
struct EditValidatingEngine: ConversionEngine {
    let base: any ConversionEngine

    var id: EngineID { base.id }
    var displayName: String { base.displayName }
    var maxConcurrentJobs: Int { base.maxConcurrentJobs }

    func availability() async -> EngineAvailability { await base.availability() }
    func version() async -> String? { await base.version() }
    func edges() -> [ConversionEdge] { base.edges() }

    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if step.operation == "trim" {
            let duration = (try? await AVURLAsset(url: step.input).load(.duration)).map(CMTimeGetSeconds)
            guard let duration, duration.isFinite, duration > 0 else {
                throw ConversionError.engineFailed(
                    engine: id, message: "cannot read the length of \(step.input.lastPathComponent)"
                )
            }
            _ = try TimeEdit.trimRange(step.options.edit, duration: duration)
        }
        return try await base.convert(step, progress: progress)
    }
}
