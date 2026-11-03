import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

/// A builder where the image formats convert to each other and every tool runs on them, as the real engines offer.
private func imageBuilder(settings: AppSettings = AppSettings()) -> WheelContentBuilder {
    let images = ["png", "jpg", "heic", "webp"]
    let presets = ToolCatalog.presets(settings: settings)
    var edges: [ConversionEdge] = []
    for source in images {
        for target in images where target != source {
            edges.append(ConversionEdge(from: FormatID(source), to: FormatID(target), engineID: "x", cost: 1, flags: []))
        }
        for preset in presets where preset.categories?.contains(.image) ?? true {
            edges.append(ConversionEdge(from: FormatID(source), to: preset.target ?? FormatID(source), engineID: "x",
                                        cost: 1, flags: [], operation: preset.operation))
        }
    }
    let planner = RoutePlanner(edges: edges, enginePriority: ["x"])
    return WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:], tools: presets)
}

@MainActor
@Suite struct WheelEditorPaneTests {
    private func model(_ store: SettingsStore, undo: UndoManager? = nil) -> WheelEditorPaneModel {
        WheelEditorPaneModel(store: store, builder: imageBuilder(), undoManager: undo)
    }

    /// A chip of the selected wheel that isn't on its current page.
    private func freshChip(_ model: WheelEditorPaneModel) -> String {
        let onPage = Set(model.currentPage?.slices.map(\.id) ?? [])
        let all = model.candidates.convert + model.candidates.tools + model.candidates.fileTools
        return all.first { !onPage.contains($0.id) }!.id
    }

    @Test func selectingFormatFollowsKind() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        #expect(model.selection == .kind(.image))
        #expect(!model.isFormatFollowingKind)
        model.addPage()
        let kindWheel = store.settings.wheels["kind.image"]
        #expect(kindWheel != nil)

        model.select(.format("png"))
        #expect(model.isFormatFollowingKind)
        #expect(model.editor.wheel == kindWheel)
        #expect(store.settings.wheels["format.png"] == nil)
        #expect(!model.customized.contains(.format("png")))

