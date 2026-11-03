import Foundation
import Testing
@testable import PomeloCore

@Suite struct ExtractedDataTests {
    private typealias Item = ExtractedData.LineItem

    private let receipt = """
        COOP ZURICH
        Bahnhofstrasse 12
        12.10.2026
        Bread 3.50
        Milk 1.80
        VAT 2.6% 0.14
        TOTAL CHF 5.30
        """

    private func full() -> ExtractedData {
        ExtractedData(
            kind: "receipt", issuer: "Coop Zurich", date: "12.10.2026", total: 5.3, currency: "CHF", tax: 0.14,
            lineItems: [Item(name: "Bread", quantity: nil, amount: 3.5), Item(name: "Milk", quantity: nil, amount: 1.8)]
        )
    }

    // MARK: Grounding

    @Test func everythingPrintedIsKeptWithTheDateInISO() {
        var expected = full()
        expected.date = "2026-10-12"
        #expect(full().grounded(in: receipt) == expected)
    }

    @Test func numbersAreFoundWhicheverDecimalSeparatorAndThousandsTheTextUses() {
        let text = "Totale 1.234,50 EUR\nIVA 0,61\nSubtotal 2,000.75\nQty 3"
        let data = ExtractedData(total: 1234.5, currency: "EUR", tax: 0.61, lineItems: [Item(name: "Subtotal", quantity: 3, amount: 2000.75)])
        #expect(data.grounded(in: text) == data)
        #expect(ExtractedData(total: -5.3).grounded(in: "Refund -5,30").total == -5.3)
    }

    @Test func spacesGroupThousandsBeforeThreeDigits() {
        for space in [" ", "\u{00A0}", "\u{202F}"] {
            let data = ExtractedData(total: 1234.5, currency: "EUR", tax: 205.75)
            #expect(data.grounded(in: "TOTAL TTC 1\(space)234,50 €\nTVA 205,75") == data, "\(space.unicodeScalars.first!.value)")
            let kronor = ExtractedData(total: 1234.5, currency: "SEK")
            #expect(kronor.grounded(in: "Totalt 1\(space)234,50 SEK") == kronor)
            #expect(ExtractedData(total: 1_234_567).grounded(in: "1\(space)234\(space)567").total == 1_234_567)
        }
        // Two numbers side by side stay two numbers, and the pieces of a grouped one still count.
        let line = ExtractedData(lineItems: [Item(name: "Bread", quantity: 2, amount: 3.5)])
        #expect(line.grounded(in: "Bread 2 3.50") == line)
        #expect(ExtractedData(total: 2).grounded(in: "Qty 2 350").total == 2)
        #expect(ExtractedData(total: 12_345).grounded(in: "1 2345").total == nil)
    }

    @Test func aValueThatIsNotPrintedIsLeftOut() {
        let invented = ExtractedData(
            kind: "receipt", issuer: "Migros", date: "2025-01-01", total: 9.99, currency: "USD", tax: 0.5,
            lineItems: [Item(name: "Butter", quantity: nil, amount: 2.2)]
        )
        #expect(invented.grounded(in: receipt) == ExtractedData(kind: "receipt"))
    }

    @Test func aLineItemKeepsOnlyItsPrintedPartsAndGoesWhenNothingButItsNameIsLeft() {
        let data = ExtractedData(lineItems: [
            Item(name: "Bread", quantity: 7, amount: 3.5), Item(name: "Milk", quantity: nil, amount: 0),
            Item(name: "Respond", quantity: nil, amount: 1.8),
        ])
        #expect(data.grounded(in: receipt).lineItems == [Item(name: "Bread", quantity: nil, amount: 3.5)])
        #expect(ExtractedData(lineItems: [Item(name: "Milk", quantity: nil, amount: 0)]).grounded(in: receipt).lineItems == nil)
    }

    @Test func namesMatchIgnoringCaseAccentsAndSpacing() {
        let text = "CAFÉ  DE\nLA GARE\nCroissant 2.10"
        #expect(ExtractedData(issuer: "Cafe de la Gare").grounded(in: text).issuer == "Cafe de la Gare")
        #expect(ExtractedData(issuer: "  ").grounded(in: text).issuer == nil)
    }

    @Test func aPrintedDateIsReadAsISOWithDotsAndDashesDayFirst() {
        func date(_ printed: String, in text: String? = nil, currency: String? = nil) -> String? {
            ExtractedData(date: printed, currency: currency).grounded(in: (text ?? printed) + " $").date
        }
        #expect(date("12.10.2026") == "2026-10-12")
        #expect(date("12-10-26") == "2026-10-12")
        #expect(date("03/11/2026", in: "03/11/2026 EUR", currency: "EUR") == "2026-11-03")
        #expect(date("10/12/2026", currency: "USD") == "2026-10-12")
        #expect(date("10/13/2026") == "2026-10-13")
        #expect(date("13/10/2026", currency: "USD") == "2026-10-13")
        #expect(date("2026-10-12") == "2026-10-12")
        #expect(date("2026年10月12日") == "2026-10-12")
        #expect(date("10/12/2026 14:22", in: "Date: 10/12/2026 14:22", currency: "USD") == "2026-10-12")
    }

