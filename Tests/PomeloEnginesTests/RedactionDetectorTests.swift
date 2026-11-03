import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

private func decode(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// A white `width` x `height` picture with each line of black 48 pt Helvetica at its distance from the top.
private func textPicture(width: Int, height: Int, lines: [(text: String, top: Int)]) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
    for line in lines {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        // A context's origin is the bottom left; the baseline sits about one line below the requested top.
        context.textPosition = CGPoint(x: 40, y: height - line.top - 48)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes)), context)
    }
    return try #require(context.makeImage())
}

private func contains(_ outer: UnitRect, _ inner: UnitRect, tolerance: Double = 0) -> Bool {
    inner.x >= outer.x - tolerance && inner.y >= outer.y - tolerance
        && inner.x + inner.width <= outer.x + outer.width + tolerance
        && inner.y + inner.height <= outer.y + outer.height + tolerance
}

/// Vision proposes boxes for the redaction editor (P27): faces, emails, then lines of text, top-left unit rects.
@Suite struct RedactionDetectorTests {
    @Test func emailsGetTheirOwnBoxInsideTheirLine() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = try decode(try Fixtures.textImage("Write to ann@example.com today", in: dir))

        let regions = try await RedactionDetector.detect(in: image)

        let emails = regions.filter { $0.kind == .email }
        let lines = regions.filter { $0.kind == .text }
        #expect(emails.count == 1, "\(regions)")
        let email = try #require(emails.first)
        let line = try #require(lines.first { contains($0.rect, email.rect, tolerance: 0.02) }, "\(regions)")
        #expect(email.rect.width < line.rect.width * 0.8)
        #expect(email.rect.x > line.rect.x + 0.05, "the email starts after \"Write to\"")
        #expect(regions.map(\.kind) == emails.map(\.kind) + lines.map(\.kind), "emails before text")
    }

    @Test func regionsAreTopLeft() async throws {
        let image = try textPicture(width: 1000, height: 800, lines: [("Top secret line", 40)])

        let regions = try await RedactionDetector.detect(in: image)

        let line = try #require(regions.first { $0.kind == .text }, "\(regions)")
        #expect(line.rect.y < 0.25 && line.rect.y + line.rect.height < 0.25, "\(line.rect)")
        #expect(line.rect.x < 0.1)
    }

    @Test func textRegionsAreOrderedTopToBottomAndPadded() async throws {
        let image = try textPicture(
            width: 1000, height: 800, lines: [("Bottom words here", 600), ("Middle words here", 350), ("Top words here", 60)]
        )

        let regions = try await RedactionDetector.detect(in: image)

        let lines = regions.filter { $0.kind == .text }
        #expect(lines.count == 3, "\(regions)")
        #expect(lines.map(\.rect.y) == lines.map(\.rect.y).sorted())
        for line in lines {
            #expect(line.rect.x >= 0 && line.rect.y >= 0 && line.rect.x + line.rect.width <= 1
                    && line.rect.y + line.rect.height <= 1)
        }
        // 48 pt text is about 35 px tall; padded by 10% of that height on each side it covers more than the glyphs.
        let top = try #require(lines.first)
        #expect(top.rect.y * 800 < 60 + 10 && (top.rect.y + top.rect.height) * 800 > 60 + 30, "\(top.rect)")
    }

    @Test func aBlankImageHasNoRegions() async throws {
        let image = try textPicture(width: 800, height: 600, lines: [])
        #expect(try await RedactionDetector.detect(in: image).isEmpty)
    }

    @Test func aCancelledDetectionThrows() async throws {
        let image = try textPicture(width: 800, height: 600, lines: [("Some words", 100)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RedactionDetector.detect(in: image)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// face.jpg: NASA portrait of Neil Armstrong (photo S69-31741, 1969), public domain as a work of NASA. Source:
    /// https://commons.wikimedia.org/wiki/File:Neil_Armstrong_pose.jpg (330 px rendition, re-encoded with sips).
    @Test(.enabled(if: Bundle.module.url(forResource: "face", withExtension: "jpg", subdirectory: "Resources") != nil))
    func aFaceIsFound() async throws {
        let url = try #require(Bundle.module.url(forResource: "face", withExtension: "jpg", subdirectory: "Resources"))

        let regions = try await RedactionDetector.detect(in: try decode(url))

        let faces = regions.filter { $0.kind == .face }
        #expect(faces.count >= 1, "\(regions)")
        #expect(regions.first?.kind == .face, "faces come first")
        let face = try #require(faces.first)
        // The face sits in the upper half of the portrait, right of centre.
        #expect(face.rect.y + face.rect.height / 2 < 0.5, "\(face.rect)")
        #expect(face.rect.x + face.rect.width / 2 > 0.5, "\(face.rect)")
        #expect(face.rect.width > 0.1 && face.rect.height > 0.1, "\(face.rect)")
    }
}
