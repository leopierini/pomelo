import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloTestSupport
@testable import PomeloEvalsKit

/// A copy of `url` drawn at `size` (nil: its own), with uniform noise of standard deviation `sigma` added to every
/// channel, written as a PNG.
private func derived(from url: URL, size: (Int, Int)? = nil, sigma: Double = 0, in directory: URL) throws -> URL {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = size?.0 ?? image.width
    let height = size?.1 ?? image.height
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    if sigma > 0 {
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // A uniform distribution of standard deviation sigma spans sigma * sqrt(3) either way.
        let reach = sigma * 3.0.squareRoot()
        var generator = SystemRandomNumberGenerator()
        for index in 0..<(width * height * 4) where index % 4 != 3 {
            let noisy = Double(bytes[index]) + Double.random(in: -reach...reach, using: &generator)
            bytes[index] = UInt8(max(0, min(255, noisy.rounded())))
        }
    }
    let output = directory.appending(path: "derived-\(UUID().uuidString).png")
    let destination = try #require(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return output
}

@Suite struct OutputQualityTests {
    @Test func ssimOfAnImageWithItselfIsOne() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 256, height: 192, type: "public.png", ext: "png", in: dir)
        #expect(try #require(OutputCheck.ssim(photo, photo)) > 0.999)
    }

    @Test func ssimDropsForANoisyCopy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 256, height: 192, type: "public.png", ext: "png", in: dir)
        let noisy = try derived(from: photo, sigma: 25, in: dir)
        #expect(try #require(OutputCheck.ssim(photo, noisy)) < 0.8)
    }

    @Test func ssimComparesDifferentSizesAtTheSmaller() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 256, height: 192, type: "public.png", ext: "png", in: dir)
        let half = try derived(from: photo, size: (128, 96), in: dir)
        let value = try #require(OutputCheck.ssim(photo, half))
        #expect(value > 0.9)
        #expect(OutputCheck.ssim(half, photo) == value)
    }

    @Test func ssimOfSomethingThatIsNotAnImageIsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 64, height: 64, type: "public.png", ext: "png", in: dir)
        let text = dir.appending(path: "a.txt")
        try Data("not an image".utf8).write(to: text)
        #expect(OutputCheck.ssim(photo, text) == nil)
        #expect(OutputCheck.ssim(photo, dir.appending(path: "missing.png")) == nil)
    }

    @Test func ssimOfAVideoIsOfItsFirstFrame() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        #expect(try #require(OutputCheck.ssim(clip, clip)) > 0.999)
        let still = try Fixtures.photo(width: 320, height: 240, type: "public.png", ext: "png", in: dir)
        #expect(try #require(OutputCheck.ssim(clip, still)) < 0.999)
    }

    /// `Corpus` makes clip.mov with `Fixtures.movie(seconds: 10, …)`, which writes 30 frames per second (P141).
    @Test func frameCountOfTheCorpusClip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await Fixtures.movie(seconds: 10, withAudio: true, in: dir)
        #expect(OutputCheck.frameCount(clip) == 300)
    }

    @Test func frameCountIsNilForWhatHasNoVideo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(OutputCheck.frameCount(try Fixtures.wav(seconds: 1, channels: 1, in: dir)) == nil)
        #expect(OutputCheck.frameCount(dir.appending(path: "missing.mov")) == nil)
    }

    @Test func aCaseBelowItsSSIMFloorFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 128, height: 96, type: "public.png", ext: "png", in: dir)
        let inspection = await OutputCheck.inspect(photo)
        let expect = EvalCase.Expect(ssimMin: 0.99)
        #expect(OutputCheck.failures(inspection, expect: expect, ssim: 0.93) == ["SSIM is 0.930, expected at least 0.99"])
        #expect(OutputCheck.failures(inspection, expect: expect, ssim: 0.995).isEmpty)
        let unmeasured = OutputCheck.failures(inspection, expect: expect)
        #expect(unmeasured.count == 1 && unmeasured[0].contains("SSIM"), "\(unmeasured)")
    }

    @Test func aWrongFrameCountFails() {
        var inspection = Inspection()
        inspection.opens = true
        inspection.videoFrames = 299
        let failures = OutputCheck.failures(inspection, expect: .init(frameCount: 300))
        #expect(failures == ["frameCount is 299, expected 300"])
        inspection.videoFrames = 300
        #expect(OutputCheck.failures(inspection, expect: .init(frameCount: 300)).isEmpty)
    }

    @Test func expectationsDecodeFromJSON() throws {
        let cases = try JSONDecoder().decode(
            [EvalCase].self,
            from: Data(#"[{"name":"c","input":"clip.mov","to":"mp4","expect":{"opens":true,"ssimMin":0.9,"frameCount":300}}]"#.utf8))
        #expect(cases[0].expect.ssimMin == 0.9)
        #expect(cases[0].expect.frameCount == 300)
    }

    @Test func qualityMetricsHaveTheirDefaults() {
        let ssim = MetricDefaults.metric(named: "edge.png-jpg.ssim", value: 0.97)
        #expect(ssim.better == .higher && ssim.unit == "")
        #expect(ssim.regressed(by: 0.90))
        #expect(!ssim.regressed(by: 0.965))
        let ratio = MetricDefaults.metric(named: "edge.compress-jpg.ratio", value: 0.3)
        #expect(ratio.better == .lower && ratio.unit == "x")
        #expect(ratio.regressed(by: 0.4))
        #expect(!ratio.regressed(by: 0.31))
    }
}

@Suite struct EdgeQualityMetricsTests {
    /// A stand-in for `pomelo convert --json` that "converts" its input into `product` (which it copies).
    private func fakeCLI(product: URL, in directory: URL) throws -> URL {
        let script = directory.appending(path: "fake-pomelo")
        let body = """
            #!/bin/sh
            # args: convert <input> ... -o <outputs> --json
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then outputs="$2"; fi
              shift
            done
            cp '\(product.path)' "$outputs/result.jpg"
            printf '{"results":[{"source":"x","status":"succeeded","outputs":["%s/result.jpg"]}]}' "$outputs"
            """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func size(_ url: URL) throws -> Double {
        Double(try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int))
    }

    @Test func compressCasesRecordTheirRatioAndSSIM() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = dir.appending(path: "corpus", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let original = try Fixtures.photo(width: 256, height: 192, type: "public.png", ext: "png", in: corpus)
        try FileManager.default.moveItem(at: original, to: corpus.appending(path: "photo.png"))
        let small = try Fixtures.photo(width: 256, height: 192, type: "public.jpeg", ext: "jpg", quality: 0.5, in: dir)

        let runner = EdgeRunner(cli: try fakeCLI(product: small, in: dir), corpus: corpus)
        let evalCase = EvalCase(
            name: "x", input: "photo.png", preset: "compress", expect: .init(opens: true, ssimMin: 0.5))
        let results = await runner.run([evalCase])

        #expect(results.checks.map(\.ok) == [true], "\(results.checks)")
        let ratio = try #require(results.metrics["edge.x.ratio"])
        #expect(abs(ratio - (try size(small) / size(corpus.appending(path: "photo.png")))) < 1e-9)
        #expect(try #require(results.metrics["edge.x.ssim"]) > 0.5)
    }

    @Test func aCaseThatCombinesInputsHasNoRatio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = dir.appending(path: "corpus", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        for name in ["a.png", "b.png"] {
            try FileManager.default.moveItem(
                at: try Fixtures.png(width: 64, height: 48, in: dir), to: corpus.appending(path: name))
        }
        let product = try Fixtures.photo(width: 64, height: 48, type: "public.jpeg", ext: "jpg", in: dir)
        let runner = EdgeRunner(cli: try fakeCLI(product: product, in: dir), corpus: corpus)
        let results = await runner.run([
            EvalCase(name: "y", input: "a.png", moreInputs: ["b.png"], preset: "merge", expect: .init())
        ])
        #expect(results.checks.map(\.ok) == [true], "\(results.checks)")
        #expect(results.metrics["edge.y.ratio"] == nil)
        #expect(results.metrics["edge.y.ssim"] == nil)
    }
}
