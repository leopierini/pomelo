import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

private func page(_ kind: WheelPageKind, _ count: Int) -> WheelPage {
    WheelPage(kind: kind, slices: (0..<count).map { i in
        WheelSlice(id: "s\(i)", title: "Slice \(i)", symbol: "circle", kind: .preset(id: "s\(i)"))
    })
}

/// Make Zip is off for images by default (P202); tests that give a lone PNG or JPEG a Tools page switch it on.
let makeZipOnImages = ToolVisibility(overrides: ["image": ["make-zip": true]])

/// A builder over every tool and editor, as the real engines will offer them: an operation edge per preset and
/// sample format, plus a convert edge per sample.
private func editorBuilder(visibility: ToolVisibility = .defaults) -> WheelContentBuilder {
    let samples: [(String, FormatCategory)] = [("mov", .video), ("m4a", .audio), ("jpg", .image), ("pdf", .pdf)]
    let presets = ToolCatalog.presets(settings: AppSettings())
    var edges = [ConversionEdge(from: "mov", to: "mp4", engineID: "x", cost: 1, flags: []),
                 ConversionEdge(from: "jpg", to: "png", engineID: "x", cost: 1, flags: [])]
    for preset in presets {
        for (format, category) in samples where preset.categories?.contains(category) ?? true {
            edges.append(ConversionEdge(from: FormatID(format), to: preset.target ?? FormatID(format), engineID: "x",
                                        cost: 1, flags: [], operation: preset.operation))
        }
    }
    let planner = RoutePlanner(edges: edges, enginePriority: ["x"])
    return WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:], tools: presets,
                               visibility: visibility)
}

@MainActor
@Suite struct WheelModelTests {
    /// P31 and P177: editors are Tools page slices, and the on-device tools have their own AI page.
    @Test func theWheelHasConvertToolsAndAIPages() {
        let mov = URL(fileURLWithPath: "/tmp/a.mov")
        let builder = editorBuilder()
        let model = WheelModel()
        let pages = builder.pages(for: [mov])
        model.load(pages: pages, files: [mov], builder: builder)
        model.trigger = .shift
        #expect(pages.map(\.kind) == [.convert, .tools, .ai])
        #expect(model.pill.titles == ["Convert", "Tools", "AI"])
        #expect(pages[1].slices.first?.id == "editor.trim")
        #expect(model.pageIndex == 0)
        model.setPage(1)
        #expect(model.page?.kind == .tools)
        model.setPage(0)
        #expect(model.page?.kind == .convert)
    }

    /// Regression: the same hovered index on a page with another slice count is another angle.
    @Test func setPageRehoversSoTheHighlightMatchesTheNewPage() {
        let model = WheelModel()
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        model.load(pages: [page(.convert, 8), page(.tools, 5)], files: [URL(fileURLWithPath: "/tmp/a.png")],
                   builder: builder)

        // The middle of slice 1 of the 8-slice ring: 45 degrees clockwise from 12 o'clock.
        let eight = WheelGeometry(sliceCount: 8)
        let angle = eight.centerAngle(ofSlice: 1)
        let point = CGPoint(x: 120 * sin(angle), y: 120 * cos(angle))
        model.hover(at: point)
        #expect(model.hovered == 1)
        #expect(model.highlightAngle == eight.centerAngle(ofSlice: 1))

        model.setPage(1)

        // 45 degrees lies in slice 1 of five (36 to 108 degrees), so the index is unchanged, but the angle is not.
        #expect(model.hovered == 1)
        #expect(model.highlightAngle == WheelGeometry(sliceCount: 5).centerAngle(ofSlice: 1))
    }

    /// P32: the page pill shows the trigger's glyph and the page titles, and nothing between them.
    @Test func thePagePillListsConvertAndToolsWithNoSeparatorText() {
        let model = WheelModel()
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        model.load(pages: [page(.convert, 3), page(.tools, 2)],
                   files: [URL(fileURLWithPath: "/tmp/a.png")], builder: builder)
        model.trigger = .shift
        #expect(model.pill == WheelModel.Pill(key: "\u{21E7}", titles: ["Convert", "Tools"]))
        model.clickMode = true
        #expect(model.pill.key == "\u{21E5}")
        let texts = [model.pill.key] + model.pill.titles
        #expect(texts.allSatisfy { !$0.contains("\u{00B7}") && !$0.contains("\u{2014}") })
    }

