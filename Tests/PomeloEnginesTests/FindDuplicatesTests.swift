import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

private struct FakePrint: ImageFingerprint {
    let value: Float

    func distance(to other: any ImageFingerprint) -> Float {
        guard let other = other as? FakePrint else { return .infinity }
        return abs(value - other.value)
    }
}

/// Prints keyed by file name: two files are as far apart as their values. Records every file it was asked for and
/// the context it was given, and runs `onPrint` before each print.
private final class FakePrints: ImageFingerprinting, @unchecked Sendable {
    private let values: [String: Float]
    private let onPrint: @Sendable () -> Void
    private let lock = NSLock()
    private var names: [String] = []
    private var drawnWith: [ObjectIdentifier] = []

    init(_ values: [String: Float], onPrint: @escaping @Sendable () -> Void = {}) {
        self.values = values
        self.onPrint = onPrint
    }

    var asked: [String] { lock.withLock { names } }
    var contexts: [ObjectIdentifier] { lock.withLock { drawnWith } }

    func fingerprint(of image: URL, using context: CIContext) throws -> any ImageFingerprint {
        onPrint()
        lock.withLock {
            names.append(image.lastPathComponent)
            drawnWith.append(ObjectIdentifier(context))
        }
        guard let value = values[image.lastPathComponent] else {
            throw Fixtures.Failure("no print for \(image.lastPathComponent)")
        }
        return FakePrint(value: value)
    }
}

