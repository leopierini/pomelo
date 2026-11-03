import CoreGraphics
import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Crop editor's rectangle (P27): ratios, handles, nudges, the minimum size and what the footer says.
@Suite struct CropModelTests {
    private let landscape = CGSize(width: 4000, height: 3000)
    private let portrait = CGSize(width: 3000, height: 4000)

    /// The rectangle in pixels of the model's image.
    private func pixels(_ model: CropModel) -> CGRect {
        CGRect(x: model.rect.x * model.pixelSize.width, y: model.rect.y * model.pixelSize.height,
               width: model.rect.width * model.pixelSize.width, height: model.rect.height * model.pixelSize.height)
    }

    private func isInside(_ rect: UnitRect) -> Bool {
        rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 1 + 1e-12 && rect.y + rect.height <= 1 + 1e-12
    }

    @Test func itStartsWithTheWholeImage() {
        let model = CropModel(pixelSize: landscape)
        #expect(model.rect == UnitRect(x: 0, y: 0, width: 1, height: 1))
        #expect(model.ratio == .free)
        #expect(!model.isPortrait)
        #expect(CropModel(pixelSize: portrait).isPortrait)
    }

    @Test func squareOnALandscapePhotoIsCentred() {
        var m = CropModel(pixelSize: landscape)
        m.setRatio(.square)
        #expect(m.rect == UnitRect(x: 0.125, y: 0, width: 0.75, height: 1))
        #expect(m.readout == "3000 \u{00D7} 3000")
    }

    @Test func sixteenNineOnAPortraitPhotoIsTall() {
        var m = CropModel(pixelSize: portrait)
        m.setRatio(.sixteenNine)
        // 9:16 inside 3000 × 4000: 2250 × 4000.
        #expect(m.rect == UnitRect(x: 0.125, y: 0, width: 0.75, height: 1))
        #expect(m.readout == "2250 \u{00D7} 4000")
    }

    @Test func aRatioIsCentredOnTheCurrentRectangle() {
        var m = CropModel(pixelSize: landscape)
        m.drag(.bottomRight, by: CGSize(width: -0.5, height: -0.5))
        // 2000 × 1500 at the top left, centred on (1000, 750): the largest square there is 1500.
        m.setRatio(.square)
        #expect(pixels(m) == CGRect(x: 250, y: 0, width: 1500, height: 1500))
    }

    @Test func flippingSwapsTheRatio() {
        var m = CropModel(pixelSize: landscape)
        m.setRatio(.fourThree)
        #expect(!m.isPortrait)
        #expect(m.readout == "4000 \u{00D7} 3000")
        m.flip()
        #expect(m.isPortrait)
        // 3:4 inside 4000 × 3000: 2250 × 3000, centred.
        #expect(m.readout == "2250 \u{00D7} 3000")
        #expect(pixels(m) == CGRect(x: 875, y: 0, width: 2250, height: 3000))
        m.setRatio(.sixteenNine)
        #expect(m.readout == "1688 \u{00D7} 3000" || m.readout == "1687 \u{00D7} 3000")
        m.flip()
        #expect(!m.isPortrait)
        #expect(m.readout == "4000 \u{00D7} 2250")
    }

    @Test func flipShowsOnlyForRatiosThatTurn() {
        #expect(CropRatio.allCases.filter(\.canFlip) == [.fourThree, .sixteenNine])
        var m = CropModel(pixelSize: landscape)
        m.setRatio(.square)
        let before = m
        m.flip()
        #expect(m.rect == before.rect)
    }

    @Test func originalKeepsTheSourceRatio() {
        var m = CropModel(pixelSize: CGSize(width: 1000, height: 500))
        m.drag(.right, by: CGSize(width: -0.5, height: 0))
        #expect(m.readout == "500 \u{00D7} 500")
        m.setRatio(.original)
        // Centred on (250, 250) of a 2:1 image: 500 × 250.
        #expect(m.readout == "500 \u{00D7} 250")
        #expect(pixels(m) == CGRect(x: 0, y: 125, width: 500, height: 250))
    }

    @Test func ratiosHaveTitles() {
        #expect(CropRatio.allCases.map(\.title) == ["Free", "1:1", "4:3", "16:9", "Original"])
    }

    @Test func aCornerDragKeepsTheRatio() {
        var m = CropModel(pixelSize: landscape)
        m.setRatio(.square)
        m.drag(.bottomRight, by: CGSize(width: -0.1, height: 0))
        let rect = pixels(m)
        #expect(abs(rect.width - rect.height) <= 1)
        #expect(rect.width < 3000, "the corner moved")
        // The opposite corner stays where it was.
        #expect(rect.minX == 500 && rect.minY == 0)

        m.drag(.topLeft, by: CGSize(width: 0, height: 0.2))
        let after = pixels(m)
        #expect(abs(after.width - after.height) <= 1)
        #expect(after.maxX == rect.maxX && after.maxY == rect.maxY)
    }

    @Test func aFreeEdgeDragMovesOneSide() {
        var m = CropModel(pixelSize: landscape)
        m.drag(.left, by: CGSize(width: 0.25, height: 0.3))
        #expect(pixels(m) == CGRect(x: 1000, y: 0, width: 3000, height: 3000))
        m.drag(.bottom, by: CGSize(width: 0.4, height: -0.5))
        #expect(pixels(m) == CGRect(x: 1000, y: 0, width: 3000, height: 1500))
        m.drag(.topRight, by: CGSize(width: -0.25, height: 0.1))
        #expect(pixels(m) == CGRect(x: 1000, y: 300, width: 2000, height: 1200))
    }