    /// The highlight springs only from slice to slice: it jumps when it appears from the hub or outside, and when a
    /// page change clears the hover first. Unwrapped angles make 7 → 0 turn forward through 12 o'clock.
    @Test func theHighlightAnimatesOnlyBetweenSlices() {
        let model = WheelModel()
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        model.load(pages: [page(.convert, 8), page(.tools, 8)], files: [URL(fileURLWithPath: "/tmp/a.png")],
                   builder: builder)
        let eight = WheelGeometry(sliceCount: 8)
        func point(inSlice index: Int) -> CGPoint {
            let angle = eight.centerAngle(ofSlice: index)
            return CGPoint(x: 120 * sin(angle), y: 120 * cos(angle))
        }

        model.hover(at: .zero)                       // the hub
        model.hover(at: point(inSlice: 6))
        #expect(model.highlightAnimates == false)    // appears from nothing: jumps
        model.hover(at: point(inSlice: 7))
        #expect(model.highlightAnimates == true)
        model.hover(at: point(inSlice: 0))
        #expect(model.highlightAnimates == true)
        #expect(model.highlightAngle == 2 * .pi)     // forward through 12 o'clock, not back round to 0
        model.hover(at: point(inSlice: 1))
        #expect(model.highlightAnimates == true)

        model.hover(at: CGPoint(x: 500, y: 0))       // outside the ring
        #expect(model.hovered == nil)
        model.hover(at: point(inSlice: 3))
        #expect(model.highlightAnimates == false)

        model.setPage(1)                             // cleared, then re-hovered under the same point
        #expect(model.hovered == 3)
        #expect(model.highlightAnimates == false)
    }

    // MARK: - Customized wheels (P175, P176)

    private let png = URL(fileURLWithPath: "/tmp/a.png")

    private func emptyBuilder() -> WheelContentBuilder {
        let empty = RoutePlanner(edges: [], enginePriority: [])
        return WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
    }

    private func customPage(_ index: Int, _ name: String, _ ids: [String]) -> WheelPage {
        WheelPage(customIndex: index, name: name, slices: ids.map { id in
            WheelSlice(id: id, title: id, symbol: "photo", kind: .convert(FormatID(String(id.dropFirst("convert.".count)))))
        })
    }

    /// A customized wheel has no built-in pages, even one the user named "Tools": it opens on its first page.
    @Test func customPagesOpenOnFirstPage() {
        let model = WheelModel()
        model.load(pages: [customPage(0, "Mine", ["convert.jpg"]), customPage(1, "Tools", ["convert.gif"])],
                   files: [png], builder: emptyBuilder(), firstPage: .tools)
        #expect(model.pageIndex == 0)
    }

    /// Review Focus 4: engines change while a customized wheel is open. The shown page and the hovered slot are
    /// found again by their ids.
    @Test func replanKeepsCustomPageAndHover() {
        let model = WheelModel()
        let first = customPage(0, "Mine", ["convert.heic", "convert.webp"])
        model.load(pages: [first, customPage(1, "Web", ["convert.gif", "convert.jpg", "convert.avif"])],
                   files: [png], builder: emptyBuilder())
        model.setPage(1)
        model.setHovered(1)
        #expect(model.hovered.map { model.slices[$0].id } == "convert.jpg")

        model.replan(pages: [first, customPage(1, "Web", ["convert.jpg", "convert.avif", "convert.gif"])],
                     builder: emptyBuilder())

        #expect(model.page?.id == "custom.1")
        #expect(model.hovered == 0)
        #expect(model.hovered.map { model.slices[$0].id } == "convert.jpg")
    }

    @Test func pagePillUsesTitles() {
        let model = WheelModel()
        model.load(pages: [customPage(0, "Mine", ["convert.jpg"]), customPage(1, "For the web", ["convert.webp"])],
                   files: [png], builder: emptyBuilder())
        #expect(model.pill.titles == ["Mine", "For the web"])
        #expect(model.page?.title == "Mine")
    }

    /// P176 end to end: the controller opens the user's pages, the own-format slot is greyed with its reason in the
    /// hub, a drop on it does nothing, and the page change lands on the next named page.
    @Test func aCustomizedWheelOpensItsPagesAndItsGreyedSlotDoesNothing() throws {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, desktop: .offScreen, readabilityCheck: { _, _ in .clean })
        defer { wheel.close() }
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        let wheels = ["kind.image": CustomWheel(pages: [
            CustomPage(name: "Mine", slots: ["convert.png", "convert.jpg"]),
            CustomPage(name: "Share", slots: ["action.copyPaths"]),
        ])]
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: [], wheels: wheels)
        var chosen: [String] = []
        wheel.onChoose = { slice, _, _ in
            chosen.append(slice.id)
            return nil
        }

        wheel.open(files: [png], at: NSEvent.mouseLocation, clickMode: false)

        #expect(wheel.model.pages.map(\.id) == ["custom.0", "custom.1"])
        #expect(wheel.model.pill.titles == ["Mine", "Share"])
        let own = try #require(wheel.model.slices.first)
        #expect(own.id == "convert.png" && !own.isEnabled)
        wheel.model.setHovered(0)
        #expect(wheel.model.preview.subtitle == "Already a PNG file.")
        wheel.choose(own, files: [png])
        #expect(chosen.isEmpty)
        #expect(wheel.model.phase == .choosing)
        wheel.cyclePage()
        #expect(wheel.model.page?.title == "Share")
    }
}

