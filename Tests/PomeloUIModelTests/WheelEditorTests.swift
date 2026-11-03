import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct WheelEditorTests {
    private func wheel(_ pages: [String]...) -> CustomWheel {
        CustomWheel(pages: pages.enumerated().map { CustomPage(name: "Page \($0.offset + 1)", slots: $0.element) })
    }

    private func editor(_ fallback: CustomWheel, key: WheelKey = .kind(.image)) -> WheelEditor {
        WheelEditor(key: key, settings: AppSettings(), fallback: fallback)
    }

    @Test func moveUsesInsertionIndex() {
        let start = wheel(["a", "b", "c", "d"])
        var e = editor(start)
        e.move(page: 0, from: 0, to: 3)
        #expect(e.wheel.pages[0].slots == ["b", "c", "a", "d"])
        e = editor(start)
        e.move(page: 0, from: 0, to: 4)
        #expect(e.wheel.pages[0].slots == ["b", "c", "d", "a"])
        e = editor(start)
        e.move(page: 0, from: 3, to: 0)
        #expect(e.wheel.pages[0].slots == ["d", "a", "b", "c"])
        e = editor(start)
        e.move(page: 0, from: 1, to: 1)
        e.move(page: 0, from: 1, to: 2)
        #expect(e.wheel == start)
        #expect(!e.isCustomized)
    }

    @Test func moveToAnotherPageAppends() {
        var e = editor(wheel(["a", "b"], ["c"]))
        #expect(e.move(page: 0, at: 0, toPage: 1) == nil)
        #expect(e.wheel.pages[0].slots == ["b"])
        #expect(e.wheel.pages[1].slots == ["c", "a"])
        #expect(e.isCustomized)

        var dup = editor(wheel(["a"], ["a", "x"]))
        #expect(dup.move(page: 0, at: 0, toPage: 1) == .alreadyOnPage)
        var full = editor(wheel(["a"], (0..<8).map { "s\($0)" }))
        #expect(full.move(page: 0, at: 0, toPage: 1) == .pageFull)
        #expect(!dup.isCustomized && !full.isCustomized)
    }

    @Test func refusalMessages() {
        #expect(WheelEditor.Refusal.lastSlot.message(for: .kind(.image))
            == "A wheel keeps at least one slot. Reset to default to go back to the built-in wheel.")
        #expect(WheelEditor.Refusal.lastSlot.message(for: .format(FormatID("png")))
            == "A wheel keeps at least one slot. Use the Images wheel to go back to it.")
        #expect(WheelEditor.Refusal.pageFull.message(for: .kind(.image)) == "This page already has 8 slots.")
        #expect(WheelEditor.Refusal.alreadyOnPage.message(for: .kind(.image)) == "It's already on this page.")
        #expect(WheelEditor.Refusal.lastPage.message(for: .kind(.image)) == "A wheel keeps at least one page.")
    }

    @Test func addRespectsCaps() {
        var e = editor(wheel((0..<8).map { "s\($0)" }, ["x"]))
        #expect(e.add("new", page: 0, at: 8) == .pageFull)
        #expect(e.add("s3", page: 0, at: 0) == .alreadyOnPage)
        #expect(!e.isCustomized)
        #expect(e.add("s3", page: 1, at: 0) == nil)
        #expect(e.wheel.pages[1].slots == ["s3", "x"])
        #expect(e.isCustomized)
    }

    @Test func replaceOnFullPage() {
        var e = editor(wheel((0..<8).map { "s\($0)" }))
        #expect(e.replace(page: 0, at: 3, with: "s5") == .alreadyOnPage)
        #expect(!e.isCustomized)
        #expect(e.replace(page: 0, at: 3, with: "new") == nil)
        #expect(e.wheel.pages[0].slots.count == 8)
        #expect(e.wheel.pages[0].slots[3] == "new")
    }

    @Test func removeRefusesLastSlot() {
        var e = editor(wheel(["a"], []))
        #expect(e.remove(page: 0, at: 0) == .lastSlot)
        #expect(e.wheel == wheel(["a"], []))
        #expect(!e.isCustomized)

        var two = editor(wheel(["a"], ["b"]))
        #expect(two.remove(page: 0, at: 0) == nil)
        #expect(two.wheel.pages.count == 2)
        #expect(two.wheel.pages[0].slots.isEmpty)
        #expect(two.isCustomized)
    }

    @Test func pages() {
        var e = editor(wheel(["a"]))
        #expect(e.addPage() == 1)
        #expect(e.addPage() == 2)
        #expect(e.addPage() == 3)
        #expect(e.addPage() == nil)
        #expect(e.wheel.pages.map(\.name) == ["Page 1", "Page 2", "Page 3", "Page 4"])

        e.renamePage(0, to: "  Mine  ")
        #expect(e.wheel.pages[0].name == "Mine")
        e.renamePage(0, to: "")
        #expect(e.wheel.pages[0].name == "Mine")
        e.renamePage(0, to: String(repeating: "x", count: 30))
        #expect(e.wheel.pages[0].name == String(repeating: "x", count: 20))

        #expect(e.deletePage(0) == .lastSlot)
        e.add("b", page: 2, at: 0)
        #expect(e.deletePage(1) == nil)
        #expect(e.wheel.pages.map(\.name) == [String(repeating: "x", count: 20), "Page 3", "Page 4"])

        e.movePage(from: 2, to: 0)
        #expect(e.wheel.pages.map(\.name) == ["Page 4", String(repeating: "x", count: 20), "Page 3"])

        var only = editor(wheel(["a"]))
        #expect(only.deletePage(0) == .lastPage)
    }

    @Test func lookingCreatesNothing() {
        var settings = AppSettings()
        var e = WheelEditor(key: .kind(.pdf), settings: settings, fallback: wheel(["a", "b"]))
        e.save(into: &settings)
        #expect(settings.wheels.isEmpty)
        e.remove(page: 0, at: 5)
        e.renamePage(0, to: "Page 1")
        e.add("a", page: 0, at: 0)
        #expect(!e.isCustomized)

        e.add("c", page: 0, at: 2)
        e.save(into: &settings)
        #expect(settings.wheels["kind.pdf"] == e.wheel)

        let reopened = WheelEditor(key: .kind(.pdf), settings: settings, fallback: wheel(["z"]))
        #expect(reopened.isCustomized)
        #expect(reopened.wheel == e.wheel)
    }

    @Test func resetClearsOldSettings() {
        var settings = AppSettings()
        settings.wheels["kind.image"] = wheel(["a"])
        settings.wheels["format.png"] = wheel(["b"])
        settings.wheelOrder = ["image": ["x"], "video": ["y"]]
        settings.toolVisibility = ["image": ["t": false], "video": ["t": false]]

        WheelEditor.reset(.format(FormatID("png")), in: &settings)
        #expect(settings.wheels["format.png"] == nil)
        #expect(settings.wheels["kind.image"] != nil)
        #expect(settings.wheelOrder["image"] != nil)

        WheelEditor.reset(.kind(.image), in: &settings)
        #expect(settings.wheels["kind.image"] == nil)
        #expect(settings.wheelOrder["image"] == nil)
        #expect(settings.toolVisibility["image"] == nil)
        #expect(settings.wheelOrder["video"] == ["y"])
        #expect(settings.toolVisibility["video"] != nil)
    }
}
