import CoreImage
import Foundation
import ImageIO
import PomeloCore

extension VisionEngine {
    /// Two prints closer than this look alike (P268, P269). Measured on generated photographic scenes at 1200, 2000 and
    /// 4032 px: resized, re-encoded, other-format and EXIF-rotated copies 0.010 to 0.069, burst frames 0.100 to 0.186,
    /// unrelated scenes 0.338 and more.
    public static let defaultLookAlikeThreshold: Float = 0.085

    /// Find duplicates (P263): files with the same size and SHA-256 are identical; one picture of each identical group
    /// and every other picture are then printed and grouped by single-link under `lookAlikeThreshold`. Only reads the
    /// inputs.
    func findDuplicates(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard step.to.id == "txt" else {
            throw Failure("Find duplicates writes plain text, not \(step.to.displayName)")
        }
        let files = Self.uniqueFiles(step.inputs)
        guard files.count >= 2 else { throw ConversionError.notApplicable(reason: DuplicateReport.fewerThanTwoReason) }
        guard files.count <= DuplicateReport.maxImages else {
            throw ConversionError.notApplicable(reason: DuplicateReport.tooManyReason)
        }
        let (fingerprinter, threshold) = (fingerprinter, lookAlikeThreshold)
        let report = try await Self.offThePool { isCancelled in
            try Self.duplicateReport(
                files, fingerprinter: fingerprinter, threshold: threshold, progress: progress, isCancelled: isCancelled
            )
        }
        try Task.checkCancellation()
        guard let report else { throw ConversionError.notApplicable(reason: DuplicateReport.noneFoundReason) }
        return try Self.write(Data(report.utf8), to: step.suggestedOutput)
    }

    /// A file given twice, or through a symbolic link, is one file, kept where it was first given. `given` is the URL
    /// the user handed in (shown and blamed), `resolved` the one read.
    private static func uniqueFiles(_ inputs: [URL]) -> [(given: URL, resolved: URL)] {
        var seen = Set<String>()
        return inputs.compactMap { given in
            let resolved = given.resolvingSymlinksInPath().standardizedFileURL
            return seen.insert(resolved.path).inserted ? (given, resolved) : nil
        }
    }

    /// The report's text, nil when nothing groups. Progress is the files done over the files: a file is done once it
    /// is printed, or once it is known to be an identical copy that is not printed.
    private static func duplicateReport(
        _ files: [(given: URL, resolved: URL)], fingerprinter: any ImageFingerprinting, threshold: Float,
        progress: @Sendable (Double) -> Void, isCancelled: @Sendable () -> Bool
    ) throws -> String? {
        // The whole run is one work item off the pool, so each file's autoreleased Image I/O, Core Image and Vision
        // objects are drained with a pool of its own, not at the end of the run.
        var entries: [DuplicateReport.Entry] = []
        for (order, file) in files.enumerated() {
            if isCancelled() { throw CancellationError() }
            entries.append(try autoreleasepool {
                try CombineInputError.blaming(file.given) { try entry(file, order: order) }
            })
        }

        var identical: [[Int]] = []
        let sameSize = Dictionary(grouping: entries.indices) { entries[$0].bytes }.values
            .filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
        for group in sameSize {
            var byDigest: [Data: [Int]] = [:]
            for index in group {
                if isCancelled() { throw CancellationError() }
                let digest = try autoreleasepool {
                    try CombineInputError.blaming(files[index].given) {
                        try FileDigest.sha256(of: files[index].resolved, isCancelled: isCancelled)
                    }
                }
                byDigest[digest, default: []].append(index)
            }
            identical += byDigest.values.filter { $0.count > 1 }
        }
        identical.sort { $0[0] < $1[0] }

        let copies = Set(identical.flatMap { $0 })
        let printed = (entries.indices.filter { !copies.contains($0) }
            + identical.map { DuplicateReport.representative(of: $0, in: entries) }).sorted()
        var done = entries.count - printed.count
        progress(Double(done) / Double(entries.count))
        var lookAlike: [[Int]] = []
        if printed.count > 1 {
            let context = CIContext()
            var prints: [any ImageFingerprint] = []
            for index in printed {
                if isCancelled() { throw CancellationError() }
                let file = files[index]
                prints.append(try autoreleasepool {
                    try CombineInputError.blaming(file.given) {
                        try fingerprinter.fingerprint(of: file.resolved, using: context)
                    }
                })
                done += 1
                progress(Double(done) / Double(entries.count))
            }
            lookAlike = DuplicateReport.cluster(count: printed.count, threshold: threshold) {
                prints[$0].distance(to: prints[$1])
            }.map { $0.map { printed[$0] } }
        }
        guard !identical.isEmpty || !lookAlike.isEmpty else { return nil }
        return DuplicateReport.text(entries: entries, identical: identical, lookAlike: lookAlike)
    }

    /// The primary image's pixel count from its properties, without decoding it, and the file's size.
    private static func entry(_ file: (given: URL, resolved: URL), order: Int) throws -> DuplicateReport.Entry {
        let name = file.given.lastPathComponent
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file.resolved as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source, CGImageSourceGetPrimaryImageIndex(source), nil
            ) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0
        else { throw Failure("cannot read \(name) as an image") }
        let bytes = try file.resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return DuplicateReport.Entry(url: file.given, pixels: width * height, bytes: Int64(bytes), order: order)
    }
}
