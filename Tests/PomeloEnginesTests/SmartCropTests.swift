import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// A subject finder that answers a fixed box and records the size of every picture it was shown.
private final class FixedSubject: SubjectFinding, @unchecked Sendable {
    private let box: UnitRect?
    private let lock = NSLock()
    private var shown: [CGSize] = []

    init(_ box: UnitRect?) {
        self.box = box
    }

    var sizes: [CGSize] { lock.withLock { shown } }

    func subject(in image: CGImage) async throws -> UnitRect? {
        lock.withLock { shown.append(CGSize(width: image.width, height: image.height)) }
        return box
    }
}

/// Smart crop (P261): the subject a finder reports, plus the rules' margin or shape, cut and written as Crop writes.
@Suite struct SmartCropTests {
    private static let centred = UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    private func runner(_ finder: FixedSubject) -> JobRunner {
        JobRunner(
            registry: EngineRegistry(engines: [ImageIOEngine(subjectFinder: finder)], priority: ["imageio"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func smartCrop(_ input: URL, _ finder: FixedSubject, aspect: String? = nil) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == "smart-crop" })
        preset.options.aspect = aspect
        return try #require(await runner(finder).run(ConversionRequest.from(preset, inputs: [input])).first)
    }

    private func output(_ result: FileResult) throws -> URL {
        guard case .succeeded(_, let outputs, _) = result, let output = outputs.first else {
            throw Fixtures.Failure("\(result)")
        }
        return output
    }

    private func reason(_ result: FileResult) -> String? {
        if case .failed(_, .notApplicable(let reason)) = result { reason } else { nil }
    }

    private func size(_ url: URL) throws -> (width: Int, height: Int) {
        let size = try #require(Fixtures.imageSize(url))
        return (Int(size.width), Int(size.height))
    }

    /// `Fixtures.png`'s gradient written as `format`, from 8-bit RGB every ImageIO writer takes.
    private func image(_ format: FormatID, width: Int, height: Int, in dir: URL) throws -> URL {
        let file = try #require(FormatRegistry.builtIn.format(id: format))
        let png = try Fixtures.png(width: width, height: height, in: dir)
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = dir.appending(path: "gradient-\(UUID().uuidString.prefix(8)).\(file.extensions[0])")
        let type = try #require(file.utTypeIdentifier)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination), "\(format) source")
        return url
    }

    @Test func fitCropsToTheSubjectPlusMargin() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 1000, height: 800, in: dir)

        let cropped = try output(try await smartCrop(input, FixedSubject(Self.centred)))

