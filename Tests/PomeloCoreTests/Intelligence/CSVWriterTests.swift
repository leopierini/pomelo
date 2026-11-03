import Foundation
import Testing
@testable import PomeloCore

@Suite struct CSVWriterTests {
    private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    private func text(_ rows: [[String]]) -> String {
        let data = CSVWriter.write(rows: rows)
        #expect(Array(data.prefix(3)) == bom)
        return String(decoding: data.dropFirst(3), as: UTF8.self)
    }

    @Test func rowsAreCommaSeparatedWithCRLFAfterEach() {
        #expect(text([["a", "b"], ["c", "d"]]) == "a,b\r\nc,d\r\n")
    }

    @Test func noRowsGiveJustTheByteOrderMark() {
        #expect(Array(CSVWriter.write(rows: [])) == bom)
    }

    @Test func cellsWithCommasQuotesOrLineBreaksAreQuoted() {
        #expect(text([["a,b", "say \"hi\"", "two\nlines", "cr\rhere", "plain"]]) == "\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",\"cr\rhere\",plain\r\n")
    }

    @Test func aCellStartingWithAFormulaCharacterGetsALeadingApostrophe() {
        #expect(text([["=SUM(A1)", "+1", "-2+3", "@x", "\tTab", "\rCR"]]) == "'=SUM(A1),'+1,'-2+3,'@x,'\tTab,\"'\rCR\"\r\n")
        #expect(text([["=a,b"]]) == "\"'=a,b\"\r\n")
        #expect(text([["a=b", "x-y", "'quoted"]]) == "a=b,x-y,'quoted\r\n")
    }

    @Test func aPlainNumberKeepsItsSignAndNeedsNoApostrophe() {
        #expect(text([["-5.30", "-5", "-0.5", "-120"]]) == "-5.30,-5,-0.5,-120\r\n")
        #expect(text([["-2+3", "-", "-5.", "-.5", "-1,5", "-5 ", "--5", "-5e3", "+1", "=1", "@x"]])
            == "'-2+3,'-,'-5.,'-.5,\"'-1,5\",'-5 ,'--5,'-5e3,'+1,'=1,'@x\r\n")
    }

    @Test func raggedRowsArePaddedToTheWidestRow() {
        #expect(text([["a"], ["b", "c", "d"], []]) == "a,,\r\nb,c,d\r\n,,\r\n")
    }

    @Test func emptyCellsAndUnicodeSurvive() {
        let data = CSVWriter.write(rows: [["", "日本語", "🍊"], ["é", "", ""]])
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == ",日本語,🍊\r\né,,\r\n")
    }
}
