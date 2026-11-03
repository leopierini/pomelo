import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import PDFKit

/// Test files generated on the fly with Apple frameworks, so no binary fixtures are checked in.
/// Every function writes a uniquely named file into `directory` and returns its URL.
public enum Fixtures {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    private static let sampleRate = 44_100.0
    private static let toneFrequency = 440.0

    private static func uniqueURL(_ prefix: String, _ ext: String, in directory: URL) -> URL {
        directory.appending(path: "\(prefix)-\(UUID().uuidString.prefix(8)).\(ext)", directoryHint: .notDirectory)
    }

    // MARK: Text formats

    /// A 100x50 viewBox SVG: a red rectangle on a transparent background, with no script or remote reference.
    public static let sampleSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50">
          <rect x="10" y="10" width="40" height="30" fill="#e02020"/>
        </svg>

        """

    public static let sampleSRT = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello, <i>Pomelo</i>.

        2
        00:00:04,000 --> 00:00:06,250
        Second line one
        Second line two

        """

    public static let sampleVTT = """
        WEBVTT

        NOTE a comment
        that spans two lines

        STYLE
        ::cue { color: red }

        intro
        01:02.000 --> 01:04.500 align:start position:10%
        <v Ann>Hello, <i>Pomelo</i>.</v>

        01:00:05.000 --> 01:00:07.250
        <c.loud>Second</c> line
        two

        """

    /// Writes `text` as UTF-8 to a uniquely named `ext` file.
    public static func textFile(_ text: String, ext: String, in directory: URL) throws -> URL {
        try textFile(Data(text.utf8), ext: ext, in: directory)
    }

    public static func textFile(_ data: Data, ext: String, in directory: URL) throws -> URL {
        let url = uniqueURL("text", ext, in: directory)
        try data.write(to: url)
        return url
    }

    public static func svg(_ text: String = sampleSVG, in directory: URL) throws -> URL {
        try textFile(text, ext: "svg", in: directory)
    }

    public static func srt(_ text: String = sampleSRT, in directory: URL) throws -> URL {
        try textFile(text, ext: "srt", in: directory)
    }

    public static func vtt(_ text: String = sampleVTT, in directory: URL) throws -> URL {
        try textFile(text, ext: "vtt", in: directory)
    }

    // MARK: Images

