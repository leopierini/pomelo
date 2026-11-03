import CoreGraphics
import Foundation
import Testing
@testable import PomeloCore

@Suite struct RotateEditTests {
    private let allStates: [RotateSpec] = (0..<4).flatMap { turns in
        [false, true].map { RotateSpec(quarterTurns: turns, flipHorizontal: $0) }
    }

    @Test func fourTurnsRightComeBackToTheStart() {
        var spec = RotateSpec.identity
        for _ in 0..<4 { spec = spec.rotatedRight() }
        #expect(spec == .identity && spec.isIdentity)
        #expect(RotateSpec.identity.rotatedLeft().quarterTurns == 3)
        #expect(RotateSpec.identity.rotatedRight().quarterTurns == 1)
    }

    @Test func flippingVerticallyIsTwoTurnsAndAFlip() {
        #expect(RotateSpec.identity.flippedVertically() == RotateSpec(quarterTurns: 2, flipHorizontal: true))
        #expect(RotateSpec.identity.flippedHorizontally() == RotateSpec(quarterTurns: 0, flipHorizontal: true))
        for spec in allStates {
            #expect(spec.flippedHorizontally().flippedHorizontally() == spec)
            #expect(spec.flippedVertically().flippedVertically() == spec)
        }
    }

    @Test func quarterTurnsAreNormalised() {
        #expect(RotateSpec(quarterTurns: 5, flipHorizontal: false).quarterTurns == 1)
        #expect(RotateSpec(quarterTurns: -1, flipHorizontal: false).quarterTurns == 3)
        var spec = RotateSpec.identity
        spec.quarterTurns = 6
        #expect(spec.quarterTurns == 2)
        #expect(RotateSpec(quarterTurns: 4, flipHorizontal: false).isIdentity)
        #expect(!RotateSpec(quarterTurns: 0, flipHorizontal: true).isIdentity)
    }

    @Test func oddTurnsSwapTheSides() {
        #expect(RotateSpec(quarterTurns: 1, flipHorizontal: false).outputSize(width: 4, height: 2) == (2, 4))
        #expect(RotateSpec(quarterTurns: 3, flipHorizontal: true).outputSize(width: 4, height: 2) == (2, 4))
        #expect(RotateSpec(quarterTurns: 2, flipHorizontal: false).outputSize(width: 4, height: 2) == (4, 2))
        #expect(RotateSpec(quarterTurns: 0, flipHorizontal: true).outputSize(width: 4, height: 2) == (4, 2))
    }

    /// Top-left origin, y down, in pixels: a pixel's centre is at (x + 0.5, y + 0.5).
    @Test func theTransformMovesTheTopLeftPixelWhereTheEditSays() {
        let topLeft = CGPoint(x: 0.5, y: 0.5)
        let turned = RotateSpec(quarterTurns: 1, flipHorizontal: false).transform(width: 4, height: 2)
        #expect(topLeft.applying(turned) == CGPoint(x: 1.5, y: 0.5))
        let flipped = RotateSpec(quarterTurns: 0, flipHorizontal: true).transform(width: 4, height: 2)
        #expect(topLeft.applying(flipped) == CGPoint(x: 3.5, y: 0.5))
        let left = RotateSpec(quarterTurns: 3, flipHorizontal: false).transform(width: 4, height: 2)
        #expect(topLeft.applying(left) == CGPoint(x: 0.5, y: 3.5))
        let half = RotateSpec(quarterTurns: 2, flipHorizontal: false).transform(width: 4, height: 2)
        #expect(topLeft.applying(half) == CGPoint(x: 3.5, y: 1.5))
        #expect(RotateSpec.identity.transform(width: 4, height: 2) == .identity)
    }

    @Test func everyTransformFillsExactlyItsOutputSize() {
        for spec in allStates {
            let output = spec.outputSize(width: 4, height: 2)
            let corners = CGRect(x: 0, y: 0, width: 4, height: 2).applying(spec.transform(width: 4, height: 2))
            #expect(corners == CGRect(x: 0, y: 0, width: output.width, height: output.height), "\(spec)")
        }
    }

    /// Every button acts on the picture the preview shows, whatever the stored turns and flip are.
    @Test func eachButtonActsOnTheShownResult() {
        let size = (width: 4, height: 2)
        func shown(_ spec: RotateSpec) -> CGAffineTransform { spec.transform(width: size.width, height: size.height) }
        for spec in allStates {
            let output = spec.outputSize(width: size.width, height: size.height)
            let right = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(output.height), ty: 0)
            let left = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(output.width))
            let horizontal = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(output.width), ty: 0)
            let vertical = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(output.height))
            #expect(shown(spec.rotatedRight()) == shown(spec).concatenating(right), "right \(spec)")
            #expect(shown(spec.rotatedLeft()) == shown(spec).concatenating(left), "left \(spec)")
            #expect(shown(spec.flippedHorizontally()) == shown(spec).concatenating(horizontal), "flip h \(spec)")
            #expect(shown(spec.flippedVertically()) == shown(spec).concatenating(vertical), "flip v \(spec)")
        }
    }

    @Test func theSpecOfAnEditIsRefusedWhenThereIsNothingToRotate() throws {
        let spec = RotateSpec(quarterTurns: 1, flipHorizontal: true)
        #expect(try RotateEdit.spec(.rotate(spec)) == spec)
        for edit in [nil, .rotate(.identity), .crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))] as [EditSpec?] {
            #expect(throws: ConversionError.notApplicable(reason: "Nothing to rotate")) { try RotateEdit.spec(edit) }
        }
    }
}
