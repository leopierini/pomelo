import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PomeloEngines
import PomeloTestSupport
import PDFKit
import PomeloCore
import VideoToolbox
import Vision

/// What can be read back from a produced file or folder.
public struct Inspection: Equatable, Sendable {
    public var opens = false
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var frames: Int?
    /// A video's exact sample count; read only when a case expects one (`OutputCheck.frameCount`).
    public var videoFrames: Int?
    public var pages: Int?
    public var audioChannels: Int?
    public var folderItems: Int?
    public var text: String?
    public var hasTransparency: Bool?
    /// An xlsx workbook's sheet count, nil for any other file or a workbook that does not unzip.
    public var sheets: Int?
    /// A JSON file's top-level object, nil for any other file or JSON that does not parse into an object.
    public var jsonFields: [String: JSONValue]?
    /// The file's size; a folder's is the sum of its files.
    public var bytes: Int64?
    /// For an image: whether `RedactionCheck` passes. nil for anything else.
    public var noMetadata: Bool?
    /// Why `RedactionCheck` refused the image, when it did.
    public var metadataLeak: String?
    /// The text Vision reads in an image; read only when a case expects some (`OutputCheck.imageText`).
    public var imageText: String?

    public init() {}
}

public enum OutputCheck {
    static let durationTolerance = 0.15
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "bmp", "webp"]
    private static let avExtensions: Set<String> = ["mov", "mp4", "m4v", "m4a", "wav", "mp3", "aac", "caf", "aiff", "flac"]
    private static let ffprobeExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "wma"]
    private static let richTextExtensions: Set<String> = ["rtf", "docx", "html", "odt"]
    private static let plainTextExtensions: Set<String> = ["txt", "md", "csv", "srt", "vtt"]
    private static let structuredExtensions: Set<String> = ["xlsx", "json"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "tgz", "gz"]

    public static func inspect(_ url: URL) async -> Inspection {
        var result = Inspection()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return result }
        result.bytes = totalBytes(of: url)
        if isDirectory.boolValue {
            result.opens = true
            result.folderItems = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                .filter { !$0.hasPrefix(".") }.count
            return result
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { return result }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            inspectImage(url, into: &result)
        } else if ext == "pdf" {
            inspectPDF(url, into: &result)
        } else if avExtensions.contains(ext) {
            await inspectAV(url, into: &result)
        } else if ffprobeExtensions.contains(ext) {
            inspectWithFFprobe(url, into: &result)
        } else if richTextExtensions.contains(ext) {
            if let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                result.opens = true
                result.text = text.string
            }
        } else if archiveExtensions.contains(ext) {
            result.opens = archiveHasEntries(url)
        } else if structuredExtensions.contains(ext) {
            inspectStructured(url, ext: ext, into: &result)
        } else if plainTextExtensions.contains(ext) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                result.opens = !text.isEmpty
                result.text = text
            }
        } else {
            result.opens = true
        }
        return result
    }

    /// The failures of `inspection` against `expect`; empty when the output is as expected. `psnr` and `ssim` are
    /// the measured PSNR and SSIM against the input, nil when not measured.
    public static func failures(
        _ inspection: Inspection, expect: EvalCase.Expect, psnr: Double? = nil, ssim: Double? = nil
    ) -> [String] {
        var failures: [String] = []
        if expect.opens != inspection.opens { failures.append("opens is \(inspection.opens), expected \(expect.opens)") }
        failures += countFailures(inspection, expect: expect)
        failures += shapeFailures(inspection, expect: expect)
        failures += qualityFailures(inspection, expect: expect, psnr: psnr, ssim: ssim)
        failures += textFailures(inspection, expect: expect)
        failures += structureFailures(inspection, expect: expect)
        failures += fileFailures(inspection, expect: expect)
        return failures
    }

    private static func equalFailure(_ label: String, _ actual: Int?, _ expected: Int?) -> [String] {
        guard let expected, actual != expected else { return [] }
        return ["\(label) is \(actual.map(String.init) ?? "missing"), expected \(expected)"]
    }

    private static func atMostFailure(_ label: String, _ actual: Int?, _ limit: Int?) -> [String] {
        guard let limit, (actual ?? .max) > limit else { return [] }
        return ["\(label) is \(actual.map(String.init) ?? "missing"), expected at most \(limit)"]
    }

    private static func countFailures(_ inspection: Inspection, expect: EvalCase.Expect) -> [String] {
        equalFailure("width", inspection.width, expect.width)
            + equalFailure("height", inspection.height, expect.height)
            + equalFailure("frames", inspection.frames, expect.frames)
            + equalFailure("frameCount", inspection.videoFrames, expect.frameCount)
            + equalFailure("pages", inspection.pages, expect.pages)
            + equalFailure("audioChannels", inspection.audioChannels, expect.audioChannels)
            + equalFailure("folderItems", inspection.folderItems, expect.folderItems)
    }

    private static func shapeFailures(_ inspection: Inspection, expect: EvalCase.Expect) -> [String] {
        var failures: [String] = []
        if let ratio = expect.aspectRatio {
            var actual: Double?
            if let width = inspection.width, let height = inspection.height, width > 0, height > 0 {
                actual = Double(max(width, height)) / Double(min(width, height))
            }
            if actual.map({ abs($0 - ratio.value) > ratio.tolerance }) ?? true {
                let found = actual.map { String(format: "%.3f", $0) } ?? "missing"
                failures.append(String(format: "aspect ratio is %@, expected %.3f within %.3f", found, ratio.value,
                                       ratio.tolerance))
            }
        }
        return failures + atMostFailure("width", inspection.width, expect.maxWidth)
            + atMostFailure("height", inspection.height, expect.maxHeight)
    }

    private static func qualityFailures(
        _ inspection: Inspection, expect: EvalCase.Expect, psnr: Double?, ssim: Double?
    ) -> [String] {
        var failures: [String] = []
        if let expected = expect.durationSeconds {
            let actual = inspection.durationSeconds
            if actual.map({ abs($0 - expected) > durationTolerance }) ?? true {
                failures.append("duration is \(actual.map { String(format: "%.2f", $0) } ?? "missing") s, expected \(expected) s")
            }
        }
        if let minimum = expect.psnrMinDB, (psnr ?? 0) < minimum {
            failures.append("PSNR is \(psnr.map { String(format: "%.1f", $0) } ?? "missing") dB, expected at least \(minimum) dB")
        }
        if let minimum = expect.ssimMin, (ssim ?? 0) < minimum {
            failures.append("SSIM is \(ssim.map { String(format: "%.3f", $0) } ?? "missing"), expected at least \(minimum)")
        }
        return failures
    }

    private static func textFailures(_ inspection: Inspection, expect: EvalCase.Expect) -> [String] {
        var failures: [String] = []
        if let needle = expect.textContains,
           inspection.text?.range(of: needle, options: .caseInsensitive) == nil {
            failures.append("text lacks \"\(needle)\"")
        }
        if let needle = expect.imageTextContains,
           inspection.imageText?.range(of: needle, options: .caseInsensitive) == nil {
            failures.append("image text lacks \"\(needle)\"")
        }
        if let prefix = expect.textStartsWith, inspection.text?.hasPrefix(prefix) != true {
            failures.append("text does not start with \"\(prefix)\"")
        }
        return failures
    }

    private static func structureFailures(_ inspection: Inspection, expect: EvalCase.Expect) -> [String] {
        var failures = equalFailure("xlsxSheets", inspection.sheets, expect.xlsxSheets)
        for (key, expected) in (expect.jsonFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let actual = inspection.jsonFields?[key]
            if !jsonValuesMatch(actual, expected) {
                failures.append("json \(key) is \(actual?.compactString ?? "missing"), expected \(expected.compactString)")
            }
        }
        return failures
    }

    private static func fileFailures(_ inspection: Inspection, expect: EvalCase.Expect) -> [String] {
        var failures: [String] = []
        if let expected = expect.hasTransparency, (inspection.hasTransparency ?? false) != expected {
            failures.append("hasTransparency is \(inspection.hasTransparency ?? false), expected \(expected)")
        }
        if let limit = expect.maxBytes, (inspection.bytes ?? .max) > limit {
            failures.append("\(inspection.bytes.map(String.init) ?? "unknown") bytes, expected at most \(limit)")
        }
        if let expected = expect.noMetadata, (inspection.noMetadata ?? false) != expected {
            let why = inspection.metadataLeak.map { " (\($0))" } ?? ""
            failures.append("noMetadata is \(inspection.noMetadata.map(String.init) ?? "missing")\(why), expected \(expected)")
        }
        return failures
    }

    private static func inspectPDF(_ url: URL, into result: inout Inspection) {
        guard let document = PDFDocument(url: url) else { return }
        result.opens = true
        result.pages = document.pageCount
        if let box = document.page(at: 0)?.bounds(for: .mediaBox) {
            result.width = Int(box.width.rounded())
            result.height = Int(box.height.rounded())
        }
    }

    /// An xlsx counts as opened when it unzips to a workbook, a json when it parses into an object.
    private static func inspectStructured(_ url: URL, ext: String, into result: inout Inspection) {
        if ext == "xlsx" {
            result.sheets = sheetCount(ofWorkbook: url)
            result.opens = result.sheets != nil
        } else if let data = try? Data(contentsOf: url),
                  let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            result.opens = true
            result.jsonFields = object
            result.text = String(decoding: data, as: UTF8.self)
        }
    }

    private static func jsonValuesMatch(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
        if case .number(let wanted) = expected, case .number(let found)? = actual { return abs(found - wanted) < 1e-9 }
        return actual == expected
    }

    /// The `<sheet>` elements of the workbook's `xl/workbook.xml`; nil when `unzip` cannot read it.
    static func sheetCount(ofWorkbook url: URL) -> Int? {
        let result = Shell.run("/usr/bin/unzip", ["-p", url.path, "xl/workbook.xml"])
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output.components(separatedBy: "<sheet ").count - 1
    }

    /// The outputs whose mark differs from `expect.marked`, by name; empty when the case expects nothing of it.
    public static func markFailures(_ outputs: [URL], expect: EvalCase.Expect) -> [String] {
        guard let expected = expect.marked else { return [] }
        return outputs.filter { OutputMark.isMarked($0) != expected }
            .map { "\($0.lastPathComponent) is \(expected ? "not marked" : "marked")" }
    }

    /// Peak signal-to-noise ratio of two images over their RGB channels, both drawn at the size of the first.
    /// Infinite for identical pixels; nil when either does not open.
    public static func psnr(_ a: URL, _ b: URL) -> Double? {
        guard let first = rgba(a, size: nil), let second = rgba(b, size: (first.width, first.height)) else { return nil }
        var squares = 0.0
        var count = 0.0
        for index in stride(from: 0, to: first.pixels.count, by: 4) {
            for channel in 0..<3 {
                let difference = Double(first.pixels[index + channel]) - Double(second.pixels[index + channel])
                squares += difference * difference
                count += 1
            }
        }
        let mse = squares / count
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Mean structural similarity of two images (or the first frames of two videos) over non-overlapping 8 x 8
    /// windows of their 8-bit grayscale, both drawn at the smaller of their sizes. 1 for identical pixels; nil when
    /// either does not open or the common size is under 8 pixels a side.
    public static func ssim(_ a: URL, _ b: URL) -> Double? {
        guard let first = firstImage(a), let second = firstImage(b) else { return nil }
        let width = min(first.width, second.width)
        let height = min(first.height, second.height)
        guard width >= ssimWindow, height >= ssimWindow,
              let x = grayscale(first, width: width, height: height),
              let y = grayscale(second, width: width, height: height)
        else { return nil }
        let c1 = (0.01 * 255.0) * (0.01 * 255.0), c2 = (0.03 * 255.0) * (0.03 * 255.0)
        let count = Double(ssimWindow * ssimWindow)
        var total = 0.0
        var windows = 0.0
        for top in stride(from: 0, through: height - ssimWindow, by: ssimWindow) {
            for left in stride(from: 0, through: width - ssimWindow, by: ssimWindow) {
                var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
                for row in top..<(top + ssimWindow) {
                    let base = row * width + left
                    for column in 0..<ssimWindow {
                        let px = Double(x[base + column]), py = Double(y[base + column])
                        sumX += px; sumY += py
                        sumXX += px * px; sumYY += py * py; sumXY += px * py
                    }
                }
                let meanX = sumX / count, meanY = sumY / count
                let varianceX = sumXX / count - meanX * meanX
                let varianceY = sumYY / count - meanY * meanY
                let covariance = sumXY / count - meanX * meanY
                total += ((2 * meanX * meanY + c1) * (2 * covariance + c2))
                    / ((meanX * meanX + meanY * meanY + c1) * (varianceX + varianceY + c2))
                windows += 1
            }
        }
        return total / windows
    }

    /// The lines Vision reads in the image at `url`, accurately and with language correction; nil when the file does
    /// not open as an image or Vision fails on it.
    public static func imageText(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The number of video samples in `url`, counted off the track with `AVAssetReader` (not duration times rate).
    /// nil when AVFoundation finds no video track or cannot read it.
    public static func frameCount(_ url: URL) -> Int? {
        let asset = AVURLAsset(url: url)
        guard let track = firstVideoTrack(of: asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        return reader.status == .completed ? count : nil
    }

    // MARK: Private

    private static let ssimWindow = 8

    /// The video track of `asset`, loaded with the completion-handler API so the callers stay synchronous without
    /// blocking a cooperative thread on a Task.
    private static func firstVideoTrack(of asset: AVURLAsset) -> AVAssetTrack? {
        nonisolated(unsafe) var track: AVAssetTrack?
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            track = tracks?.first
            done.signal()
        }
        done.wait()
        return track
    }

    /// The image at `url`, or the first frame of the video there.
    private static func firstImage(_ url: URL) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        let asset = AVURLAsset(url: url)
        guard let track = firstVideoTrack(of: asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample)
        else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        reader.cancelReading()
        return image
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func totalBytes(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let item = files?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func inspectImage(_ url: URL, into result: inout Inspection) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return }
        result.opens = true
        result.frames = CGImageSourceGetCount(source)
        result.hasTransparency = hasTransparentPixel(source)
        do {
            try RedactionCheck.verify(url)
            result.noMetadata = true
        } catch {
            result.noMetadata = false
            result.metadataLeak = "\(error)"
        }
        if let size = Fixtures.imageSize(url) {
            result.width = Int(size.width)
            result.height = Int(size.height)
        }
    }

    /// Whether any pixel of the first image is not fully opaque, judged on a 64 x 64 thumbnail.
    private static func hasTransparentPixel(_ source: CGImageSource) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * context.bytesPerRow + x * 4 + 3] < 255 { return true }
        }
        return false
    }

    private static func inspectAV(_ url: URL, into result: inout Inspection) async {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration)
        else { return }
        result.opens = true
        result.durationSeconds = duration.seconds
        // The size players show: a quarter turn (Rotate) changes only the preferred transform, not the stored frames.
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await video.load(.naturalSize, .preferredTransform) {
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            result.width = Int(shown.width.rounded())
            result.height = Int(shown.height.rounded())
        }
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else { return }
        // 0 tells a file without sound (Remove audio) from one whose channels could not be read (nil).
        guard let audio = audioTracks.first else { result.audioChannels = 0; return }
        if let descriptions = try? await audio.load(.formatDescriptions),
           let description = descriptions.first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            result.audioChannels = Int(basic.pointee.mChannelsPerFrame)
        }
    }

    /// Whether `bsdtar -t` lists at least one entry.
    private static func archiveHasEntries(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-t", "-f", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let listing = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !listing.isEmpty
    }

    private static func inspectWithFFprobe(_ url: URL, into result: inout Inspection) {
        guard let ffprobe = Installed.path(of: "ffprobe") else { result.opens = true; return }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height,channels", "-of", "json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = ((root["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        else { return }
        result.opens = true
        result.durationSeconds = seconds
        let streams = root["streams"] as? [[String: Any]] ?? []
        if let video = streams.first(where: { $0["codec_type"] as? String == "video" }) {
            result.width = video["width"] as? Int
            result.height = video["height"] as? Int
        }
        result.audioChannels = streams.first { $0["codec_type"] as? String == "audio" }?["channels"] as? Int ?? 0
    }

    private static func rgba(_ url: URL, size: (width: Int, height: Int)?) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = size?.width ?? image.width
        let height = size?.height ?? image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, pixels) : nil
    }
}