        model.customizeFormat()
        #expect(!model.isFormatFollowingKind)
        #expect(store.settings.wheels["format.png"] == kindWheel)
        #expect(model.customized == [.kind(.image), .format("png")])
    }

    @Test func aFormatFollowingItsKindTakesNoEdits() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        model.select(.format("png"))
        model.add(freshChip(model))
        model.addPage()
        #expect(store.settings.wheels.isEmpty)
    }

    @Test func editWritesAndUndoes() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = model(store, undo: undo)
        let chip = freshChip(model)

        undo.beginUndoGrouping()
        model.add(chip)
        undo.endUndoGrouping()
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots.last == chip)
        #expect(model.customized == [.kind(.image)])

        undo.undo()
        #expect(store.settings.wheels == [:])
        #expect(model.customized.isEmpty)
        #expect(model.currentPage?.slices.map(\.id).contains(chip) == false)

        undo.redo()
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots.last == chip)
        #expect(model.currentPage?.slices.last?.id == chip)
    }

    /// Undoing an edit of another wheel brings that wheel back on screen, on the page it was edited on.
    @Test func undoSelectsTheWheelItChanges() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = model(store, undo: undo)
        model.selectPage(1)
        undo.beginUndoGrouping()
        model.remove(at: 0)
        undo.endUndoGrouping()
        model.select(.kind(.video))

        undo.undo()
        #expect(model.selection == .kind(.image))
        #expect(model.pageIndex == 1)
        #expect(store.settings.wheels.isEmpty)
    }

    @Test func resetKindConfirmsAndClears() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        store.settings.wheelOrder["image"] = ["heic", "jpg"]
        store.settings.toolVisibility["image"] = ["snapshot": true]
        let model = model(store)
        #expect(model.canReset)
        model.add(freshChip(model))
        #expect(store.settings.wheels["kind.image"] != nil)

        model.reset()
        #expect(store.settings.wheels["kind.image"] == nil)
        #expect(store.settings.wheelOrder["image"] == nil)
        #expect(store.settings.toolVisibility["image"] == nil)
        #expect(model.customized.isEmpty)
        #expect(!model.canReset)
    }

    @Test func resettingAFormatGoesBackToItsKind() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        store.settings.wheelOrder["image"] = ["heic"]
        let model = model(store)
        model.select(.format("png"))
        model.customizeFormat()
        model.reset()
        #expect(model.isFormatFollowingKind)
        #expect(store.settings.wheels.isEmpty)
        #expect(store.settings.wheelOrder["image"] == ["heic"])
    }

    @Test func refusalShowsMessage() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let one = CustomWheel(pages: [CustomPage(name: "Mine", slots: ["convert.jpg"])])
        store.settings.wheels["kind.image"] = one
        let model = model(store)
        model.remove(at: 0)
        #expect(model.message == WheelEditor.Refusal.lastSlot.message(for: model.selection))
        #expect(store.settings.wheels["kind.image"] == one)
        #expect(model.editor.wheel == one)
    }

    @Test func pagesFollowTheirEdits() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let count = model.pages.count
        model.addPage()
        #expect(model.pages.count == count + 1)
        #expect(model.pageIndex == count)
        #expect(model.currentPage?.title == "Page \(count + 1)")
        #expect(model.hubCount == "0 of 8")

        model.renamePage(model.pageIndex, to: "  Mine  ")
        #expect(model.currentPage?.title == "Mine")
        model.movePage(from: model.pageIndex, to: 0)
        #expect(model.pageIndex == 0)
        #expect(model.pages[0].title == "Mine")
        model.deletePage(0)
        #expect(model.pages.count == count)
        #expect(model.pageIndex == 0)
    }

    /// Pages A, B, C with C shown: deleting A keeps C on screen.
    @Test func deletingAnEarlierPageKeepsTheShownOne() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let three = CustomWheel(pages: [CustomPage(name: "A", slots: ["convert.jpg"]),
                                        CustomPage(name: "B", slots: ["convert.png"]),
                                        CustomPage(name: "C", slots: ["convert.heic"])])
        store.settings.wheels["kind.image"] = three
        let model = model(store)
        model.selectPage(2)
        model.deletePage(0)
        #expect(model.pages.map(\.title) == ["B", "C"])
        #expect(model.currentPage?.title == "C")
    }

    /// Deleting the shown page shows its neighbour: the next one, or the one before when it was the last.
    @Test func deletingTheShownPageShowsItsNeighbour() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        store.settings.wheels["kind.image"] = CustomWheel(pages: [
            CustomPage(name: "A", slots: ["convert.jpg"]), CustomPage(name: "B", slots: ["convert.png"]),
            CustomPage(name: "C", slots: ["convert.heic"]),
        ])
        let model = model(store)
        model.selectPage(1)
        model.deletePage(1)
        #expect(model.currentPage?.title == "C")
        model.deletePage(1)
        #expect(model.currentPage?.title == "A")
    }

    @Test func undoingAResetBringsBackTheOldOrderAndSwitches() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.settings.wheelOrder["image"] = ["heic", "jpg"]
        store.settings.toolVisibility["image"] = ["snapshot": true]
        let model = model(store, undo: undo)
        undo.beginUndoGrouping()
        model.add(freshChip(model))
        undo.endUndoGrouping()
        let wheel = store.settings.wheels["kind.image"]

        undo.beginUndoGrouping()
        model.reset()
        undo.endUndoGrouping()
        undo.undo()
        #expect(store.settings.wheels["kind.image"] == wheel)
        #expect(store.settings.wheelOrder["image"] == ["heic", "jpg"])
        #expect(store.settings.toolVisibility["image"] == ["snapshot": true])
        #expect(model.customized == [.kind(.image)])
    }

    @Test func undoingCustomizeFollowsTheKindAgain() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = model(store, undo: undo)
        model.select(.format("png"))
        undo.beginUndoGrouping()
        model.customizeFormat()
        undo.endUndoGrouping()
        #expect(store.settings.wheels["format.png"] != nil)

        undo.undo()
        #expect(model.selection == .format("png"))
        #expect(model.isFormatFollowingKind)
        #expect(store.settings.wheels.isEmpty)
    }

    /// Redo shows the page the edit showed, as the edit did: a new page comes back on screen.
    @Test func redoingANewPageShowsIt() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = model(store, undo: undo)
        let count = model.pages.count
        undo.beginUndoGrouping()
        model.addPage()
        undo.endUndoGrouping()
        undo.undo()
        #expect(model.pageIndex == 0)
        undo.redo()
        #expect(model.pages.count == count + 1)
        #expect(model.pageIndex == count)
        undo.undo()
        #expect(model.pageIndex == 0)
    }

    /// A customized wheel keeps at least one slot: a wheel left without one is never saved, nor copied to a format.
    @Test func aWheelWithoutSlotsIsNeverSaved() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let empty = CustomWheel(pages: [CustomPage(name: "Page 1", slots: [])])
        store.settings.wheels["kind.image"] = empty
        let model = model(store)
        model.addPage()
        model.renamePage(0, to: "Mine")
        #expect(store.settings.wheels["kind.image"] == empty)
        model.select(.format("png"))
        model.customizeFormat()
        #expect(store.settings.wheels["format.png"] == nil)
        #expect(model.isFormatFollowingKind)

        model.select(.kind(.image))
        model.add("convert.jpg")
        #expect(store.settings.wheels["kind.image"]?.slotCount == 1)
    }

    @Test func movingASlotKeepsThePageShown() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let first = model.currentPage!.slices[0].id
        model.move(from: 0, to: 2)
        #expect(model.currentPage?.slices[1].id == first)
        // The image Tools page is full (8, P194), so the slot goes to the AI page.
        #expect(model.pages.map(\.title) == ["Convert", "Tools", "AI"])
        model.move(at: 1, toPage: 2)
        #expect(model.pageIndex == 0)
        #expect(model.pages[2].slices.last?.id == first)
    }

    @Test func replacingASlotKeepsItsPlace() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let chip = freshChip(model)
        let count = model.currentPage!.slices.count
        model.replace(at: 2, with: chip)
        #expect(model.currentPage?.slices[2].id == chip)
        #expect(model.currentPage?.slices.count == count)
        model.replace(at: 3, with: chip)
        #expect(model.message == WheelEditor.Refusal.alreadyOnPage.message(for: model.selection))
    }

    /// A chip on the page shows as placed, and placing it again is refused.
    @Test func aChipOnThePageIsPlaced() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let placed = model.currentPage!.slices[0].id
        #expect(model.isOnPage(placed))
        model.add(placed)
        #expect(model.message == WheelEditor.Refusal.alreadyOnPage.message(for: model.selection))
        #expect(store.settings.wheels.isEmpty)
    }

    /// The editor draws over the app's latest plans: a built-in wheel follows a new builder, a customized one stays.
    @Test func aNewBuilderRedrawsTheBuiltInWheel() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let bare = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        model.isVisible = true
        #expect(model.pages.first?.title == "Convert")
        model.update(builder: bare)
        #expect(model.pages.first?.title != "Convert")
        #expect(model.candidates.convert.isEmpty)
    }

    /// Planning a kind's every format takes about 30 ms: a new builder while another pane is shown waits for this one.
    @Test func aNewBuilderWaitsUntilThePaneIsShown() {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let model = model(store)
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let bare = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        let before = (model.pages, model.candidates)
        model.update(builder: bare)
        #expect(model.pages == before.0)
        #expect(model.candidates == before.1)
        model.isVisible = true
        #expect(model.pages.first?.title != "Convert")
        #expect(model.candidates.convert.isEmpty)
        // Hidden again, then a builder with the conversions back: still the bare plan until it shows.
        model.isVisible = false
        model.update(builder: imageBuilder())
        #expect(model.candidates.convert.isEmpty)
        model.isVisible = true
        #expect(!model.candidates.convert.isEmpty)
    }

    // MARK: Drag and drop

    private static let four = ["convert.jpg", "convert.heic", "convert.webp", "action.makeZip"]
    private static let eight = four + ["convert.gif", "convert.tiff", "convert.bmp", "action.copyPaths"]

    /// A drop point on the wheel's labels' radius, `degrees` clockwise from 12 o'clock, centre-relative and y-up.
    private func point(_ degrees: Double, slices: Int) -> CGPoint {
        let center = WheelGeometry(sliceCount: slices).labelCenter(ofSlice: 0)
        let radius = Double(hypot(center.x, center.y))
        let angle = degrees * .pi / 180
        return CGPoint(x: radius * sin(angle), y: radius * cos(angle))
    }

    private func store(_ pages: [CustomPage]) -> SettingsStore {
        let store = SettingsStore(defaults: EphemeralDefaults())
        store.settings.wheels["kind.image"] = CustomWheel(pages: pages)
        return store
    }

    @Test func chipDropInserts() {
        let store = store([CustomPage(name: "Mine", slots: Self.four)])
        let model = model(store)
        let chip = freshChip(model)
        #expect(WheelGeometry(sliceCount: 4).insertionIndex(at: point(100, slices: 4)) == 2)
        model.drop(slot: chip, from: .chip, at: point(100, slices: 4))
        let four = Self.four
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == [four[0], four[1], chip, four[2], four[3]])

        let other = freshChip(model)
        model.drop(slot: other, from: nil, at: .zero)
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots.last == other)
    }

    @Test func chipDropReplacesOnFullPage() {
        let store = store([CustomPage(name: "Mine", slots: Self.eight)])
        let model = model(store)
        let chip = freshChip(model)
        model.drop(slot: chip, from: .chip, at: WheelGeometry(sliceCount: 8).labelCenter(ofSlice: 5))
        var expected = Self.eight
        expected[5] = chip
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == expected)

        model.drop(slot: freshChip(model), from: .chip, at: .zero)
        #expect(model.message == WheelEditor.Refusal.pageFull.message(for: model.selection))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == expected)
    }

    @Test func sliceDragMovesAndRemoves() {
        let store = store([CustomPage(name: "Mine", slots: Self.four)])
        let model = model(store)
        let four = Self.four
        model.drop(slot: four[0], from: .slice(page: 0, index: 0), at: point(190, slices: 4))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == [four[1], four[2], four[0], four[3]])

        #expect(model.dropOutside(slot: four[2], from: .slice(page: 0, index: 1)))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == [four[1], four[0], four[3]])

        let one = CustomWheel(pages: [CustomPage(name: "Mine", slots: ["convert.jpg"])])
        let lastStore = self.store(one.pages)
        let last = self.model(lastStore)
        #expect(!last.dropOutside(slot: "convert.jpg", from: .slice(page: 0, index: 0)))
        #expect(last.message == WheelEditor.Refusal.lastSlot.message(for: last.selection))
        #expect(lastStore.settings.wheels["kind.image"] == one)
    }

    @Test func dropOnTabMovesPage() {
        let store = store([CustomPage(name: "A", slots: Self.four), CustomPage(name: "B", slots: ["convert.png"])])
        let model = model(store)
        let four = Self.four
        model.dropOnTab(slot: four[1], from: .slice(page: 0, index: 1), page: 1)
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == [four[0], four[2], four[3]])
        #expect(store.settings.wheels["kind.image"]?.pages[1].slots == ["convert.png", four[1]])
        #expect(model.pageIndex == 0)

        let full = self.store([CustomPage(name: "A", slots: ["convert.png"]), CustomPage(name: "B", slots: Self.eight)])
        let fullModel = self.model(full)
        let before = full.settings.wheels["kind.image"]
        fullModel.dropOnTab(slot: "convert.png", from: .slice(page: 0, index: 0), page: 1)
        #expect(fullModel.message == WheelEditor.Refusal.pageFull.message(for: fullModel.selection))
        #expect(full.settings.wheels["kind.image"] == before)
    }

    /// A chip dropped on a tab joins the end of that page; the page shown stays.
    @Test func chipDropOnTabAppends() {
        let store = store([CustomPage(name: "A", slots: Self.four), CustomPage(name: "B", slots: ["convert.png"])])
        let model = model(store)
        model.dropOnTab(slot: "action.copyPaths", from: .chip, page: 1)
        #expect(store.settings.wheels["kind.image"]?.pages[1].slots == ["convert.png", "action.copyPaths"])
        #expect(model.pageIndex == 0)
    }

    /// The hub cancels a slice's drag, the rim's outside removes it, and a stale index (the page changed under the
    /// drag) moves nothing.
    @Test func sliceDropOutcomes() {
        let store = store([CustomPage(name: "Mine", slots: Self.four)])
        let model = model(store)
        let four = Self.four
        #expect(model.dropOutcome(slot: four[0], from: .slice(page: 0, index: 0), at: .zero) == .nothing)
        #expect(model.dropOutcome(slot: four[0], from: .slice(page: 0, index: 0), at: CGPoint(x: 169, y: 169))
            == .remove(0))
        #expect(model.dropOutcome(slot: four[1], from: .slice(page: 0, index: 0), at: point(190, slices: 4))
            == .nothing)
        #expect(model.dropOutcome(slot: "action.copyPaths", from: .chip, at: CGPoint(x: 169, y: 169)) == .nothing)
        #expect(!model.dropOutside(slot: "action.copyPaths", from: .chip))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == four)
    }

    /// A slice dragged off the wheel after the page shifted under the drag (an undo, a new plan) removes nothing:
    /// whatever now sits at its old index stays.
    @Test func staleDropOutsideRemovesNothing() {
        let store = store([CustomPage(name: "Mine", slots: Self.four)])
        let model = model(store)
        let four = Self.four
        model.move(from: 0, to: 4)
        let shifted = [four[1], four[2], four[3], four[0]]
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == shifted)
        #expect(!model.dropOutside(slot: four[0], from: .slice(page: 0, index: 0)))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == shifted)
        #expect(!model.dropOutside(slot: four[0], from: .slice(page: 1, index: 3)))
        #expect(model.dropOutside(slot: four[0], from: .slice(page: 0, index: 3)))
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == [four[1], four[2], four[3]])
    }

    /// A chip already on the page has nowhere to land, so the ring forbids it rather than refusing after the drop;
    /// the hub of a full page still takes the drop to say why.
    @Test func aPlacedChipHasNoDropOutcome() {
        let store = store([CustomPage(name: "Mine", slots: Self.eight)])
        let model = model(store)
        let geometry = WheelGeometry(sliceCount: 8)
        #expect(model.dropOutcome(slot: Self.eight[2], from: .chip, at: geometry.labelCenter(ofSlice: 5)) == .nothing)
        #expect(model.dropOutcome(slot: Self.eight[2], from: nil, at: .zero) == .nothing)
        #expect(model.dropOutcome(slot: freshChip(model), from: .chip, at: .zero) == .insert(8))
    }

    /// A tab takes a slice from another page and a chip not on its page; a slice over its own page's tab, or a chip
    /// already there, is turned away so the drag slides back. A full page still takes it, to say why.
    @Test func whatATabAccepts() {
        let store = store([CustomPage(name: "A", slots: Self.four), CustomPage(name: "B", slots: ["convert.png"])])
        let model = model(store)
        let four = Self.four
        #expect(model.acceptsTabDrop(slot: four[1], from: .slice(page: 0, index: 1), page: 1))
        #expect(!model.acceptsTabDrop(slot: four[1], from: .slice(page: 0, index: 1), page: 0))
        #expect(!model.acceptsTabDrop(slot: four[0], from: .slice(page: 0, index: 1), page: 1))
        #expect(model.acceptsTabDrop(slot: "action.copyPaths", from: .chip, page: 1))
        #expect(!model.acceptsTabDrop(slot: "convert.png", from: .chip, page: 1))
        #expect(!model.acceptsTabDrop(slot: four[0], from: nil, page: 0))
        #expect(!model.acceptsTabDrop(slot: "action.copyPaths", from: .chip, page: 5))

        model.dropOnTab(slot: four[1], from: .slice(page: 0, index: 1), page: 0)
        #expect(store.settings.wheels["kind.image"]?.pages[0].slots == four)
    }

    @Test func theKindsAreListedInTheSpecsOrder() {
        #expect(WheelEditorPaneModel.kinds.map(\.wheelTitle) == [
            "Images", "Videos", "Audio", "PDFs", "Documents", "Text", "Subtitles", "Data", "Archives", "Fonts", "Other",
        ])
        #expect(Set(WheelEditorPaneModel.kinds) == Set(FormatCategory.allCases))
    }

    @Test func theWheelPaneIsWider() {
        #expect(SettingsPane.wheel.size == CGSize(width: 980, height: 620))
        for pane in SettingsPane.allCases where pane != .wheel {
            #expect(pane.size == SettingsView.size)
        }
    }
}