    @Test func theRectangleNeverLeavesTheImage() {
        var m = CropModel(pixelSize: landscape)
        m.drag(.bottomRight, by: CGSize(width: -0.5, height: -0.5))
        m.drag(.body, by: CGSize(width: 2, height: 2))
        #expect(isInside(m.rect))
        #expect(pixels(m) == CGRect(x: 2000, y: 1500, width: 2000, height: 1500), "moved, not resized")
        m.drag(.body, by: CGSize(width: -5, height: -5))
        #expect(pixels(m).origin == .zero)
        m.drag(.topLeft, by: CGSize(width: -3, height: -3))
        m.drag(.bottomRight, by: CGSize(width: 3, height: 3))
        #expect(m.rect == UnitRect(x: 0, y: 0, width: 1, height: 1))

        var square = CropModel(pixelSize: landscape)
        square.setRatio(.square)
        square.drag(.bottomRight, by: CGSize(width: 3, height: 3))
        #expect(isInside(square.rect))
        #expect(abs(pixels(square).width - pixels(square).height) <= 1)
    }

    @Test func theRectangleNeverGetsTooSmall() {
        var m = CropModel(pixelSize: landscape)
        m.drag(.bottomRight, by: CGSize(width: -2, height: -2))
        #expect(pixels(m).size == CGSize(width: 16, height: 16))
        m.drag(.left, by: CGSize(width: 1, height: 0))
        #expect(pixels(m).width == 16 && pixels(m).minX == 0)

        var square = CropModel(pixelSize: landscape)
        square.setRatio(.sixteenNine)
        square.drag(.topLeft, by: CGSize(width: 2, height: 2))
        let rect = pixels(square)
        #expect(rect.width >= 16 && rect.height >= 16)
        #expect(isInside(square.rect))

        // An image under the minimum can only be kept whole.
        var tiny = CropModel(pixelSize: CGSize(width: 10, height: 40))
        tiny.drag(.bottomRight, by: CGSize(width: -1, height: -1))
        #expect(pixels(tiny).size == CGSize(width: 10, height: 16))
        #expect(CropModel.minimumPixels == 16)
    }

    @Test func nudgesMoveAndResizeByPixels() {
        var m = CropModel(pixelSize: landscape)
        m.drag(.bottomRight, by: CGSize(width: -0.5, height: -0.5))
        m.nudge(.body, dx: 1, dy: 0, coarse: false)
        #expect(pixels(m) == CGRect(x: 1, y: 0, width: 2000, height: 1500))
        m.nudge(.body, dx: 0, dy: 1, coarse: true)
        #expect(pixels(m) == CGRect(x: 1, y: 10, width: 2000, height: 1500))
        m.nudge(.bottomRight, dx: -1, dy: 0, coarse: true)
        #expect(pixels(m) == CGRect(x: 1, y: 10, width: 1990, height: 1500))
        m.nudge(.bottomRight, dx: 0, dy: 1, coarse: false)
        #expect(pixels(m) == CGRect(x: 1, y: 10, width: 1990, height: 1501))
        m.nudge(.body, dx: -1, dy: -1, coarse: true)
        #expect(pixels(m).origin == .zero)
    }

    @Test func edgeHandlesHideWithAFixedRatio() {
        var m = CropModel(pixelSize: landscape)
        #expect(m.handles() == CropHandle.allCases)
        for ratio in [CropRatio.square, .fourThree, .sixteenNine, .original] {
            m.setRatio(ratio)
            #expect(m.handles() == [.topLeft, .topRight, .bottomRight, .bottomLeft, .body], "\(ratio)")
        }
        m.setRatio(.free)
        #expect(m.handles().count == 9)
    }

    @Test func readoutIsInPixelsAndTheWholeImageBlocks() {
        var m = CropModel(pixelSize: landscape)
        #expect(m.readout == "4000 \u{00D7} 3000")
        #expect(m.blocker == "Nothing to crop")
        #expect(m.spec == nil)
        // One pixel off still keeps everything.
        m.nudge(.bottomRight, dx: -1, dy: 0, coarse: false)
        #expect(m.blocker == "Nothing to crop")
        m.nudge(.bottomRight, dx: -1, dy: 0, coarse: false)
        #expect(m.blocker == nil)
        #expect(m.readout == "3998 \u{00D7} 3000")
        #expect(m.spec == .crop(m.rect))
    }

    @Test func aRememberedRatioIsAppliedAtOnce() {
        let m = CropModel(pixelSize: landscape, ratio: .square)
        #expect(m.ratio == .square)
        #expect(m.rect == UnitRect(x: 0.125, y: 0, width: 0.75, height: 1))
        #expect(m.blocker == nil)
    }

    @Test func theSpecMatchesThePixelsTheEngineCuts() {
        var m = CropModel(pixelSize: CGSize(width: 1080, height: 1920))
        m.setRatio(.square)
        guard case .crop(let rect) = m.spec else {
            Issue.record("no spec")
            return
        }
        #expect(rect.pixels(width: 1080, height: 1920) == CGRect(x: 0, y: 420, width: 1080, height: 1080))
    }
}