/// P23: the up-front readability check turns the hub red.
@MainActor
@Suite struct WheelModelDamageTests {
    private let a = URL(fileURLWithPath: "/tmp/a.png")
    private let b = URL(fileURLWithPath: "/tmp/b.png")

    private func loaded(files: [URL]) -> WheelModel {
        let model = WheelModel()
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = WheelContentBuilder(formats: .builtIn, available: empty, all: empty, installHints: [:], tools: [])
        let convert = WheelSlice(id: "convert.jpg", title: "JPEG", symbol: "photo", kind: .convert("jpg"))
        let tool = WheelSlice(id: "preset.half-size", title: "Half size", symbol: "x", kind: .preset(id: "half-size"))
        let action = WheelSlice(id: "action.makeZip", title: "Make Zip", symbol: "x", kind: .action(.makeZip))
        model.load(pages: [WheelPage(kind: .convert, slices: [convert]),
                           WheelPage(kind: .tools, slices: [tool, action])],
                   files: files, builder: builder)
        return model
    }

    private func point(inSlice index: Int, of count: Int) -> CGPoint {
        let angle = WheelGeometry(sliceCount: count).centerAngle(ofSlice: index)
        return CGPoint(x: 120 * sin(angle), y: 120 * cos(angle))
    }

    @Test func aCleanCheckChangesNothing() {
        let model = loaded(files: [a])
        model.apply(.clean)
        #expect(model.alert == nil)
        #expect(model.pages.allSatisfy { $0.slices.allSatisfy(\.isEnabled) })
    }

