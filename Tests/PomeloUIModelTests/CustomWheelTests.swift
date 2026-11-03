import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct CustomWheelTests {
    @Test func wheelKeyRoundTrips() {
        #expect(WheelKey(rawValue: "kind.image") == .kind(.image))
        #expect(WheelKey.kind(.image).rawValue == "kind.image")
        #expect(WheelKey.format(FormatID("png")).rawValue == "format.png")
        #expect(WheelKey(rawValue: "format.png") == .format(FormatID("png")))
        #expect(WheelKey(rawValue: "kind.banana") == nil)
        #expect(WheelKey(rawValue: "format.") == nil)
        #expect(WheelKey(rawValue: "png") == nil)
    }

    @Test func clampedNameTrimsFallsBackAndCuts() {
        #expect(CustomWheel.clampedName("  Mine  ", fallback: "Page 1") == "Mine")
        #expect(CustomWheel.clampedName("   ", fallback: "Page 2") == "Page 2")
        #expect(CustomWheel.clampedName(String(repeating: "a", count: 40), fallback: "Page 1").count == 20)
    }

    @Test func clampedNameTrimsAfterTheCut() {
        // 25 characters, the 20th a space: the cut must not keep it.
        #expect(CustomWheel.clampedName("Screenshots for Mac posts", fallback: "Page 1") == "Screenshots for Mac")
    }

    private func decode(_ json: String) throws -> CustomWheel {
        try JSONDecoder().decode(CustomWheel.self, from: Data(json.utf8))
    }

    @Test func aBadSlotDropsAloneNotThePage() throws {
        let wheel = try decode(#"{"pages":[{"name":"A","slots":["convert.jpg",5,{"x":1},"action.makeZip"]}]}"#)
        #expect(wheel.pages == [CustomPage(name: "A", slots: ["convert.jpg", "action.makeZip"])])
    }

    @Test func anUnreadablePageDoesNotCountTowardTheCap() throws {
        let wheel = try decode(#"{"pages":[5,{"name":"A","slots":["a"]},{"name":"B","slots":["b"]},"#
            + #"{"name":"C","slots":["c"]},{"name":"D","slots":["d"]},{"name":"E","slots":["e"]}]}"#)
        #expect(wheel.pages.map(\.name) == ["A", "B", "C", "D"])
    }

    @Test func anEmptySlotIDIsKept() throws {
        let wheel = try decode(#"{"pages":[{"name":"A","slots":["","action.makeZip"]}]}"#)
        #expect(wheel.pages.first?.slots == ["", "action.makeZip"])
    }

    @Test func slotCountSumsEveryPage() {
        let wheel = CustomWheel(pages: [CustomPage(name: "A", slots: ["x", "y"]), CustomPage(name: "B", slots: ["z"])])
        #expect(wheel.slotCount == 3)
        #expect(CustomWheel(pages: []).slotCount == 0)
    }

    @Test func everyCategoryHasAWheelTitle() {
        for category in FormatCategory.allCases { #expect(!category.wheelTitle.isEmpty) }
        #expect(FormatCategory.pdf.wheelTitle == "PDFs")
        #expect(FormatCategory.other.wheelTitle == "Other")
    }
}
