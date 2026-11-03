// The up-front check the wheel runs on the dragged files (P23): a file that is certainly damaged turns the hub red
// before the user drops on a slice that could only fail. Cheap by design: a zero-byte file is damaged whatever its
// format; images are opened with ImageIO without decoding pixels and PDFs with CGPDFDocument; audio and video that
// AVFoundation reads are opened as assets, at most 2 s each; documents and archives get magic-number checks only
// (parsing would cost too much); every other format is left unchecked, and so are files past the first `maxChecked`
// and files whose contents are not on this Mac (an iCloud Drive or File Provider placeholder): reading one would
// download it, or fail offline and look damaged. Not main-actor: the wheel runs it off the main thread so the open
// never waits for it, and stops it between files when the wheel closes. The same pass gathers the facts the hub's
// size estimate needs (bytes, image dimensions, media duration) so no file is opened twice.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PomeloCore
import PomeloUIModel
import os

enum FileReadability {
    /// How many files are checked, from the first; the rest count as unchecked.
    static let maxChecked = 50
    /// How long one audio or video file may take; past it the file is unchecked.
    static let mediaLimit: Duration = .seconds(2)

    enum Verdict: Equatable, Sendable {
        case readable
        case damaged
        /// A format the check does not look into (or past `maxChecked`).
        case unchecked
    }

    struct Report: Equatable, Sendable {
        /// The damaged files, in the order given.
        var damaged: [URL]
        /// True when every file was checked and found damaged: nothing can be converted.
        var allDamaged: Bool
        /// What the pass learned about each local file among the first `maxChecked`, for the size estimate.
        var facts: [URL: SourceFacts] = [:]

        static let clean = Report(damaged: [], allDamaged: false)

        /// `files` without the damaged ones: what a conversion or tool runs on.
        func readable(_ files: [URL]) -> [URL] {
            guard !damaged.isEmpty else { return files }
            let damaged = Set(damaged.map(\.standardizedFileURL))
            return files.filter { !damaged.contains($0.standardizedFileURL) }
        }
    }

    /// Checks up to the first `maxChecked` of `files`. `isCancelled` is asked before each file; once it says yes
    /// the check stops, and the report (of the files checked so far) is not meant to be used.
    static func check(_ files: [URL], formats: FormatRegistry = .builtIn,
                      isCancelled: @Sendable () -> Bool = { false }) async -> Report {
        var damaged: [URL] = []
        var facts: [URL: SourceFacts] = [:]
        var everyFileChecked = files.count <= maxChecked
        for file in files.prefix(maxChecked) {
            if isCancelled() { return Report(damaged: damaged, allDamaged: false, facts: facts) }
            let inspection = await inspect(file, formats: formats)
            facts[file] = inspection.facts
            switch inspection.verdict {
            case .damaged: damaged.append(file)
            case .readable: break
            case .unchecked: everyFileChecked = false
            }
        }
        return Report(damaged: damaged, allDamaged: everyFileChecked && !files.isEmpty && damaged.count == files.count,
                      facts: facts)
    }

    /// A file's verdict and the facts found on the way. `facts` is nil for a file the check does not look at.
    struct Inspection: Equatable, Sendable {
        var verdict: Verdict
        var facts: SourceFacts?
    }

    /// What probing an audio or video file found.
    struct MediaProbe: Equatable, Sendable {
        var verdict: Verdict
        var duration: Double?
    }

    /// The verdict for one file. A folder, a missing file, one whose size cannot be read and one that is not fully
    /// on this Mac are unchecked: the job reports those itself. Nothing here reads a placeholder's contents.
    /// `isLocal` and `probeMedia` are parameters so the tests can stand in for a placeholder and for AVFoundation.
    static func verdict(
        for url: URL, formats: FormatRegistry = .builtIn,
        isLocal: (URL, URLUbiquitousItemDownloadingStatus?) -> Bool = { url, status in
            FileReadability.isLocal(statFlags: statFlags(of: url), downloadingStatus: status)
        },
        probeMedia: @Sendable (URL) async -> Verdict = { await FileReadability.probeMedia($0).verdict }
    ) async -> Verdict {
        await inspect(url, formats: formats, isLocal: isLocal,
                      probeMedia: { MediaProbe(verdict: await probeMedia($0), duration: nil) }).verdict
    }

