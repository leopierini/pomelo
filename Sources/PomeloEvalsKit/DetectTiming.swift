import CoreGraphics
import Foundation
import ImageIO
import PomeloEngines

/// How long Vision takes to propose redaction boxes (P27) on corpus pictures, as the redaction editor runs it.
public enum DetectTiming {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Corpus file and metric name.
    public static let cases = [
        ("photo.jpg", "vision.redact_detect.photo.seconds"), ("text.png", "vision.redact_detect.text.seconds"),
    ]
    static let runs = 3

    /// The median of `runs` detections per picture, after one untimed run (Vision loads its models on the first).
    /// The text picture must yield text, so a detector that finds nothing cannot pass as a fast one.
    public static func measure(corpus: URL) async throws -> [String: Double] {
        var metrics: [String: Double] = [:]
        for (file, name) in cases {
            let url = corpus.appending(path: file, directoryHint: .notDirectory)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw Failure(description: "cannot open \(url.path)") }
            let found = try await RedactionDetector.detect(in: image)
            if file == "text.png", !found.contains(where: { $0.kind == .text }) {
                throw Failure(description: "no text found in \(file)")
            }
            var seconds: [Double] = []
            for _ in 0..<runs {
                let clock = ContinuousClock()
                let start = clock.now
                _ = try await RedactionDetector.detect(in: image)
                let elapsed = clock.now - start
                seconds.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            metrics[name] = Percentile.of(0.5, in: seconds)
        }
        return metrics
    }
}
