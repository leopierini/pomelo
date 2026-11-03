import Foundation
import Testing
@testable import PomeloCore

@Suite struct CSVReaderTests {
    private func read(_ text: String) throws -> CSVReader.Table {
        try CSVReader.read(Data(text.utf8))
    }

    @Test func rfc4180Quotes() throws {
        let table = try read("a,\"b,c\",\"d\"\"e\"\r\n1,\"two\nlines\",3")
        #expect(table.rows == [["a", "b,c", "d\"e"], ["1", "two\nlines", "3"]])
        #expect(table.delimiter == ",")
    }

    @Test func aTrailingLineBreakAddsNoRow() throws {
        #expect(try read("a,b\n1,2\n").rows == [["a", "b"], ["1", "2"]])
        #expect(try read("a,b\r\n1,2\r\n").rows == [["a", "b"], ["1", "2"]])
        #expect(try read("a,b\r1,2").rows == [["a", "b"], ["1", "2"]])
    }

    @Test func aQuoteInsideAnUnquotedFieldIsLiteral() throws {
        #expect(try read("5\" pipe,x").rows == [["5\" pipe", "x"]])
    }

    @Test func utf8WithoutBOMIsNotWindows1252() throws {
        #expect(try CSVReader.read(Data("città,€\n".utf8)).rows == [["città", "€"]])
    }

    @Test func bomIsDropped() throws {
        let table = try CSVReader.read(Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n".utf8))
        #expect(table.rows == [["a", "b"]])
    }

    @Test func utf16WithBOM() throws {
        let text = "città;prezzo\n"
        let little = Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        let big = Data([0xFE, 0xFF]) + (text.data(using: .utf16BigEndian) ?? Data())
        #expect(try CSVReader.read(little).rows == [["città", "prezzo"]])
        #expect(try CSVReader.read(big).rows == [["città", "prezzo"]])
    }

    @Test func windows1252Fallback() throws {
        let table = try CSVReader.read(Data([0x63, 0x61, 0x66, 0x65, 0x2C, 0xE0, 0x0A]))
        #expect(table.rows == [["cafe", "à"]])
    }

    @Test func delimiterDetection() throws {
        #expect(try read("a;b;c\n1;2;3\n").delimiter == ";")
        #expect(try read("a\tb\tc\n1\t2\t3\n").delimiter == "\t")
        #expect(try read("a|b|c\n1|2|3\n").delimiter == "|")
        #expect(try read("a\nb\nc\n").delimiter == ",")
        #expect(try read("a,b;c\n1,2;3\n").delimiter == ",")
        #expect(try read("\"x,y,z\";\"b,c\"\n\"1,2,3\";\"d,e\"\n").delimiter == ";")
        #expect(try read("\"x,y,z\";\"b,c\"\n\"1,2,3\";\"d,e\"\n").rows == [["x,y,z", "b,c"], ["1,2,3", "d,e"]])
    }

    @Test func theDelimiterWithTheMostConsistentLinesWins() throws {
        #expect(try read("name;note\nAnn;hello, world\nBob;hi, there, you\n").delimiter == ";")
    }

    @Test func shortRowsArePadded() throws {
        #expect(try read("a,b,c\n1\n2,3\n").rows == [["a", "b", "c"], ["1", "", ""], ["2", "3", ""]])
    }

    @Test func emptyInputHasNoRows() throws {
        #expect(try CSVReader.read(Data()).rows.isEmpty)
    }

    @Test func decimalCommaOnlyWithSemicolons() {
        #expect(CSVReader.numberValue("1,5", decimalComma: true) == "1.5")
        #expect(CSVReader.numberValue("1,5", decimalComma: false) == nil)
        #expect(CSVReader.numberValue("007", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("-1,50", decimalComma: true) == "-1.50")
        #expect(CSVReader.numberValue("3.5", decimalComma: false) == "3.5")
        #expect(CSVReader.numberValue("12", decimalComma: true) == "12")
        #expect(CSVReader.numberValue("1,2,3", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("1.234,5", decimalComma: true) == "1234.5")
        #expect(CSVReader.numberValue("abc", decimalComma: true) == nil)
    }

    /// In a semicolon file a dot groups thousands, and only in that pattern; any other dot is ambiguous there and
    /// stays text, since text is never a wrong value (P209).
    @Test func aDotGroupsThousandsInASemicolonFile() {
        #expect(CSVReader.numberValue("1.234,56", decimalComma: true) == "1234.56")
        #expect(CSVReader.numberValue("-1.234.567,5", decimalComma: true) == "-1234567.5")
        #expect(CSVReader.numberValue("1.234.567", decimalComma: true) == "1234567")
        #expect(CSVReader.numberValue("1.500", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("2.50", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("1.23,5", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("1234.567,5", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("1.234,", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("-0,75", decimalComma: true) == "-0.75")
        #expect(CSVReader.numberValue("12", decimalComma: true) == "12")
        // P165 still applies once the dots are gone: no leading zero, at most 15 digits.
        #expect(CSVReader.numberValue("0.123,5", decimalComma: true) == nil)
        #expect(CSVReader.numberValue("999.999.999.999.999,9", decimalComma: true) == nil)
        // A comma file keeps the dot as its decimal point.
        #expect(CSVReader.numberValue("1.500", decimalComma: false) == "1.500")
        #expect(CSVReader.numberValue("1.234,56", decimalComma: false) == nil)
    }

    @Test func aSheetBeyondExcelsLimitsIsRefused() throws {
        let wide = String(repeating: ",", count: 16_384) + "x"
        #expect(throws: CSVReader.Failure.tooLarge) { try CSVReader.read(Data(wide.utf8)) }
    }

    @Test func moreRowsThanTheLimitAreRefused() throws {
        let data = Data("a,b\n1,2\n3,4\n".utf8)
        #expect(try CSVReader.read(data, maxRows: 3, maxColumns: 10, maxCells: 100).rows.count == 3)
        #expect(throws: CSVReader.Failure.tooLarge) { try CSVReader.read(data, maxRows: 2, maxColumns: 10, maxCells: 100) }
    }

    @Test func paddingIsCappedByTheCellCount() throws {
        let data = Data("a,b,c\n1\n2\n".utf8)
        #expect(try CSVReader.read(data, maxRows: 10, maxColumns: 10, maxCells: 9).rows.count == 3)
        #expect(throws: CSVReader.Failure.tooLarge) { try CSVReader.read(data, maxRows: 10, maxColumns: 10, maxCells: 8) }
    }

    @Test func aRaggedFileCannotAskForGigabytesOfPadding() throws {
        let wide = String(repeating: ",", count: CSVReader.maxColumns - 1) + "\n"
        let rows = String(repeating: "x\n", count: 700)
        #expect(throws: CSVReader.Failure.tooLarge) { try CSVReader.read(Data((wide + rows).utf8)) }
    }
}
