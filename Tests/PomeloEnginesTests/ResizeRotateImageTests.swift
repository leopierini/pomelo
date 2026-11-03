import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// Resize and Rotate on images, through the whole runner so the published names are the ones people see.
@Suite(.serialized) struct ResizeRotateImageTests {
    private func runner() -> JobRunner {
        JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            ),
            trashItem: { _ in throw Fixtures.Failure("the trash must not be touched") }
        )
    }

    private func run(_ presetID: String, _ input: URL, _ edit: EditSpec?) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == presetID })
        preset.options.edit = edit
        return try #require(await runner().run(ConversionRequest.from(preset, inputs: [input])).first)
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

    private func resize(_ input: URL, _ spec: ResizeSpec) async throws -> URL {
        try output(try await run("resize", input, .resize(spec)))
    }

    private func rotate(_ input: URL, _ spec: RotateSpec) async throws -> URL {
        try output(try await run("rotate", input, .rotate(spec)))
    }

    private func moved(_ file: URL, to name: String) throws -> URL {
        let target = file.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    private func pixels(of url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgba(of image: CGImage, x: Int, y: Int) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // A context's origin is bottom left: this shifts pixel (x, y), counted from the top left, onto its only pixel.
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return bytes.map(Int.init)
    }

    private func near(_ found: [Int], _ expected: [Int], _ tolerance: Int = 12) -> Bool {
        zip(found, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    private func orientation(of url: URL) throws -> Int {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private func hasThumbnail(_ url: URL) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let size = try #require(Fixtures.imageSize(url))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)) * 4,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        return CGFloat(image.width) != size.width || CGFloat(image.height) != size.height
    }

    // MARK: Resize

    @Test func resizeWritesSuffixedName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try moved(try Fixtures.quadrantPNG(width: 400, height: 300, in: dir), to: "photo.png")

        let resized = try await resize(photo, .width(200))

        #expect(resized.lastPathComponent == "photo-200x150.png")
        #expect(Fixtures.imageSize(resized) == CGSize(width: 200, height: 150))
        let image = try pixels(of: resized)
        #expect(near(try rgba(of: image, x: 40, y: 30), Fixtures.Quadrant.topLeft.rgb + [255], 3))
        #expect(near(try rgba(of: image, x: 160, y: 120), Fixtures.Quadrant.bottomRight.rgb + [255], 3))
    }

    @Test func exactResizeOfOrientation6IsUpright() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Stored 300 × 200 with orientation 6: shown 200 × 300, the marker in the shown top-left quarter.
        let input = try Fixtures.jpgWithOrientation(6, width: 300, height: 200, in: dir)

        let resized = try await resize(input, .exact(width: 100, height: 100))

        #expect(Fixtures.imageSize(resized) == CGSize(width: 100, height: 100))
        #expect(try orientation(of: resized) == 1)
        #expect(resized.lastPathComponent.hasSuffix("-100x100.jpg"))
        // The centred 200 × 200 of the shown picture keeps the marker over its top-left 100 × 100.
        let image = try pixels(of: resized)
        #expect(near(try rgba(of: image, x: 10, y: 30), Fixtures.orientationMarker + [255]))
        #expect(near(try rgba(of: image, x: 10, y: 70), Fixtures.orientationBackground + [255]))
        #expect(near(try rgba(of: image, x: 80, y: 20), Fixtures.orientationBackground + [255]))
    }

    /// 400 × 200: red for the left 100 px, green for the middle 200, blue for the right 100.
    private func stripesPNG(in dir: URL) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for (x, colour) in [(0, [1.0, 0, 0]), (100, [0, 1.0, 0]), (300, [0, 0, 1.0])] {
            context.setFillColor(CGColor(srgbRed: colour[0], green: colour[1], blue: colour[2], alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: x == 100 ? 200 : 100, height: 200))
        }
        let url = dir.appending(path: "stripes.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func exactResizeFillsTheBoxAndCutsTheOverflowEvenly() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }

        let resized = try await resize(try stripesPNG(in: dir), .exact(width: 100, height: 100))

        // The centred 200 × 200 is all green: nothing of the side stripes is left, and nothing is squeezed in.
        let image = try pixels(of: resized)
        for x in [2, 25, 50, 75, 97] {
            #expect(near(try rgba(of: image, x: x, y: 50), [0, 255, 0, 255], 3), "\(x)")
        }
        // A wider box than the picture's proportions cuts top and bottom instead.
        let wide = try await resize(try Fixtures.quadrantPNG(width: 400, height: 200, in: dir), .exact(width: 200, height: 50))
        let wideImage = try pixels(of: wide)
        #expect(near(try rgba(of: wideImage, x: 10, y: 5), Fixtures.Quadrant.topLeft.rgb + [255], 3))
        #expect(near(try rgba(of: wideImage, x: 10, y: 45), Fixtures.Quadrant.bottomLeft.rgb + [255], 3))
    }

    @Test func resizingToTheSameSizeIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Fixtures.quadrantPNG(width: 200, height: 100, in: dir)
        #expect(reason(try await run("resize", png, .resize(.scale(percent: 100)))) == "It's already that size")
        #expect(reason(try await run("resize", png, nil)) == "Choose a size")
        #expect(reason(try await run("resize", png, .resize(.width(20_000)))) == "Between 1 and 16,384 pixels")
    }

    @Test func enlargingIsAllowed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Fixtures.quadrantPNG(width: 100, height: 50, in: dir)
        let resized = try await resize(png, .scale(percent: 300))
        #expect(Fixtures.imageSize(resized) == CGSize(width: 300, height: 150))
    }

    @Test func animatedGIFRefused() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let gif = try Fixtures.animatedGIF(width: 40, height: 40, delays: [0.1, 0.1], loopCount: 0, in: dir)
        #expect(reason(try await run("resize", gif, .resize(.width(20)))) == "Animated images can't be resized")
        #expect(reason(try await run("rotate", gif, .rotate(RotateSpec(quarterTurns: 1, flipHorizontal: false))))
                == "Animated images can't be rotated")
    }

    @Test func noThumbnailEmbedded() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "with-thumbnail.jpg")
        let pixels = try pixels(of: try Fixtures.quadrantPNG(width: 2000, height: 1500, in: dir))
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try hasThumbnail(input), "the source carries an EXIF thumbnail")

        let resized = try await resize(input, .width(1000))
        let turned = try await rotate(input, RotateSpec(quarterTurns: 1, flipHorizontal: false))

        #expect(try !hasThumbnail(resized))
        #expect(try !hasThumbnail(turned))
        #expect(Fixtures.imageSize(resized) == CGSize(width: 1000, height: 750))
    }

    @Test func pngKeepsAlpha() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let transparent = try Fixtures.png(width: 40, height: 30, alpha: true, in: dir)

        let resized = try pixels(of: try await resize(transparent, .width(20)))
        let turned = try pixels(of: try await rotate(transparent, RotateSpec(quarterTurns: 1, flipHorizontal: false)))

        for image in [resized, turned] {
            #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
            #expect(try rgba(of: image, x: 5, y: 5)[3] == 0)
        }
    }

    @Test func bmpFlattenedOnWhite() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // ImageIO reads a 32-bit BMP with straight alpha, so a transparent one needs flattening to be a valid result.
        let source = try pixels(of: try Fixtures.png(width: 40, height: 30, alpha: true, in: dir))
        let bmp = dir.appending(path: "clear.bmp")
        let destination = try #require(CGImageDestinationCreateWithURL(bmp as CFURL, "com.microsoft.bmp" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(try pixels(of: bmp).alphaInfo))

        let resized = try pixels(of: try await resize(bmp, .width(20)))
        let turned = try pixels(of: try await rotate(bmp, RotateSpec(quarterTurns: 1, flipHorizontal: false)))

        #expect(near(try rgba(of: resized, x: 5, y: 5), [255, 255, 255, 255], 3))
        #expect(near(try rgba(of: turned, x: 5, y: 5), [255, 255, 255, 255], 3))
    }

    @Test func aSourceWithNoAlphaStaysOpaqueInAJPEG() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.photo(width: 400, height: 300, type: "public.jpeg", ext: "jpg", in: dir)
        let resized = try await resize(photo, .scale(percent: 50))
        #expect(Fixtures.imageSize(resized) == CGSize(width: 200, height: 150))
        #expect(Fixtures.imageUTType(resized) == "public.jpeg")
    }

    // MARK: Rotate

    @Test func rotateRightOfOrientation6() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Shown 200 × 300 with the marker top left; one turn right gives 300 × 200 with it top right.
        let input = try Fixtures.jpgWithOrientation(6, width: 300, height: 200, in: dir)

        let turned = try await rotate(input, RotateSpec(quarterTurns: 1, flipHorizontal: false))

        #expect(Fixtures.imageSize(turned) == CGSize(width: 300, height: 200))
        #expect(try orientation(of: turned) == 1)
        #expect(turned.lastPathComponent.hasSuffix("-rotated.jpg"))
        let image = try pixels(of: turned)
        #expect(near(try rgba(of: image, x: 225, y: 50), Fixtures.orientationMarker + [255]))
        #expect(near(try rgba(of: image, x: 75, y: 50), Fixtures.orientationBackground + [255]))
        #expect(near(try rgba(of: image, x: 225, y: 150), Fixtures.orientationBackground + [255]))
        #expect(near(try rgba(of: image, x: 75, y: 150), Fixtures.orientationBackground + [255]))
    }

    @Test func everyTurnPutsTheQuadrantsWhereTheyBelong() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.quadrantPNG(width: 400, height: 200, in: dir)
        // After n turns right, the shown quadrants at (left top, right top, left bottom, right bottom).
        let expected: [[Fixtures.Quadrant]] = [
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.bottomLeft, .topLeft, .bottomRight, .topRight],
            [.bottomRight, .bottomLeft, .topRight, .topLeft],
            [.topRight, .bottomRight, .topLeft, .bottomLeft],
        ]
        for turns in 0..<4 {
            let spec = RotateSpec(quarterTurns: turns, flipHorizontal: false)
            guard !spec.isIdentity else { continue }
            let image = try pixels(of: try await rotate(input, spec))
            let (width, height) = (image.width, image.height)
            #expect(width == (turns % 2 == 1 ? 200 : 400) && height == (turns % 2 == 1 ? 400 : 200))
            let spots = [(width / 4, height / 4), (width * 3 / 4, height / 4), (width / 4, height * 3 / 4),
                         (width * 3 / 4, height * 3 / 4)]
            for (spot, quadrant) in zip(spots, expected[turns]) {
                #expect(near(try rgba(of: image, x: spot.0, y: spot.1), quadrant.rgb + [255], 3), "\(turns) \(spot)")
            }
        }
    }

    @Test func flipKeepsSize() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.quadrantPNG(width: 400, height: 200, in: dir)

        let flipped = try await rotate(input, RotateSpec.identity.flippedHorizontally())
        let image = try pixels(of: flipped)
        #expect(image.width == 400 && image.height == 200)
        #expect(near(try rgba(of: image, x: 100, y: 50), Fixtures.Quadrant.topRight.rgb + [255], 3))
        #expect(near(try rgba(of: image, x: 300, y: 150), Fixtures.Quadrant.bottomLeft.rgb + [255], 3))

        let upsideDown = try pixels(of: try await rotate(input, RotateSpec.identity.flippedVertically()))
        #expect(upsideDown.width == 400 && upsideDown.height == 200)
        #expect(near(try rgba(of: upsideDown, x: 100, y: 50), Fixtures.Quadrant.bottomLeft.rgb + [255], 3))
        #expect(near(try rgba(of: upsideDown, x: 300, y: 50), Fixtures.Quadrant.bottomRight.rgb + [255], 3))
    }

    @Test func nothingToRotateIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let png = try Fixtures.quadrantPNG(width: 200, height: 100, in: dir)
        #expect(reason(try await run("rotate", png, nil)) == "Nothing to rotate")
        #expect(reason(try await run("rotate", png, .rotate(.identity))) == "Nothing to rotate")
    }

    @Test func theEdgesAreThoseOfCropAndLossyWhereItsAre() {
        let edges = ImageIOEngine().edges()
        for operation in ["resize", "rotate"] {
            let own = edges.filter { $0.operation == operation }
            let crop = edges.filter { $0.operation == "crop" }
            #expect(own.map { "\($0.from)>\($0.to)" } == crop.map { "\($0.from)>\($0.to)" }, "\(operation)")
            #expect(own.allSatisfy { $0.from == $0.to })
            #expect(own.contains { $0.from == "jpg" && $0.flags.contains(.lossy) })
            #expect(own.contains { $0.from == "png" && !$0.flags.contains(.lossy) })
            #expect(!own.contains { ["pdf", "ico", "icns"].contains($0.from.rawValue) })
        }
    }
}
