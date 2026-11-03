import Foundation
import Testing
@testable import PomeloCore

@Suite struct RecognizedDocumentTests {
    private typealias Block = RecognizedDocument.Block

    private func box(_ x: Double, _ y: Double, _ width: Double = 0.4, _ height: Double = 0.1) -> UnitRect {
        UnitRect(x: x, y: y, width: width, height: height)
    }

    private func markdown(_ blocks: [Block]) -> String {
        RecognizedDocument(pages: [blocks]).markdown()
    }

    @Test func paragraphsAreSeparatedByBlankLines() {
        #expect(markdown([Block(.paragraph("One"), box: box(0, 0)), Block(.paragraph("Two"), box: box(0, 0.2))]) == "One\n\nTwo")
    }

    @Test func blocksAreSortedTopToBottom() {
        let blocks = [
            Block(.paragraph("Third"), box: box(0, 0.6)),
            Block(.paragraph("First"), box: box(0, 0.0)),
            Block(.paragraph("Second"), box: box(0, 0.3)),
        ]
        #expect(markdown(blocks) == "First\n\nSecond\n\nThird")
    }

    @Test func blocksOverlappingVerticallyByOverHalfReadLeftToRight() {
        let blocks = [
            Block(.paragraph("Right"), box: box(0.5, 0.01)),
            Block(.paragraph("Left"), box: box(0.0, 0.03)),
            Block(.paragraph("Below"), box: box(0.0, 0.3)),
        ]
        #expect(markdown(blocks) == "Left\n\nRight\n\nBelow")
    }

    @Test func blocksOverlappingByLessThanHalfStayTopToBottom() {
        let blocks = [
            Block(.paragraph("Upper right"), box: box(0.5, 0.0, 0.4, 0.1)),
            Block(.paragraph("Lower left"), box: box(0.0, 0.08, 0.4, 0.1)),
        ]
        #expect(markdown(blocks) == "Upper right\n\nLower left")
    }

    @Test func aTallColumnIsReadBeforeTheBlocksBesideItWhenItIsOnTheLeft() {
        let blocks = [
            Block(.paragraph("Side top"), box: box(0.5, 0.0, 0.4, 0.2)),
            Block(.paragraph("Side bottom"), box: box(0.5, 0.5, 0.4, 0.2)),
            Block(.paragraph("Column"), box: box(0.0, 0.0, 0.4, 0.8)),
        ]
        #expect(markdown(blocks) == "Column\n\nSide top\n\nSide bottom")
    }

    @Test func aTableIsAPipeTableWithTheFirstRowAsHeader() {
        let table = Block(.table([["Name", "Age"], ["Ann", "30"], ["Bob", "25"]]), box: box(0, 0))
        #expect(markdown([table]) == "| Name | Age |\n| --- | --- |\n| Ann | 30 |\n| Bob | 25 |")
    }

    @Test func tableCellsEscapePipesAndTurnNewlinesIntoBreaks() {
        let table = Block(.table([["a|b", "x\ny"], ["c\r\nd", "e"]]), box: box(0, 0))
        #expect(markdown([table]) == "| a\\|b | x<br>y |\n| --- | --- |\n| c<br>d | e |")
    }

    @Test func aRaggedTableIsPaddedAndAHeaderOnlyTableStillHasItsSeparator() {
        #expect(markdown([Block(.table([["a", "b"], ["c"]]), box: box(0, 0))]) == "| a | b |\n| --- | --- |\n| c |  |")
        #expect(markdown([Block(.table([["only"]]), box: box(0, 0))]) == "| only |\n| --- |")
    }

    @Test func aListIsDashItems() {
        #expect(markdown([Block(.list(["one", "two\nlines", "three"]), box: box(0, 0))]) == "- one\n- two\n  lines\n- three")
    }

    @Test func pagesAreSeparatedByARule() {
        let document = RecognizedDocument(pages: [
            [Block(.paragraph("Page one"), box: box(0, 0))],
            [Block(.paragraph("Page two"), box: box(0, 0)), Block(.list(["x"]), box: box(0, 0.5))],
        ])
        #expect(document.markdown() == "Page one\n\n---\n\nPage two\n\n- x")
    }

    @Test func emptyBlocksAndPagesLeaveNoTrace() {
        let document = RecognizedDocument(pages: [
            [Block(.paragraph(""), box: box(0, 0)), Block(.list([]), box: box(0, 0.2)), Block(.table([]), box: box(0, 0.4))],
            [Block(.paragraph("Text"), box: box(0, 0))],
        ])
        #expect(document.markdown() == "Text")
        #expect(RecognizedDocument(pages: []).markdown() == "")
    }

    // MARK: Text and tables (document scan)

    @Test func hasTextIgnoresWhitespaceAndEmptyCells() {
        #expect(!RecognizedDocument(pages: []).hasText)
        let blank = [
            Block(.paragraph(" \n"), box: box(0, 0)), Block(.list(["", " "]), box: box(0, 0.2)),
            Block(.table([["", " "]]), box: box(0, 0.4)),
        ]
        #expect(!RecognizedDocument(pages: [blank]).hasText)
        #expect(RecognizedDocument(pages: [blank, [Block(.table([["", "x"]]), box: box(0, 0))]]).hasText)
        #expect(RecognizedDocument(pages: [[Block(.list(["", "a"]), box: box(0, 0))]]).hasText)
    }

    @Test func tablesComeInReadingOrderAcrossPagesWithTrimmedPaddedCells() {
        let lower = Block(.table([[" a ", "b"], ["c"]]), box: box(0, 0.5))
        let upper = Block(.table([["x"]]), box: box(0, 0.1))
        let empty = Block(.table([["", ""]]), box: box(0, 0.3))
        let second = Block(.table([["p", "q"]]), box: box(0, 0))
        let document = RecognizedDocument(pages: [[lower, Block(.paragraph("text"), box: box(0, 0.8)), empty, upper], [second]])
        #expect(document.tables().map(\.rows) == [[["x"]], [["a", "b"], ["c", ""]], [["p", "q"]]])
    }

    @Test func tablesCarryTheirMerges() {
        let merge = RecognizedDocument.TableMerge(row: 0, column: 1, rowSpan: 1, columnSpan: 2)
        let table = Block(.table([["a", "b", "", "c"]]), box: box(0, 0), merges: [merge])
        let plain = Block(.table([["x"]]), box: box(0, 0.5))
        #expect(RecognizedDocument(pages: [[table, plain]]).tables() == [
            .init(rows: [["a", "b", "", "c"]], merges: [merge]), .init(rows: [["x"]], merges: []),
        ])
    }
}
