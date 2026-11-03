import CoreGraphics
import PDFKit

/// Draws PDF pages to bitmaps; shared by the PDF-to-image edges and the code reader.
enum PDFPageRenderer {
    /// A rendered page larger than this on either side is refused instead of exhausting memory.
    private static let maxPixelsPerSide = 30_000

    /// Draws `page` upright on a white sRGB bitmap of `bounds x dpi / 72` pixels.
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        let number = (page.document?.index(for: page)).map { $0 + 1 } ?? 1
        guard dpi > 0 else { throw PDFKitEngine.Failure("the render resolution must be positive, not \(dpi) dpi") }
        var bounds = page.bounds(for: .mediaBox)
        if page.rotation % 180 != 0 { bounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.height, height: bounds.width) }
        let scale = Double(dpi) / 72
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, width <= maxPixelsPerSide, height <= maxPixelsPerSide else {
            throw PDFKitEngine.Failure("page \(number) would be \(width) x \(height) px at \(dpi) dpi, which is outside the supported range")
        }
        guard let pageReference = page.pageRef,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw PDFKitEngine.Failure("cannot create a \(width) x \(height) bitmap to render page \(number)") }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(canvas)
        // `getDrawingTransform` never scales a page up, so it maps the page onto a rect of its own size in points
        // (handling rotation and the media box origin) and the context scale provides the dpi.
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        let upright = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        context.concatenate(pageReference.getDrawingTransform(.mediaBox, rect: upright, rotate: 0, preserveAspectRatio: false))
        context.drawPDFPage(pageReference)
        guard let image = context.makeImage() else { throw PDFKitEngine.Failure("cannot render page \(number)") }
        return image
    }
}
