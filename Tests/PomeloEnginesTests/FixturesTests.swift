import AVFoundation
import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
import PomeloTestSupport

private final class Renders: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    var all: [Data] { lock.withLock { values } }

    func add(_ value: Data) { lock.withLock { values.append(value) } }
}

@Suite struct FixturesTests {
    @Test func fixturesProduceReadableFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = try Fixtures.png(width: 40, height: 30, in: dir)
        #expect(Fixtures.imageUTType(png) == "public.png")
        #expect(Fixtures.imageSize(png) == CGSize(width: 40, height: 30))

        let alphaPNG = try Fixtures.png(width: 10, height: 10, alpha: true, in: dir)
        let alphaSource = try #require(CGImageSourceCreateWithURL(alphaPNG as CFURL, nil))
        let alphaProperties = try #require(CGImageSourceCopyPropertiesAtIndex(alphaSource, 0, nil) as? [CFString: Any])
        #expect(alphaProperties[kCGImagePropertyHasAlpha] as? Bool == true)

        let jpg = try Fixtures.jpgWithGPS(in: dir)
        #expect(Fixtures.imageUTType(jpg) == "public.jpeg")
        let jpgSource = try #require(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        let jpgProperties = try #require(CGImageSourceCopyPropertiesAtIndex(jpgSource, 0, nil) as? [CFString: Any])
        let gps = try #require(jpgProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(gps[kCGImagePropertyGPSLatitude] as? Double == 45.0)

        let text = try Fixtures.textImage("Hello Pomelo", in: dir)
        #expect(Fixtures.imageSize(text) == CGSize(width: 1000, height: 200))

        let pdf = try Fixtures.pdf(pages: 3, in: dir)
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(document.page(at: 1)?.string?.contains("Page 2") == true)

        let wav = try Fixtures.wav(seconds: 0.5, in: dir)
        let wavFile = try AVAudioFile(forReading: wav)
        #expect(wavFile.fileFormat.sampleRate == 44_100)
        #expect(wavFile.fileFormat.channelCount == 1)
        #expect(wavFile.length == 22_050)

        for withAudio in [false, true] {
            let movie = try await Fixtures.movie(seconds: 1, withAudio: withAudio, in: dir)
            let asset = AVURLAsset(url: movie)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            #expect(video.count == 1)
            #expect(audio.count == (withAudio ? 1 : 0))
            let size = try await #require(video.first).load(.naturalSize)
            #expect(size == CGSize(width: 320, height: 240))
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 1) < 0.2)
        }

        let rtf = try Fixtures.rtf("Hello RTF", in: dir)
        let attributed = try NSAttributedString(
            url: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        )
        #expect(attributed.string == "Hello RTF")
    }

    /// Feeding the video input alone while the writer waited for audio hung on clips this long.
    @Test(.timeLimit(.minutes(1))) func aLongMovieWithAudioIsWritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 20, withAudio: true, in: dir)
        let asset = AVURLAsset(url: movie)
        #expect(abs(try await asset.load(.duration).seconds - 20) < 0.2)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func mediaFixturesForTheTools() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tagged = try await Fixtures.movieWithLocationAndTitle(seconds: 1, in: dir)
        var values: Set<String> = []
        for item in try await AVURLAsset(url: tagged).load(.metadata) {
            if let value = try await item.load(.stringValue) { values.insert(value) }
        }
        #expect(values == [Fixtures.movieTitle, Fixtures.movieLocation])

        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        let sideways = try await Fixtures.movie(seconds: 0.5, withAudio: false, transform: quarterTurn, in: dir)
        let track = try #require(try await AVURLAsset(url: sideways).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform) == quarterTurn)

        let stereo = try Fixtures.stereoWavWithSilentRight(seconds: 0.5, in: dir)
        let file = try AVAudioFile(forReading: stereo, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let frames = 0..<Int(buffer.frameLength)
        #expect(file.fileFormat.channelCount == 2)
        #expect(frames.contains { abs(channels[0][$0]) > 0.4 })
        #expect(frames.allSatisfy { channels[1][$0] == 0 })
    }

    /// Core Graphics fills a translucent antialiased path differently while another thread draws (final review:
    /// parallel renders of one scene gave up to 24 different pictures), and Swift Testing runs suites in parallel. The
    /// scene's comparisons (Find duplicates' distances, P268) need the same pixels every time.
    @Test func aSceneDrawsTheSamePixelsWhileOthersDraw() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = Renders()
        // Every other worker draws `photo`, whose strokes and blobs are translucent and antialiased.
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            guard index.isMultiple(of: 2) else {
                _ = try? Fixtures.photo(width: 600, height: 450, type: "public.png", ext: "png", in: dir)
                return
            }
            let bytes = (try? Fixtures.scene(seed: 1, width: 600, height: 450, in: dir)).flatMap { try? Data(contentsOf: $0) }
            made.add(bytes ?? Data())
        }
        let all = made.all
        #expect(all.count == 8 && !all[0].isEmpty)
        #expect(Set(all).count == 1)
    }

    @Test func presentationIsAWellFormedPackageOfItsSlides() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deck = try Fixtures.presentation(slides: 3, in: dir)
        #expect(deck.lastPathComponent == "deck.pptx")

        let unpacked = dir.appending(path: "unpacked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/bsdtar")
        tar.arguments = ["-x", "-f", deck.path, "-C", unpacked.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let walker = try #require(FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil))
        var parts: [String] = []
        for case let url as URL in walker where url.pathExtension == "xml" || url.pathExtension == "rels" {
            let parser = XMLParser(contentsOf: url)
            #expect(parser?.parse() == true, "\(url.lastPathComponent) is not well-formed")
            parts.append(url.lastPathComponent)
        }
        #expect(parts.filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") && !$0.contains("Layout") && !$0.contains("Master") }.count == 3)
        let presentation = try String(contentsOf: unpacked.appending(path: "ppt/presentation.xml"), encoding: .utf8)
        #expect(presentation.components(separatedBy: "<p:sldId ").count == 4)
    }
}
