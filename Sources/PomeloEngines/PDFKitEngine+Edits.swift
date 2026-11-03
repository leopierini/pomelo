import Foundation
import PomeloCore
import PDFKit
import Quartz

extension PDFKitEngine {
    /// The editor's page list as a new document: each source page is copied (its links and annotations come with
    /// it, the outline does not), turned by the added rotation, and the document's title, author and the like are
    /// kept.
    func organize(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        guard case .organize(let edits) = step.options.edit else {
            throw ConversionError.notApplicable(reason: "The pages changed since the editor opened")
        }
        guard !edits.isEmpty else { throw ConversionError.notApplicable(reason: "Keep at least one page") }
        let source = try openDocument(step.input)
        guard edits.allSatisfy({ (0..<source.pageCount).contains($0.page) && $0.rotation % 90 == 0 }) else {
            throw ConversionError.notApplicable(reason: "The pages changed since the editor opened")
        }

        let organized = PDFDocument()
        for (position, edit) in edits.enumerated() {
            try Task.checkCancellation()
            guard let page = source.page(at: edit.page)?.copy() as? PDFPage else {
                throw Failure("cannot read page \(edit.page + 1) of \(step.input.lastPathComponent)")
            }
            page.rotation = ((page.rotation + edit.rotation) % 360 + 360) % 360
            organized.insert(page, at: position)
            progress(Double(position + 1) / Double(edits.count + 1))
        }
        if let attributes = source.documentAttributes { organized.documentAttributes = attributes }
        try Task.checkCancellation()
        let output = step.suggestedOutput
        guard organized.write(to: output) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure("cannot write \(output.lastPathComponent)")
        }
        return output
    }

    /// The system's own "Reduce File Size" Quartz filter, the one Preview's Export offers.
    static let reduceFileSizeFilterURL = URL(filePath: "/System/Library/Filters/Reduce File Size.qfilter")
    /// After the screen optimisation, the filter's image settings, tried in order: (largest image side, JPEG quality).
    static let filterLadder: [(maxPixelSize: Int, quality: Double)] = [(2000, 0.75), (1500, 0.6), (1100, 0.5), (800, 0.4)]

    /// Tries ever smaller images until the PDF fits `targetBytes`; text and drawings are left as they are.
    func compressToSize(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        guard let target = step.options.targetBytes else {
            throw ConversionError.notApplicable(reason: "No size was chosen")
        }
        let label = TargetSize.label(bytes: target)
        if let size = Self.fileSize(step.input), size <= target {
            throw ConversionError.notApplicable(reason: "It's already under \(label)")
        }
        let rungs = Double(Self.filterLadder.count + 1)

        let compressed = try compress(step)
        if let size = Self.fileSize(compressed), size <= target { return compressed }
        try? FileManager.default.removeItem(at: compressed)

        let document = try openDocument(step.input)
        let output = step.suggestedOutput
        for (index, rung) in Self.filterLadder.enumerated() {
            try Task.checkCancellation()
            progress(Double(index + 1) / rungs)
            let filterFile = step.stagingDirectory.appending(
                path: ".reduce-file-size-\(UUID().uuidString).qfilter", directoryHint: .notDirectory
            )
            defer { try? FileManager.default.removeItem(at: filterFile) }
            let settings = try Self.reduceFileSizeFilter(maxPixelSize: rung.maxPixelSize, quality: rung.quality)
            do {
                try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0).write(to: filterFile)
            } catch {
                throw Failure("cannot write the size filter: \(error.localizedDescription)")
            }
            guard let filter = QuartzFilter(url: filterFile) else { throw Failure("cannot load the size filter") }
            // PDFDocument.h documents the "QuartzFilter" key: the filter is applied as the PDF is written.
            let options = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]
            guard document.write(to: output, withOptions: options) else {
                try? FileManager.default.removeItem(at: output)
                throw Failure("cannot write \(output.lastPathComponent)")
            }
            if let size = Self.fileSize(output), size <= target { return output }
            try? FileManager.default.removeItem(at: output)
        }
        throw ConversionError.notApplicable(reason: "Can't get it under \(label)")
    }

    /// The system "Reduce File Size" filter with its image size cap and JPEG quality replaced.
    static func reduceFileSizeFilter(maxPixelSize: Int, quality: Double) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: reduceFileSizeFilterURL),
            var filter = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            var filterData = filter["FilterData"] as? [String: Any],
            var color = filterData["ColorSettings"] as? [String: Any],
            var image = color["ImageSettings"] as? [String: Any],
            var scale = image["ImageScaleSettings"] as? [String: Any],
            image["Compression Quality"] != nil, scale["ImageSizeMax"] != nil
        else { throw Failure("the system's Reduce File Size filter has no image settings") }
        scale["ImageSizeMax"] = maxPixelSize
        image["ImageScaleSettings"] = scale
        image["Compression Quality"] = quality
        color["ImageSettings"] = image
        filterData["ColorSettings"] = color
        filter["FilterData"] = filterData
        return filter
    }

    /// Read from the disk each time: a URL caches its resource values, so a rewritten file would keep its old size.
    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
