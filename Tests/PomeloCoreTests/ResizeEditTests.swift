import CoreGraphics
import Foundation
import Testing
@testable import PomeloCore

@Suite struct ResizeEditTests {
    private func size(_ spec: ResizeSpec, _ width: Int = 4032, _ height: Int = 3024) throws -> [Int] {
        let result = try ResizeEdit.size(.resize(spec), width: width, height: height)
        return [result.width, result.height]
    }

    private func reason(_ edit: EditSpec?, _ width: Int = 4032, _ height: Int = 3024) -> String? {
        do {
            _ = try ResizeEdit.size(edit, width: width, height: height)
            return nil
        } catch ConversionError.notApplicable(let reason) {
            return reason
        } catch {
            return "\(error)"
        }
    }

    @Test func eachModeKeepsOrFillsItsRule() throws {
        #expect(try size(.scale(percent: 50)) == [2016, 1512])
        #expect(try size(.width(1000)) == [1000, 750])
        #expect(try size(.height(1000)) == [1333, 1000])
        #expect(try size(.exact(width: 1080, height: 1080)) == [1080, 1080])
        #expect(try size(.scale(percent: 400), 100, 50) == [400, 200])
    }

    @Test func aSideIsNeverZero() throws {
        #expect(try size(.width(1)) == [1, 1])
        #expect(try size(.scale(percent: 1), 50, 20) == [1, 1])
    }

    @Test func exactKeepsTheCentredPartThatFillsTheBox() {
        #expect(ResizeEdit.keptRect(width: 4032, height: 3024, target: (1080, 1080)) == CGRect(x: 504, y: 0, width: 3024, height: 3024))
        #expect(ResizeEdit.keptRect(width: 3024, height: 4032, target: (1080, 1080)) == CGRect(x: 0, y: 504, width: 3024, height: 3024))
        #expect(ResizeEdit.keptRect(width: 400, height: 300, target: (200, 150)) == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(ResizeEdit.keptRect(width: 400, height: 300, target: (300, 100)) == CGRect(x: 0, y: 83, width: 400, height: 133))
    }

    @Test func outOfRangeResultsAreRefusedWithTheEditorsReasons() {
        #expect(reason(.resize(.width(16_385))) == "Between 1 and 16,384 pixels")
        #expect(reason(.resize(.width(0))) == "Between 1 and 16,384 pixels")
        #expect(reason(.resize(.height(-5))) == "Between 1 and 16,384 pixels")
        #expect(reason(.resize(.exact(width: 100, height: 16_385))) == "Between 1 and 16,384 pixels")
        #expect(reason(.resize(.scale(percent: 400)), 8000, 100) == "Between 1 and 16,384 pixels")
        #expect(reason(.resize(.scale(percent: 0.5))) == "Between 1 and 400 %")
        #expect(reason(.resize(.scale(percent: 401))) == "Between 1 and 400 %")
        #expect(reason(.resize(.scale(percent: .nan))) == "Between 1 and 400 %")
    }

    @Test func noEditOrAnotherEditIsChooseASize() {
        #expect(reason(nil) == "Choose a size")
        #expect(reason(.crop(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))) == "Choose a size")
    }

    @Test func theSourcesOwnSizeIsAlreadyThatSize() {
        #expect(reason(.resize(.scale(percent: 100))) == "It's already that size")
        #expect(reason(.resize(.width(4032))) == "It's already that size")
        #expect(reason(.resize(.exact(width: 4032, height: 3024))) == "It's already that size")
    }

    @Test func videoSizesRoundDownToEvenAndAtLeastSixteen() throws {
        func video(_ spec: ResizeSpec, _ width: Int = 1920, _ height: Int = 1080) throws -> [Int] {
            let result = try ResizeEdit.videoSize(.resize(spec), width: width, height: height)
            return [result.width, result.height]
        }
        #expect(try video(.width(721)) == [720, 404])
        #expect(try video(.exact(width: 10, height: 10)) == [16, 16])
        #expect(try video(.height(720)) == [1280, 720])
        #expect(try video(.scale(percent: 50)) == [960, 540])
        #expect(try video(.height(480)) == [852, 480])
        #expect(throws: ConversionError.notApplicable(reason: "Between 1 and 16,384 pixels")) {
            try video(.width(20_000))
        }
        #expect(throws: ConversionError.notApplicable(reason: "It's already that size")) {
            try video(.scale(percent: 100))
        }
        #expect(throws: ConversionError.notApplicable(reason: "Choose a size")) {
            try ResizeEdit.videoSize(nil, width: 1920, height: 1080)
        }
    }

    @Test func theNameSuffixIsTheSize() {
        #expect(ResizeEdit.nameSuffix(width: 1080, height: 1080) == "1080x1080")
    }
}