        // 200 x 160 px of subject, 6 % more on each side: 224 x 179.2, rounded outwards.
        let (width, height) = try size(cropped)
        #expect(abs(width - 224) <= 1 && abs(height - 179) <= 1, "\(width)x\(height)")
        #expect(cropped.pathExtension == "png")
        #expect(cropped.deletingPathExtension().lastPathComponent.hasSuffix("-cropped"))
    }

    @Test func shapeIsExact() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 1000, height: 800, in: dir)

        let square = try size(try output(try await smartCrop(input, FixedSubject(Self.centred), aspect: "1:1")))
        #expect(abs(square.width - square.height) <= 1, "\(square)")

        let wide = try size(try output(try await smartCrop(input, FixedSubject(Self.centred), aspect: "16:9")))
        #expect(abs(Double(wide.width) * 9 / 16 - Double(wide.height)) <= 1, "\(wide)")
        #expect(wide.width > wide.height)
    }

    @Test func orientation6PhotoIsCroppedUpright() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 800 x 1000 with orientation 6: shown 1000 x 800.
        let input = try Fixtures.jpgWithOrientation(6, width: 800, height: 1000, in: dir)
        let finder = FixedSubject(Self.centred)

        let cropped = try output(try await smartCrop(input, finder))

        #expect(finder.sizes == [CGSize(width: 1000, height: 800)])
        let source = try #require(CGImageSourceCreateWithURL(cropped as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
        let stored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(abs(stored.width - 224) <= 1 && abs(stored.height - 179) <= 1, "\(stored.width)x\(stored.height)")
    }

    @Test func noSubjectIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeTempDir(); defer { try? FileManager.default.removeItem(at: staging) }
        let input = try Fixtures.png(width: 400, height: 300, in: dir)
        let png = try #require(FormatRegistry.builtIn.format(id: "png"))
        let step = ConversionStep(
            input: input, stagingDirectory: staging, from: png, to: png, options: PresetOptions(quality: 0.92),
            operation: "smart-crop"
        )

        await #expect(throws: ConversionError.notApplicable(reason: "No subject found")) {
            try await ImageIOEngine(subjectFinder: FixedSubject(nil)).convert(step) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        #expect(reason(try await smartCrop(input, FixedSubject(nil))) == "No subject found")
    }

    @Test func wholePictureSubjectIsNothingToCrop() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 300, in: dir)
        let whole = FixedSubject(UnitRect(x: 0, y: 0, width: 1, height: 1))
        #expect(reason(try await smartCrop(input, whole)) == "Nothing to crop")
    }

    @Test func animatedGifIsRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = try Fixtures.animatedGIF(width: 40, height: 40, delays: [0.1, 0.1], loopCount: 0, in: dir)
        let finder = FixedSubject(Self.centred)
        #expect(reason(try await smartCrop(gif, finder)) == "Animated images can't be cropped")
        #expect(finder.sizes.isEmpty)
    }

    @Test func edgesMatchCrop() {
        let edges = ImageIOEngine().edges()
        let crop = edges.filter { $0.operation == "crop" }
        let smart = edges.filter { $0.operation == "smart-crop" }
        #expect(!smart.isEmpty)
        #expect(smart.map(\.from) == crop.map(\.from))
        #expect(smart.map(\.flags) == crop.map(\.flags))
        #expect(smart.allSatisfy { $0.to == $0.from && $0.cost == 10 && $0.engineID == "imageio" })
        for excluded: FormatID in ["pdf", "ico", "icns"] {
            #expect(!smart.contains { $0.from == excluded }, "\(excluded)")
        }
    }

    /// P84: these writers refuse the cut sub-image, so Smart crop takes Crop's fresh copy.
    @Test(arguments: ["bmp", "tga", "exr"] as [FormatID])
    func bmpTgaExrUseFreshPixels(format: FormatID) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try image(format, width: 200, height: 100, in: dir)

        let cropped = try output(try await smartCrop(input, FixedSubject(Self.centred)))

        let source = try #require(CGImageSourceCreateWithURL(cropped as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil, "\(format)")
        #expect(cropped.pathExtension == FormatRegistry.builtIn.format(id: format)?.extensions[0])
        let (width, height) = try size(cropped)
        // 40 x 20 px of subject plus the margin: 44.8 x 22.4, rounded outwards to 46 x 24.
        #expect(abs(width - 46) <= 1 && abs(height - 24) <= 1, "\(format) \(width)x\(height)")
    }

    // MARK: Real Vision

    @Test func realFinderFindsABrightShape() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.subjectScene(width: 800, height: 600, in: dir)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let found = try #require(try await SystemSubjectFinder().subject(in: image))

        let centre = Fixtures.subjectSceneCentre
        #expect(found.x <= centre.x && centre.x <= found.x + found.width, "\(found)")
        #expect(found.y <= centre.y && centre.y <= found.y + found.height, "\(found)")
        #expect(found.width * found.height < 0.5, "\(found)")
    }

    /// P271 (manual check 4): the second run on a Smart crop's own result used to crop again, and the third cut the disc.
    @Test func realFinderLeavesItsOwnResultAlone() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let scene = try Fixtures.subjectScene(width: 1600, height: 1200, in: dir)
        let runner = JobRunner(
            registry: EngineRegistry(engines: [ImageIOEngine(subjectFinder: SystemSubjectFinder())], priority: ["imageio"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
        let preset = try #require(Preset.builtIns.first { $0.id == "smart-crop" })
        func run(_ input: URL) async throws -> FileResult {
            try #require(await runner.run(ConversionRequest.from(preset, inputs: [input])).first)
        }

        let first = try output(try await run(scene))
        #expect(try size(first).width < 1600 && size(first).height < 1200)
        #expect(reason(try await run(first)) == "Nothing to crop")
    }

    /// A 1600 x 1200 picture drawn here, so its pixels are exactly what a test names; transparent where `draw` leaves it.
    private func picture(_ draw: (CGContext) throws -> Void = { _ in }) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        try draw(context)
        return try #require(context.makeImage())
    }

    /// A `ground` grey with a disc of `ink` centred at `centre` (fractions from the top left), `radius` px across.
    private func disc(ground: Double, ink: CGColor, centre: CGPoint, radius: Double) throws -> CGImage {
        try picture { context in
            context.setFillColor(CGColor(srgbRed: ground, green: ground, blue: ground, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
            context.setFillColor(ink)
            // The context's origin is the bottom left.
            let (x, y) = (centre.x * 1600, (1 - centre.y) * 1200)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
        }
    }

    /// One grey, a blank white page, a black-to-white ramp, or nothing at all.
    private func flat(_ kind: String) throws -> CGImage {
        switch kind {
        case "grey", "white page":
            let level = kind == "grey" ? 0.5 : 1
            let same = CGColor(srgbRed: level, green: level, blue: level, alpha: 1)
            return try disc(ground: level, ink: same, centre: CGPoint(x: 0.5, y: 0.5), radius: 100)
        case "gradient":
            return try picture { context in
                let ends = [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
                let ramp = try #require(CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: ends as CFArray, locations: nil
                ))
                context.drawLinearGradient(ramp, start: .zero, end: CGPoint(x: 1600, y: 1200), options: [])
            }
        default:
            return try picture()
        }
    }

    private func pixels(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Manual check 5: Vision's attention map of a featureless picture is its centre prior, so it boxed the middle.
    @Test(arguments: ["grey", "white page", "gradient", "transparent"])
    func realFinderFindsNoSubjectInAFeaturelessPicture(kind: String) async throws {
        let found = try await SystemSubjectFinder().subject(in: try flat(kind))
        #expect(found == nil, "\(kind): \(String(describing: found))")
    }

    @Test func realFinderFindsNoSubjectInTheGradientFixture() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = try pixels(try Fixtures.png(width: 1000, height: 800, in: dir))
        #expect(try await SystemSubjectFinder().subject(in: image) == nil)
    }

    /// A small disc on a plain ground: Vision's objectness finds nothing there, so the attention map's box is used.
    @Test func realFinderFindsASmallSubjectOnAPlainGround() async throws {
        let red = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let image = try disc(ground: 0.5, ink: red, centre: CGPoint(x: 0.7, y: 0.3), radius: 36)

        let found = try #require(try await SystemSubjectFinder().subject(in: image))

        #expect(found.x <= 0.7 && 0.7 <= found.x + found.width, "\(found)")
        #expect(found.y <= 0.3 && 0.3 <= found.y + found.height, "\(found)")
        #expect(found.width * found.height < 0.2, "\(found)")
    }

    @Test func featurelessSourceIsNoSubjectFound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeTempDir(); defer { try? FileManager.default.removeItem(at: staging) }
        let input = dir.appending(path: "grey.png")
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try flat("grey"), nil)
        #expect(CGImageDestinationFinalize(destination))
        let png = try #require(FormatRegistry.builtIn.format(id: "png"))
        let step = ConversionStep(
            input: input, stagingDirectory: staging, from: png, to: png, options: PresetOptions(quality: 0.92),
            operation: "smart-crop"
        )

        await #expect(throws: ConversionError.notApplicable(reason: SmartCropRules.noSubjectReason)) {
            try await ImageIOEngine().convert(step) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    // MARK: The pieces of the real finder

    /// The measure the featureless rule reads (P261): flat colours and ramps measured under 0.006, a 6 % grey disc 0.075.
    @Test func detailSeparatesFlatPicturesFromFaintSubjects() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for kind in ["grey", "white page", "gradient", "transparent"] {
            #expect(SystemSubjectFinder.detail(of: try flat(kind)) < SystemSubjectFinder.featurelessDetail / 2, "\(kind)")
        }
        let faintGrey = CGColor(srgbRed: 0.56, green: 0.56, blue: 0.56, alpha: 1)
        let faint = try disc(ground: 0.5, ink: faintGrey, centre: CGPoint(x: 0.3, y: 0.4), radius: 168)
        #expect(SystemSubjectFinder.detail(of: faint) > SystemSubjectFinder.featurelessDetail * 2)
        let scene = try pixels(try Fixtures.subjectScene(width: 800, height: 600, in: dir))
        #expect(SystemSubjectFinder.detail(of: scene) > SystemSubjectFinder.featurelessDetail * 2)
    }

    /// An attention map made by hand: one float per cell, its first row the top of the picture.
    private func heatMap(width: Int, height: Int, _ heat: (Int, Int) -> Float) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent32Float, nil, &made)
        let map = try #require(status == kCVReturnSuccess ? made : nil)
        CVPixelBufferLockBaseAddress(map, [])
        defer { CVPixelBufferUnlockBaseAddress(map, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(map))
        for y in 0..<height {
            let row = (base + y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)
            for x in 0..<width { row[x] = heat(x, y) }
        }
        return map
    }

    @Test func heatMapBoxKeepsTheCellsAtHalfThePeak() throws {
        // Hot cells x 10...19, y 2...5 (0.6 to 0.9), warm ones beside them under half the peak, the rest cold.
        let map = try heatMap(width: 40, height: 20) { x, y in
            if (10...19).contains(x) && (2...5).contains(y) { return x == 15 && y == 3 ? 0.9 : 0.6 }
            return (5...30).contains(x) && (0...12).contains(y) ? 0.4 : 0.01
        }
        let box = try #require(SystemSubjectFinder.heatMapBox(map))
        #expect(box == UnitRect(x: 0.25, y: 0.1, width: 0.25, height: 0.2), "\(box)")
    }

    @Test func heatMapBoxOfAColdMapIsNil() throws {
        #expect(SystemSubjectFinder.heatMapBox(try heatMap(width: 8, height: 8) { _, _ in 0 }) == nil)
    }
}
