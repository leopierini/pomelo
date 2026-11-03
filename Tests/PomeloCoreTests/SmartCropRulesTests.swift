import CoreGraphics
import Foundation
import Testing
@testable import PomeloCore

@Suite struct SmartCropRulesTests {
    private func pixels(_ rect: UnitRect, _ width: Int, _ height: Int) -> CGRect {
        CGRect(x: rect.x * Double(width), y: rect.y * Double(height),
               width: rect.width * Double(width), height: rect.height * Double(height))
    }

    private func contains(_ outer: UnitRect, _ inner: UnitRect) -> Bool {
        let slack = 1e-9
        return outer.x <= inner.x + slack && outer.y <= inner.y + slack
            && outer.x + outer.width >= inner.x + inner.width - slack
            && outer.y + outer.height >= inner.y + inner.height - slack
    }

    @Test func shapeRatios() {
        #expect(SmartCropRules.longOverShort(of: "1:1") == 1)
        #expect(SmartCropRules.longOverShort(of: "4:5") == 1.25)
        #expect(SmartCropRules.longOverShort(of: "4:3") == 4.0 / 3)
        #expect(SmartCropRules.longOverShort(of: "16:9") == 16.0 / 9)
        #expect(SmartCropRules.longOverShort(of: nil) == nil)
        #expect(SmartCropRules.longOverShort(of: "9:16") == nil)
    }

