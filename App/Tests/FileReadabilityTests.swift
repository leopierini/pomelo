import CoreGraphics
import Foundation
import ImageIO
import PomeloCore
import PomeloUIModel
import Testing
import UniformTypeIdentifiers
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func writePNG(to url: URL) throws {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}

/// Writes a one-page PDF.
private func writePDF(to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
    context.endPDFPage()
    context.closePDF()
}

/// A count shared with a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// Writes a .docx with textutil, as a person's Mac would make one.
private func writeDocx(to url: URL, in dir: URL) throws {
    let rtf = try Fixtures.rtf("Hello", in: dir)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    process.arguments = ["-convert", "docx", "-output", url.path, rtf.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Suite struct FileReadabilityTests {
    @Test func eachKindOfFileGetsItsVerdict() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)
        let corruptPNG = dir.appending(path: "bad.png")
        try Data("x".utf8).write(to: corruptPNG)
        let empty = dir.appending(path: "empty.txt")
        try Data().write(to: empty)
        let pdf = dir.appending(path: "doc.pdf")
        try writePDF(to: pdf)
        let corruptPDF = dir.appending(path: "bad.pdf")
        try Data("%PDF-1.4\nnot really a pdf\n".utf8).write(to: corruptPDF)
        let text = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        #expect(await FileReadability.verdict(for: png) == .readable)
        #expect(await FileReadability.verdict(for: corruptPNG) == .damaged)
        // Zero bytes is damaged whatever the format, even one the check otherwise leaves alone.
        #expect(await FileReadability.verdict(for: empty) == .damaged)
        #expect(await FileReadability.verdict(for: pdf) == .readable)
        #expect(await FileReadability.verdict(for: corruptPDF) == .damaged)
        #expect(await FileReadability.verdict(for: text) == .unchecked)
    }

    @Test func foldersMissingFilesAndFormatsImageIOCannotReadAreUnchecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = dir.appending(path: "logo.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: svg)

        #expect(await FileReadability.verdict(for: dir) == .unchecked)
        #expect(await FileReadability.verdict(for: dir.appending(path: "missing.png")) == .unchecked)
        #expect(await FileReadability.verdict(for: svg) == .unchecked)
    }

    @Test func aReportSaysWhetherEveryFileIsDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "a.png")
        try writePNG(to: good)
        let bad = dir.appending(path: "bad.png")
        try Data("x".utf8).write(to: bad)
        let worse = dir.appending(path: "worse.pdf")
        try Data().write(to: worse)
        let text = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        func verdicts(_ files: [URL]) async -> (damaged: [URL], allDamaged: Bool) {
            let report = await FileReadability.check(files)
            return (report.damaged, report.allDamaged)
        }
        #expect(await verdicts([good]) == ([], false))
        #expect(await verdicts([bad, worse]) == ([bad, worse], true))
        #expect(await verdicts([good, bad]) == ([bad], false))
        // An unchecked file might convert, so the files are not all damaged.
        #expect(await verdicts([bad, text]) == ([bad], false))
        #expect(await FileReadability.check([]) == .clean)
    }

    @Test func onlyTheFirstFiftyFilesAreChecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (0..<51).map { index in
            let url = dir.appending(path: "\(index).png")
            try Data().write(to: url)
            return url
        }

        let report = await FileReadability.check(files)
        #expect(report.damaged == Array(files.prefix(50)))
        #expect(!report.allDamaged)
    }

    @Test func readableFilesLeaveOutTheDamagedOnes() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let c = URL(fileURLWithPath: "/tmp/sub/../c.png")
        let report = FileReadability.Report(damaged: [b, URL(fileURLWithPath: "/tmp/c.png")], allDamaged: false)
        #expect(report.readable([a, b, c]) == [a])
        #expect(FileReadability.Report.clean.readable([a, b]) == [a, b])
    }

    /// An iCloud Drive or File Provider placeholder is never read: that would download it, or fail offline and
    /// look damaged. (A real evicted file can't be made here; reading one is in the manual checks.)
    @Test func aFileNotFullyOnThisMacIsUnchecked() {
        #expect(FileReadability.isLocal(statFlags: 0, downloadingStatus: nil))
        #expect(FileReadability.isLocal(statFlags: nil, downloadingStatus: .current))
        #expect(!FileReadability.isLocal(statFlags: UInt32(SF_DATALESS), downloadingStatus: nil))
        #expect(!FileReadability.isLocal(statFlags: UInt32(SF_DATALESS) | UInt32(UF_HIDDEN), downloadingStatus: .current))
        #expect(!FileReadability.isLocal(statFlags: 0, downloadingStatus: .notDownloaded))
        #expect(!FileReadability.isLocal(statFlags: 0, downloadingStatus: .downloaded))
    }

    @Test func aCancelledCheckStopsBeforeTheNextFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (0..<10).map { index in
            let url = dir.appending(path: "\(index).png")
            try Data().write(to: url)
            return url
        }
        let asked = Counter()
        let report = await FileReadability.check(files, isCancelled: { asked.increment() > 3 })
        #expect(report.damaged == Array(files.prefix(3)))
        #expect(!report.allDamaged)
    }

    // MARK: Audio and video

    @Test func aShortRealClipIsReadable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await Fixtures.movie(seconds: 1, withAudio: true, in: dir)
        let tone = try Fixtures.m4a(seconds: 1, in: dir)
        #expect(await FileReadability.verdict(for: clip) == .readable)
        #expect(await FileReadability.verdict(for: tone) == .readable)
    }

    @Test func sevenBytesNamedMovIsDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.mov")
        try Data("garbage".utf8).write(to: broken)
        let alsoBroken = dir.appending(path: "broken.wav")
        try Data("garbage".utf8).write(to: alsoBroken)
        #expect(await FileReadability.verdict(for: broken) == .damaged)
        #expect(await FileReadability.verdict(for: alsoBroken) == .damaged)
    }

    @Test func aZeroByteMP3IsDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appending(path: "empty.mp3")
        try Data().write(to: empty)
        #expect(await FileReadability.verdict(for: empty) == .damaged)
    }

    /// Matroska, WebM, AVI, Ogg and Opus are formats AVFoundation can't open: garbage would look damaged.
    @Test func aFormatAVFoundationCannotReadIsUnchecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["clip.mkv", "clip.webm", "clip.avi", "song.ogg", "song.opus"] {
            let file = dir.appending(path: name)
            try Data("garbage".utf8).write(to: file)
            #expect(await FileReadability.verdict(for: file) == .unchecked, "\(name)")
        }
    }

    /// A file iCloud hasn't downloaded is never opened, however its format would be checked.
    @Test func aPlaceholderVideoIsNeverOpened() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "broken.mov")
        try Data("garbage".utf8).write(to: broken)
        let probed = Counter()
        let verdict = await FileReadability.verdict(
            for: broken, isLocal: { _, _ in false },
            probeMedia: { _ in
                _ = probed.increment()
                return .damaged
            }
        )
        #expect(verdict == .unchecked)
        #expect(probed.count == 0)
    }

    /// P41: a file AVFoundation reads but can't play (DNxHD, MPEG-2, VP9, AV1) may still convert through ffmpeg.
    @Test func aMovieAVFoundationCannotPlayIsUncheckedNotDamaged() async throws {
        typealias Facts = FileReadability.MediaFacts
        #expect(FileReadability.verdict(for: Facts(isReadable: true, isPlayable: false, hasTracks: true)) == .unchecked)
        #expect(FileReadability.verdict(for: Facts(isReadable: true, isPlayable: true, hasTracks: true)) == .readable)
        #expect(FileReadability.verdict(for: Facts(isReadable: false, isPlayable: false, hasTracks: true)) == .damaged)
        #expect(FileReadability.verdict(for: Facts(isReadable: true, isPlayable: true, hasTracks: false)) == .damaged)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "dnxhd.mov")
        try Data("stands in for a DNxHD movie".utf8).write(to: movie)
        let verdict = await FileReadability.verdict(for: movie, probeMedia: { _ in
            FileReadability.verdict(for: Facts(isReadable: true, isPlayable: false, hasTracks: true))
        })
        #expect(verdict == .unchecked)
    }

    /// A probe that runs past the limit gives up: the file is unchecked, not damaged.
    @Test func aMediaProbeOverItsLimitIsUnchecked() async {
        let started = ContinuousClock.now
        let probe = await FileReadability.bounded(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(30))
            return .init(verdict: .damaged, duration: 5)
        }
        #expect(probe == .init(verdict: .unchecked, duration: nil))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func theCheckStopsBetweenVideos() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.mov", "b.mov", "c.mov"].map { name in
            let url = dir.appending(path: name)
            try Data("garbage".utf8).write(to: url)
            return url
        }
        let asked = Counter()
        let report = await FileReadability.check(files, isCancelled: { asked.increment() > 1 })
        #expect(report.damaged == [files[0]])
        #expect(!report.allDamaged)
    }

    // MARK: Documents

    @Test func aDocxWithoutAZipDirectoryIsDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appending(path: "a.docx")
        try Data("x".utf8).write(to: broken)
        let real = dir.appending(path: "real.docx")
        try writeDocx(to: real, in: dir)
        #expect(await FileReadability.verdict(for: broken) == .damaged)
        #expect(await FileReadability.verdict(for: real) == .readable)

        // The same zip check for every zip container.
        for ext in ["xlsx", "pptx", "odt", "ods", "odp", "epub"] {
            let file = dir.appending(path: "copy.\(ext)")
            try FileManager.default.copyItem(at: real, to: file)
            #expect(await FileReadability.verdict(for: file) == .readable, "\(ext)")
            let bad = dir.appending(path: "bad.\(ext)")
            try Data(repeating: 0x50, count: 100_000).write(to: bad)
            #expect(await FileReadability.verdict(for: bad) == .damaged, "\(ext)")
        }
    }

    /// Only the end-of-central-directory record decides, wherever it lies within the zip comment's reach.
    @Test func theZipRecordIsFoundWithinTheLast66KB() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)
        let near = dir.appending(path: "near.docx")
        try Data(Array(repeating: 0x41, count: 200_000) + record + Array(repeating: 0x20, count: 65_000))
            .write(to: near)
        let far = dir.appending(path: "far.docx")
        try Data(Array(repeating: 0x41, count: 1_000) + record + Array(repeating: 0x20, count: 70_000)).write(to: far)
        #expect(await FileReadability.verdict(for: near) == .readable)
        #expect(await FileReadability.verdict(for: far) == .damaged)
    }

    @Test func anOLEDocumentNeedsItsSignature() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for ext in ["doc", "xls", "ppt"] {
            let good = dir.appending(path: "good.\(ext)")
            try Data(signature + Array(repeating: 0, count: 504)).write(to: good)
            let bad = dir.appending(path: "bad.\(ext)")
            try Data("not a compound file".utf8).write(to: bad)
            #expect(await FileReadability.verdict(for: good) == .readable, "\(ext)")
            #expect(await FileReadability.verdict(for: bad) == .damaged, "\(ext)")
        }
    }

    /// P42: bank exports save HTML (or RTF) as .xls; Office opens them, so they aren't damaged.
    @Test func anHTMLOrRTFExportUnderAnOfficeNameIsUnchecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exports: [(String, [UInt8])] = [
            ("statement.xls", Array("<html><body><table></table></body></html>".utf8)),
            ("bom.xls", [0xEF, 0xBB, 0xBF] + Array("\r\n  <?xml version=\"1.0\"?><Workbook/>".utf8)),
            ("letter.doc", Array("{\\rtf1\\ansi Hello}".utf8)),
            ("spaced.ppt", Array("\n\t<table/>".utf8)),
        ]
        for (name, bytes) in exports {
            let file = dir.appending(path: name)
            try Data(bytes).write(to: file)
            #expect(await FileReadability.verdict(for: file) == .unchecked, "\(name)")
        }
        let notText = dir.appending(path: "garbage.xls")
        try Data("x<html>".utf8).write(to: notText)
        #expect(await FileReadability.verdict(for: notText) == .damaged)
    }

    @Test func anRTFWithoutItsHeaderIsDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = try Fixtures.rtf("Hello", in: dir)
        let broken = dir.appending(path: "broken.rtf")
        try Data("Hello, not RTF".utf8).write(to: broken)
        #expect(await FileReadability.verdict(for: real) == .readable)
        #expect(await FileReadability.verdict(for: broken) == .damaged)
    }

    /// Any bytes may be valid text, markup or subtitles.
    @Test func plainTextAndHTMLAreUnchecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "a.html", "a.md", "a.srt", "a.vtt", "a.svg"] {
            let file = dir.appending(path: name)
            try Data([0xFF, 0x00, 0x13]).write(to: file)
            #expect(await FileReadability.verdict(for: file) == .unchecked, "\(name)")
        }
    }

    @Test func archiveMagicsDecideReadability() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Holiday", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: folder.appending(path: "a.txt"))
        let zip = try Fixtures.zip(folder, named: "Holiday.zip", in: dir)
        let tar = try Fixtures.tar(entries: [.file("a.txt", Data("a".utf8))], named: "x.tar", in: dir)
        let tgz = dir.appending(path: "x.tgz")
        try FileManager.default.copyItem(at: try Fixtures.gzip(tar), to: tgz)
        let emptyZip = dir.appending(path: "empty.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: emptyZip)
        let rar = dir.appending(path: "x.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00] + [UInt8](repeating: 0, count: 32)).write(to: rar)

        for readable in [zip, emptyZip, tar, dir.appending(path: "x.tar.gz"), tgz, rar] {
            #expect(await FileReadability.verdict(for: readable) == .readable, "\(readable.lastPathComponent)")
        }
        for name in ["a.zip", "a.tar", "a.tgz", "a.gz", "a.rar"] {
            let file = dir.appending(path: name)
            try Data("x".utf8).write(to: file)
            #expect(await FileReadability.verdict(for: file) == .damaged, "\(name)")
        }
        // A zip renamed .tar is not a tar: its magic is not at offset 257.
        let misnamed = dir.appending(path: "zip.tar")
        try FileManager.default.copyItem(at: zip, to: misnamed)
        #expect(await FileReadability.verdict(for: misnamed) == .damaged)
    }

    // MARK: Facts for the size estimate

    @Test func factsComeFromTheSamePass() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)
        let note = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: note)
        let clip = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let tone = try Fixtures.m4a(seconds: 1, in: dir)
        let folder = dir.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let report = await FileReadability.check([png, note, clip, tone, folder])
        func size(_ url: URL) throws -> Int64 { Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!) }

        #expect(report.facts[png] == SourceFacts(bytes: try size(png), pixelWidth: 16, pixelHeight: 16))
        #expect(report.facts[note] == SourceFacts(bytes: 5))
        #expect(report.facts[folder] == nil)
        let clipFacts = try #require(report.facts[clip])
        #expect(clipFacts.bytes == (try size(clip)))
        #expect(abs((clipFacts.durationSeconds ?? 0) - 2) < 0.2)
        #expect(clipFacts.pixelWidth == nil)
        let toneFacts = try #require(report.facts[tone])
        #expect(abs((toneFacts.durationSeconds ?? 0) - 1) < 0.2)
    }

    /// A file Pomelo may not open (macOS refused a protected folder, or no read permission) is unchecked, not
    /// damaged: a declined privacy prompt must not paint the hub red.
    @Test func aFileThatCannotBeOpenedIsUncheckedNotDamaged() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "locked.png")
        try writePNG(to: png)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: png.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: png.path) }

        let inspection = await FileReadability.inspect(png, isLocal: { _, _ in true })
        #expect(inspection.verdict == .unchecked)
        #expect(inspection.facts?.bytes == Int64(try png.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1))
    }

    @Test func factsSkipPlaceholdersAndStopWhenCancelled() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)

        // A placeholder is never opened and has no facts, not even its size.
        let placeholder = await FileReadability.inspect(png, isLocal: { _, _ in false })
        #expect(placeholder == FileReadability.Inspection(verdict: .unchecked, facts: nil))

        let files = try (0..<10).map { index in
            let url = dir.appending(path: "\(index).png")
            try writePNG(to: url)
            return url
        }
        let asked = Counter()
        let report = await FileReadability.check(files, isCancelled: { asked.increment() > 3 })
        #expect(Set(report.facts.keys) == Set(files.prefix(3)))
    }

    @Test func aCleanReportStillCarriesFacts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appending(path: "a.png")
        try writePNG(to: png)
        let report = await FileReadability.check([png])
        #expect(report.damaged.isEmpty)
        #expect(!report.allDamaged)
        #expect(report.facts[png]?.pixelWidth == 16)
        #expect(report != .clean)
    }

    @Test func onlyTheFirstFiftyFilesHaveFacts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try (0..<51).map { index in
            let url = dir.appending(path: "\(index).txt")
            try Data("x".utf8).write(to: url)
            return url
        }
        let report = await FileReadability.check(files)
        #expect(report.facts.count == 50)
        #expect(report.facts[files[50]] == nil)
    }
}
