import Foundation
import PomeloCore

/// Presentations to one image per slide: LibreOffice's pdf conversion, then PDF → images by PDFKit. A single hop
/// on its own edges because PDF → images is direct-only (R22), so no route can chain through a PDF (P201).
public struct SlidesEngine: ConversionEngine {
    private static let sources: [FormatID] = ["pptx", "ppt", "odp"]
    private static let edgeCost = 70
    /// What `CommandEngine` says for the bundled manifest, for when the registry has no `libreoffice` engine at all.
    private static let installHint = "brew install --cask libreoffice"

    private let office: (any ConversionEngine)?

    /// `office` is the registry's `libreoffice` engine, nil when it has none.
    public init(office: (any ConversionEngine)?) {
        self.office = office
    }

    public var id: EngineID { "slides" }
    public var displayName: String { "Slides (LibreOffice)" }
    public var hostEngineID: EngineID? { "libreoffice" }
    public var maxConcurrentJobs: Int { office?.maxConcurrentJobs ?? 1 }
    public var availabilityIsVolatile: Bool { office?.availabilityIsVolatile ?? false }

    public func availability() async -> EngineAvailability {
        guard let office else { return .missing(installHint: Self.installHint) }
        return await office.availability()
    }

    public func version() async -> String? { await office?.version() }

    /// With an office engine, only the sources it converts to PDF: a user manifest can drop one. With none, all of
    /// them, so the wheel shows them disabled with the install sentence.
    public func edges() -> [ConversionEdge] {
        let converted = office.map { engine in
            Set(engine.edges().filter { $0.to == "pdf" && $0.operation == nil }.map(\.from))
        }
        return Self.sources.filter { converted?.contains($0) ?? true }.flatMap { source in
            [
                ConversionEdge(from: source, to: "png", engineID: id, cost: Self.edgeCost, flags: [.layoutRisk, .directOnly]),
                ConversionEdge(
                    from: source, to: "jpg", engineID: id, cost: Self.edgeCost, flags: [.lossy, .layoutRisk, .directOnly]
                ),
            ]
        }
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard let office else {
            throw ConversionError.converterUnavailable(engine: id, message: "LibreOffice is not installed")
        }
        guard let pdf = FormatRegistry.builtIn.format(id: "pdf") else {
            throw ConversionError.converterFault(engine: id, message: "no PDF format")
        }
        progress(0)

        // Inside staging, so the runner's cleanup of a failed job takes it too, and removed here in every outcome.
        let work = step.stagingDirectory.appending(path: ".slides-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let toPDF = ConversionStep(
            input: step.input, stagingDirectory: work, from: step.from, to: pdf, options: step.options
        )
        let document = try await office.convert(toPDF) { progress($0 * 0.5) }
        try Task.checkCancellation()

        // The PDF is named like the deck, so its pages get the deck's name, as PDF → images names them.
        let render = ConversionStep(
            input: document, stagingDirectory: step.stagingDirectory, from: pdf, to: step.to, options: step.options
        )
        let output = try await PDFKitEngine().renderPages(render) { progress(0.5 + $0 * 0.5) }
        progress(1)
        return output
    }
}
