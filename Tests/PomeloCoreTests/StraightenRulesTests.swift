import CoreGraphics
import Foundation
import Testing
@testable import PomeloCore

/// Straighten document's geometry (P262): the quad's sides and angles, the page ratio snap and the verdicts.
@Suite struct StraightenRulesTests {
    private func quad(_ tl: (Double, Double), _ tr: (Double, Double), _ br: (Double, Double), _ bl: (Double, Double))
        -> PageQuad {
        PageQuad(
            topLeft: CGPoint(x: tl.0, y: tl.1), topRight: CGPoint(x: tr.0, y: tr.1),
            bottomRight: CGPoint(x: br.0, y: br.1), bottomLeft: CGPoint(x: bl.0, y: bl.1)
        )
    }

    /// An axis-aligned rectangle `width` x `height` at the origin.
    private func rectangle(_ width: Double, _ height: Double) -> PageQuad {
        quad((0, 0), (width, 0), (width, height), (0, height))
    }

    @Test func meanSizeAveragesOppositeEdges() {
        // Top 600, bottom 800; left and right sqrt(100² + 1000²).
        let trapezoid = quad((200, 0), (800, 0), (900, 1000), (100, 1000))
        let side = (100.0 * 100 + 1000 * 1000).squareRoot()
        #expect(abs(trapezoid.meanSize.width - 700) < 1e-9)
        #expect(abs(trapezoid.meanSize.height - side) < 1e-9)
    }

    @Test func coverageOfTheFullFrameIsOne() {
        #expect(abs(rectangle(400, 300).coverage(width: 400, height: 300) - 1) < 1e-12)
        #expect(abs(rectangle(200, 150).coverage(width: 400, height: 300) - 0.25) < 1e-12)
        // The corners' order around the quad does not change its area's sign.
        let mirrored = quad((400, 0), (0, 0), (0, 300), (400, 300))
        #expect(abs(mirrored.coverage(width: 400, height: 300) - 1) < 1e-12)
    }

    @Test func rightAnglesHaveNoDeviation() {
        #expect(rectangle(400, 300).worstCornerDeviation < 1e-9)
        let turned = quad((100, 0), (200, 100), (100, 200), (0, 100))
        #expect(turned.worstCornerDeviation < 1e-9)
    }

    @Test func skewedCornerDeviationIsReported() {
        // The top-right corner pulled 100 px left over a 1000 px side: the corners there are 90° ± atan(0.1).
        let skewed = quad((0, 0), (900, 0), (1000, 1000), (0, 1000))
        let expected = atan(0.1) * 180 / .pi
        #expect(abs(skewed.worstCornerDeviation - expected) < 1e-9, "\(skewed.worstCornerDeviation)")
    }

    @Test func a4PhotoSnapsToTheSheet() {
        let size = StraightenRules.outputSize(for: rectangle(1000, 1380))
        #expect(size == (976, 1380), "\(size)")
        let wide = StraightenRules.outputSize(for: rectangle(1380, 1000))
        #expect(wide == (1380, 976), "\(wide)")
    }

    @Test func letterSnapsEitherWayUp() {
        #expect(StraightenRules.outputSize(for: rectangle(1100, 850)) == (1100, 850))
        #expect(StraightenRules.outputSize(for: rectangle(850, 1080)) == (835, 1080))
        // 1.5 is 6 % off A4 and 16 % off Letter: the page keeps its own shape.
        #expect(StraightenRules.outputSize(for: rectangle(1000, 1500)) == (1000, 1500))
    }

    @Test func outputSizeRoundsTheMeanSize() {
        // 700 x 806.2: a ratio of 1.15, near neither sheet.
        let trapezoid = quad((200, 0), (800, 0), (900, 800), (100, 800))
        #expect(StraightenRules.outputSize(for: trapezoid) == (700, 806))
    }

    @Test func verdicts() {
        let skewed = quad((60, 20), (950, 0), (1000, 1000), (0, 960))
        #expect(StraightenRules.verdict(confidence: 0.5, quad: skewed, imageWidth: 1000, imageHeight: 1000)
                == .noDocument)
        // 316 px square: 10 % of the picture.
        #expect(StraightenRules.verdict(confidence: 0.9, quad: rectangle(316, 316), imageWidth: 1000, imageHeight: 1000)
                == .noDocument)
        let nearlyWhole = quad((3, 2), (998, 2), (998, 997), (3, 997))
        #expect(StraightenRules.verdict(confidence: 0.9, quad: nearlyWhole, imageWidth: 1000, imageHeight: 1000)
                == .alreadyFlat)
        #expect(StraightenRules.verdict(confidence: 0.9, quad: skewed, imageWidth: 1000, imageHeight: 1000)
                == .straighten(skewed))
        #expect(StraightenRules.verdict(confidence: 0.6, quad: skewed, imageWidth: 1000, imageHeight: 1000)
                == .straighten(skewed))
        // The page fills the picture but its corners are not square: there is something to straighten.
        let fullButSkewed = quad((0, 0), (1000, 0), (1000, 1000), (20, 1000))
        #expect(StraightenRules.verdict(confidence: 0.9, quad: fullButSkewed, imageWidth: 1000, imageHeight: 1000)
                == .straighten(fullButSkewed))
    }

    @Test func cornersOutsideThePictureAreClamped() {
        let outside = quad((-3, -3), (1005, 60), (1005, 805), (-3, 700))
        let clamped = outside.clamped(width: 1000, height: 800)
        for corner in [clamped.topLeft, clamped.topRight, clamped.bottomRight, clamped.bottomLeft] {
            #expect((0...1000).contains(corner.x) && (0...800).contains(corner.y), "\(corner)")
        }
        #expect(clamped.topLeft == .zero && clamped.topRight == CGPoint(x: 1000, y: 60))

        let verdict = StraightenRules.verdict(confidence: 0.9, quad: outside, imageWidth: 1000, imageHeight: 800)
        guard case .straighten(let kept) = verdict else {
            Issue.record("\(verdict)")
            return
        }
        #expect(kept == clamped)
        let size = StraightenRules.outputSize(for: kept)
        #expect(size.width > 0 && size.height > 0)

        let broken = quad((.nan, 0), (1000, .infinity), (1000, 800), (0, 800)).clamped(width: 1000, height: 800)
        for corner in [broken.topLeft, broken.topRight, broken.bottomRight, broken.bottomLeft] {
            #expect(corner.x.isFinite && corner.y.isFinite, "\(corner)")
        }
    }

    @Test func aDegenerateQuadIsNoDocument() {
        let line = quad((0, 0), (1000, 0), (1000, 0), (0, 0))
        #expect(StraightenRules.verdict(confidence: 1, quad: line, imageWidth: 1000, imageHeight: 800) == .noDocument)
        #expect(StraightenRules.verdict(confidence: 1, quad: line, imageWidth: 0, imageHeight: 0) == .noDocument)
    }

    @Test func sentences() {
        #expect(StraightenRules.noDocumentReason == "No document found")
        #expect(StraightenRules.alreadyFlatReason == "It's already flat")
    }
}