    /// A PNG. Without `alpha` it is an opaque blue-to-orange gradient; with `alpha` it is fully transparent.
    public static func png(width: Int, height: Int, alpha: Bool = false, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: alpha) { context in
            guard !alpha else { return }
            let colors = [
                CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1),
                CGColor(srgbRed: 1.0, green: 0.6, blue: 0.1, alpha: 1),
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)
            else { return }
            context.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
            )
        }
        let url = uniqueURL("image", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// A 64x64 JPEG carrying a GPS dictionary (45 N, 9 E) that `CGImageSourceCopyPropertiesAtIndex` reads back, and
    /// the EXIF `orientation` tag when one is given.
    public static func jpgWithGPS(orientation: Int? = nil, in directory: URL) throws -> URL {
        let image = try makeImage(width: 64, height: 64, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 45.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 9.0,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "pomelo fixture"
            ],
        ]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        let url = uniqueURL("photo-gps", "jpg", in: directory)
        try write(image, type: "public.jpeg", properties: properties, to: url)
        return url
    }

    /// A JPEG whose stored pixels are `width` x `height` and whose EXIF orientation tag is `orientation` (1...8). Its
    /// `orientationMarker` fills the quarter that shows at the top left once the orientation is applied; the rest
    /// is `orientationBackground`.
    public static func jpgWithOrientation(_ orientation: Int, width: Int, height: Int, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            context.setFillColor(rgbColor(orientationBackground))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(rgbColor(orientationMarker))
            context.fill(storedQuarter(showing: .topLeft, orientation: orientation, width: width, height: height))
        }
        let url = uniqueURL("oriented-\(orientation)", "jpg", in: directory)
        try write(image, type: "public.jpeg", properties: [kCGImagePropertyOrientation: orientation], to: url)
        return url
    }

    /// `jpgWithOrientation`'s colours, as 8-bit sRGB.
    public static let orientationMarker = [255, 128, 26]
    public static let orientationBackground = [51, 102, 204]

    /// Strings `jpgWithThumbnail` hides in its metadata; a redacted copy must hold none of them, byte for byte.
    public static let secretMetadata = ["pomelo secret caption", "pomelo secret xmp", "iPhone 15 Pro"]

    /// A 1600x1200 photo JPEG carrying what a phone photo can leak: GPS, an EXIF date, TIFF make and model, an IPTC
    /// caption, an XMP packet (a custom namespace ImageIO cannot map to EXIF, so it stays XMP) and an embedded
    /// thumbnail (160x120, smaller than the image, so a reader can tell it apart).
    public static func jpgWithThumbnail(in directory: URL) throws -> URL {
        let image = try makeImage(width: 1600, height: 1200, alpha: false) { context in
            drawPhoto(in: context, width: 1600, height: 1200)
        }
        let metadata = CGImageMetadataCreateMutable()
        let custom = "http://pomelo.example/ns/1.0/" as CFString
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, custom, "kq" as CFString, nil),
            CGImageMetadataSetValueWithPath(metadata, nil, "kq:secret" as CFString, secretMetadata[1] as CFString),
            CGImageMetadataSetValueWithPath(metadata, nil, "dc:description" as CFString, secretMetadata[0] as CFString)
        else { throw Failure("cannot build the XMP metadata") }
        let properties: [(CFString, CFString, CFTypeRef)] = [
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, 45.0 as CFNumber),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, "N" as CFString),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, 9.0 as CFNumber),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, "E" as CFString),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, "2026:10:26 10:00:00" as CFString),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, "Apple" as CFString),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, secretMetadata[2] as CFString),
        ]
        for (dictionary, key, value) in properties
        where !CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value) {
            throw Failure("cannot set \(key) in the metadata")
        }
        let url = uniqueURL("photo-thumbnail", "jpg", in: directory)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw Failure("cannot create a JPEG destination at \(url.path)")
        }
        CGImageDestinationAddImageAndMetadata(
            destination, image, metadata, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalise \(url.lastPathComponent)") }
        return url
    }

    /// A 640x480 `quadrantPNG`-coloured HEIC carrying a 64x48 disparity map as auxiliary data, as an iPhone portrait
    /// photo carries its depth.
    public static func heicWithDisparity(in directory: URL) throws -> URL {
        let image = try makeImage(width: 640, height: 480, alpha: false) { context in
            drawQuadrants(in: context, width: 640, height: 480, orientation: 1)
        }
        let (width, height) = (64, 48)
        // Half floats as bit patterns (Float16 is unavailable on Intel Macs): 0.25 on the left half, 0.75 on the right.
        var map = Data(capacity: width * height * 2)
        for _ in 0..<height {
            for column in 0..<width {
                let half: UInt16 = column < width / 2 ? 0x3400 : 0x3A00
                map.append(UInt8(half & 0xFF))
                map.append(UInt8(half >> 8))
            }
        }
        let description: [String: Any] = [
            "Width": width, "Height": height, "BytesPerRow": width * 2, "PixelFormat": kCVPixelFormatType_DisparityFloat16,
        ]
        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: map, kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: CGImageMetadataCreateMutable(),
        ]
        let url = uniqueURL("portrait", "heic", in: directory)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw Failure("cannot create a HEIC destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, info as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalise \(url.lastPathComponent)") }
        return url
    }

    /// A quarter of a picture as it is shown, and the colour `quadrantPNG` and `quadrantMovie` fill it with.
    public enum Quadrant: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// 8-bit sRGB, far enough apart that a video encoder's rounding never makes one look like another.
        public var rgb: [Int] {
            switch self {
            case .topLeft: [230, 40, 40]
            case .topRight: [40, 200, 60]
            case .bottomLeft: [40, 80, 230]
            case .bottomRight: [240, 220, 40]
            }
        }

        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    /// A `width` x `height` PNG of four solid `Quadrant` colours.
    public static func quadrantPNG(width: Int, height: Int, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            drawQuadrants(in: context, width: width, height: height, orientation: 1)
        }
        let url = uniqueURL("quadrants", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// A 1000x200 PNG with `text` in black 64 pt Helvetica on white, for the OCR tests.
    public static func textImage(_ text: String, in directory: URL) throws -> URL {
        let image = try makeImage(width: 1000, height: 200, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 200))
            context.textPosition = CGPoint(x: 40, y: 70)
            CTLineDraw(textLine(text, size: 64), context)
        }
        let url = uniqueURL("text", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// A PNG of `lines` in black 40 pt Helvetica on white, one under the other: a receipt for the OCR and data tests.
    public static func textImage(lines: [String], in directory: URL) throws -> URL {
        let lineHeight = 60
        let height = lines.count * lineHeight + 80
        let image = try makeImage(width: 900, height: height, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: height))
            for (index, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 40, y: height - 40 - (index + 1) * lineHeight + 15)
                CTLineDraw(textLine(line, size: 40), context)
            }
        }
        let url = uniqueURL("text", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// The receipt of the OCR, data and eval tests; its printed total is `receiptTotal`.
    public static let receiptLines = [
        "COOP ZURICH", "Bahnhofstrasse 12", "12.10.2026", "Bread 3.50", "Milk 1.80", "TOTAL CHF 5.30",
    ]
    public static let receiptTotal = 5.3

    /// `receiptLines` as a PNG.
    public static func receipt(in directory: URL) throws -> URL {
        try textImage(lines: receiptLines, in: directory)
    }

    /// The cells of `tableImage`, row by row.
    public static let tableCells = [["Item", "Qty", "Price"], ["Apples", "4", "2.50"], ["Pears", "6", "3.10"], ["Plums", "2", "1.75"]]

    /// A 1200x800 PNG of a heading, a paragraph and a ruled 4 by 3 table (`tableCells`), for the document scanning tests.
    public static func tableImage(in directory: URL) throws -> URL {
        let width = 1200, height = 800
        let left = 100.0, columnWidth = 330.0, rowHeight = 90.0, top = 330.0
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.textPosition = CGPoint(x: left, y: Double(height) - 110)
            CTLineDraw(textLine("Fruit order", size: 72), context)
            context.textPosition = CGPoint(x: left, y: Double(height) - 200)
            CTLineDraw(textLine("The quantities and prices for this week.", size: 40), context)
            context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(3)
            let rows = Double(tableCells.count), columns = Double(tableCells[0].count)
            let bottom = Double(height) - top - rowHeight * rows
            for row in 0...tableCells.count {
                let y = Double(height) - top - rowHeight * Double(row)
                context.move(to: CGPoint(x: left, y: y))
                context.addLine(to: CGPoint(x: left + columnWidth * columns, y: y))
            }
            for column in 0...tableCells[0].count {
                let x = left + columnWidth * Double(column)
                context.move(to: CGPoint(x: x, y: bottom))
                context.addLine(to: CGPoint(x: x, y: Double(height) - top))
            }
            context.strokePath()
            for (row, cells) in tableCells.enumerated() {
                for (column, text) in cells.enumerated() {
                    context.textPosition = CGPoint(
                        x: left + columnWidth * Double(column) + 24,
                        y: Double(height) - top - rowHeight * Double(row + 1) + 28)
                    CTLineDraw(textLine(text, size: 44), context)
                }
            }
        }
        let url = uniqueURL("table", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// A 600x600 PNG of a QR code for `text`: black modules on white, with the quiet zone a scanner needs.
    public static func qrCode(_ text: String, in directory: URL) throws -> URL {
        let url = uniqueURL("qr", "png", in: directory)
        try write(try qrImage(text), type: "public.png", to: url)
        return url
    }

    /// A one-page, 600x600 pt PDF holding `qrCode`'s image, the way a scanned ticket or invoice carries one.
    public static func qrCodePDF(_ text: String, in directory: URL) throws -> URL {
        let url = uniqueURL("codes", "pdf", in: directory)
        var box = CGRect(x: 0, y: 0, width: 600, height: 600)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw Failure("cannot create a PDF context at \(url.path)")
        }
        context.beginPDFPage(nil)
        context.draw(try qrImage(text), in: box)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func qrImage(_ text: String) throws -> CGImage {
        guard let generator = CIFilter(name: "CIQRCodeGenerator") else { throw Failure("CIQRCodeGenerator is not available") }
        generator.setValue(Data(text.utf8), forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = generator.outputImage else { throw Failure("cannot generate a QR code for \(text)") }
        // The generator's output is one pixel per module; scale it up without smoothing.
        let side = 480.0
        let scaled = code
            .transformed(by: CGAffineTransform(scaleX: side / code.extent.width, y: side / code.extent.height))
            .samplingNearest()
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 600)
        let placed = scaled.transformed(by: CGAffineTransform(translationX: 60 - scaled.extent.minX, y: 60 - scaled.extent.minY))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        let composite = placed.composited(over: white)
        guard let image = CIContext().createCGImage(composite, from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { throw Failure("cannot render the QR code") }
        return image
    }

    /// A 512x512 PNG of a shaded dark sphere centred on a light, slightly textured backdrop, for background removal.
    public static func subjectPhoto(in directory: URL) throws -> URL {
        let size = 512
        let image = try makeImage(width: size, height: size, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.92, green: 0.91, blue: 0.88, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            var generator = SeededGenerator(seed: 0x5342_4A43)
            for _ in 0..<400 {
                let x = Double.random(in: 0...Double(size), using: &generator)
                let y = Double.random(in: 0...Double(size), using: &generator)
                context.setFillColor(CGColor(gray: .random(in: 0.82...0.97, using: &generator), alpha: 0.5))
                context.fillEllipse(in: CGRect(x: x, y: y, width: 6, height: 6))
            }
            let sphere = CGRect(x: 136, y: 136, width: 240, height: 240)
            context.saveGState()
            context.addEllipse(in: sphere)
            context.clip()
            let colors = [
                CGColor(srgbRed: 0.55, green: 0.3, blue: 0.2, alpha: 1),
                CGColor(srgbRed: 0.12, green: 0.05, blue: 0.04, alpha: 1),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient, startCenter: CGPoint(x: 210, y: 300), startRadius: 0,
                    endCenter: CGPoint(x: 256, y: 256), endRadius: 140, options: [.drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        }
        let url = uniqueURL("subject", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// Where `subjectScene` puts its disc, as fractions of the picture from its top-left corner: the centre, and the
    /// radius as a fraction of the picture's height.
    public static let subjectSceneCentre = CGPoint(x: 0.3, y: 0.4)
    public static let subjectSceneRadius = 0.14

    /// A saturated red disc, lit from the top left, on a soft grey gradient: a subject Vision's saliency finds, away
    /// from the centre so a crop must move to reach it.
    public static func subjectScene(width: Int, height: Int, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            let ground = [
                CGColor(srgbRed: 0.86, green: 0.86, blue: 0.85, alpha: 1),
                CGColor(srgbRed: 0.7, green: 0.71, blue: 0.72, alpha: 1),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: ground, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: []
                )
            }
            let radius = subjectSceneRadius * Double(height)
            // The context's origin is the bottom left.
            let centre = CGPoint(x: subjectSceneCentre.x * Double(width), y: (1 - subjectSceneCentre.y) * Double(height))
            context.saveGState()
            context.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
            context.clip()
            let disc = [
                CGColor(srgbRed: 1, green: 0.25, blue: 0.15, alpha: 1),
                CGColor(srgbRed: 0.6, green: 0, blue: 0.02, alpha: 1),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: disc, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient, startCenter: CGPoint(x: centre.x - radius * 0.35, y: centre.y + radius * 0.35),
                    startRadius: 0, endCenter: centre, endRadius: radius, options: [.drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        }
        let url = uniqueURL("subject-scene", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// The page corners of `pagePhoto` as fractions of its side from the top left: top left, top right, bottom
    /// right, bottom left. The far (top) edge is the shorter one, as a camera held over the near edge sees it, and the
    /// mean sides are 1 : 1.396, within the snap to A4.
    public static let pagePhotoCorners = [
        CGPoint(x: 0.24, y: 0.08), CGPoint(x: 0.76, y: 0.11), CGPoint(x: 0.80, y: 0.90), CGPoint(x: 0.18, y: 0.88),
    ]
    public static let pagePhotoHeading = "Pomelo evals page"

    /// A `side` x `side` JPEG of a sheet of paper photographed at an angle (P268): an off-white page 2 : 2.8 holding
    /// `pagePhotoHeading` and a short paragraph near its top, warped by `CIPerspectiveTransform` onto
    /// `pagePhotoCorners`, with a soft shadow, over a wood-grain ground drawn from a fixed seed.
    public static func pagePhoto(side: Int, in directory: URL) throws -> URL {
        let pageWidth = side * 2 / 3
        let pageHeight = pageWidth * 14 / 10
        let scale = Double(pageWidth) / 2000
        let page = try makeImage(width: pageWidth, height: pageHeight, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            context.textPosition = CGPoint(x: 160 * scale, y: Double(pageHeight) - 360 * scale)
            CTLineDraw(textLine(pagePhotoHeading, size: 150 * scale), context)
            let paragraph = [
                "A sheet of paper photographed at an angle,", "so the straightened copy can be read back.",
                "Its words are printed in plain black type", "on a white page lying on a wooden desk.",
            ]
            for (index, line) in paragraph.enumerated() {
                context.textPosition = CGPoint(x: 160 * scale, y: Double(pageHeight) - (620 + Double(index) * 120) * scale)
                CTLineDraw(textLine(line, size: 72 * scale), context)
            }
        }
        let size = Double(side)
        let ground = try makeImage(width: side, height: side, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.45, green: 0.29, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            var generator = SeededGenerator(seed: 0x5741_4C4E)
            for _ in 0..<900 {
                var y = Double.random(in: 0...size, using: &generator)
                let shade = Double.random(in: -0.12...0.12, using: &generator)
                context.setStrokeColor(CGColor(
                    srgbRed: 0.45 + shade, green: 0.29 + shade * 0.8, blue: 0.16 + shade * 0.5, alpha: 0.5
                ))
                context.setLineWidth(size * Double.random(in: 0.0005...0.004, using: &generator))
                context.move(to: CGPoint(x: 0, y: y))
                for step in 1...40 {
                    y += Double.random(in: -size / 400...size / 400, using: &generator)
                    context.addLine(to: CGPoint(x: size * Double(step) / 40, y: y))
                }
                context.strokePath()
            }
        }
        // Core Image's origin is the bottom left.
        func corner(_ index: Int) -> CIVector {
            CIVector(x: pagePhotoCorners[index].x * size, y: (1 - pagePhotoCorners[index].y) * size)
        }
        let warped = CIImage(cgImage: page).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": corner(0), "inputTopRight": corner(1), "inputBottomRight": corner(2),
            "inputBottomLeft": corner(3),
        ])
        let none = CIVector(x: 0, y: 0, z: 0, w: 0)
        let shadow = warped
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": none, "inputGVector": none, "inputBVector": none,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            ])
            .transformed(by: CGAffineTransform(translationX: size * 0.008, y: -size * 0.01))
            .applyingGaussianBlur(sigma: size * 0.008)
        let frame = CGRect(x: 0, y: 0, width: size, height: size)
        let photo = warped.composited(over: shadow.composited(over: CIImage(cgImage: ground)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CIContext().createCGImage(photo, from: frame, format: .RGBA8, colorSpace: space)
        else { throw Failure("cannot render the page photo") }
        let url = uniqueURL("page-photo", "jpg", in: directory)
        try write(image, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: 0.9], to: url)
        return url
    }

    /// A JPEG (quality 0.9) of a generated outdoor scene, for Find duplicates (P268): a sky and a ground whose colours,
    /// hills, soft blobs and grass strokes all come from `seed`, a lit figure standing on the ground, and sensor-like
    /// grain. `frame` is a burst frame of the same scene: the figure has moved right by 3 % of the width per frame and
    /// the grain is new, everything else is the same.
    public static func scene(seed: UInt64, frame: Int = 0, width: Int, height: Int, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            var generator = SeededGenerator(seed: seed)
            let (w, h) = (Double(width), Double(height))
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            func random(_ range: ClosedRange<Double>) -> Double { .random(in: range, using: &generator) }
            func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
                CGColor(srgbRed: r, green: g, blue: b, alpha: a)
            }
            func gradient(_ colors: [CGColor]) -> CGGradient? {
                CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)
            }
            // The context's origin is the bottom left: the horizon sits between 35 % and 50 % up.
            let horizon = h * random(0.35...0.5)
            if let sky = gradient([color(random(0.3...0.9), random(0.5...0.9), random(0.7...1)),
                                   color(random(0.05...0.4), random(0.1...0.5), random(0.3...0.8))]) {
                context.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: h), options: [])
            }
            let groundTop = color(random(0.2...0.6), random(0.3...0.7), random(0.05...0.3))
            if let ground = gradient([color(random(0.1...0.4), random(0.1...0.4), random(0...0.2)), groundTop]) {
                context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: horizon), options: [])
            }
            for _ in 0..<3 {
                context.setFillColor(color(random(0.1...0.5), random(0.2...0.5), random(0.1...0.5)))
                context.move(to: CGPoint(x: 0, y: horizon))
                var x = 0.0
                while x < w {
                    let next = x + w * random(0.1...0.3)
                    context.addQuadCurve(
                        to: CGPoint(x: next, y: horizon),
                        control: CGPoint(x: (x + next) / 2, y: horizon + h * random(0.05...0.3))
                    )
                    x = next
                }
                context.closePath()
                context.fillPath()
            }
            for _ in 0..<90 {
                let centre = CGPoint(x: random(0...w), y: random(0...h))
                let radius = min(w, h) * random(0.02...0.12)
                if let blob = gradient([color(random(0...1), random(0...1), random(0...1), 0.45),
                                        color(random(0...1), random(0...1), random(0...1), 0)]) {
                    context.drawRadialGradient(blob, startCenter: centre, startRadius: 0, endCenter: centre,
                                               endRadius: radius, options: [])
                }
            }
            // Not antialiased: Core Graphics blends a translucent antialiased stroke differently while another thread
            // draws, so parallel tests got different pixels for the same seed (final review).
            context.saveGState()
            context.setShouldAntialias(false)
            context.setLineWidth(max(1, w / 900))
            for _ in 0..<1400 {
                let root = CGPoint(x: random(0...w), y: random(0...horizon))
                context.setStrokeColor(color(random(0...0.4), random(0.2...0.7), random(0...0.3), 0.6))
                context.move(to: root)
                context.addLine(to: CGPoint(x: root.x + w * random(-0.004...0.004), y: root.y + h * random(0.005...0.03)))
                context.strokePath()
            }
            context.restoreGState()
            let figureX = w * (random(0.25...0.45) + 0.03 * Double(frame))
            let figureHeight = h * 0.32
            let body = CGRect(x: figureX - figureHeight * 0.13, y: horizon * 0.5, width: figureHeight * 0.26,
                              height: figureHeight * 0.62)
            context.setFillColor(color(random(0.5...0.9), random(0...0.3), random(0...0.3)))
            context.fill(body)
            let head = CGPoint(x: figureX, y: body.maxY + figureHeight * 0.14)
            if let lit = gradient([color(0.98, 0.85, 0.7), color(0.55, 0.35, 0.25)]) {
                context.drawRadialGradient(
                    lit, startCenter: CGPoint(x: head.x - figureHeight * 0.04, y: head.y + figureHeight * 0.04),
                    startRadius: 0, endCenter: head, endRadius: figureHeight * 0.14, options: []
                )
            }
            addGrain(to: context, seed: seed &* 31 &+ UInt64(frame))
        }
        let url = uniqueURL("scene", "jpg", in: directory)
        try write(image, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: 0.9], to: url)
        return url
    }

    /// `image`'s stored pixels written again as `type`: scaled by `scale`, at `quality` when one is given, and with
    /// `orientation6` turned a quarter left and tagged EXIF orientation 6, so a viewer turns it back upright.
    public static func copy(
        of image: URL, scale: Double = 1, quality: Double? = nil, orientation6: Bool = false, type: String, ext: String,
        in directory: URL
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
            let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure("cannot read \(image.lastPathComponent)") }
        let width = Int((Double(pixels.width) * scale).rounded())
        let height = Int((Double(pixels.height) * scale).rounded())
        let copy = try makeImage(
            width: orientation6 ? height : width, height: orientation6 ? width : height, alpha: false
        ) { context in
            context.interpolationQuality = .high
            if orientation6 {
                // A quarter turn left: the picture's top edge becomes the stored left edge.
                context.translateBy(x: Double(height), y: 0)
                context.rotate(by: .pi / 2)
            }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if orientation6 { properties[kCGImagePropertyOrientation] = 6 }
        let url = uniqueURL("copy", ext, in: directory)
        try write(copy, type: type, properties: properties, to: url)
        return url
    }

    /// A photograph-like image in `type` (a UTType identifier such as "public.jpeg"): a smooth gradient with soft
    /// blobs and fine strokes, drawn from a fixed seed so every run makes the same pixels. PSNR against it means
    /// something, which a flat fill would not give. A lossy `type` is encoded at `quality` (0...1) when one is given.
    public static func photo(
        width: Int, height: Int, type: String, ext: String, quality: Double? = nil, in directory: URL
    ) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            drawPhoto(in: context, width: width, height: height)
        }
        let url = uniqueURL("photo", ext, in: directory)
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as [CFString: Any] }
        try write(image, type: type, properties: properties, to: url)
        return url
    }

    /// A `photo` with per-pixel grain, which no encoder can squeeze much without losing quality or pixels. With
    /// `alpha` its left quarter is fully transparent. A lossy `type` is encoded at `quality` when one is given.
    public static func noisyImage(
        width: Int, height: Int, alpha: Bool = false, type: String, ext: String, quality: Double? = nil,
        in directory: URL
    ) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: alpha) { context in
            drawPhoto(in: context, width: width, height: height)
            if alpha { context.clear(CGRect(x: 0, y: 0, width: width / 4, height: height)) }
            addGrain(to: context, seed: 0x4E4F_4953)
        }
        let url = uniqueURL("noisy", ext, in: directory)
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as [CFString: Any] }
        try write(image, type: type, properties: properties, to: url)
        return url
    }

    public static func noisyPNG(width: Int, height: Int, alpha: Bool = false, in directory: URL) throws -> URL {
        try noisyImage(width: width, height: height, alpha: alpha, type: "public.png", ext: "png", in: directory)
    }

    /// A UI-like image: flat blocks of colour with a few lines of text-sized bars, as a screenshot would be.
    public static func screenshot(width: Int, height: Int, in directory: URL) throws -> URL {
        let image = try makeImage(width: width, height: height, alpha: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let sidebar = width / 6
            context.setFillColor(CGColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: sidebar, height: height))
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: sidebar + 40, y: height - 120, width: 360, height: 64))
            context.setFillColor(CGColor(srgbRed: 0.75, green: 0.76, blue: 0.8, alpha: 1))
            for row in 0..<14 {
                let y = height - 240 - row * 90
                context.fill(CGRect(x: sidebar + 40, y: y, width: width / 2 - row * 20, height: 36))
            }
        }
        let url = uniqueURL("screenshot", "png", in: directory)
        try write(image, type: "public.png", to: url)
        return url
    }

    /// The solid colours of the frames of `animatedGIF` and the pages of `multiPageTIFF`, in order (red, green, blue,
    /// then grey for any further frame).
    public static func frameColor(_ frame: Int) -> CGColor {
        switch frame {
        case 0: return CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case 1: return CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        case 2: return CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        default: return CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
    }

    /// An animated GIF of one solid-colour `width` x `height` frame per entry of `delays` (seconds; GIF stores
    /// hundredths), repeating `loopCount` times (0 loops forever).
    public static func animatedGIF(width: Int, height: Int, delays: [Double], loopCount: Int, in directory: URL) throws -> URL {
        let url = uniqueURL("animation", "gif", in: directory)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil)
        else { throw Failure("cannot create a GIF destination at \(url.path)") }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        for (frame, delay) in delays.enumerated() {
            let image = try makeImage(width: width, height: height, alpha: false) { context in
                context.setFillColor(frameColor(frame))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay],
            ]
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalise \(url.lastPathComponent)") }
        return url
    }

    /// A TIFF of `pages` solid-colour `width` x `height` images: several images, but no animation timing.
    public static func multiPageTIFF(width: Int, height: Int, pages: Int, in directory: URL) throws -> URL {
        let url = uniqueURL("pages", "tiff", in: directory)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, pages, nil)
        else { throw Failure("cannot create a TIFF destination at \(url.path)") }
        for page in 0..<pages {
            let image = try makeImage(width: width, height: height, alpha: false) { context in
                context.setFillColor(frameColor(page))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalise \(url.lastPathComponent)") }
        return url
    }

    public static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return CGSize(width: width, height: height)
    }

    public static func imageUTType(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    // MARK: Documents

    /// A PDF of US Letter pages (612x792 pt); page N shows the text "Page N" as real, extractable text.
    public static func pdf(pages: Int, in directory: URL) throws -> URL {
        try pdf(texts: (1...max(1, pages)).map { "Page \($0)" }, in: directory)
    }

    /// A PDF of US Letter pages (612x792 pt), one per entry of `texts`, each page showing its text as real, extractable text.
    public static func pdf(texts: [String], in directory: URL) throws -> URL {
        let url = uniqueURL("document", "pdf", in: directory)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure("cannot create a PDF context at \(url.path)")
        }
        for text in texts {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(textLine(text, size: 36), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// `pdf(texts:in:)` with page `n` turned `rotations[n]` degrees clockwise (missing entries stay upright) and, when
    /// given, a document title.
    public static func pdf(pageTexts: [String], rotations: [Int] = [], title: String? = nil, in directory: URL) throws -> URL {
        let plain = try pdf(texts: pageTexts, in: directory)
        guard title != nil || rotations.contains(where: { $0 != 0 }) else { return plain }
        defer { try? FileManager.default.removeItem(at: plain) }
        guard let document = PDFDocument(url: plain) else { throw Failure("cannot reopen the PDF at \(plain.path)") }
        for (index, rotation) in rotations.enumerated() {
            document.page(at: index)?.rotation = rotation
        }
        if let title {
            var attributes = document.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.titleAttribute] = title
            document.documentAttributes = attributes
        }
        let url = uniqueURL("document", "pdf", in: directory)
        guard document.write(to: url) else { throw Failure("cannot write a PDF at \(url.path)") }
        return url
    }

    /// A PDF of US Letter pages, each holding an uncompressed 1600x1200 `photo` image, so it is large until its
    /// images are recompressed.
    public static func pdfWithPhoto(pages: Int, in directory: URL) throws -> URL {
        let url = uniqueURL("scan", "pdf", in: directory)
        let image = try makeImage(width: 1600, height: 1200, alpha: false) { context in
            drawPhoto(in: context, width: 1600, height: 1200)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw Failure("cannot create a PDF context at \(url.path)")
        }
        for _ in 0..<max(1, pages) {
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 36, y: 200, width: 540, height: 405))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A one-page PDF that asks for `password` before it opens.
    public static func lockedPDF(password: String = "secret", in directory: URL) throws -> URL {
        let plain = try pdf(pages: 1, in: directory)
        defer { try? FileManager.default.removeItem(at: plain) }
        let url = uniqueURL("locked", "pdf", in: directory)
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard let document = PDFDocument(url: plain), document.write(to: url, withOptions: options) else {
            throw Failure("cannot write a locked PDF at \(url.path)")
        }
        return url
    }

    /// An RTF document of `text` in 14 pt Helvetica.
    public static func rtf(_ text: String, in directory: URL) throws -> URL {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont(name: "Helvetica", size: 14) ?? NSFont.systemFont(ofSize: 14)]
        )
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = uniqueURL("document", "rtf", in: directory)
        try data.write(to: url)
        return url
    }

    // MARK: Audio and video

    /// A 44.1 kHz, 16-bit WAV of a 440 Hz sine, the same on every channel.
    public static func wav(seconds: Double, channels: Int = 1, in directory: URL) throws -> URL {
        try wav(seconds: seconds, channels: channels, silentChannels: [], in: directory)
    }

    /// A 44.1 kHz, 16-bit stereo WAV with the 440 Hz sine on the left channel and silence on the right.
    public static func stereoWavWithSilentRight(seconds: Double, in directory: URL) throws -> URL {
        try wav(seconds: seconds, channels: 2, silentChannels: [1], in: directory)
    }

    /// A 44.1 kHz, 16-bit mono WAV of a 440 Hz sine peaking at `amplitude` (0 is silence, 1 full scale).
    public static func wav(seconds: Double, amplitude: Double, in directory: URL) throws -> URL {
        try wav(seconds: seconds, channels: 1, silentChannels: [], amplitude: amplitude, in: directory)
    }

    private static func wav(
        seconds: Double, channels: Int, silentChannels: Set<Int>, amplitude: Double = 0.5, in directory: URL
    ) throws -> URL {
        let url = uniqueURL("tone", "wav", in: directory)
        let frameCount = max(1, Int((seconds * sampleRate).rounded()))
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels),
                interleaved: true),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let samples = buffer.int16ChannelData?[0]
        else { throw Failure("cannot create a PCM buffer") }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            for channel in 0..<channels {
                samples[index * channels + channel] = silentChannels.contains(channel)
                    ? 0 : sineSample(at: index, amplitude: amplitude)
            }
        }
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true
            )
            try file.write(from: buffer)
        }  // the file is finalised when it goes out of scope
        return url
    }

    /// A 44.1 kHz stereo AAC M4A of a 440 Hz sine.
    public static func m4a(seconds: Double, in directory: URL) throws -> URL {
        let url = uniqueURL("tone", "m4a", in: directory)
        let frameCount = max(1, Int((seconds * sampleRate).rounded()))
        guard
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let channels = buffer.floatChannelData
        else { throw Failure("cannot create a PCM buffer") }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            let sample = Float(sin(2 * Double.pi * toneFrequency * Double(index) / sampleRate) * 0.5)
            channels[0][index] = sample
            channels[1][index] = sample
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }  // the file is finalised when it goes out of scope
        return url
    }

    /// What `speech(in:)` says: two short English sentences a second apart, about 7 seconds in all.
    public static let speechText = "Hello from Pomelo. [[slnc 1000]] This sentence was spoken on this Mac, and Pomelo turned it into text."

    /// `speechText` spoken by the system voice (`/usr/bin/say`) and encoded as a mono AAC M4A.
    public static func speech(in directory: URL) throws -> URL {
        let spoken = uniqueURL("speech", "aiff", in: directory)
        defer { try? FileManager.default.removeItem(at: spoken) }
        try run("/usr/bin/say", ["-o", spoken.path, speechText])
        let url = uniqueURL("speech", "m4a", in: directory)
        do {
            let source = try AVAudioFile(forReading: spoken)
            let format = source.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length))
            else { throw Failure("cannot create a PCM buffer") }
            try source.read(into: buffer)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64_000,
            ])
            try file.write(from: buffer)
        }  // the file is finalised when it goes out of scope
        return url
    }

    /// The tags written by `m4aWithTags`; the artwork is a 1x1 PNG.
    public static let songTitle = "Pomelo fixture song"
    public static let songArtist = "Pomelo fixture artist"
    public static let songArtwork = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// `m4a` carrying `songTitle`, `songArtist` and `songArtwork` as iTunes tags, the way a music library stores them.
    public static func m4aWithTags(seconds: Double, in directory: URL) async throws -> URL {
        let plain = try m4a(seconds: seconds, in: directory)
        defer { try? FileManager.default.removeItem(at: plain) }
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if identifier == .iTunesMetadataCoverArt { item.dataType = kCMMetadataBaseDataType_PNG as String }
            return item
        }
        let url = uniqueURL("song", "m4a", in: directory)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough)
        else { throw Failure("cannot create an export session for the tagged m4a") }
        session.metadata = [
            item(.iTunesMetadataSongName, songTitle as NSString), item(.iTunesMetadataArtist, songArtist as NSString),
            item(.iTunesMetadataCoverArt, songArtwork as NSData),
        ]
        session.outputURL = url
        session.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw Failure("cannot tag the m4a: \(session.error?.localizedDescription ?? "unknown error")")
        }
        return url
    }

    /// The title and ISO 6709 location written by `movieWithLocationAndTitle`.
    public static let movieTitle = "Pomelo fixture title"
    public static let movieLocation = "+48.8584+002.2945+035.000/"

    /// A 320x240 `movie` with audio, carrying `movieTitle` and `movieLocation` as QuickTime metadata, the way an
    /// iPhone stores where a video was taken.
    public static func movieWithLocationAndTitle(seconds: Double, in directory: URL) async throws -> URL {
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeMetadataTitle
        title.value = movieTitle as NSString
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = movieLocation as NSString
        return try await movie(seconds: seconds, withAudio: true, metadata: [title, location], in: directory)
    }

    /// A QuickTime movie, H.264 at 30 fps (320x240 unless sized), with a 440 Hz AAC audio track when `withAudio`.
    /// `transform` becomes the video track's preferred transform (a 90° rotation plays the movie sideways);
    /// `compression` holds H.264 compression properties (such as `AVVideoQualityKey`), for a heavier file than the
    /// encoder's frugal default. `grain` (an opacity, 0 for none) lays fresh noise over every frame, so each one costs
    /// bits as a camera's do; 0.08 is camera-like, 0.35 is far noisier than any camera.
    ///
    /// It is async so that it never blocks a thread of the cooperative pool: AVAssetWriter needs a free one to
    /// finish, and parallel tests that each blocked one while writing a movie deadlocked the pool.
    public static func movie(
        seconds: Double, withAudio: Bool, width: Int = 320, height: Int = 240,
        transform: CGAffineTransform = .identity, metadata: [AVMetadataItem] = [],
        compression: [String: any Sendable] = [:], grain: Double = 0, in directory: URL
    ) async throws -> URL {
        try await writeMovie(
            named: "clip", seconds: seconds, withAudio: withAudio, width: width, height: height, transform: transform,
            metadata: metadata, compression: compression, grain: grain, paint: drawMovingSquare, in: directory
        )
    }

    /// A movie with sound whose frames are four solid `Quadrant` colours as shown. Its frames are stored `width` x
    /// `height`; `rotated90` gives it an iPhone portrait's preferred transform (a quarter turn clockwise, then
    /// `height` across), so it shows `height` x `width` with the quadrants where `Quadrant` names them.
    public static func quadrantMovie(
        width: Int, height: Int, seconds: Double, rotated90: Bool, in directory: URL
    ) async throws -> URL {
        try await quadrantMovie(width: width, height: height, seconds: seconds, orientation: rotated90 ? 6 : 1, in: directory)
    }

    /// `quadrantMovie` whose preferred transform turns or mirrors the stored frame as EXIF `orientation` 1, 2
    /// (mirrored), 3 (upside down) or 6 (an iPhone portrait) does a photo; the quadrants show where `Quadrant` names them.
    public static func quadrantMovie(
        width: Int, height: Int, seconds: Double, orientation: Int, in directory: URL
    ) async throws -> URL {
        let (w, h) = (CGFloat(width), CGFloat(height))
        let transform = switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 6: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: CGAffineTransform.identity
        }
        return try await writeMovie(
            named: "quadrants", seconds: seconds, withAudio: true, width: width, height: height, transform: transform,
            metadata: [], compression: [:], grain: 0,
            paint: { context, width, height, _, _ in
                drawQuadrants(in: context, width: width, height: height, orientation: orientation)
            },
            in: directory
        )
    }

    /// Draws one frame of a movie: the context, its width and height, the frame and the frame count.
    private typealias FramePainter = (CGContext, Int, Int, Int, Int) -> Void

    private static func writeMovie(
        named prefix: String, seconds: Double, withAudio: Bool, width: Int, height: Int, transform: CGAffineTransform,
        metadata: [AVMetadataItem], compression: [String: any Sendable], grain: Double, paint: FramePainter,
        in directory: URL
    ) async throws -> URL {
        let url = uniqueURL(prefix, "mov", in: directory)
        let grainTiles = grain > 0
            ? try (0..<8).map { try grainTile(seed: 0x4752_4149 + UInt64($0), opacity: grain) } : []
        let framesPerSecond = 30
        let samplesPerFrame = Int(sampleRate) / framesPerSecond  // 1470, exact
        let frameCount = max(1, Int((seconds * Double(framesPerSecond)).rounded()))

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if !compression.isEmpty { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        writer.metadata = metadata
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if withAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
            var description = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
            )
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat
            )
            guard status == noErr, audioFormat != nil else {
                throw Failure("cannot describe the audio format (\(status))")
            }
        }

        guard writer.startWriting() else {
            throw Failure("cannot start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // The writer interleaves the tracks and stops taking one input until the other catches up, so each pass
        // feeds whichever input is ready; waiting on one input alone hangs on longer clips with audio.
        var nextFrame = 0
        var nextChunk = audioInput == nil ? frameCount : 0
        while nextFrame < frameCount || nextChunk < frameCount {
            if writer.status == .failed { throw writer.error ?? Failure("the movie writer failed") }
            var appended = false
            if nextFrame < frameCount, videoInput.isReadyForMoreMediaData {
                let buffer = try pixelBuffer(
                    width: width, height: height, frame: nextFrame, of: frameCount, paint: paint,
                    grain: grainTiles.isEmpty ? nil : grainTiles[nextFrame % grainTiles.count]
                )
                let time = CMTime(value: CMTimeValue(nextFrame), timescale: 30)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? Failure("cannot append video frame \(nextFrame)")
                }
                nextFrame += 1
                if nextFrame == frameCount { videoInput.markAsFinished() }
                appended = true
            }
            if let audioInput, let audioFormat, nextChunk < frameCount, audioInput.isReadyForMoreMediaData {
                let chunk = try audioSampleBuffer(
                    format: audioFormat, firstSample: nextChunk * samplesPerFrame, count: samplesPerFrame
                )
                guard audioInput.append(chunk) else {
                    throw writer.error ?? Failure("cannot append audio at frame \(nextChunk)")
                }
                nextChunk += 1
                if nextChunk == frameCount { audioInput.markAsFinished() }
                appended = true
            }
            if !appended { try await Task.sleep(for: .milliseconds(2)) }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? Failure("the movie writer did not complete")
        }
        return url
    }

    /// `movie` remuxed into Matroska by ffmpeg (stream copy), for what AVFoundation cannot write. Throws when ffmpeg
    /// is not installed.
    public static func matroskaMovie(
        seconds: Double, width: Int = 320, height: Int = 240, compression: [String: any Sendable] = [:], in directory: URL
    ) async throws -> URL {
        let ffmpeg = try ffmpegPath()
        let source = try await movie(
            seconds: seconds, withAudio: true, width: width, height: height, compression: compression, in: directory
        )
        let url = uniqueURL("clip", "mkv", in: directory)
        let process = Process()
        process.executableURL = URL(filePath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", source.path, "-c", "copy", url.path]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: source)
        guard process.terminationStatus == 0 else { throw Failure("ffmpeg could not remux the movie") }
        return url
    }

    /// `wav(seconds:channels:)` encoded by ffmpeg into `ext` (mp3, flac), formats AVFoundation cannot write. Throws
    /// when ffmpeg is not installed.
    public static func ffmpegAudio(seconds: Double, channels: Int = 1, ext: String, in directory: URL) throws -> URL {
        let ffmpeg = try ffmpegPath()
        let source = try wav(seconds: seconds, channels: channels, in: directory)
        defer { try? FileManager.default.removeItem(at: source) }
        let url = uniqueURL("tone", ext, in: directory)
        try run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", source.path, url.path])
        return url
    }

    private static func ffmpegPath() throws -> String {
        guard let url = Installed.path(of: "ffmpeg") else { throw Failure("ffmpeg is not installed") }
        return url.path
    }

    // MARK: Archives

    /// One entry of `tar(entries:named:in:)`, written exactly as given, so a test can craft the hostile names and
    /// links (`../x`, `/tmp/x`, a symlink to a folder outside) that a real archiver would refuse to store.
    public enum TarEntry: Sendable {
        case file(String, Data)
        case directory(String, mode: Int = 0o755)
        case symlink(String, target: String)
        case hardLink(String, target: String)
    }

    /// A ustar archive of `entries`, headers written by hand. A name longer than 100 bytes goes into the prefix
    /// field, split at a slash.
    public static func tar(entries: [TarEntry], named name: String = "archive.tar", in directory: URL) throws -> URL {
        var data = Data()
        for entry in entries {
            switch entry {
            case .file(let path, let contents):
                data += try tarHeader(path: path, type: "0", size: contents.count, mode: 0o644)
                data += contents + Data(count: (512 - contents.count % 512) % 512)
            case .directory(let path, let mode):
                data += try tarHeader(path: path, type: "5", mode: mode)
            case .symlink(let path, let target):
                data += try tarHeader(path: path, type: "2", linkName: target, mode: 0o755)
            case .hardLink(let path, let target):
                data += try tarHeader(path: path, type: "1", linkName: target, mode: 0o644)
            }
        }
        data += Data(count: 1024)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    /// `item` zipped by `ditto` as Finder's Compress does (`--sequesterRsrc`, and `--keepParent` unless told
    /// otherwise, in which case the zip holds the folder's contents). Without `sequesterResources`, extended
    /// attributes go into inline `._name` entries next to their file instead of under `__MACOSX/`.
    public static func zip(
        _ item: URL, keepParent: Bool = true, sequesterResources: Bool = true, named name: String, in directory: URL
    ) throws -> URL {
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        let options = (sequesterResources ? ["--sequesterRsrc"] : []) + (keepParent ? ["--keepParent"] : [])
        try run("/usr/bin/ditto", ["-c", "-k"] + options + [item.path, url.path])
        return url
    }

    /// A one-sheet workbook with a text cell, a number and a date (`2026-10-30` as serial 46325 in built-in format 14):
    /// `XLSXWriter` writes no styles, so the reader's dates need a hand-built package.
    public static func dateWorkbook(named name: String = "sheet.xlsx", in directory: URL) throws -> URL {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                </Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """),
            ("xl/workbook.xml", """
                <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="\(main)" xmlns:r="\(relationships)">\
                <sheets><sheet name="Orders" sheetId="1" r:id="rId1"/></sheets></workbook>
                """),
            ("xl/_rels/workbook.xml.rels", """
                <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="\(relationships)/styles" Target="styles.xml"/>\
                <Relationship Id="rId3" Type="\(relationships)/sharedStrings" Target="sharedStrings.xml"/></Relationships>
                """),
            ("xl/styles.xml", """
                <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="\(main)"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>
                """),
            ("xl/sharedStrings.xml", """
                <?xml version="1.0" encoding="UTF-8"?><sst xmlns="\(main)"><si><t>Pomelo order</t></si></sst>
                """),
            ("xl/worksheets/sheet1.xml", """
                <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="\(main)"><sheetData>\
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>12.5</v></c><c r="C1" s="1"><v>46325</v></c></row>\
                </sheetData></worksheet>
                """),
        ]
        return try zippedPackage(parts, prefix: "xlsx", named: name, in: directory)
    }

    /// Writes `parts` (path inside the package, text) into a folder of their own and zips them as an Office file.
    private static func zippedPackage(
        _ parts: [(String, String)], prefix: String, named name: String, in directory: URL
    ) throws -> URL {
        let package = directory.appending(path: "\(prefix)-package-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: package) }
        for (path, text) in parts {
            let file = package.appending(path: path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return try zip(package, keepParent: false, sequesterResources: false, named: name, in: directory)
    }

    /// The smallest PresentationML package LibreOffice opens: `slides` slides, each a title shape reading "Slide N",
    /// on one master and one layout with a minimal theme.
    public static func presentation(slides: Int, named name: String = "deck.pptx", in directory: URL) throws -> URL {
        let count = max(1, slides)
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let slideOverrides = (1...count).map {
            #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }.joined()
        let slideIDs = (1...count).map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 2)"/>"# }.joined()
        let slideRelationships = (1...count).map {
            #"<Relationship Id="rId\#($0 + 2)" Type="\#(r)/slide" Target="slides/slide\#($0).xml"/>"#
        }.joined()
        let shapeTree = #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
        var parts: [(String, String)] = [
            ("[Content_Types].xml", """
                \(header)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
                <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
                <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
                <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
                \(slideOverrides)</Types>
                """),
            ("_rels/.rels", """
                \(header)<Relationships xmlns="\(pkg)">\
                <Relationship Id="rId1" Type="\(r)/officeDocument" Target="ppt/presentation.xml"/></Relationships>
                """),
            ("ppt/presentation.xml", """
                \(header)<p:presentation xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)">\
                <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
                <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="9144000" cy="6858000" type="screen4x3"/>\
                <p:notesSz cx="6858000" cy="9144000"/></p:presentation>
                """),
            ("ppt/_rels/presentation.xml.rels", """
                \(header)<Relationships xmlns="\(pkg)">\
                <Relationship Id="rId1" Type="\(r)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
                <Relationship Id="rId2" Type="\(r)/theme" Target="theme/theme1.xml"/>\(slideRelationships)</Relationships>
                """),
            ("ppt/slideMasters/slideMaster1.xml", """
                \(header)<p:sldMaster xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)">\(shapeTree)</p:spTree></p:cSld>\
                <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
                accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
                <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
                """),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
                \(header)<Relationships xmlns="\(pkg)">\
                <Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
                <Relationship Id="rId2" Type="\(r)/theme" Target="../theme/theme1.xml"/></Relationships>
                """),
            ("ppt/slideLayouts/slideLayout1.xml", """
                \(header)<p:sldLayout xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)" type="blank">\(shapeTree)</p:spTree></p:cSld>\
                </p:sldLayout>
                """),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
                \(header)<Relationships xmlns="\(pkg)">\
                <Relationship Id="rId1" Type="\(r)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
                """),
            ("ppt/theme/theme1.xml", """
                \(header)<a:theme xmlns:a="\(a)" name="Pomelo"><a:themeElements>\
                <a:clrScheme name="Pomelo"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
                <a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2>\
                <a:accent1><a:srgbClr val="F59E0B"/></a:accent1><a:accent2><a:srgbClr val="10B981"/></a:accent2>\
                <a:accent3><a:srgbClr val="3B82F6"/></a:accent3><a:accent4><a:srgbClr val="EF4444"/></a:accent4>\
                <a:accent5><a:srgbClr val="8B5CF6"/></a:accent5><a:accent6><a:srgbClr val="14B8A6"/></a:accent6>\
                <a:hlink><a:srgbClr val="2563EB"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme>\
                <a:fontScheme name="Pomelo"><a:majorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
                <a:minorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
                <a:fmtScheme name="Pomelo">\
                <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
                <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
                <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
                <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
                <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
                <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
                <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
                <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
                </a:themeElements></a:theme>
                """),
        ]
        for number in 1...count {
            parts.append(("ppt/slides/slide\(number).xml", """
                \(header)<p:sld xmlns:a="\(a)" xmlns:r="\(r)" xmlns:p="\(p)">\(shapeTree)\
                <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
                <p:spPr><a:xfrm><a:off x="914400" y="2743200"/><a:ext cx="7315200" cy="1371600"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="4400"/><a:t>Slide \(number)</a:t></a:r></a:p></p:txBody>\
                </p:sp></p:spTree></p:cSld></p:sld>
                """))
            parts.append(("ppt/slides/_rels/slide\(number).xml.rels", """
                \(header)<Relationships xmlns="\(pkg)">\
                <Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
                """))
        }
        return try zippedPackage(parts, prefix: "pptx", named: name, in: directory)
    }

    /// A RAR 5 archive of four files: no RAR writer ships with macOS. libarchive's `test_read_format_rar5_multiple_files`
    /// (BSD-2-Clause, see `Tests/PomeloEnginesTests/Resources/archives/NOTICE.md`), the same bytes as that folder's `rar5.rar`.
    public static func rar5Archive(named name: String = "archive.rar", in directory: URL) throws -> URL {
        let encoded = """
            UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAAxaewicCAwvkAgSAIKSDAsayE36ABQEJdGVzdDEuYmluCgMTZ1+sWxpanhDK8WABEGRU
            Zy9XBW9SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSST9/exzM7d9roun2pLrrtxu75nR5vOfJ8
            YzMM6cw1zOeZ5pz4n6gAgAgBsMPHTht6efl4+Hf3dvZ19XT0c/Ny8nHxcPBv727ube1s7Gvraupp6WjoZ+dm5mXlZORj42LiYeFg
            4F/fXt5d3VzcW9ta2lnZWNhX11bWVdVU1FPTUtJR0VDQT89Ozk3NTMxLy0rKSclIyEfHRsZFxUTEQ8NCwkHBQMA/vz6+Pb1/fd9j
            3RS4Ut32cUKAz8MALZ0RvEaAh0IWsCwHCJ27S08IfnZoBZgBbOiN0jQEOhC1gWA4RO3KWnhD85NALMALZ0RuEaAh0IWsCwHCJ23S
            08Ifm5oBZgBbOiNsjQEOhC1gWA4RNY/fRX5jVV99hK+m/FfMOU1zVNOtTQp+JH/+gE59beQnAgML5AIEgCCkgwLLr2bxgAUBCXRl
            c3QyLmJpbgoDE3pfrFstVHMXyfJgARBkVGcvVwVvUkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk
            kk/f3sczO3fa6Lp9qS667cbu+Z0ebznyfGMzDOnMNcznmeac+J+oAIAIAamHjpw29PPy8fDv7u3s6+rp6Ofm5eTj4uHg397d3Nva
            2djX1tXU09LR0M/OzczLysnIx8bFxMPCwcC/vr28u7q5uLe2tbSzsrGwr66trKuqqainpqWko6KhoJ+enZybmpmYl5aVlJOSkZCP
            jo2Mi4qJiIeGhYSDgoGAf359fHt6/vu+x7opcKW77OKFAZ+GAFs6I3iNAQ6ELWBYDhE7dpaeEPzs0AswAtnRG6RoCHQhawLAcInb
            lLTwh+cmgFmAFs6I3CNAQ6ELWBYDhE7bpaeEPzc0AswAtnRG2RoCHQhawLAcImsfvor8xqq++wlfTfivmHKa5qmnWpoU/Ej//QBz
            ewC3JwIDC/ACBIAgpIMC2SOxn4AFAQl0ZXN0My5iaW4KAxN+X6xb0D0AA8n+bAEQdFVGL3V9SSSSSSSSSSSSSSSSSSSSSSSSSSSS
            SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSTft+37exzmeOm72vC8dqS869czmZ3PDO85/T4xmYZ45nWHO5+/cOfyfqACACAGwowus
            r6efl4+Hf3dvZ19XT0c/Ny8nHxcPBv727ube1s7Gvraupp6WjoZ+dm5mXlZORj42LiYeFg4F/fXt5d3VzcW9ta2lnZWNhX11bWVd
            VU1FPTUtJR0VDQT89Ozk3NTMxLy0rKSclIyEfHRsZFxUTEQ8NCwkHBQMA/vz6+Pb1/fe9T3BDfxDZezEGDqbCAmk4E2CZVg0wTbk
            wnjSZYUu3hEoeDTwA6GICaTgTXJlVzQ8abkANpMsKXbsiUPBp2AdDEBNJwJrEyqxoeNNyAG0mWFLt0RKHg06AOhiAmk4E1SZVU0P
            Gm5ADaTLCl9T98EfmOVH32kj6b8R8xchzrUOPWhwafio//wAM0zNwCcCAwvwAgSAIKSDAtQ+xBCABQEJdGVzdDQuYmluCgMTgV+s
            W6EmHRLK/WwBEHRVRi91f5JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJN+37d3sc5njpu9rwv
            HakvOvXM5mdzwzvOf0+MZmGeOZ1hzufv3Dn8n6gAgAgBrumFlVPTz8vHw7+7t7Ovq6ejn5uXk4+Lh4N/e3dzb2tnY19bV1NPS0dD
            Pzs3My8rJyMfGxcTDwsHAv769vLu6ubi3trW0s7KxsK+urayrqqmop6alpKOioaCfnp2cm5qZmJeWlZSTkpGQj46NjIuKiYiHhoW
            Eg4KBgH9+fXx7ev773uvcEN/ENl7MQYOpsICaTgTYJlWDTBNuTCeNJlhS7XIlDwaXAOhiAmk4E1iZVY0PGm5ADaTLCl28IlDwaeA
            HQxATScCapMqqaHjTcgBtJlhS7dkSh4NOwDoYgJpOBNQmVUNDxpuQA2kywpfdfvgj8xyo++0kfTfiPmLkOdahx60ODT8VH/+AB13
            VlEDBQQA
            """
        guard let data = Data(base64Encoded: encoded.filter { !$0.isWhitespace }) else { throw Failure("bad RAR fixture") }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    /// `file` gzipped beside it as `<name>.gz`, without a stored name; `file` is kept.
    public static func gzip(_ file: URL) throws -> URL {
        try run("/usr/bin/gzip", ["-k", "-n", file.path])
        return file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".gz", directoryHint: .notDirectory)
    }

    private static func tarHeader(path: String, type: Character, size: Int = 0, linkName: String = "", mode: Int) throws -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) throws {
            let bytes = Array(text.utf8)
            guard bytes.count <= length else { throw Failure("\(text) does not fit a \(length)-byte tar field") }
            header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        func octal(_ value: Int, at offset: Int, length: Int) throws {
            let digits = String(value, radix: 8)
            try put(String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits, at: offset, length: length - 1)
        }
        var prefix = ""
        var base = path
        if path.utf8.count > 100 {
            guard let slash = path.indices.filter({ path[$0] == "/" }).last(where: {
                path[path.index(after: $0)...].utf8.count <= 100 && path[..<$0].utf8.count <= 155
            }) else { throw Failure("\(path) is too long for ustar") }
            prefix = String(path[..<slash])
            base = String(path[path.index(after: slash)...])
        }
        try put(base, at: 0, length: 100)
        try octal(mode, at: 100, length: 8)
        try octal(Int(getuid()), at: 108, length: 8)
        try octal(Int(getgid()), at: 116, length: 8)
        try octal(size, at: 124, length: 12)
        try octal(1_700_000_000, at: 136, length: 12)
        try put("        ", at: 148, length: 8)
        header[156] = type.asciiValue!
        try put(linkName, at: 157, length: 100)
        try put("ustar", at: 257, length: 6)
        try put("00", at: 263, length: 2)
        try put(prefix, at: 345, length: 155)
        let checksum = header.reduce(0) { $0 + Int($1) }
        try octal(checksum, at: 148, length: 7)
        header[154] = 0
        return Data(header)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
    }

    // MARK: Helpers

    /// `movie`'s frames: a colour that shifts from blue to red with a white square crossing the middle.
    private static func drawMovingSquare(in context: CGContext, width: Int, height: Int, frame: Int, total: Int) {
        let progress = CGFloat(frame) / CGFloat(max(1, total - 1))
        context.setFillColor(CGColor(srgbRed: progress, green: 0.4, blue: 1 - progress, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let travel = CGFloat(width - 40)
        let middle = CGFloat(height) / 2 - 20
        context.fill(CGRect(x: progress * travel, y: middle, width: 40, height: 40))
    }

    private static func drawQuadrants(in context: CGContext, width: Int, height: Int, orientation: Int) {
        for quadrant in Quadrant.allCases {
            context.setFillColor(rgbColor(quadrant.rgb))
            context.fill(storedQuarter(showing: quadrant, orientation: orientation, width: width, height: height))
        }
    }

    /// The quarter of a stored `width` x `height` picture (in a bitmap context's coordinates, origin bottom left)
    /// that shows as `quadrant` once EXIF `orientation` is applied.
    private static func storedQuarter(showing quadrant: Quadrant, orientation: Int, width: Int, height: Int) -> CGRect {
        let (right, bottom) = (quadrant.isRight, quadrant.isBottom)
        // Where the shown quarter sits in the stored picture, counted from its top left (EXIF 5 to 8 swap the axes).
        let stored: (right: Bool, bottom: Bool) = switch orientation {
        case 2: (!right, bottom)
        case 3: (!right, !bottom)
        case 4: (right, !bottom)
        case 5: (bottom, right)
        case 6: (bottom, !right)
        case 7: (!bottom, !right)
        case 8: (!bottom, right)
        default: (right, bottom)
        }
        let half = CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        return CGRect(x: stored.right ? half.width : 0, y: stored.bottom ? 0 : half.height,
                      width: half.width, height: half.height)
    }

    private static func rgbColor(_ rgb: [Int]) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }

    private static func drawPhoto(in context: CGContext, width: Int, height: Int) {
        let colors = [
            CGColor(srgbRed: 0.08, green: 0.2, blue: 0.5, alpha: 1),
            CGColor(srgbRed: 0.9, green: 0.55, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.9, blue: 0.7, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1]
        ) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
        var generator = SeededGenerator(seed: 0x4B55_4D51)
        let side = Double(min(width, height))
        for _ in 0..<260 {
            let radius = side * Double.random(in: 0.01...0.09, using: &generator)
            let center = CGPoint(
                x: Double.random(in: 0...Double(width), using: &generator),
                y: Double.random(in: 0...Double(height), using: &generator)
            )
            context.setFillColor(CGColor(
                srgbRed: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                blue: .random(in: 0...1, using: &generator), alpha: 0.35
            ))
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        context.setLineWidth(max(1, side / 1500))
        for _ in 0..<1800 {
            let from = CGPoint(
                x: Double.random(in: 0...Double(width), using: &generator),
                y: Double.random(in: 0...Double(height), using: &generator)
            )
            let reach = side * Double.random(in: 0.005...0.03, using: &generator)
            let angle = Double.random(in: 0...(2 * Double.pi), using: &generator)
            context.setStrokeColor(CGColor(gray: .random(in: 0...1, using: &generator), alpha: 0.5))
            context.move(to: from)
            context.addLine(to: CGPoint(x: from.x + cos(angle) * reach, y: from.y + sin(angle) * reach))
            context.strokePath()
        }
    }

    /// Adds up to ±24 to every colour channel of the context's opaque pixels (8-bit RGBA or RGBX).
    private static func addGrain(to context: CGContext, seed: UInt64) {
        guard let data = context.data else { return }
        let bytesPerRow = context.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * context.height)
        var generator = SeededGenerator(seed: seed)
        for y in 0..<context.height {
            for x in 0..<context.width {
                let pixel = y * bytesPerRow + x * 4
                if context.alphaInfo == .premultipliedLast, bytes[pixel + 3] == 0 { continue }
                let random = generator.next()
                for channel in 0..<3 {
                    let offset = Int((random >> (UInt64(channel) * 8)) & 0xFF) % 49 - 24
                    bytes[pixel + channel] = UInt8(clamping: Int(bytes[pixel + channel]) + offset)
                }
            }
        }
    }

    private static func sineSample(at index: Int, amplitude: Double = 0.5) -> Int16 {
        Int16((sin(2 * Double.pi * toneFrequency * Double(index) / sampleRate) * amplitude * Double(Int16.max)).rounded())
    }

    private static func textLine(_ text: String, size: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func makeImage(
        width: Int, height: Int, alpha: Bool, draw: (CGContext) -> Void
    ) throws -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: info.rawValue
            )
        else { throw Failure("cannot create a \(width)x\(height) bitmap context") }
        draw(context)
        guard let image = context.makeImage() else { throw Failure("cannot render the image") }
        return image
    }

    private static func write(_ image: CGImage, type: String, properties: [CFString: Any]? = nil, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw Failure("cannot create an image destination (\(type)) at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalise \(url.lastPathComponent)") }
    }

    /// A 128x128 tile of grey noise at `opacity`, laid over a movie frame by `pixelBuffer`.
    private static func grainTile(seed: UInt64, opacity: Double) throws -> CGImage {
        let alpha = max(1, min(255, Int((opacity * 255).rounded())))
        return try makeImage(width: 128, height: 128, alpha: true) { context in
            guard let data = context.data else { return }
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * 128)
            var generator = SeededGenerator(seed: seed)
            for y in 0..<128 {
                for x in 0..<128 {
                    let pixel = y * context.bytesPerRow + x * 4
                    // Premultiplied: the grey never exceeds the alpha.
                    let grey = UInt8(Int(generator.next() & 0xFF) * alpha / 255)
                    bytes[pixel] = grey
                    bytes[pixel + 1] = grey
                    bytes[pixel + 2] = grey
                    bytes[pixel + 3] = UInt8(alpha)
                }
            }
        }
    }

    private static func pixelBuffer(
        width: Int, height: Int, frame: Int, of total: Int, paint: FramePainter, grain: CGImage? = nil
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created
        )
        guard status == kCVReturnSuccess, let buffer = created else {
            throw Failure("cannot create a pixel buffer (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw Failure("cannot draw into the pixel buffer") }
        paint(context, width, height, frame, total)
        if let grain {
            let shift = CGFloat((frame * 37) % 128)
            context.draw(grain, in: CGRect(x: -shift, y: -shift, width: 128, height: 128), byTiling: true)
        }
        return buffer
    }

    private static func audioSampleBuffer(
        format: CMAudioFormatDescription, firstSample: Int, count: Int
    ) throws -> CMSampleBuffer {
        var samples = (0..<count).map { sineSample(at: firstSample + $0) }
        let byteCount = count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw Failure("cannot allocate an audio block (\(status))")
        }
        status = samples.withUnsafeMutableBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == kCMBlockBufferNoErr else { throw Failure("cannot fill an audio block (\(status))") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(firstSample), timescale: Int32(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { throw Failure("cannot create an audio sample buffer (\(status))") }
        return buffer
    }
}

/// SplitMix64: a small deterministic generator, so a seeded fixture is identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