    /// A clean report still carries the facts the hub's estimate reads.
    @Test func aCleanReportWithFactsGivesTheHoveredSliceAnEstimate() {
        let model = WheelModel()
        let planner = RoutePlanner(edges: [ConversionEdge(from: "png", to: "jpg", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        let builder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:],
                                          tools: [])
        let pages = builder.pages(for: [a])
        model.load(pages: pages, files: [a], builder: builder)
        model.hover(at: point(inSlice: 0, of: pages[0].slices.count))
        #expect(model.preview.subtitle == nil)

        let facts = [a: SourceFacts(bytes: 20_000_000, pixelWidth: 4000, pixelHeight: 3000)]
        model.apply(FileReadability.Report(damaged: [], allDamaged: false, facts: facts))
        #expect(model.alert == nil)
        #expect(model.preview.title == "a.jpg")
        #expect(model.preview.subtitle == SizeEstimate.text(estimate: 3_000_000, source: 20_000_000))
    }

    @Test func damagedFilesLeaveFileToolsUsable() {
        let model = loaded(files: [a])
        model.apply(.init(damaged: [a], allDamaged: true))

        #expect(model.alert == WheelAlert(title: "a.png can't be read", subtitle: "The file may be damaged"))
        let byKind = Dictionary(uniqueKeysWithValues: model.pages.map { ($0.kind, $0.slices) })
        #expect(byKind[.convert]?.allSatisfy { !$0.isEnabled && $0.disabledReason == "The file may be damaged" } == true)
        let tools = byKind[.tools] ?? []
        #expect(tools.first { $0.id == "preset.half-size" }?.isEnabled == false)
        #expect(tools.first { $0.id == "preset.half-size" }?.disabledReason == "The file may be damaged")
        #expect(tools.first { $0.id == "action.makeZip" }?.isEnabled == true)

        // Hovering a disabled slice keeps the red hub; an enabled file tool previews as usual.
        model.setPage(1)
        model.hover(at: point(inSlice: 0, of: 2))
        #expect(model.hovered == 0)
        #expect(model.alert != nil)
        model.hover(at: point(inSlice: 1, of: 2))
        #expect(model.hovered == 1)
        #expect(model.alert == nil)
        #expect(model.preview.title == "Make Zip")
    }

    @Test func damagedFilesDisableEditorSlices() {
        let jpg = URL(fileURLWithPath: "/tmp/a.jpg")
        let builder = editorBuilder(visibility: makeZipOnImages)
        let model = WheelModel()
        model.load(pages: builder.pages(for: [jpg]), files: [jpg], builder: builder)
        model.apply(.init(damaged: [jpg], allDamaged: true))

        let tools = model.pages.first { $0.kind == .tools }?.slices ?? []
        let editors = tools.filter { if case .editor = $0.kind { true } else { false } }
        #expect(editors.map(\.id) == ["editor.crop", "editor.compress-to-size", "editor.resize", "editor.rotate", "editor.redact"])
        for editor in editors {
            #expect(!editor.isEnabled && editor.disabledReason == "The file may be damaged", "\(editor.id)")
        }
        #expect(tools.first { $0.id == "action.makeZip" }?.isEnabled == true)
    }

    @Test func damagedFilesKeepEachPagesIdentity() {
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let slice = WheelSlice(id: "preset.x", title: "X", symbol: "circle", kind: .preset(id: "x"))
        let custom = WheelPage(customIndex: 1, name: "Mine", slices: [slice])
        let model = WheelModel()
        model.load(pages: [page(.ai, 1), custom], files: [png], builder: editorBuilder())
        model.apply(.init(damaged: [png], allDamaged: true))
        #expect(model.pages.map(\.id) == ["ai", "custom.1"])
        #expect(model.pages.map(\.title) == ["AI", "Mine"])
        #expect(model.pages[1].kind == nil)
        #expect(model.pages.allSatisfy { $0.slices.allSatisfy { !$0.isEnabled } })
    }

    @Test func severalDamagedFilesAreCounted() {
        let model = loaded(files: [a, b])
        model.apply(.init(damaged: [a, b], allDamaged: true))
        #expect(model.alert == WheelAlert(title: "2 files can't be read", subtitle: "The files may be damaged"))
    }

    @Test func someDamagedFilesShowTheRedHubOnlyUntilASliceIsHovered() {
        let model = loaded(files: [a, b])
        model.apply(.init(damaged: [b], allDamaged: false))

        #expect(model.alert == WheelAlert(title: "b.png can't be read", subtitle: "The file may be damaged"))
        #expect(model.pages.allSatisfy { $0.slices.allSatisfy(\.isEnabled) })
        model.hover(at: point(inSlice: 0, of: 1))
        #expect(model.alert == nil)
        // The preview counts only the file that will convert.
        #expect(model.preview.title == "a.jpg")
        model.hover(at: .zero)
        #expect(model.alert != nil)
    }

    @Test func conversionsAndToolsSkipDamagedFilesButFileToolsTakeThemAll() {
        let model = loaded(files: [a, b])
        model.apply(.init(damaged: [b], allDamaged: false))
        let convert = model.pages[0].slices[0]
        let tool = model.pages[1].slices[0]
        let action = model.pages[1].slices[1]
        #expect(model.files(toRun: convert, from: [a, b]) == [a])
        #expect(model.files(toRun: tool, from: [a, b]) == [a])
        #expect(model.files(toRun: action, from: [a, b]) == [a, b])
    }

    @Test func waitingFreezesTheHoverAndAFailureReplacesItWithTheRedHub() {
        let model = loaded(files: [a, b])
        model.apply(.init(damaged: [b], allDamaged: false))
        model.hover(at: point(inSlice: 0, of: 1))
        model.beginWaiting()
        model.hover(at: nil)
        #expect(model.hovered == 0)                  // the chosen slice stays lit
        #expect(model.alert == nil)

        let failure = WheelAlert(title: "Couldn't convert a.png", subtitle: "file not found")
        model.showFailure(failure)
        #expect(model.isFailed)
        #expect(model.hovered == nil)
        #expect(model.alert == failure)              // over the damaged-file line
        #expect(!model.dimsSlices)
        // P191: the wheel is live again; a hovered slice previews in place of the red hub, which returns off it.
        model.hover(at: point(inSlice: 0, of: 1))
        #expect(model.hovered == 0)
        #expect(model.alert == nil)
        model.hover(at: nil)
        #expect(model.alert == failure)
    }

    @Test func reopeningClearsTheVerdict() {
        let model = loaded(files: [a])
        model.apply(.init(damaged: [a], allDamaged: true))
        let fresh = loaded(files: [a])
        model.load(pages: fresh.pages, files: [a], builder: fresh.builder!)
        #expect(model.alert == nil)
        #expect(model.pages[0].slices[0].isEnabled)
    }
}
