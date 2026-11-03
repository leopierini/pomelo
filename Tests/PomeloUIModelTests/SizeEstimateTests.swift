import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

private func format(_ id: FormatID) -> FileFormat { FormatRegistry.builtIn.format(id: id)! }

private func settings(_ toolOptions: [String: PresetOptions]) -> AppSettings {
    var settings = AppSettings()
    settings.toolOptions = toolOptions
    return settings
}

private func tool(_ id: String, settings: AppSettings = AppSettings()) -> Preset {
    ToolCatalog.presets(settings: settings).first { $0.id == id }!
}

private func image(_ id: FormatID = "png", width: Int = 4000, height: Int = 3000, bytes: Int64 = 20_000_000)
    -> (format: FileFormat, facts: SourceFacts) {
    (format(id), SourceFacts(bytes: bytes, pixelWidth: width, pixelHeight: height))
}

private func media(_ id: FormatID, seconds: Double, bytes: Int64)
    -> (format: FileFormat, facts: SourceFacts) {
    (format(id), SourceFacts(bytes: bytes, durationSeconds: seconds))
}

@Suite struct SizeEstimateTests {
    @Test func jpegEstimateUsesBytesPerPixel() throws {
        let result = try #require(SizeEstimate.estimate(target: "jpg", preset: nil, sources: [image()]))
        #expect(result.estimate == 3_000_000)
        #expect(result.source == 20_000_000)
    }

