import CoreImage
import Foundation
import ImageIO
import PomeloCore
import PDFKit
import Vision

/// Vision on images: reads text (image to txt), cuts out the subject (remove-background), reads QR and bar codes
/// (read-codes, also for PDFs), flattens a photographed page (straighten, the page `segmenter` finds) and reports the
/// duplicates among many images (find-duplicates, a combine, by `fingerprinter`'s prints).
public struct VisionEngine: CombiningEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private static let edgeCost = 10
    private static let textSources: [FormatID] = ["png", "jpg", "heic", "tiff"]
    private static let toolSources: [FormatID] = ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp"]
    private static let removeBackground = "remove-background"
    private static let readCodes = "read-codes"
    private static let straighten = "straighten"
    private static let findDuplicates = "find-duplicates"
    /// A PDF's pages beyond these are not searched for codes: rendering a long document would take minutes.
    private static let maxCodePages = 10
    private static let codePageDPI = 200

    let segmenter: any DocumentSegmenting
    let fingerprinter: any ImageFingerprinting
    let lookAlikeThreshold: Float

    public init(
        segmenter: any DocumentSegmenting = SystemDocumentSegmenter(),
        fingerprinter: any ImageFingerprinting = SystemImageFingerprinter(),
        lookAlikeThreshold: Float = defaultLookAlikeThreshold
    ) {
        self.segmenter = segmenter
        self.fingerprinter = fingerprinter
        self.lookAlikeThreshold = lookAlikeThreshold
    }

    public var id: EngineID { "vision" }
    public var displayName: String { "Vision" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    /// The text edges are direct-only: recognised text is offered as text, never as the first step towards a document
    /// format.
    public func edges() -> [ConversionEdge] {
        var edges = Self.textSources.map {
            ConversionEdge(from: $0, to: "txt", engineID: id, cost: Self.edgeCost, flags: [.directOnly])
        }
        edges += Self.toolSources.map {
            ConversionEdge(from: $0, to: "png", engineID: id, cost: Self.edgeCost, flags: [], operation: Self.removeBackground)
        }
        edges += (Self.toolSources + ["pdf"]).map {
            ConversionEdge(from: $0, to: "txt", engineID: id, cost: Self.edgeCost, flags: [], operation: Self.readCodes)
        }
        edges += ImageIOEngine().cropFormats().map { ImageIOEngine.editEdge($0, operation: Self.straighten, engineID: id) }
        edges += Self.toolSources.map {
            ConversionEdge(from: $0, to: "txt", engineID: id, cost: Self.edgeCost, flags: [], operation: Self.findDuplicates)
        }
        return edges
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Self.reporting(progress) {
            switch step.operation {
            case nil: return try await recognizeText(step)
            case Self.removeBackground: return try await cutOut(step)
            case Self.readCodes: return try await readCodes(step)
            case Self.straighten: return try await straightenPage(step)
            default: throw Failure("Vision has no \(step.operation ?? "") tool")
            }
        }
    }

    public func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Self.reporting(progress) {
            guard step.operation == Self.findDuplicates else {
                throw Failure("Vision cannot combine files by \(step.operation)")
            }
            return try await findDuplicates(step, progress: progress)
        }
    }

    /// Progress runs from 0 to 1 around `work`, and a cancelled job never starts it.
    private static func reporting(
        _ progress: @Sendable (Double) -> Void, _ work: () async throws -> URL
    ) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let output = try await work()
        progress(1)
        return output
    }

    // MARK: Text

    private func recognizeText(_ step: ConversionStep) async throws -> URL {
        guard step.to.id == "txt" else {
            throw Failure("Vision can only write plain text, not \(step.to.displayName)")
        }
        let input = step.input
        let text = try await Self.offThePool { _ in try Self.recognizeTextSynchronously(in: input) }
        try Task.checkCancellation()
        return try Self.write(Data(text.utf8), to: step.suggestedOutput)
    }

    private static func recognizeTextSynchronously(in input: URL) throws -> String {
        try recognizeTextSynchronously(with: VNImageRequestHandler(url: input, options: [:]), name: input.lastPathComponent)
    }

    /// The text Vision reads in the handler's image, line by line from the top. Shared with Extract data and
    /// Summarize (`DocumentText`), which hand it rendered PDF pages. `name` is for the error only.
    static func recognizeTextSynchronously(with handler: VNImageRequestHandler, name: String) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try handler.perform([request])
        } catch {
            throw Failure("cannot read text in \(name): \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        // Vision's boundingBox origin is the lower left, so a larger minY is higher up in the image.
        let ordered = observations.sorted { lhs, rhs in
            if lhs.boundingBox.minY != rhs.boundingBox.minY { return lhs.boundingBox.minY > rhs.boundingBox.minY }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: Remove background

    private func cutOut(_ step: ConversionStep) async throws -> URL {
        guard step.to.id == "png" else { throw Failure("Remove background writes PNG, not \(step.to.displayName)") }
        let input = step.input
        let cutout = try await Self.offThePool { _ in try Self.cutOutSynchronously(input) }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure("cannot create \(output.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, cutout, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent)")
        }
        return output
    }

    private static func cutOutSynchronously(_ input: URL) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(url: input, options: [:])
        let pixels: CVPixelBuffer
        do {
            try handler.perform([request])
            guard let mask = request.results?.first, !mask.allInstances.isEmpty else {
                throw ConversionError.notApplicable(reason: "No subject found")
            }
            pixels = try mask.generateMaskedImage(
                ofInstances: mask.allInstances, from: handler, croppedToInstancesExtent: false
            )
        } catch let error as ConversionError {
            throw error
        } catch {
            throw Failure("cannot find the subject of \(input.lastPathComponent): \(error.localizedDescription)")
        }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let cutout = CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
        else { throw Failure("cannot render the cutout of \(input.lastPathComponent)") }
        return cutout
    }

    // MARK: Read codes

    private func readCodes(_ step: ConversionStep) async throws -> URL {
        guard step.to.id == "txt" else { throw Failure("Read codes writes plain text, not \(step.to.displayName)") }
        let input = step.input
        let isPDF = step.from.id == "pdf"
        let payloads = try await Self.offThePool { isCancelled in
            try Self.readCodesSynchronously(in: input, isPDF: isPDF, isCancelled: isCancelled)
        }
        try Task.checkCancellation()
        guard !payloads.isEmpty else { throw ConversionError.notApplicable(reason: "No code found") }
        // The app splits the file on blank lines to count the codes (P53); a payload may itself hold line breaks.
        return try Self.write(Data((payloads.joined(separator: "\n\n") + "\n").utf8), to: step.suggestedOutput)
    }

    /// The payloads of the codes in reading order, page by page, each listed once.
    private static func readCodesSynchronously(
        in input: URL, isPDF: Bool, isCancelled: @Sendable () -> Bool
    ) throws -> [String] {
        var payloads: [String] = []
        func collect(_ handler: VNImageRequestHandler) throws {
            for payload in try detectCodes(with: handler, name: input.lastPathComponent) where !payloads.contains(payload) {
                payloads.append(payload)
            }
        }
        guard isPDF else {
            try collect(VNImageRequestHandler(url: input, options: [:]))
            return payloads
        }
        guard let document = PDFDocument(url: input) else { throw Failure("cannot open \(input.lastPathComponent) as a PDF") }
        guard !document.isLocked else { throw Failure("\(input.lastPathComponent) is password protected") }
        for index in 0..<min(document.pageCount, maxCodePages) {
            if isCancelled() { throw CancellationError() }
            guard let page = document.page(at: index) else { continue }
            try collect(VNImageRequestHandler(cgImage: try PDFPageRenderer.render(page, dpi: codePageDPI), options: [:]))
        }
        return payloads
    }

    private static func detectCodes(with handler: VNImageRequestHandler, name: String) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        if let every = try? request.supportedSymbologies() { request.symbologies = every }
        do {
            try handler.perform([request])
        } catch {
            throw Failure("cannot read codes in \(name): \(error.localizedDescription)")
        }
        return inReadingOrder(request.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty }
    }

    /// Top to bottom, then left to right. Codes whose centres differ by less than half a code's height share a row,
    /// since two codes side by side are never at exactly the same height.
    private static func inReadingOrder(_ codes: [VNBarcodeObservation]) -> [VNBarcodeObservation] {
        // Vision's boundingBox origin is the lower left, so a larger midY is higher up in the image.
        let byHeight = codes.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNBarcodeObservation]] = []
        for code in byHeight {
            if let first = rows.last?.first, first.boundingBox.midY - code.boundingBox.midY < first.boundingBox.height / 2 {
                rows[rows.count - 1].append(code)
            } else {
                rows.append([code])
            }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }

    // MARK: Shared

    static func write(_ data: Data, to output: URL) throws -> URL {
        do {
            try data.write(to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent): \(error.localizedDescription)")
        }
        return output
    }

    /// Runs blocking Vision work off the cooperative thread pool. `work` is told when the task was cancelled, so a
    /// long loop can stop between pages.
    static func offThePool<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work { cancellation.isCancelled } })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