    @Test func fitAddsSixPercentOfTheSubjectOnEachSide() throws {
        let rect = try #require(SmartCropRules.rect(
            subject: UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), shape: nil, imageWidth: 1000, imageHeight: 800))
        #expect(abs(rect.x - 0.388) < 1e-9 && abs(rect.y - 0.388) < 1e-9)
        #expect(abs(rect.width - 0.224) < 1e-9 && abs(rect.height - 0.224) < 1e-9)
    }

    @Test func fitIsClampedToThePicture() throws {
        let rect = try #require(SmartCropRules.rect(
            subject: UnitRect(x: 0, y: 0, width: 0.3, height: 0.3), shape: nil, imageWidth: 1000, imageHeight: 800))
        #expect(rect.x == 0 && rect.y == 0)
        #expect(abs(rect.width - 0.318) < 1e-9 && abs(rect.height - 0.318) < 1e-9)
    }

    @Test func subjectFillingThePictureIsNothingToCrop() {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> UnitRect? {
            SmartCropRules.rect(subject: UnitRect(x: x, y: y, width: w, height: h), shape: nil, imageWidth: 1000, imageHeight: 800)
        }
        #expect(rect(0, 0, 1, 1) == nil)
        #expect(rect(0.01, 0.01, 0.98, 0.98) == nil)
        #expect(rect(0, 0, 1, 0.5) != nil)
    }

    /// P271: Vision's box is a few percent off, so a crop that keeps most of the picture is not worth the risk of
    /// cutting into the subject, and running Smart crop on its own result must not shave it again.
    @Test func aCropThatKeepsMostOfThePictureIsNothingToCrop() {
        func rect(_ side: Double) -> UnitRect? {
            let origin = (1 - side) / 2
            return SmartCropRules.rect(
                subject: UnitRect(x: origin, y: origin, width: side, height: side), shape: nil, imageWidth: 1000, imageHeight: 800)
        }
        // With the margin these keep 0.8 and 0.7056 of the area (nothing to crop), then 0.687 (cropped).
        #expect(rect(0.8) == nil)
        #expect(rect(0.75) == nil)
        #expect(rect(0.74) != nil)
        #expect(rect(0.5) != nil)
    }

    @Test func runningItOnItsOwnResultCutsNothingMore() throws {
        let subject = UnitRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let first = try #require(SmartCropRules.rect(subject: subject, shape: nil, imageWidth: 1600, imageHeight: 1200))
        let (width, height) = (first.width * 1600, first.height * 1200)
        // The same subject inside the new picture, then the box Vision might give it: 10 % too small, off centre.
        let inside = UnitRect(
            x: (subject.x - first.x) / first.width, y: (subject.y - first.y) / first.height,
            width: subject.width / first.width, height: subject.height / first.height)
        let undershoot = UnitRect(
            x: inside.x + 0.05 * inside.width, y: inside.y, width: 0.9 * inside.width, height: 0.9 * inside.height)
        for box in [inside, undershoot] {
            #expect(SmartCropRules.rect(subject: box, shape: nil, imageWidth: Int(width), imageHeight: Int(height)) == nil)
        }
    }

    @Test func aShapeStillReshapesAPictureThatIsNotThatShape() throws {
        // A big subject in a 4:3 picture: the 16:9 band keeps 0.75 of the area, yet the picture changes shape.
        let subject = UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let rect = try #require(SmartCropRules.rect(subject: subject, shape: "16:9", imageWidth: 1200, imageHeight: 900))
        #expect(abs(rect.width * 1200 / (rect.height * 900) - 16.0 / 9) < 0.01)
    }

    @Test func aShapeThePictureAlreadyHasIsNothingToCrop() {
        let subject = UnitRect(x: 0.125, y: 0.125, width: 0.75, height: 0.75)
        #expect(SmartCropRules.rect(subject: subject, shape: "1:1", imageWidth: 1000, imageHeight: 1000) == nil)
        #expect(SmartCropRules.rect(subject: subject, shape: "1:1", imageWidth: 1000, imageHeight: 800) != nil)
    }

    @Test func squareShapeGrowsAboutTheCentre() throws {
        let subject = UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let rect = try #require(SmartCropRules.rect(subject: subject, shape: "1:1", imageWidth: 1000, imageHeight: 800))
        let box = pixels(rect, 1000, 800)
        #expect(abs(box.width - box.height) < 1e-6)
        // The subject is 200 x 160 px, so the margined one is 224 x 179.2 and the square takes its long side.
        #expect(abs(box.width - 224) < 1e-6)
        #expect(abs(box.midX - 500) < 1e-6 && abs(box.midY - 400) < 1e-6)
        #expect(contains(rect, UnitRect(x: 0.388, y: 0.388, width: 0.224, height: 0.224)))
    }

    @Test func orientationFollowsTheSubject() throws {
        let wide = UnitRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1)
        let wideRect = try #require(SmartCropRules.rect(subject: wide, shape: "4:5", imageWidth: 1000, imageHeight: 1000))
        let wideBox = pixels(wideRect, 1000, 1000)
        #expect(abs(wideBox.width / wideBox.height - 1.25) < 1e-6)
        let tall = UnitRect(x: 0.45, y: 0.2, width: 0.1, height: 0.5)
        let tallRect = try #require(SmartCropRules.rect(subject: tall, shape: "4:5", imageWidth: 1000, imageHeight: 1000))
        let tallBox = pixels(tallRect, 1000, 1000)
        #expect(abs(tallBox.width / tallBox.height - 0.8) < 1e-6)
        #expect(contains(wideRect, wide) && contains(tallRect, tall))
    }

    @Test func shapeIsShiftedBackInside() throws {
        let subject = UnitRect(x: 0.8, y: 0.42, width: 0.2, height: 0.15)
        let rect = try #require(SmartCropRules.rect(subject: subject, shape: "16:9", imageWidth: 1000, imageHeight: 800))
        let box = pixels(rect, 1000, 800)
        #expect(rect.x + rect.width <= 1 + 1e-9 && rect.x >= 0)
        #expect(abs(box.width - box.height * 16 / 9) <= 1)
        #expect(contains(rect, subject))
    }

    @Test func shapeLargerThanThePictureTakesTheLargestThatFits() throws {
        // A tall subject asks for a portrait 9:16 that is wider than the 300 px picture.
        let subject = UnitRect(x: 0.2, y: 0.1, width: 0.6, height: 0.5)
        let rect = try #require(SmartCropRules.rect(subject: subject, shape: "16:9", imageWidth: 300, imageHeight: 1200))
        let box = pixels(rect, 300, 1200)
        #expect(abs(box.width - 300) < 1e-6)
        #expect(abs(box.height - 300 * 16 / 9) <= 1)
        #expect(box.minY >= 0 && box.maxY <= 1200 + 1e-6)
        let subjectBox = pixels(subject, 300, 1200)
        #expect(abs(box.midY - subjectBox.midY) < 1e-6)
    }

    @Test func tinyResultsGrowToTheMinimumSide() throws {
        let subject = UnitRect(x: 0.5, y: 0.5, width: 0.004, height: 0.005)
        for shape in [nil, "1:1", "16:9"] as [String?] {
            let rect = try #require(SmartCropRules.rect(subject: subject, shape: shape, imageWidth: 1000, imageHeight: 800))
            let box = rect.pixels(width: 1000, height: 800)
            #expect(box.width >= CGFloat(CropEdit.minimumSide) && box.height >= CGFloat(CropEdit.minimumSide))
        }
    }

    @Test func shapeThatFillsThePictureIsNothingToCrop() {
        let subject = UnitRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        #expect(SmartCropRules.rect(subject: subject, shape: "1:1", imageWidth: 1000, imageHeight: 1000) == nil)
    }

    @Test func anEmptySubjectIsNoCrop() {
        let empty = [
            UnitRect(x: 0.5, y: 0.5, width: 0, height: 0),
            UnitRect(x: 0.5, y: 0.5, width: 0.2, height: 0),
            UnitRect(x: .nan, y: 0.5, width: 0.2, height: 0.2),
            UnitRect(x: 0.5, y: 0.5, width: .infinity, height: .nan),
            UnitRect(x: 2, y: 2, width: 0.2, height: 0.2),
        ]
        for subject in empty {
            for shape in [nil, "1:1", "16:9"] as [String?] {
                #expect(SmartCropRules.rect(subject: subject, shape: shape, imageWidth: 1000, imageHeight: 800) == nil)
            }
        }
    }
}