    @Test func bytesPerPixelInterpolatesBetweenTheTableAndHoldsAtItsEnds() throws {
        let pixels = 1_000_000.0
        func jpeg(quality: Double) throws -> Int64 {
            let custom = settings(["compress": PresetOptions(quality: quality)])
            let source = image("jpg", width: 1000, height: 1000, bytes: 10_000_000)
            return try #require(SizeEstimate.estimate(target: nil, preset: tool("compress", settings: custom),
                                                      sources: [source])).estimate
        }
        #expect(try jpeg(quality: 0.75) == Int64(pixels * 0.175))
        #expect(try jpeg(quality: 0.4) == Int64(pixels * 0.10))
        #expect(try jpeg(quality: 0.95) == Int64(pixels * 0.425))
    }

    @Test func otherImageTargetsScaleTheJPEGRule() throws {
        func bytes(_ target: FormatID) -> Int64? {
            SizeEstimate.estimate(target: target, preset: nil, sources: [image()])?.estimate
        }
        #expect(bytes("heic") == 1_500_000)
        #expect(bytes("avif") == 1_350_000)
        #expect(bytes("webp") == 1_680_000)
        #expect(bytes("jp2") == 1_800_000)
        #expect(bytes("bmp") == 36_000_054)
        #expect(bytes("tga") == 36_000_054)
        #expect(bytes("png") == nil)
        #expect(bytes("pdf") == nil)
        #expect(bytes("tiff") == nil)
    }

    @Test func estimateTextShowsTheChange() {
        #expect(SizeEstimate.text(estimate: 860_000, source: 2_400_000)
            == "About \(ByteCountFormatter.string(fromByteCount: 860_000, countStyle: .file)), 64% smaller")
        #expect(SizeEstimate.text(estimate: 2_500_000, source: 2_000_000)
            == "About \(ByteCountFormatter.string(fromByteCount: 2_500_000, countStyle: .file)), 25% larger")
        #expect(SizeEstimate.text(estimate: 2_000_000, source: 2_005_000)
            == "About \(ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file))")
    }

    @Test func estimateTextReadsAsOnePlainSentence() {
        for text in [SizeEstimate.text(estimate: 860_000, source: 2_400_000),
                     SizeEstimate.text(estimate: 2_500_000, source: 2_000_000),
                     SizeEstimate.text(estimate: 2_000_000, source: 2_000_000)] {
            #expect(!text.contains("\u{00B7}") && !text.contains("\u{2014}"))
        }
    }

    @Test func halfSizeKeepsThirtyPercentOfTheBytes() throws {
        let result = try #require(SizeEstimate.estimate(target: nil, preset: tool("half-size"),
                                                        sources: [image(bytes: 1_000_000)]))
        #expect(result.estimate == 300_000)
    }

    @Test func compressingImagesFollowsTheirFormat() throws {
        let compress = tool("compress")
        // jpg at the tool's 0.70: 12 MP x 0.15.
        let jpg = try #require(SizeEstimate.estimate(target: nil, preset: compress, sources: [image("jpg")]))
        #expect(jpg.estimate == 1_800_000)
        // png: 0.35 of the source.
        let png = try #require(SizeEstimate.estimate(target: nil, preset: compress, sources: [image("png")]))
        #expect(png.estimate == 7_000_000)
        // Compress more is q 0.50: 12 MP x 0.10.
        let more = try #require(SizeEstimate.estimate(target: nil, preset: tool("compress-more"),
                                                      sources: [image("heic")]))
        #expect(more.estimate == 600_000)
        #expect(SizeEstimate.estimate(target: nil, preset: compress, sources: [image("webp")]) == nil)
        #expect(SizeEstimate.estimate(target: nil, preset: compress, sources: [image("tiff")]) == nil)
    }

    @Test func compressVideoUsesTheBitrateForItsHeight() throws {
        let video = media("mp4", seconds: 60, bytes: 500_000_000)
        let at1080 = try #require(SizeEstimate.estimate(target: nil, preset: tool("compress"), sources: [video]))
        #expect(at1080.estimate == Int64((6.128 * 60 / 8 * 1_000_000).rounded()))
        let at720 = try #require(SizeEstimate.estimate(target: nil, preset: tool("compress-more"), sources: [video]))
        #expect(at720.estimate == Int64((3.128 * 60 / 8 * 1_000_000).rounded()))
        let custom = settings(["compress": PresetOptions(videoMaxHeight: 2160)])
        let at2160 = try #require(SizeEstimate.estimate(target: nil, preset: tool("compress", settings: custom),
                                                        sources: [video]))
        #expect(at2160.estimate == Int64((16.128 * 60 / 8 * 1_000_000).rounded()))
    }

    @Test func aCompressEstimateNearTheSourceIsOmitted() throws {
        // 45.96 MB estimated for a 46 MB source: 99.9%, so nothing would be published.
        #expect(SizeEstimate.estimate(target: nil, preset: tool("compress"),
                                      sources: [media("mp4", seconds: 60, bytes: 46_000_000)]) == nil)
        // An already small JPEG: 12 MP x 0.15 = 1.8 MB against 1.8 MB.
        #expect(SizeEstimate.estimate(target: nil, preset: tool("compress"),
                                      sources: [image("jpg", bytes: 1_800_000)]) == nil)
    }

    @Test func aFileThatCompressWouldSkipLeavesTheSums() throws {
        let big = media("mp4", seconds: 60, bytes: 500_000_000)
        let small = media("mp4", seconds: 60, bytes: 46_000_000)
        let result = try #require(SizeEstimate.estimate(target: nil, preset: tool("compress"), sources: [big, small]))
        #expect(result.source == 500_000_000)
        #expect(result.estimate == Int64((6.128 * 60 / 8 * 1_000_000).rounded()))
    }

    @Test func audioEstimatesFollowTheTarget() throws {
        let song = media("wav", seconds: 100, bytes: 17_640_044)
        func bytes(_ target: FormatID) -> Int64? {
            SizeEstimate.estimate(target: target, preset: nil, sources: [song])?.estimate
        }
        #expect(bytes("m4a") == 2_400_000)
        #expect(bytes("mp3") == 2_400_000)
        #expect(bytes("opus") == 2_400_000)
        #expect(bytes("wav") == 17_640_000)
        #expect(bytes("aiff") == 17_640_000)
        #expect(bytes("caf") == 17_640_000)
        #expect(bytes("flac") == 9_702_000)
        #expect(bytes("mp4") == nil)
    }

    @Test func extractAudioUsesTheConfiguredBitrate() throws {
        let video = media("mp4", seconds: 100, bytes: 100_000_000)
        let normal = try #require(SizeEstimate.estimate(target: nil, preset: tool("extract-audio"), sources: [video]))
        #expect(normal.estimate == 2_400_000)
        let custom = settings(["extract-audio": PresetOptions(audioBitrate: "256k")])
        let high = try #require(SizeEstimate.estimate(target: nil, preset: tool("extract-audio", settings: custom),
                                                      sources: [video]))
        #expect(high.estimate == 3_200_000)
    }

    @Test func estimatesSumOverFiles() throws {
        let result = try #require(SizeEstimate.estimate(
            target: "jpg", preset: nil,
            sources: [image(bytes: 20_000_000), image(width: 2000, height: 1000, bytes: 4_000_000)]
        ))
        #expect(result.estimate == 3_000_000 + 500_000)
        #expect(result.source == 24_000_000)
    }

    @Test func missingFactsOmitTheEstimate() {
        let complete = image()
        let noPixels = (format: format("png"), facts: SourceFacts(bytes: 1_000))
        let noBytes = (format: format("png"), facts: SourceFacts(pixelWidth: 10, pixelHeight: 10))
        let noDuration = (format: format("wav"), facts: SourceFacts(bytes: 1_000))
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: [complete, noPixels]) == nil)
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: [complete, noBytes]) == nil)
        #expect(SizeEstimate.estimate(target: "mp3", preset: nil, sources: [noDuration]) == nil)
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: []) == nil)
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: [(format("png"), SourceFacts(bytes: 0,
            pixelWidth: 10, pixelHeight: 10))]) == nil)
    }

    @Test func noEstimateBeyondFiftyFiles() {
        let many = Array(repeating: image(), count: 51)
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: many) == nil)
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: Array(many.prefix(50))) != nil)
    }

    @Test func noEstimateForPDFsDocumentsOrOtherTools() {
        let pdf = (format: format("pdf"), facts: SourceFacts(bytes: 1_000_000, pixelWidth: 600, pixelHeight: 800))
        let doc = (format: format("docx"), facts: SourceFacts(bytes: 1_000_000))
        #expect(SizeEstimate.estimate(target: "jpg", preset: nil, sources: [pdf]) == nil)
        #expect(SizeEstimate.estimate(target: "pdf", preset: nil, sources: [doc]) == nil)
        #expect(SizeEstimate.estimate(target: nil, preset: tool("compress"), sources: [pdf]) == nil)
        for id in ["remove-background", "smart-crop", "straighten", "remove-audio", "snapshot", "mono", "strip-metadata", "speed-up",
                   "normalize-volume", "images-to-pdf", "find-duplicates", "merge-pdfs", "split-pdf", "extract-archive", "read-codes"] {
            #expect(SizeEstimate.estimate(target: tool(id).target, preset: tool(id), sources: [image()]) == nil, "\(id)")
        }
    }
}
