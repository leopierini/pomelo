import CoreGraphics
import CoreImage
import Foundation
import PomeloCore

extension VisionEngine {
    private static let animatedStraightenReason = "Animated images can't be straightened"

    /// Flattens the page `segmenter` finds in the upright primary image (P262) with `CIPerspectiveCorrection` at the
    /// picture's full resolution, into `StraightenRules.outputSize`, and writes it as Crop writes (ImageIOEngine's
    /// `writeEdited`), so a photo stored sideways comes out upright.
    func straightenPage(_ step: ConversionStep) async throws -> URL {
        let imageIO = ImageIOEngine()
        let (destinationType, source) = try imageIO.openForEdit(step)
        let (sourceProperties, upright) = try ImageIOEngine.uprightPrimary(source, animated: Self.animatedStraightenReason)
        guard let page = try await segmenter.page(in: upright) else {
            throw ConversionError.notApplicable(reason: StraightenRules.noDocumentReason)
        }
        let quad: PageQuad
        switch StraightenRules.verdict(
            confidence: page.confidence, quad: page.quad, imageWidth: upright.width, imageHeight: upright.height
        ) {
        case .noDocument: throw ConversionError.notApplicable(reason: StraightenRules.noDocumentReason)
        case .alreadyFlat: throw ConversionError.notApplicable(reason: StraightenRules.alreadyFlatReason)
        case .straighten(let kept): quad = kept
        }
        let size = StraightenRules.outputSize(for: quad)
        let flat = try await Self.offThePool { _ in
            try Self.flattened(upright, page: quad, width: size.width, height: size.height)
        }
        try Task.checkCancellation()
        return try imageIO.writeEdited(flat, sourceProperties: sourceProperties, as: destinationType, for: step)
    }

    /// `page` of `image` flattened into a new `width` x `height` bitmap of the picture's own pixel format (opaque stays
    /// opaque, an EXR keeps its floats, and the writers that refuse a sub-image get fresh pixels, P84).
    private static func flattened(_ image: CGImage, page: PageQuad, width: Int, height: Int) throws -> CGImage {
        let pictureHeight = Double(image.height)
        // The quad is y down from the top; Core Image's origin is the bottom left.
        func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x, y: pictureHeight - point.y) }
        // Clamped, so the corners sample the picture's border pixels rather than the transparency beyond it.
        let corrected = CIImage(cgImage: image).clampedToExtent().applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(page.topLeft), "inputTopRight": vector(page.topRight),
            "inputBottomRight": vector(page.bottomRight), "inputBottomLeft": vector(page.bottomLeft),
        ])
        let extent = corrected.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else {
            throw Failure("cannot flatten the page of the picture")
        }
        let fitted = corrected
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(width) / extent.width, y: Double(height) / extent.height))
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let rendered = CIContext().createCGImage(
            fitted, from: frame, format: image.bitsPerComponent > 8 ? .RGBAh : .RGBA8, colorSpace: space
        ) else { throw Failure("cannot render the straightened page") }
        return try ImageIOEngine.redrawn(image, width: width, height: height) { context, rect in
            context.draw(rendered, in: rect)
        }
    }
}
