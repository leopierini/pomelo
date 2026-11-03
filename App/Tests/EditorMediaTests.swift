import CoreGraphics
import Foundation
import ImageIO
import PomeloCore
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-editor-media-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// What the editors learn about a file before showing it, read off the main thread.
@Suite struct EditorMediaTests {
    @Test func displaySizeFollowsTheOrientation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rotated = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let upright = try Fixtures.jpgWithOrientation(1, width: 400, height: 300, in: dir)

        let info = try await EditorMedia.info(of: rotated)
        #expect(info.displaySize == CGSize(width: 300, height: 400))
        #expect(info.bytes > 0)
        #expect(info.durationSeconds == nil && info.pageCount == nil && !info.hasAudio)
        #expect(try await EditorMedia.info(of: upright).displaySize == CGSize(width: 400, height: 300))
    }

    @Test func thePreviewIsUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rotated = try Fixtures.jpgWithOrientation(6, width: 400, height: 300, in: dir)
        let preview = try #require(await EditorMedia.preview(of: rotated, maxPixelSize: 200))
        #expect(preview.width == 150 && preview.height == 200)
    }

    /// A HEIC whose primary image is not its first (as an iPhone's can be): the editor shows what the engines cut.
    @Test func theSizeAndPreviewAreThePrimaryImages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "two.heic")
        func solid(_ width: Int, _ height: Int) throws -> CGImage {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try solid(300, 300), nil)
        CGImageDestinationAddImage(destination, try solid(200, 100), [kCGImagePropertyPrimaryImage: true] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetPrimaryImageIndex(source) == 1, "the fixture's primary image is its second")

        #expect(try await EditorMedia.info(of: url).displaySize == CGSize(width: 200, height: 100))
        let preview = try #require(await EditorMedia.preview(of: url, maxPixelSize: 100))
        #expect(preview.width == 100 && preview.height == 50)
    }

    @Test func mediaInfoReadsDurationAndAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = try await Fixtures.movie(seconds: 2, withAudio: true, in: dir)
        let info = try await EditorMedia.info(of: movie)
        let duration = try #require(info.durationSeconds)
        #expect(abs(duration - 2) <= 0.05)
        #expect(info.hasAudio)
        #expect(info.displaySize == CGSize(width: 320, height: 240))
        #expect(info.encodedSize == CGSize(width: 320, height: 240))
        #expect(abs((info.frameRate ?? 0) - 30) < 0.5)
        #expect(info.pageCount == nil)

        let silent = try await Fixtures.movie(seconds: 1, withAudio: false, in: dir)
        #expect(try await EditorMedia.info(of: silent).hasAudio == false)
    }

    @Test func aPortraitMovieShowsUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let movie = try await Fixtures.movie(seconds: 1, withAudio: false, transform: quarterTurn, in: dir)
        let info = try await EditorMedia.info(of: movie)
        #expect(info.displaySize == CGSize(width: 240, height: 320))
        #expect(info.encodedSize == CGSize(width: 320, height: 240))
        let frame = try #require(await EditorMedia.frame(of: movie, at: 0.5, maxPixelSize: 160))
        #expect(frame.height > frame.width)
    }

    @Test func pdfInfoCountsPages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(pages: 3, in: dir)
        let info = try await EditorMedia.info(of: pdf)
        #expect(info.pageCount == 3)
        #expect(info.durationSeconds == nil && !info.hasAudio)
    }

    @Test func aMissingFileThrows() async {
        await #expect(throws: (any Error).self) {
            try await EditorMedia.info(of: URL(fileURLWithPath: "/tmp/pomelo-no-such-file-\(UUID()).png"))
        }
    }
}