    /// 10/12/2026 is October in America and December elsewhere: without a currency to tell, it is left out.
    @Test func aSlashedDateNoCurrencySettlesIsLeftOut() {
        let walmart = "WALMART\n10/12/2026\nTOTAL $5.16"
        #expect(ExtractedData(date: "10/12/2026", total: 5.16).grounded(in: walmart) == ExtractedData(total: 5.16))
        #expect(ExtractedData(date: "10/12/2026", currency: "CAD").grounded(in: walmart + " CAD").date == nil)
        #expect(ExtractedData(date: "10/12/2026", currency: "USD").grounded(in: walmart).date == "2026-10-12")
        #expect(ExtractedData(date: "10/12/2026", currency: "EUR").grounded(in: walmart + " €").date == "2026-12-10")
        #expect(ExtractedData(date: "12.10.2026").grounded(in: "12.10.2026").date == "2026-10-12")
    }

    @Test func aPrintedDateWithAMonthNameIsReadInTheModelsLanguages() {
        func date(_ printed: String) -> String? { ExtractedData(date: printed).grounded(in: printed).date }
        #expect(date("3 novembre 2026") == "2026-11-03")
        #expect(date("Oct 12, 26") == "2026-10-12")
        #expect(date("12. Oktober 2026") == "2026-10-12")
        #expect(date("1er février 2026") == "2026-02-01")
        #expect(date("12 de octubre de 2026") == "2026-10-12")
    }

    @Test func aDateThatIsNotPrintedOrNotADayIsLeftOut() {
        #expect(ExtractedData(date: "2026-10-12").grounded(in: "12.10.2026").date == nil)
        #expect(ExtractedData(date: "12.10.2026").grounded(in: "13.10.2026").date == nil)
        #expect(ExtractedData(date: "30.02.2026").grounded(in: "30.02.2026").date == nil)
        #expect(ExtractedData(date: "next week").grounded(in: "see you next week").date == nil)
        #expect(ExtractedData(date: "14:22").grounded(in: "14:22").date == nil)
        #expect(ExtractedData(date: " ").grounded(in: "x").date == nil)
    }

    @Test func aCurrencyNeedsItsCodeOrASignOfItPrinted() {
        #expect(ExtractedData(currency: "eur").grounded(in: "TOTALE EURO 6,75").currency == "EUR")
        #expect(ExtractedData(currency: "EUR").grounded(in: "Total 6,75 €").currency == "EUR")
        #expect(ExtractedData(currency: "USD").grounded(in: "TOTAL $5.16").currency == "USD")
        #expect(ExtractedData(currency: "GBP").grounded(in: "TOTAL $5.16").currency == nil)
        #expect(ExtractedData(currency: "USD").grounded(in: "TOTAL 5.30").currency == nil)
        #expect(ExtractedData(currency: "EUR").grounded(in: "NEUROLOGY 5.30").currency == nil)
        #expect(ExtractedData(currency: "Swiss francs").grounded(in: "Swiss francs 5").currency == nil)
    }

    @Test func theKindIsAOneLineWordNotAParagraph() {
        #expect(ExtractedData(kind: " invoice ").grounded(in: "").kind == "invoice")
        #expect(ExtractedData(kind: "a\nb").grounded(in: "").kind == "a b")
        #expect(ExtractedData(kind: String(repeating: "x", count: 81)).grounded(in: "").kind == nil)
    }

    @Test func onlyTheKindLeftCountsAsNoData() {
        #expect(ExtractedData(kind: "receipt").hasData == false)
        #expect(ExtractedData(kind: "receipt", total: 1).hasData)
        #expect(ExtractedData(lineItems: [Item(name: "a", quantity: 1, amount: nil)]).hasData)
    }

    // MARK: Writing

    @Test func jsonHasSortedKeysAndLeavesOutWhatIsMissing() throws {
        let data = ExtractedData(kind: "receipt", total: 5.3, lineItems: [Item(name: "Bread", quantity: nil, amount: 3.5)])
        let json = String(decoding: try data.json(), as: UTF8.self)
        #expect(json == """
            {
              "kind" : "receipt",
              "lineItems" : [
                {
                  "amount" : 3.5,
                  "name" : "Bread"
                }
              ],
              "total" : 5.3
            }

            """)
        let parsed = try #require(try JSONSerialization.jsonObject(with: try full().json()) as? [String: Any])
        #expect(Set(parsed.keys) == ["kind", "issuer", "date", "total", "currency", "tax", "lineItems"])
    }

    @Test func csvIsOneHeaderAndOneRowWithoutTheLineItems() {
        let csv = String(decoding: full().grounded(in: receipt).csv().dropFirst(3), as: UTF8.self)
        #expect(csv == "kind,issuer,date,total,currency,tax\r\nreceipt,Coop Zurich,2026-10-12,5.3,CHF,0.14\r\n")
        let sparse = String(decoding: ExtractedData(issuer: "=cmd", total: -5).csv().dropFirst(3), as: UTF8.self)
        #expect(sparse == "kind,issuer,date,total,currency,tax\r\n,'=cmd,,-5,,\r\n")
    }
}
