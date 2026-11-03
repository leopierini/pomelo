import CoreGraphics
import Foundation
import PomeloCore
import Vision

/// Something the redaction editor proposes to hide, in the picture's top-left unit space.
public struct DetectedRegion: Equatable, Sendable {
    public enum Kind: Sendable {
        case face, email, text
    }

    public var kind: Kind
    public var rect: UnitRect

    public init(kind: Kind, rect: UnitRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// Finds faces, email addresses and lines of text with Vision, for the redaction editor to propose as boxes (P27).
/// Only boxes leave it: the recognized text is never returned or logged.
public enum RedactionDetector {
    /// Faces first, then emails, then lines of text, each top to bottom. `image` is the picture as shown (upright).
    public static func detect(in image: CGImage) async throws -> [DetectedRegion] {
        try Task.checkCancellation()
        let regions = try await VisionEngine.offThePool { isCancelled in
            try detectSynchronously(in: image, isCancelled: isCancelled)
        }
        try Task.checkCancellation()
        return regions
    }

    private static func detectSynchronously(
        in image: CGImage, isCancelled: @Sendable () -> Bool
    ) throws -> [DetectedRegion] {
        let size = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        if isCancelled() { throw CancellationError() }
        let faceRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([faceRequest])
        let faces = (faceRequest.results ?? []).compactMap { face in
            region(.face, face.boundingBox, padX: face.boundingBox.width * 0.2, padY: face.boundingBox.height * 0.2)
        }

        if isCancelled() { throw CancellationError() }
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        try handler.perform([textRequest])
        if isCancelled() { throw CancellationError() }

        let email = try NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive)
        var emails: [DetectedRegion] = []
        var lines: [DetectedRegion] = []
        for observation in textRequest.results ?? [] {
            if let line = textRegion(.text, observation.boundingBox, in: size) { lines.append(line) }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            for match in email.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
                // The line's own region already covers an address whose box Vision cannot give.
                guard let range = Range(match.range, in: string),
                      let box = try? candidate.boundingBox(for: range)?.boundingBox,
                      let found = textRegion(.email, box, in: size)
                else { continue }
                emails.append(found)
            }
        }
        return topToBottom(faces) + topToBottom(emails) + topToBottom(lines)
    }

    /// Text is padded by 10% of its height on every side, the same distance in pixels across as down.
    private static func textRegion(_ kind: DetectedRegion.Kind, _ box: CGRect, in size: CGSize) -> DetectedRegion? {
        let pad = box.height * 0.1
        return region(kind, box, padX: size.width > 0 ? pad * size.height / size.width : 0, padY: pad)
    }

    /// Vision's normalized box (origin bottom left) grown by the padding, flipped to top-left and clamped to the
    /// picture; nil when nothing of it is left inside.
    private static func region(_ kind: DetectedRegion.Kind, _ box: CGRect, padX: CGFloat, padY: CGFloat) -> DetectedRegion? {
        let rect = UnitRect(
            x: Double(box.minX - padX), y: Double(1 - box.maxY - padY),
            width: Double(box.width + 2 * padX), height: Double(box.height + 2 * padY)
        ).clamped()
        guard rect.width > 0, rect.height > 0 else { return nil }
        return DetectedRegion(kind: kind, rect: rect)
    }

    private static func topToBottom(_ regions: [DetectedRegion]) -> [DetectedRegion] {
        regions.sorted { $0.rect.y != $1.rect.y ? $0.rect.y < $1.rect.y : $0.rect.x < $1.rect.x }
    }
}
