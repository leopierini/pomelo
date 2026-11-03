import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct SVGEngineTests {
    private let formats = FormatRegistry.builtIn

    private func render(_ source: URL, options: PresetOptions = PresetOptions(), in dir: URL) async throws -> URL {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: source, stagingDirectory: staging,
            from: try #require(formats.format(id: "svg")), to: try #require(formats.format(id: "png")),
            options: options
        )
        return try await SVGEngine().convert(step) { _ in }
    }

    @Test func svgBecomesAPNG() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await render(try Fixtures.svg(in: dir), in: dir)

        #expect(output.pathExtension == "png")
        #expect(Fixtures.imageUTType(output) == "public.png")
        let size = try #require(Fixtures.imageSize(output))
        // Quick Look does not cap the size below 2048 on this macOS; it fits the 2:1 drawing into the square.
        #expect(size.width == 2048)
        #expect(size.width / size.height == 2)
    }

    @Test func maxPixelSizeSizesTheRender() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await render(try Fixtures.svg(in: dir), options: PresetOptions(maxPixelSize: 512), in: dir)

        let size = try #require(Fixtures.imageSize(output))
        #expect(size.width == 512)
        #expect(size.width / size.height == 2)
    }

    @Test func svgKeepsTransparencyWhereQuickLookDoes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let output = try await render(try Fixtures.svg(in: dir), in: dir)

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let corner = try alpha(ofPixelAtX: image.width - 1, y: image.height - 1, in: image)
        if corner == 0 {
            // Quick Look kept the drawing's transparent background: the filled rectangle must still be opaque.
            let inside = try alpha(ofPixelAtX: image.width * 3 / 10, y: image.height / 2, in: image)
            #expect(inside == 255)
        }
    }

    private func alpha(ofPixelAtX x: Int, y: Int, in image: CGImage) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    @Test func aFileQuickLookCannotDrawFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = try Fixtures.svg("this is not an svg", in: dir)

        await #expect(throws: ConversionError.self) { _ = try await render(broken, in: dir) }
    }

    @Test func svgReachesJPEGThroughPNG() async throws {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()

        let route = try #require(planner.route(from: "svg", to: "jpg"))

        #expect(route.edges.map(\.engineID) == ["quicklook", "imageio"])
        #expect(route.edges.map(\.to) == ["png", "jpg"])
        #expect(planner.route(from: "svg", to: "png")?.edges.map(\.engineID) == ["quicklook"])
    }

    @Test func srtAndVTTRouteThroughTheSubtitleEngineOnly() async throws {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()

        #expect(planner.route(from: "srt", to: "vtt")?.edges.map(\.engineID) == ["subtitles"])
        #expect(planner.route(from: "vtt", to: "srt")?.edges.map(\.engineID) == ["subtitles"])
        #expect(planner.route(from: "srt", to: "txt") == nil)
    }
}