/// Holds a task for a print to cancel; waits a little for it to be set, since the print can start first.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, any Error>?

    func set(_ task: Task<URL, any Error>) { lock.withLock { self.task = task } }

    func cancel() {
        for _ in 0..<200 {
            if let task = lock.withLock({ task }) {
                task.cancel()
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    var all: [Double] { lock.withLock { values } }

    func record(_ value: Double) { lock.withLock { values.append(value) } }
}

/// Find duplicates (P263): identical bytes, then look-alike prints of one picture per identical group, as a report.
@Suite struct FindDuplicatesTests {
    private func engine(_ prints: any ImageFingerprinting) -> VisionEngine {
        VisionEngine(fingerprinter: prints, lookAlikeThreshold: 0.5)
    }

    private func step(_ inputs: [URL], staging: URL) throws -> CombineStep {
        let formats = try inputs.map { input in
            let id = FormatID(input.pathExtension == "jpeg" ? "jpg" : input.pathExtension)
            return try #require(FormatRegistry.builtIn.format(id: id))
        }
        let txt = try #require(FormatRegistry.builtIn.format(id: "txt"))
        return CombineStep(inputs: inputs, formats: formats, stagingDirectory: staging, to: txt, operation: "find-duplicates")
    }

    private func staging(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    /// The report for `inputs`, or the sentence it was not applicable with.
    private func report(_ inputs: [URL], _ prints: any ImageFingerprinting, in dir: URL) async throws -> String {
        let staging = try staging(in: dir)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let output = try await engine(prints).combine(try step(inputs, staging: staging), progress: { _ in })
            return try String(contentsOf: output, encoding: .utf8)
        } catch ConversionError.notApplicable(let reason) {
            #expect(try contents(staging).isEmpty)
            return reason
        }
    }

    /// A photo-like JPEG `width` x `height` named `name`.
    private func photo(_ name: String, width: Int = 200, height: Int = 150, in dir: URL) throws -> URL {
        let made = try Fixtures.photo(width: width, height: height, type: "public.jpeg", ext: "jpg", in: dir)
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    private func copy(_ url: URL, as name: String) throws -> URL {
        let copy = url.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    // MARK: Identical

    @Test func identicalBytesGroupWhateverTheName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let aCopy = try copy(a, as: "a copy.jpeg")
        // Same size as a, one byte different inside the picture's data: not identical.
        var bytes = try Data(contentsOf: a)
        bytes[bytes.count - 100] ^= 0xFF
        let tweaked = dir.appending(path: "tweaked.jpg")
        try bytes.write(to: tweaked)
        let prints = FakePrints(["a.jpg": 0, "a copy.jpeg": 0, "tweaked.jpg": 10])

        let text = try await report([a, tweaked, aCopy], prints, in: dir)

        #expect(text == "1 group of identical files, 1 extra file\n\nIdentical\na.jpg\na copy.jpeg\n")
        #expect(prints.asked == ["a.jpg", "tweaked.jpg"])
    }

    @Test func sameFileGivenTwiceIsNotADuplicate() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let link = dir.appending(path: "link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let dotted = dir.appending(path: "./a.jpg")
        let prints = FakePrints(["a.jpg": 0, "link.jpg": 0, "b.jpg": 10])

        #expect(try await report([a, dotted, link], prints, in: dir) == DuplicateReport.fewerThanTwoReason)

        let b = try photo("b.jpg", width: 210, in: dir)
        #expect(try await report([a, link, b, a], prints, in: dir) == DuplicateReport.noneFoundReason)
        #expect(prints.asked == ["a.jpg", "b.jpg"])
    }

    // MARK: Look alike

    @Test func lookAlikeUsesRepresentatives() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try photo("c.jpg", width: 300, height: 200, in: dir)
        let b = try photo("b.jpg", in: dir)
        let a = try copy(b, as: "a.jpg")
        // a would join c's group if it were compared on its own; only b, the first of the identical pair, is.
        let prints = FakePrints(["a.jpg": 0.45, "b.jpg": 0, "c.jpg": 0.4])

        let text = try await report([c, b, a], prints, in: dir)

        #expect(text == """
            1 group of identical files, 1 group that looks alike, 2 extra files

            Identical
            b.jpg
            a.jpg

            Looks alike
            c.jpg
            b.jpg

            """)
        #expect(prints.asked == ["c.jpg", "b.jpg"])
    }

    /// A Core Image context holds caches and Metal state: one is made per run and shared by every print (the final
    /// review measured about 3 MB held per image when each print made its own).
    @Test func everyPrintOfARunDrawsWithOneContext() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.jpg", "b.jpg", "c.jpg"].enumerated().map { index, name in
            try photo(name, width: 200 + index, in: dir)
        }
        let prints = FakePrints(["a.jpg": 0, "b.jpg": 0.1, "c.jpg": 9])
        _ = try await report(files, prints, in: dir)
        #expect(prints.asked == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(prints.contexts.count == 3 && Set(prints.contexts).count == 1)
    }

    @Test func lookAlikeGroupsAreSingleLinkAcrossFiles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["p.jpg", "q.jpg", "r.jpg", "s.jpg"].enumerated().map { index, name in
            try photo(name, width: 200 + index, in: dir)
        }
        // p–q and q–r are close, p–r is not; s is far from all.
        let prints = FakePrints(["p.jpg": 0, "q.jpg": 0.4, "r.jpg": 0.8, "s.jpg": 9])

        let text = try await report(files, prints, in: dir)

        #expect(text == "1 group that looks alike, 2 extra files\n\nLooks alike\nr.jpg\nq.jpg\np.jpg\n")
    }

    // MARK: Sentences and failures

    @Test func fewerThanTwoImages() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let prints = FakePrints(["a.jpg": 0])
        #expect(try await report([a], prints, in: dir) == "Choose two or more images")
        #expect(try await report([], prints, in: dir) == "Choose two or more images")
        #expect(prints.asked.isEmpty)
    }

    @Test func moreThan500() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let copies = try (1...500).map { try copy(a, as: "a-\($0).jpg") }
        let prints = FakePrints(["a.jpg": 0])

        #expect(try await report([a] + copies, prints, in: dir) == "That's too many images to compare (500 at most)")

        let five = try await report(Array(([a] + copies).prefix(500)), prints, in: dir)
        #expect(five.hasPrefix("1 group of identical files, 499 extra files\n\nIdentical\na.jpg\na-1.jpg\n"))
        #expect(prints.asked.isEmpty)
    }

    @Test func noGroupsIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let b = try photo("b.jpg", width: 220, in: dir)
        #expect(try await report([a, b], FakePrints(["a.jpg": 0, "b.jpg": 5]), in: dir) == "No duplicates found")
    }

    @Test func damagedImageIsNamed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let b = try photo("b.jpg", width: 220, in: dir)
        let bad = try Fixtures.textFile("not a picture", ext: "png", in: dir)
        let staging = try staging(in: dir)
        let prints = FakePrints(["a.jpg": 0, "b.jpg": 0.1])

        await #expect {
            _ = try await engine(prints).combine(try step([a, b, bad], staging: staging), progress: { _ in })
        } throws: { error in
            (error as? CombineInputError)?.input == bad
        }
        #expect(try contents(staging).isEmpty)
    }

    @Test func aPictureVisionCannotReadIsNamed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let b = try photo("b.jpg", width: 220, in: dir)
        let staging = try staging(in: dir)

        await #expect {
            _ = try await engine(FakePrints(["a.jpg": 0])).combine(try step([a, b], staging: staging), progress: { _ in })
        } throws: { error in
            (error as? CombineInputError)?.input == b
        }
    }

    @Test func reportIsNamedAfterTheFirstImage() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try photo("holiday 1.jpg", in: dir)
        let second = try copy(first, as: "holiday 2.jpg")
        let other = try photo("other.jpg", width: 230, in: dir)
        let staging = try staging(in: dir)
        let fractions = Fractions()
        let prints = FakePrints(["holiday 1.jpg": 0, "other.jpg": 7])

        let output = try await engine(prints).combine(
            try step([first, second, other], staging: staging), progress: { fractions.record($0) }
        )

        #expect(output == staging.appending(path: "holiday 1.txt"))
        #expect(try contents(staging) == ["holiday 1.txt"])
        #expect(fractions.all.last == 1)
        #expect(fractions.all == fractions.all.sorted())
        #expect(fractions.all.contains { $0 > 0 && $0 < 1 })
    }

    @Test func cancellingLeavesNothing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.jpg", "b.jpg", "c.jpg"].enumerated().map { index, name in
            try photo(name, width: 200 + index, in: dir)
        }
        let staging = try staging(in: dir)
        let box = TaskBox()
        let prints = FakePrints(["a.jpg": 0, "b.jpg": 0.1, "c.jpg": 0.2]) { box.cancel() }
        let combine = try step(files, staging: staging)
        let engine = engine(prints)

        let task = Task { try await engine.combine(combine, progress: { _ in }) }
        box.set(task)

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(prints.asked.count < 3)
        #expect(try contents(staging).isEmpty)
    }

    @Test func throughTheRunnerTheReportIsPublishedWithItsSuffix() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try photo("a.jpg", in: dir)
        let b = try copy(a, as: "b.jpg")
        let runner = JobRunner(
            registry: EngineRegistry(engines: [engine(FakePrints(["a.jpg": 0]))], priority: ["vision"]),
            destinations: DestinationResolver(downloadsFolder: dir, isWritable: { _ in true }),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
        let preset = try #require(Preset.builtIns.first { $0.id == "find-duplicates" })
        let results = await runner.run(ConversionRequest.from(preset, inputs: [a, b]))

        guard case .succeeded(_, let outputs, _) = try #require(results.first), let output = outputs.first else {
            Issue.record("\(results)")
            return
        }
        #expect(output.lastPathComponent == "a-duplicates.txt")
        #expect(try String(contentsOf: output, encoding: .utf8).hasPrefix("1 group of identical files, 1 extra file\n"))
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }

    // MARK: Digest

    @Test func digestIsTheSHA256OfTheWholeFile() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let abc = try Fixtures.textFile("abc", ext: "txt", in: dir)
        let known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try FileDigest.sha256(of: abc, isCancelled: { false }).map { String(format: "%02x", $0) }.joined() == known)

        // Three and a half reads' worth, so the stream crosses read boundaries.
        let big = Data((0..<3_670_016).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let file = try Fixtures.textFile(big, ext: "bin", in: dir)
        #expect(try FileDigest.sha256(of: file, isCancelled: { false }) == Data(SHA256.hash(data: big)))
    }

    @Test func digestStopsWhenCancelled() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try Fixtures.textFile(Data(count: 3_000_000), ext: "bin", in: dir)
        let checks = Fractions()
        #expect(throws: CancellationError.self) {
            _ = try FileDigest.sha256(of: file, isCancelled: {
                checks.record(0)
                return checks.all.count > 1
            })
        }
        #expect(checks.all.count == 2)
    }

    // MARK: Real Vision

    /// A generated photographic scene and its copies, printed by the real `SystemImageFingerprinter`, grouped at the
    /// engine's own threshold (P268). The rotated copy is stored sideways with orientation 6, so it only looks like
    /// the original once it is turned upright.
    @Test func realPrintsGroupReencodedAndResizedCopies() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Fixtures.scene(seed: 1, width: 1200, height: 900, in: dir)
        let resized = try Fixtures.copy(of: original, scale: 0.5, quality: 0.9, type: "public.jpeg", ext: "jpg", in: dir)
        let reencoded = try Fixtures.copy(of: original, quality: 0.5, type: "public.jpeg", ext: "jpg", in: dir)
        let png = try Fixtures.copy(of: original, type: "public.png", ext: "png", in: dir)
        let rotated = try Fixtures.copy(of: original, orientation6: true, type: "public.jpeg", ext: "jpg", in: dir)
        let unrelated = try Fixtures.scene(seed: 2, width: 1200, height: 900, in: dir)
        let threshold = VisionEngine.defaultLookAlikeThreshold
        let (fingerprinter, context) = (SystemImageFingerprinter(), CIContext())
        let print = try fingerprinter.fingerprint(of: original, using: context)
        func distance(_ url: URL) throws -> Float {
            print.distance(to: try fingerprinter.fingerprint(of: url, using: context))
        }

        #expect(try distance(resized) < threshold)
        #expect(try distance(reencoded) < threshold)
        #expect(try distance(png) < threshold)
        #expect(try distance(unrelated) > threshold)

        let staging = try staging(in: dir)
        let output = try await VisionEngine().combine(
            try step([original, resized, reencoded, png, rotated, unrelated], staging: staging), progress: { _ in }
        )
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.hasPrefix("1 group that looks alike, 4 extra files\n"))
        #expect(!text.contains(unrelated.lastPathComponent))
        // exifRotatedCopyLooksAlike
        #expect(try distance(rotated) < threshold)
    }

    /// Two frames of one scene, the subject moved a little between them, as a burst takes them (P263: they must not
    /// group).
    @Test func realPrintsKeepBurstFramesApart() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Fixtures.scene(seed: 1, width: 1200, height: 900, in: dir)
        let next = try Fixtures.scene(seed: 1, frame: 1, width: 1200, height: 900, in: dir)
        let (fingerprinter, context) = (SystemImageFingerprinter(), CIContext())
        let distance = try fingerprinter.fingerprint(of: first, using: context)
            .distance(to: try fingerprinter.fingerprint(of: next, using: context))
        #expect(distance > VisionEngine.defaultLookAlikeThreshold)
    }

    /// The fixture's rotated copy is the original once its orientation is applied.
    @Test func theRotatedCopyIsUprightOnceTurned() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Fixtures.scene(seed: 1, width: 300, height: 200, in: dir)
        let rotated = try Fixtures.copy(of: original, orientation6: true, type: "public.jpeg", ext: "jpg", in: dir)
        let stored = try #require(Fixtures.imageSize(rotated))
        #expect(stored == CGSize(width: 200, height: 300))

        func upright(_ url: URL) throws -> CGImage {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try OrientedImage.decodeUpright(source)
        }
        let turned = try upright(rotated)
        #expect(turned.width == 300 && turned.height == 200)
        let a = try tiny(try upright(original)), b = try tiny(turned)
        let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255
        #expect(worst < 40)
    }

    /// `image` drawn as 6 x 4 RGBA bytes.
    private func tiny(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 6 * 4 * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 24,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 6, height: 4))
            return true
        }
        try #require(drawn)
        return bytes
    }
}
