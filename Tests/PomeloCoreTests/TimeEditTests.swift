import Foundation
import Testing
@testable import PomeloCore

@Suite struct TimeEditTests {
    private func trim(_ start: Double, _ end: Double, duration: Double = 6) -> String? {
        TimeEdit.trimProblem(TimeRange(start: start, end: end), duration: duration)
    }

    @Test func aRangeInsideTheFileHasNoProblem() {
        #expect(trim(1, 4) == nil)
        #expect(trim(0, 5) == nil)
        #expect(trim(4, 6) == nil)
        #expect(trim(0.1, 6.04) == nil)
    }

    @Test func rangesOutsideTheFileAreRefused() {
        let outside = "The range is outside the file"
        #expect(trim(-0.1, 3) == outside)
        #expect(trim(3, 3) == outside)
        #expect(trim(4, 3) == outside)
        #expect(trim(1, 6.06) == outside)
        #expect(trim(1, 1.09) == outside)
        #expect(trim(.nan, 3) == outside)
        #expect(trim(1, .infinity) == outside)
    }

    /// P82: the end is clamped to the duration before the minimum length is checked.
    @Test func theMinimumLengthCountsFromTheClampedEnd() throws {
        let outside = "The range is outside the file"
        #expect(trim(5.95, 6.05) == outside)
        #expect(trim(5.9, 6.05) == nil)
        #expect(trim(9.95, 10.05, duration: 10) == outside)
        #expect(throws: ConversionError.notApplicable(reason: outside)) {
            try TimeEdit.trimRange(.trim(TimeRange(start: 9.95, end: 10.05)), duration: 10)
        }
    }

    @Test func theMinimumLengthIsAllowed() {
        #expect(trim(1, 1.1) == nil)
        #expect(trim(0.3, 0.4) == nil)
    }

    @Test func theWholeFileIsNothingToTrim() {
        #expect(trim(0, 6) == "Nothing to trim")
        #expect(trim(0.05, 5.95) == "Nothing to trim")
        #expect(trim(0, 6.05) == "Nothing to trim")
        #expect(trim(0.06, 6) == nil)
        #expect(trim(0, 5.94) == nil)
    }

    @Test func aTrimRangeEndingAHairPastTheDurationIsPulledBack() throws {
        let range = try TimeEdit.trimRange(.trim(TimeRange(start: 1, end: 6.04)), duration: 6)
        #expect(range == TimeRange(start: 1, end: 6))
    }

    @Test func theWrongOrNoEditIsNothingChosen() {
        for edit in [nil, EditSpec.split([1]), .crop(UnitRect(x: 0, y: 0, width: 1, height: 1))] {
            #expect(throws: ConversionError.notApplicable(reason: "Nothing was chosen")) {
                try TimeEdit.trimRange(edit, duration: 6)
            }
        }
        #expect(throws: ConversionError.notApplicable(reason: "Nothing was chosen")) {
            try TimeEdit.splitPoints(.trim(TimeRange(start: 1, end: 2)), duration: 6)
        }
    }

    @Test func splitPointsAreSortedAndThinned() {
        #expect(TimeEdit.usablePoints([4, 2], duration: 6) == [2, 4])
        #expect(TimeEdit.usablePoints([0.05, 2, 2.05, 5.97], duration: 6) == [2])
        #expect(TimeEdit.usablePoints([0.1, 5.9], duration: 6) == [0.1, 5.9])
        #expect(TimeEdit.usablePoints([2, 2.1, 2.2], duration: 6) == [2, 2.1, 2.2])
        #expect(TimeEdit.usablePoints([.nan, .infinity, 3], duration: 6) == [3])
    }

    @Test func noUsablePointIsNotApplicable() {
        #expect(throws: ConversionError.notApplicable(reason: "Add a split point first")) {
            try TimeEdit.splitPoints(.split([0.05, 5.95]), duration: 6)
        }
    }
}