    /// `verdict(for:)` plus the facts the size estimate needs. Facts exist only for a file that is on this Mac, so a
    /// placeholder never has any; bytes always come from the size already read, dimensions from the image's header
    /// (no decode) and the duration from the asset the media probe loads.
    static func inspect(
        _ url: URL, formats: FormatRegistry = .builtIn,
        isLocal: (URL, URLUbiquitousItemDownloadingStatus?) -> Bool = { url, status in
            FileReadability.isLocal(statFlags: statFlags(of: url), downloadingStatus: status)
        },
        probeMedia: @Sendable (URL) async -> MediaProbe = { await FileReadability.probeMedia($0) }
    ) async -> Inspection {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                              .ubiquitousItemDownloadingStatusKey]),
              values.isRegularFile == true, let size = values.fileSize else {
            return Inspection(verdict: .unchecked, facts: nil)
        }
        guard isLocal(url, values.ubiquitousItemDownloadingStatus) else {
            return Inspection(verdict: .unchecked, facts: nil)
        }
        var facts = SourceFacts(bytes: Int64(size))
        if size == 0 { return Inspection(verdict: .damaged, facts: facts) }
        guard let format = formats.format(for: url) else { return Inspection(verdict: .unchecked, facts: facts) }
        // ImageIO, PDFKit and AVFoundation report a file they may not open (the user declined macOS's prompt for a
        // protected folder, or no read permission) as unreadable: that is not damage, so it stays unchecked.
        guard isOpenable(url) else { return Inspection(verdict: .unchecked, facts: facts) }
        let verdict: Verdict
        switch format.category {
        case .image:
            // Only formats ImageIO reads (SVG is an image format it does not): anything else would look damaged.
            guard let type = format.utTypeIdentifier, imageIOTypes.contains(type) else {
                return Inspection(verdict: .unchecked, facts: facts)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return Inspection(verdict: .damaged, facts: facts) }
            verdict = CGImageSourceGetStatus(source) == .statusComplete && CGImageSourceGetCount(source) > 0
                ? .readable : .damaged
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            facts.pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
            facts.pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else { return Inspection(verdict: .damaged, facts: facts) }
            verdict = document.numberOfPages > 0 ? .readable : .damaged
        case .video, .audio:
            // Matroska, WebM, AVI, Ogg and Opus are not AVFoundation's: they would look damaged.
            guard avFoundationFormats.contains(format.id) else { return Inspection(verdict: .unchecked, facts: facts) }
            let probe = await probeMedia(url)
            verdict = probe.verdict
            facts.durationSeconds = probe.duration
        case .document:
            verdict = documentVerdict(for: url, format: format.id, size: size)
        case .archive:
            verdict = archiveVerdict(for: url, format: format.id)
        default:
            verdict = .unchecked
        }
        return Inspection(verdict: verdict, facts: facts)
    }

    /// Whether this process may open `url` for reading.
    static func isOpenable(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    // MARK: Audio and video

    static let avFoundationFormats: Set<FormatID> = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "caf", "flac"]

    /// What AVFoundation found in a media file.
    struct MediaFacts: Equatable, Sendable {
        var isReadable: Bool
        var isPlayable: Bool
        var hasTracks: Bool
    }

    /// P41: damaged only when unreadable or without an audio or video track. A file AVFoundation can't play (DNxHD,
    /// MPEG-2, VP9, AV1) may still convert through ffmpeg, so it is unchecked.
    static func verdict(for facts: MediaFacts) -> Verdict {
        guard facts.isReadable, facts.hasTracks else { return .damaged }
        return facts.isPlayable ? .readable : .unchecked
    }

    /// Opens `url` as an asset and judges what it finds, within `mediaLimit`. The duration comes from the same asset.
    static func probeMedia(_ url: URL) async -> MediaProbe {
        // Precise timing would make AVFoundation scan a whole MP3 or a long movie.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let probe = await bounded(mediaLimit) {
            do {
                let (isReadable, isPlayable) = try await asset.load(.isReadable, .isPlayable)
                guard isReadable else { return MediaProbe(verdict: .damaged, duration: nil) }
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let duration = (try? await asset.load(.duration))?.seconds
                return MediaProbe(
                    verdict: FileReadability.verdict(for: MediaFacts(isReadable: isReadable, isPlayable: isPlayable,
                                                                     hasTracks: !video.isEmpty || !audio.isEmpty)),
                    duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
            } catch {
                return MediaProbe(verdict: .damaged, duration: nil)
            }
        }
        if probe.verdict == .unchecked { asset.cancelLoading() }
        return probe
    }

    /// `work`'s probe, or an unchecked one once `limit` has passed. Returns at the limit even when `work` ignores
    /// cancellation: AVFoundation's loading may not stop at once, so it is left to finish on its own.
    static func bounded(_ limit: Duration, _ work: @escaping @Sendable () async -> MediaProbe) async -> MediaProbe {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let resume: @Sendable (MediaProbe) -> Void = { probe in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: probe) }
            }
            let timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                resume(MediaProbe(verdict: .unchecked, duration: nil))
            }
            Task {
                resume(await work())
                timer.cancel()
            }
        }
    }

    // MARK: Documents

    /// The zip containers' end-of-central-directory record: 22 bytes, after at most a 65,535-byte comment.
    private static let zipEndRecord: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let zipTailLength = 66 * 1024
    private static let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let rtfHeader = Array("{\\rtf".utf8)

    /// Magic numbers only. Text, HTML, Markdown and the like stay unchecked: any bytes may be valid.
    private static func documentVerdict(for url: URL, format: FormatID, size: Int) -> Verdict {
        switch format {
        case "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub":
            guard let tail = read(url, last: min(size, zipTailLength)) else { return .unchecked }
            return tail.firstRange(of: zipEndRecord) != nil ? .readable : .damaged
        case "doc", "xls", "ppt":
            guard let head = read(url, first: 512) else { return .unchecked }
            if head.starts(with: oleSignature) { return .readable }
            return isTextExport(head) ? .unchecked : .damaged
        case "rtf":
            guard let head = read(url, first: rtfHeader.count) else { return .unchecked }
            return head.elementsEqual(rtfHeader) ? .readable : .damaged
        default:
            return .unchecked
        }
    }

    // MARK: Archives

    private static let zipLocalHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let gzipHeader: [UInt8] = [0x1F, 0x8B]
    private static let rarHeader: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]
    private static let tarMagic = Array("ustar".utf8)
    private static let tarMagicOffset = 257

    /// Magic numbers only. A zip starts with a local file header, or is only the end record when empty.
    private static func archiveVerdict(for url: URL, format: FormatID) -> Verdict {
        guard let head = read(url, first: tarMagicOffset + tarMagic.count) else { return .unchecked }
        let matches: Bool
        switch format {
        case "zip": matches = head.starts(with: zipLocalHeader) || head.starts(with: zipEndRecord)
        case "gz", "tgz": matches = head.starts(with: gzipHeader)
        case "rar": matches = head.starts(with: rarHeader)
        case "tar": matches = head.dropFirst(tarMagicOffset).starts(with: tarMagic)
        default: return .unchecked
        }
        return matches ? .readable : .damaged
    }

    /// P42: HTML, XML or RTF saved under an Office extension (bank exports save HTML as .xls), which Office opens and
    /// a converter may too: `<` or `{\rtf` after an optional UTF-8 BOM and whitespace.
    static func isTextExport(_ head: [UInt8]) -> Bool {
        var bytes = head[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C]
        bytes = bytes.drop { whitespace.contains($0) }
        return bytes.starts(with: Array("<".utf8)) || bytes.starts(with: rtfHeader)
    }

    private static func read(_ url: URL, first count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            return Array(try handle.read(upToCount: count) ?? Data())
        } catch {
            return nil
        }
    }

    private static func read(_ url: URL, last count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - min(end, UInt64(count)))
            return Array(try handle.readToEnd() ?? Data())
        } catch {
            return nil
        }
    }

    // MARK: Placeholders

    /// True when a file's contents are on this Mac: it is not dataless (the flag a File Provider placeholder, such
    /// as an evicted iCloud Drive file, carries) and, when it is an iCloud item, its downloaded copy is current.
    static func isLocal(statFlags: UInt32?, downloadingStatus: URLUbiquitousItemDownloadingStatus?) -> Bool {
        if let statFlags, statFlags & UInt32(SF_DATALESS) != 0 { return false }
        if let downloadingStatus, downloadingStatus != .current { return false }
        return true
    }

    /// The file's BSD flags, without following a symlink and without reading (so without downloading) anything.
    static func statFlags(of url: URL) -> UInt32? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_flags : nil
    }

    /// The type identifiers ImageIO can read on this Mac.
    private static let imageIOTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
}
