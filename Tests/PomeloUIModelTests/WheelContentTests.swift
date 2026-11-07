import Foundation
import PomeloEngines
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

private let everyToolEdges = WheelFixtures.everyToolEdges

private func builder(availableEdges: [String], allEdges: [String]? = nil, hints: [EngineID: String] = [:],
                     unsupported: [EngineID: String] = [:], installable: Set<EngineID> = [], layoutRisk: Set<String> = [],
                     settings: AppSettings = AppSettings(),
                     visibility: ToolVisibility? = nil, replacesOriginals: Bool = false) -> WheelContentBuilder {
    WheelFixtures.builder(availableEdges: availableEdges, allEdges: allEdges, hints: hints, unsupported: unsupported,
                          installable: installable, layoutRisk: layoutRisk, settings: settings, visibility: visibility,
                          replacesOriginals: replacesOriginals)
}

private func ids(_ pages: [WheelPage], _ kind: WheelPageKind) -> [String]? {
    pages.first { $0.kind == kind }?.slices.map(\.id)
}

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

/// Half size and Make Zip left the image wheel's defaults (P202) but stay catalog tools one switch away.
private let halfAndZip = ToolVisibility(overrides: ["image": ["half-size": true, "make-zip": true]])

/// Kinds with few engine tools show the clipboard and Finder tools too, so their wheel isn't bare; the Shelf ends
/// the page (R27). A zip is never zipped again.
private let fileToolsOfAnArchive = [
    "action.copyPaths", "action.copyFiles", "action.revealInFinder", "action.openTerminal", "action.shelf",
]
private let fileToolsOfASparseKind = ["action.makeZip"] + fileToolsOfAnArchive

@Suite struct WheelContentTests {
    /// The route search was most of `WheelController.open` (Phase 6 profile): one per format per builder, and a new
    /// builder (new engines, plugins or settings) searches again.
    @Test func eachFormatIsSearchedOncePerBuilder() {
        let edges = ["png>jpg", "jpg>png", "png>png", "png>heic"]
        let b = builder(availableEdges: edges)
        let first = b.pages(for: [url("/a.png")])
        #expect(b.pages(for: [url("/b.png")]) == first)
        _ = b.pages(for: [url("/c.png"), url("/d.jpg")])
        #expect(b.routeSearches == 2)

        let fewer = builder(availableEdges: ["png>jpg"], allEdges: edges)
        #expect(fewer.pages(for: [url("/a.png")]) != first)
        #expect(fewer.routeSearches == 1)
    }

    @Test func convertPageFollowsDefaultOrder() {
        let b = builder(availableEdges: ["png>jpg", "png>heic", "png>pdf", "png>tiff", "png>png"])
        let page = b.pages(for: [url("/a.png")]).first { $0.kind == .convert }!
        #expect(page.slices.map(\.id) == ["convert.jpg", "convert.pdf", "convert.heic", "convert.tiff"])
        #expect(page.slices.allSatisfy { $0.isEnabled })
        #expect(page.slices.first?.title == "JPEG")
        #expect(page.slices.first?.symbol == "photo")
        #expect(page.slices.first?.kind == .convert("jpg"))
    }

    @Test func textRecognitionHasItsOwnVerb() {
        let b = builder(availableEdges: ["png>txt@vision", "pdf>txt@pdfkit", "png>jpg"])
        #expect(b.conversionVerb(for: [url("/a.png")], to: "txt") == "Recognizing text")
        #expect(b.conversionVerb(for: [url("/a.pdf")], to: "txt") == "Converting")
        #expect(b.conversionVerb(for: [url("/a.png")], to: "jpg") == "Converting")
        #expect(b.conversionVerb(for: [], to: "txt") == "Converting")
    }

    @Test func disabledSliceExplainsMissingEngine() {
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                        hints: ["cwebp": "cwebp|brew install webp"])
        let webp = b.pages(for: [url("/a.png")])[0].slices.first { $0.id == "convert.webp" }!
        #expect(webp.isEnabled == false)
        #expect(webp.disabledReason == "Needs cwebp. Install it with brew install webp.")
    }

    @Test func disabledSliceIsNotActionable() {
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                        hints: ["cwebp": "cwebp|brew install webp"])
        let files = [url("/a.png")]
        let webp = b.pages(for: files)[0].slices.first { $0.id == "convert.webp" }!
        let preview = b.preview(for: webp, files: files)
        #expect(preview.subtitle == "Needs cwebp. Install it with brew install webp.")
        #expect(preview.title == "a.webp")
    }

    @Test func aMissingInstallableEngineSaysSettings() {
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                        hints: ["cwebp": "cwebp|brew install webp"], installable: ["cwebp"])
        let files = [url("/a.png")]
        let webp = b.pages(for: files)[0].slices.first { $0.id == "convert.webp" }!
        #expect(webp.isEnabled == false)
        #expect(webp.disabledReason == "Needs cwebp. Install it from Pomelo's Settings.")
        #expect(b.preview(for: webp, files: files).subtitle == "Needs cwebp. Install it from Pomelo's Settings.")
        // An engine whose hint is only CommandEngine's fallback is installable all the same.
        let bare = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                           hints: ["cwebp": "cwebp|Install cwebp"], installable: ["cwebp"])
        #expect(bare.pages(for: files)[0].slices.first { $0.id == "convert.webp" }?.disabledReason
                == "Needs cwebp. Install it from Pomelo's Settings.")
    }

    @Test func aMissingEngineWithoutADownloadKeepsItsSentence() {
        // Another engine is installable; the one on this route (unar) has no pinned download.
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                        hints: ["cwebp": "cwebp|brew install webp"], installable: ["ffmpeg", "pandoc"])
        #expect(b.pages(for: [url("/a.png")])[0].slices.first { $0.id == "convert.webp" }?.disabledReason
                == "Needs cwebp. Install it with brew install webp.")
        let unar = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@unar"],
                           hints: ["unar": "The Unarchiver|https://theunarchiver.com"], installable: ["cwebp"])
        #expect(unar.pages(for: [url("/a.png")])[0].slices.first { $0.id == "convert.webp" }?.disabledReason
                == "Needs The Unarchiver. Get it from https://theunarchiver.com.")
    }

    /// P32: the install hint is a sentence, never two facts joined by a separator glyph.
    @Test func aMissingEngineReadsAsASentence() {
        func reason(hint: String?) -> String? {
            let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                            hints: hint.map { ["cwebp": $0] } ?? [:])
            return b.pages(for: [url("/a.png")])[0].slices.first { $0.id == "convert.webp" }?.disabledReason
        }
        #expect(reason(hint: "cwebp|brew install webp") == "Needs cwebp. Install it with brew install webp.")
        #expect(reason(hint: "The Unarchiver|https://theunarchiver.com")
                == "Needs The Unarchiver. Get it from https://theunarchiver.com.")
        #expect(reason(hint: "cwebp|Install cwebp") == "Needs cwebp.")
        #expect(reason(hint: "cwebp") == "Needs cwebp.")
        #expect(reason(hint: nil) == "Not available.")
    }

    @Test func enabledSliceHasNoReason() {
        let b = builder(availableEdges: ["png>jpg"])
        let jpg = b.pages(for: [url("/a.png")])[0].slices[0]
        #expect(jpg.isEnabled && jpg.disabledReason == nil)
    }

    @Test func mixedSelectionIntersectsTargets() {
        let b = builder(availableEdges: ["png>jpg", "png>pdf", "mp4>mov", "mp4>pdf"])
        let pages = b.pages(for: [url("/a.png"), url("/b.mp4")])
        #expect(pages.first { $0.kind == .convert }?.slices.map(\.id) == ["convert.pdf"])
        // Neither kind shows Make Zip by default (P202), so a photo with a movie gets the Shelf alone.
        #expect(ids(pages, .tools) == ["action.shelf"])
        let zips = builder(availableEdges: ["png>jpg", "png>pdf", "mp4>mov", "mp4>pdf"], visibility: halfAndZip)
        #expect(ids(zips.pages(for: [url("/a.png"), url("/b.mp4")]), .tools) == ["action.makeZip", "action.shelf"])
    }

    @Test func atMostEightSlices() {
        let targets = ["jpg", "heic", "webp", "pdf", "avif", "tiff", "gif", "ico", "icns", "jp2", "psd", "tga"]
        // bmp is cheaper than the other extras but not in the order list: the order list comes first, then
        // the rest by route cost.
        let b = builder(availableEdges: targets.map { "png>\($0)" } + ["png>bmp#1", "png>exr#50"])
        let page = b.pages(for: [url("/a.png")]).first { $0.kind == .convert }!
        #expect(page.slices.count == 8)
        #expect(page.slices.map(\.id) == ["convert.jpg", "convert.pdf", "convert.gif", "convert.ico",
                                          "convert.webp", "convert.heic", "convert.bmp", "convert.avif"])
    }

    @Test func remainingTargetsFollowOrderListByCost() {
        let b = builder(availableEdges: ["png>jpg", "png>tga#30", "png>bmp#20", "png>icns#20"])
        let page = b.pages(for: [url("/a.png")])[0]
        #expect(page.slices.map(\.id) == ["convert.jpg", "convert.bmp", "convert.icns", "convert.tga"])
    }

    @Test func disabledTargetsOnlyAppearThroughTheOrderList() {
        // webp is in the image order list (disabled); icns is not (and is unavailable), so it is dropped.
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp", "png>icns@other"],
                        hints: ["cwebp": "cwebp|brew install webp", "other": "Other|get other"])
        let ids = b.pages(for: [url("/a.png")])[0].slices.map(\.id)
        #expect(ids == ["convert.jpg", "convert.webp"])
    }

    /// Check 15: without LibreOffice a presentation's Convert page still shows its slides slices, disabled with
    /// LibreOffice's own sentence (P201, P204). A disabled target shows only through the order list, so the document
    /// list carries jpg and png.
    @Test func slidesSlicesShowDisabledWithoutLibreOffice() async throws {
        let bundled = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder]).manifests
        var manifest = try #require(bundled.first { $0.id == "libreoffice" })
        manifest.executable = .init(names: ["pomelo-no-such-soffice"], searchPaths: [], versionArguments: ["--version"])
        let office = CommandEngine(manifest: manifest, locator: ExecutableLocator(enginesFolder: URL(filePath: "/nonexistent")))
        let registry = EngineRegistry(engines: [office, SlidesEngine(office: office)], priority: ["libreoffice", "slides"])
        let b = WheelContentBuilder(
            formats: .builtIn, available: await registry.planner(), all: await registry.planner(includingMissing: true),
            installHints: await registry.installHints(), tools: ToolCatalog.presets(settings: AppSettings()))

        for deck in ["/deck.pptx", "/deck.ppt", "/deck.odp"] {
            let slices = try #require(b.pages(for: [url(deck)]).first { $0.kind == .convert }?.slices)
            #expect(slices.map(\.id) == ["convert.pdf", "convert.jpg", "convert.png"], "\(deck)")
            #expect(slices.allSatisfy {
                !$0.isEnabled && $0.disabledReason == "Needs LibreOffice. Install it with brew install --cask libreoffice."
            }, "\(deck)")
        }
    }

    /// With LibreOffice, a deck's page is unchanged: pdf, then jpg ahead of png (PowerPoint → JPG leads, P202).
    @Test func slidesSlicesFollowPdf() {
        let b = builder(availableEdges: ["pptx>pdf@libreoffice#60", "pptx>png@slides#70", "pptx>jpg@slides#70",
                                         "docx>pdf@libreoffice#60"])
        #expect(ids(b.pages(for: [url("/deck.pptx")]), .convert) == ["convert.pdf", "convert.jpg", "convert.png"])
        #expect(ids(b.pages(for: [url("/a.docx")]), .convert) == ["convert.pdf"])
    }

    @Test func toolsOnlyWhenApplicable() {
        let b = builder(availableEdges: ["png>png", "png>jpg"], visibility: halfAndZip)
        let tools = b.pages(for: [url("/a.png")]).first { $0.kind == .tools }
        #expect(tools?.slices.map(\.id) == ["preset.half-size", "action.makeZip", "action.shelf"])
        #expect(tools?.slices.first?.title == "Half size")
        #expect(tools?.slices.first?.symbol == "arrow.down.right.and.arrow.up.left")
        #expect(tools?.slices.first?.kind == .preset(id: "half-size"))
    }

    @Test func toolsNeedARouteForEveryFile() {
        let b = builder(availableEdges: ["png>png", "mov>mp4"], visibility: halfAndZip)
        // Half size is out by its kinds (images only, and the drag has a video); only the file tools are left.
        let pages = b.pages(for: [url("/a.png"), url("/b.mov")])
        #expect(ids(pages, .tools) == ["action.makeZip", "action.shelf"])
        // Two images where only the PNG routes: Half size is out because the JPEG has no route for it.
        #expect(ids(b.pages(for: [url("/a.png"), url("/b.jpg")]), .tools) == ["action.makeZip", "action.shelf"])
        #expect(ids(b.pages(for: [url("/a.png")]), .tools) == ["preset.half-size", "action.makeZip", "action.shelf"])
    }

    @Test func videoToolsAppearForVideo() {
        let b = builder(availableEdges: ["mp4>mp4", "mp4>m4a"])
        let tools = b.pages(for: [url("/a.mp4")]).first { $0.kind == .tools }
        #expect(tools?.slices.map(\.id) == ["preset.extract-audio", "action.shelf"])
    }

    @Test func emptyConvertPageOmitted() {
        let b = builder(availableEdges: [])
        #expect(b.pages(for: [url("/a.xyz")]).map(\.kind) == [.tools])
        // An image shows the Shelf alone (Make Zip left, P202), so with no engines that is its whole wheel.
        #expect(b.pages(for: [url("/a.png")]).map(\.kind) == [.tools])
        #expect(ids(b.pages(for: [url("/a.png")]), .tools) == ["action.shelf"])
    }

    @Test func unknownFileEmptiesConvertAndTools() {
        let b = builder(availableEdges: ["png>jpg", "png>png"], visibility: halfAndZip)
        let pages = b.pages(for: [url("/a.png"), url("/b.unknownext")])
        #expect(pages.map(\.kind) == [.tools])
        #expect(ids(pages, .tools) == fileToolsOfASparseKind)
    }

    @Test func previewSingleAndMultiple() {
        let b = builder(availableEdges: ["pdf>jpg"])
        let slice = b.pages(for: [url("/x/Report.pdf")])[0].slices[0]
        #expect(slice.id == "convert.jpg")
        #expect(b.preview(for: slice, files: [url("/x/Report.pdf")]).title == "Report.jpg")
        #expect(b.preview(for: slice, files: [url("/x/Report.pdf"), url("/x/Other.pdf")]).title == "2 files → JPG")
    }

    @Test func presetAndActionPreviewsUseTheirName() {
        let b = builder(availableEdges: ["png>png"], visibility: halfAndZip)
        let files = [url("/a.png")]
        let pages = b.pages(for: files)
        let tool = pages.first { $0.kind == .tools }!.slices[0]
        #expect(b.preview(for: tool, files: files) == HubPreview(title: "Half size", subtitle: nil, warning: nil))
        let action = pages.first { $0.kind == .tools }!.slices[1]
        #expect(action.id == "action.makeZip")
        #expect(b.preview(for: action, files: files).title == "Make Zip")
    }

    @Test func previewWarnsOnLayoutRisk() {
        let b = builder(availableEdges: ["docx>pdf"], layoutRisk: ["docx>pdf"])
        let files = [url("/x/Memo.docx")]
        let slice = b.pages(for: files)[0].slices[0]
        #expect(slice.flags.contains(.layoutRisk))
        #expect(b.preview(for: slice, files: files).warning == "Layout may shift")
        #expect(b.preview(for: slice, files: files).title == "Memo.pdf")
    }

    @Test func noWarningWithoutLayoutRisk() {
        let b = builder(availableEdges: ["png>jpg"])
        let files = [url("/a.png")]
        #expect(b.preview(for: b.pages(for: files)[0].slices[0], files: files).warning == nil)
    }

    @Test func multiPagePDFHint() {
        let b = builder(availableEdges: ["pdf>png", "png>jpg"])
        let pdf = [url("/x/Scan.pdf")]
        let slice = b.pages(for: pdf)[0].slices.first { $0.id == "convert.png" }!
        #expect(b.preview(for: slice, files: pdf).subtitle == "One image per page")
        let png = [url("/x/Pic.png")]
        let jpg = b.pages(for: png)[0].slices[0]
        #expect(b.preview(for: jpg, files: png).subtitle == nil)
    }

    @Test func mixedSelectionOffersTheFormatOfAFile() {
        let b = builder(availableEdges: ["heic>jpg"])
        let files = [url("/x/a.heic"), url("/x/b.jpg")]
        let slice = b.pages(for: files).first { $0.kind == .convert }?.slices.first { $0.id == "convert.jpg" }
        #expect(slice?.isEnabled == true)
        #expect(b.preview(for: slice!, files: files).title == "a.jpg")
    }

    @Test func sameFormatSelectionOffersNoSameFormatSlice() {
        let b = builder(availableEdges: ["png>jpg", "png>png"])
        let pages = b.pages(for: [url("/a.png"), url("/b.png")])
        let ids = pages.first { $0.kind == .convert }?.slices.map(\.id)
        #expect(ids == ["convert.jpg"])
        #expect(ids?.contains("convert.png") == false)
    }

    @Test func disabledReasonComesFromFirstFileLackingARoute() {
        let b = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "heic>jpg@magick"],
                        hints: ["magick": "ImageMagick|brew install imagemagick"])
        let files = [url("/x/a.png"), url("/x/b.heic"), url("/x/c.jpg")]
        let slice = b.pages(for: files)[0].slices.first { $0.id == "convert.jpg" }!
        #expect(!slice.isEnabled)
        #expect(slice.disabledReason == "Needs ImageMagick. Install it with brew install imagemagick.")
        #expect(b.preview(for: slice, files: files).title == "2 files → JPG")
    }

    /// Routes are planned once per distinct source format, not once per file. Over a dense graph every route search
    /// is expensive, so planning per file takes many seconds for this drag (per format, a few milliseconds); the
    /// budget sits far from both.
    @Test func aLargeDragOfTwoFormatsPlansPerFormat() {
        let images = ["png", "jpg", "gif", "tiff", "heic", "avif", "webp", "bmp", "ico", "icns", "jp2", "psd"]
        let edges = images.flatMap { from in images.map { "\(from)>\($0)" } }
        let b = builder(availableEdges: edges, visibility: halfAndZip)
        let files = (0..<500).map { url("/x/\($0).\($0.isMultiple(of: 2) ? "png" : "jpg")") }

        let clock = ContinuousClock()
        var pages: [WheelPage] = []
        var previews: [HubPreview] = []
        let elapsed = clock.measure {
            pages = b.pages(for: files)
            previews = pages.flatMap(\.slices).map { b.preview(for: $0, files: files) }
        }

        #expect(elapsed < .seconds(2))
        let convert = pages.first { $0.kind == .convert }?.slices ?? []
        #expect(convert.count == WheelContentBuilder.maxSlices && convert.allSatisfy(\.isEnabled))
        #expect(convert.first?.id == "convert.jpg")
        #expect(previews.first?.title == "250 files → JPG")
        #expect(ids(pages, .tools) == ["preset.half-size", "action.makeZip", "action.shelf"])
    }

    @Test func filesToConvertDropsFilesAlreadyInTheTarget() {
        let b = builder(availableEdges: ["heic>jpg", "png>jpg"])
        let files = [url("/x/a.heic"), url("/x/b.jpg"), url("/x/c.png"), url("/x/d.jpeg")]
        #expect(b.filesToConvert(files, to: "jpg") == [url("/x/a.heic"), url("/x/c.png")])
        #expect(b.filesToConvert(files, to: "tiff") == files)
    }
}

@Suite struct ToolPagesTests {
    private let toolIDs = { (b: WheelContentBuilder, files: [URL]) in
        b.pages(for: files).first { $0.kind == .tools }?.slices.map(\.id) ?? []
    }

    private let aiIDs = { (b: WheelContentBuilder, files: [URL]) in
        b.pages(for: files).first { $0.kind == .ai }?.slices.map(\.id)
    }

    @Test func theWheelHasThreeBuiltInPages() {
        #expect(WheelPageKind.allCases == [.convert, .tools, .ai])
        #expect(WheelPageKind.allCases.map(\.title) == ["Convert", "Tools", "AI"])
        let b = builder(availableEdges: ["png>jpg"] + everyToolEdges)
        let pages = b.pages(for: [url("/a.png")])
        #expect(pages.map(\.kind) == [.convert, .tools, .ai])
        #expect(pages.map(\.id) == ["convert", "tools", "ai"])
        #expect(pages.map(\.title) == ["Convert", "Tools", "AI"])
    }

    @Test func aCustomPageHasAnIndexedIDAndNoKind() {
        let page = WheelPage(customIndex: 2, name: "Mine", slices: [])
        #expect(page.id == "custom.2" && page.title == "Mine" && page.kind == nil)
    }

    // MARK: AI page (P177)

    /// `everyToolEdges` without the AI tools' operations: what a Mac with no on-device engine offers.
    private static let plainEdges: [String] = {
        let aiOperations = Set(ToolCatalog.presets(settings: AppSettings()).filter { ToolCatalog.info($0.id)?.isAI == true }
            .compactMap(\.operation))
        return everyToolEdges.filter { spec in
            guard let colon = spec.firstIndex(of: ":") else { return true }
            let operation = spec[spec.index(after: colon)...].split(separator: "@")[0]
            return !aiOperations.contains(String(operation))
        }
    }()

    @Test func pdfHasThreeBuiltInPages() {
        let b = builder(availableEdges: ["pdf>png"] + everyToolEdges)
        let pages = b.pages(for: [url("/a.pdf")])
        #expect(pages.map(\.id) == ["convert", "tools", "ai"])
        #expect(ids(pages, .ai) == [
            "preset.summarize", "preset.scan-document", "preset.extract-tables", "preset.extract-data",
        ])
        let tools = ids(pages, .tools) ?? []
        #expect(!tools.isEmpty)
        for info in ToolCatalog.all where info.isAI { #expect(!tools.contains("preset.\(info.id)"), "\(info.id)") }
    }

    @Test func imageToolsLoseRemoveBackground() {
        let b = builder(availableEdges: everyToolEdges)
        let pages = b.pages(for: [url("/a.png")])
        #expect(!(ids(pages, .tools) ?? []).contains("preset.remove-background"))
        #expect(ids(pages, .ai)?.prefix(3) == ["preset.remove-background", "preset.smart-crop", "preset.straighten"])
        #expect(!(ids(pages, .tools) ?? []).contains("preset.smart-crop"))
        #expect(!(ids(pages, .tools) ?? []).contains("preset.straighten"))
    }

    /// P264: Find duplicates ends the image AI page, seven tools, and like every combine it needs two files.
    @Test func findDuplicatesEndsTheImageAIPageForTwoOrMoreImages() {
        let b = builder(availableEdges: everyToolEdges)
        #expect(ids(b.pages(for: [url("/a.png"), url("/b.jpg")]), .ai) == [
            "preset.remove-background", "preset.smart-crop", "preset.straighten", "preset.scan-document",
            "preset.extract-tables", "preset.extract-data", "preset.find-duplicates",
        ])
        #expect(!(ids(b.pages(for: [url("/a.png")]), .ai) ?? []).contains("preset.find-duplicates"))
        #expect(!(ids(b.pages(for: [url("/a.png"), url("/b.png")]), .tools) ?? []).contains("preset.find-duplicates"))
    }

    @Test func aiPageLeftOutWhenNothingRuns() {
        let reason = "Needs macOS 26."
        let b = builder(availableEdges: Self.plainEdges, allEdges: Self.plainEdges + Self.onDeviceEdges,
                        unsupported: ["documentscan": reason, "intelligence": reason, "translation": reason])
        let pages = b.pages(for: [url("/a.pdf")])
        #expect(pages.first { $0.id == "ai" } == nil)
        #expect(pages.map(\.id) == ["tools"])
    }

    @Test func aiPageShowsGreyedToolWhenOthersRun() throws {
        let reason = "Needs macOS 26."
        let available = Self.plainEdges + Self.onDeviceEdges.filter { !$0.hasSuffix("@intelligence") }
        let b = builder(availableEdges: available, allEdges: Self.plainEdges + Self.onDeviceEdges,
                        unsupported: ["intelligence": reason])
        let ai = try #require(b.pages(for: [url("/a.pdf")]).first { $0.id == "ai" })
        let summarize = try #require(ai.slices.first { $0.id == "preset.summarize" })
        #expect(!summarize.isEnabled && summarize.disabledReason == reason)
        #expect(ai.slices.first { $0.id == "preset.scan-document" }?.isEnabled == true)
    }

    @Test func mixedKindsGetAIPage() {
        let b = builder(availableEdges: Self.plainEdges + Self.onDeviceEdges)
        #expect(aiIDs(b, [url("/a.png"), url("/b.pdf")]) == [
            "preset.scan-document", "preset.extract-tables", "preset.extract-data",
        ])
    }

    @Test func shelfIsOnEveryToolsPage() {
        let b = builder(availableEdges: everyToolEdges)
        let kinds: [(String, [URL])] = [
            ("one image", [url("/a.png")]),
            ("several images", [url("/a.png"), url("/b.png")]),
            ("a video", [url("/a.mp4")]),
            ("a PDF", [url("/a.pdf")]),
            ("a csv", [url("/a.csv")]),
            ("a mix of kinds", [url("/a.png"), url("/b.pdf"), url("/c.mp4")]),
        ]
        for (what, files) in kinds {
            let tools = b.pages(for: files).first { $0.kind == .tools }
            #expect(tools?.slices.last?.id == "action.shelf", "\(what)")
            #expect(tools?.slices.last?.title == "Shelf", "\(what)")
            #expect(tools?.slices.last?.kind == .action(.shelf), "\(what)")
            #expect(tools?.slices.last?.isEnabled == true, "\(what)")
        }
    }

    @Test func defaultToolsPerKind() {
        let b = builder(availableEdges: everyToolEdges)
        // Remove metadata stepped aside for the Shelf on images (S32).
        #expect(toolIDs(b, [url("/a.png"), url("/b.png")]) == [
            "preset.compress", "editor.compress-to-size", "editor.resize", "editor.rotate", "preset.images-to-pdf",
            "action.shelf",
        ])
        #expect(toolIDs(b, [url("/a.png")]) == [
            "editor.crop", "preset.compress", "editor.compress-to-size", "editor.resize", "editor.rotate",
            "editor.redact", "action.shelf",
        ])
        // Resize… stepped aside on videos for the Shelf (R2): images keep it.
        #expect(toolIDs(b, [url("/a.mp4")]) == [
            "editor.trim", "editor.crop", "preset.compress", "editor.compress-to-size", "editor.rotate",
            "preset.extract-audio", "preset.remove-audio", "action.shelf",
        ])
        #expect(toolIDs(b, [url("/a.m4a")]) == [
            "editor.trim", "preset.normalize-volume", "preset.speed-up", "preset.slow-down", "preset.mono",
            "preset.strip-metadata", "action.makeZip", "action.shelf",
        ])
        #expect(toolIDs(b, [url("/a.pdf")]) == [
            "preset.compress", "editor.compress-to-size", "preset.read-codes", "preset.split-pdf",
            "editor.organize-pages", "action.makeZip", "action.shelf",
        ])
        #expect(toolIDs(b, [url("/a.pdf"), url("/b.pdf")]) == [
            "preset.compress", "editor.compress-to-size", "preset.read-codes", "preset.merge-pdfs",
            "preset.split-pdf", "action.makeZip", "action.shelf",
        ])
        #expect(aiIDs(b, [url("/a.mp4")]) == ["preset.transcribe", "preset.make-subtitles"])
        #expect(aiIDs(b, [url("/a.m4a")]) == ["preset.transcribe", "preset.make-subtitles"])
    }

    /// The Convert pages lead with the targets people search for most (P194).
    @Test func defaultOrderFollowsMeasuredDemand() {
        let order = WheelContentBuilder.defaultOrder
        #expect(order[.image] == ["jpg", "png", "pdf", "txt", "gif", "ico", "webp", "heic"])
        #expect(order[.video] == ["mp4", "gif", "mp3", "mov", "wav", "m4a", "webm", "avi"])
        #expect(order[.audio] == ["mp3", "wav", "m4a", "ogg", "flac", "aiff", "opus"])
        #expect(order[.pdf] == ["docx", "jpg", "png", "txt"])
        #expect(order[.document] == ["csv", "pdf", "jpg", "png", "docx", "doc", "epub", "txt", "html", "odt", "rtf"])
        #expect(order[.data] == ["xlsx"])
        #expect(order[.text] == ["pdf", "docx", "html", "rtf", "md", "odt"])
        #expect(order[.archive] == ["zip", "tgz", "tar"])
        #expect(order[.subtitle] == ["vtt", "srt"])
        // The document list is three longer: only an xlsx reaches csv and only a presentation jpg and png, so no
        // source sees more than eight of them.
        for (kind, formats) in order {
            #expect(formats.count <= WheelContentBuilder.maxSlices + (kind == .document ? 3 : 0), "\(kind)")
        }
    }

    /// The edges the on-device engines offer (Phase 4b): Translate has none from pdf or docx although the document
    /// kind holds md, so the wheel offers it only where an edge is.
    private static let onDeviceEdges: [String] = {
        let translate = ["srt", "vtt", "txt", "md"].map { "\($0)>\($0):translate@translation" }
        let summarize = ["pdf", "docx", "txt", "md"].map { "\($0)>md:summarize@intelligence" }
        let scans = ["png", "pdf"].flatMap { source in
            ["\(source)>md:scan-document@documentscan", "\(source)>xlsx:extract-tables@documentscan",
             "\(source)>csv:extract-tables@documentscan", "\(source)>json:extract-data@intelligence",
             "\(source)>csv:extract-data@intelligence"]
        }
        return translate + summarize + scans
    }()

    @Test func theOnDeviceToolsAppearWhereTheirEdgesAre() {
        let b = builder(availableEdges: Self.plainEdges + Self.onDeviceEdges)
        #expect(aiIDs(b, [url("/a.srt")]) == ["preset.translate"])
        #expect(toolIDs(b, [url("/a.srt")]) == fileToolsOfASparseKind)
        #expect(aiIDs(b, [url("/a.txt")]) == ["preset.translate", "preset.summarize"])
        #expect(aiIDs(b, [url("/a.md")]) == ["preset.translate", "preset.summarize"])
        #expect(aiIDs(b, [url("/a.docx")]) == ["preset.summarize"])
        #expect(aiIDs(b, [url("/a.srt"), url("/b.txt")]) == ["preset.translate"])
        // Shown for documents, but a pptx has no edge.
        #expect(aiIDs(b, [url("/a.pptx")]) == nil)
        #expect(toolIDs(b, [url("/a.pptx")]) == fileToolsOfASparseKind)
        #expect(aiIDs(b, [url("/a.pdf")]) == [
            "preset.summarize", "preset.scan-document", "preset.extract-tables", "preset.extract-data",
        ])
        // plainEdges has no Remove background edge.
        #expect(aiIDs(b, [url("/a.png")]) == ["preset.scan-document", "preset.extract-tables", "preset.extract-data"])
    }

    @Test func aiToolsTurnedOffLeaveTheirPage() {
        var settings = AppSettings()
        for id in ["summarize", "scan-document", "extract-tables", "extract-data"] {
            settings.toolVisibility["pdf", default: [:]][id] = false
        }
        settings.toolVisibility["image", default: [:]]["extract-tables"] = false
        let b = builder(availableEdges: Self.plainEdges + Self.onDeviceEdges, settings: settings)
        #expect(aiIDs(b, [url("/a.pdf")]) == nil)
        #expect(aiIDs(b, [url("/a.png")]) == ["preset.scan-document", "preset.extract-data"])
    }

    @Test func aDisabledOnDeviceToolSaysWhyInTheHub() throws {
        let reason = "Needs macOS 26."
        // Summarize runs, so the AI page exists and holds Translate greyed out.
        let b = builder(availableEdges: Self.plainEdges + ["txt>md:summarize@intelligence"],
                        allEdges: Self.plainEdges + Self.onDeviceEdges, unsupported: ["translation": reason])
        let files = [url("/a.txt")]
        let translate = try #require(b.pages(for: files).first { $0.kind == .ai }?.slices
            .first { $0.id == "preset.translate" })
        #expect(translate.isEnabled == false && translate.disabledReason == reason)
        let preview = b.preview(for: translate, files: files)
        #expect(preview.title == translate.title && preview.subtitle == reason)
        #expect(translate.title.hasPrefix("Translate to "))
    }

    @Test func extractDataRunsInTheFormatItsSettingPicks() throws {
        var settings = AppSettings()
        settings.toolOptions["extract-data"] = PresetOptions(outputFormat: "csv")
        settings.toolVisibility["image"] = ["extract-data": true]
        let b = builder(availableEdges: ["png>csv:extract-data@intelligence"], settings: settings)
        #expect(aiIDs(b, [url("/a.png")])?.contains("preset.extract-data") == true)
        #expect(b.tool(id: "extract-data")?.target == "csv")
        // Left at json, the same Mac (csv only) has no route: no slice.
        let json = builder(availableEdges: ["png>csv:extract-data@intelligence"],
                           visibility: ToolVisibility(overrides: ["image": ["extract-data": true]]))
        #expect(aiIDs(json, [url("/a.png")]) == nil)
    }

    @Test func archivesShowExtractAndNotZip() {
        #expect(ToolVisibility.defaults.isShown("extract-archive", for: .archive))
        #expect(!ToolVisibility.defaults.isShown("make-zip", for: .archive))
    }

    /// P61: a file tool is shown when one kind in the drag shows it, so a photo with a zip (or a folder with a zip)
    /// still gets a Tools page and the wheel opens; Extract, an engine tool, still needs every file to be an archive.
    @Test func aFileToolShownForOneKindOfTheDragIsShown() throws {
        let b = builder(availableEdges: everyToolEdges + ["zip>zip:extract"])
        let photoAndZip = b.pages(for: [url("/a.txt"), url("/b.zip")])
        #expect(photoAndZip.map(\.kind).contains(.tools))
        #expect(ids(photoAndZip, .tools) == fileToolsOfASparseKind)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pomelo-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Different parents, so no Open in Terminal.
        #expect(ids(b.pages(for: [folder, url("/b.zip")]), .tools) == fileToolsOfASparseKind.filter { $0 != "action.openTerminal" })
        #expect(ids(b.pages(for: [url("/b.zip")]), .tools) == ["preset.extract-archive"] + fileToolsOfAnArchive)
    }

    /// P34: an archive's Tools page is Extract and the Shelf; zipping a zip again is never offered.
    @Test func aZipsToolsPageHoldsOnlyExtract() {
        let b = builder(availableEdges: ["zip>zip:extract", "zip>tgz", "zip>tar"])
        #expect(ids(b.pages(for: [url("/a.zip")]), .tools) == ["preset.extract-archive"] + fileToolsOfAnArchive)
    }

    @Test func archivesConvertInTheirDefaultOrder() {
        #expect(WheelContentBuilder.defaultOrder[.archive] == ["zip", "tgz", "tar"])
        let b = builder(availableEdges: ["zip>tar", "zip>tgz", "tgz>zip", "tgz>tar", "rar>tar", "rar>tgz", "rar>zip"])
        #expect(ids(b.pages(for: [url("/a.rar")]), .convert) == ["convert.zip", "convert.tgz", "convert.tar"])
        #expect(ids(b.pages(for: [url("/a.zip")]), .convert) == ["convert.tgz", "convert.tar"])
        #expect(ids(b.pages(for: [url("/a.tgz")]), .convert) == ["convert.zip", "convert.tar"])
    }

    @Test func anUnknownFileOrAFolderGetsOnlyFileTools() throws {
        let b = builder(availableEdges: everyToolEdges)
        #expect(ids(b.pages(for: [url("/a.xyz")]), .tools) == fileToolsOfASparseKind)
        #expect(b.pages(for: [url("/a.xyz")]).map(\.kind) == [.tools])
        let folder = FileManager.default.temporaryDirectory.appending(path: "pomelo-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(b.pages(for: [folder]).map(\.kind) == [.tools])
        #expect(ids(b.pages(for: [folder]), .tools) == fileToolsOfASparseKind)
    }

    @Test func aMixedDragShowsEngineToolsShownForEveryKind() {
        let b = builder(availableEdges: everyToolEdges)
        #expect(toolIDs(b, [url("/a.png"), url("/b.mp4")]) == ["preset.compress", "action.shelf"])
    }

    @Test func hiddenToolsAppearOnlyOnceEnabled() {
        let plain = builder(availableEdges: everyToolEdges)
        #expect(!toolIDs(plain, [url("/a.png")]).contains("action.copyPaths"))

        let copyForImages = builder(availableEdges: everyToolEdges, visibility: ToolVisibility(overrides: ["image": ["copy-paths": true]]))
        #expect(toolIDs(copyForImages, [url("/a.png")]).contains("action.copyPaths"))
        #expect(!toolIDs(copyForImages, [url("/a.mp4")]).contains("action.copyPaths"))

        let noVideoCompress = builder(availableEdges: everyToolEdges, visibility: ToolVisibility(overrides: ["video": ["compress": false]]))
        #expect(!toolIDs(noVideoCompress, [url("/a.mp4")]).contains("preset.compress"))
        #expect(toolIDs(noVideoCompress, [url("/a.png")]).contains("preset.compress"))
    }

    @Test func noKindShowsMoreThanEightByDefault() {
        let b = builder(availableEdges: everyToolEdges)
        for file in ["/a.png", "/a.mp4", "/a.m4a", "/a.pdf", "/a.txt", "/a.xyz"] {
            #expect(toolIDs(b, [url(file), url(file.replacingOccurrences(of: "/a.", with: "/b."))]).count <= 8)
        }
    }

    /// R27: the Shelf keeps the last slot, so every other tool switched on fills only seven.
    @Test func enablingEveryToolStillShowsEight() {
        var overrides: [String: [String: Bool]] = [:]
        for kind in FormatCategory.allCases {
            overrides[kind.rawValue] = Dictionary(uniqueKeysWithValues: ToolCatalog.all.map { ($0.id, true) })
        }
        let b = builder(availableEdges: everyToolEdges, visibility: ToolVisibility(overrides: overrides))
        #expect(toolIDs(b, [url("/a.mp4"), url("/b.mp4")]) == [
            "preset.compress", "preset.compress-more", "editor.compress-to-size", "editor.resize", "editor.rotate",
            "preset.extract-audio", "preset.remove-audio", "action.shelf",
        ])
    }

    /// R27: an override from before the custom wheel (Remove metadata and Half size on images) can't push the Shelf
    /// off the Tools page.
    @Test func anOldOverrideNeverPushesTheShelfOff() {
        let old = ToolVisibility(overrides: ["image": ["strip-metadata": true, "half-size": true]])
        let b = builder(availableEdges: everyToolEdges, visibility: old)
        let tools = toolIDs(b, [url("/a.png")])
        #expect(tools.count == 8)
        #expect(tools.last == "action.shelf")
        #expect(tools.filter { $0 == "action.shelf" }.count == 1)
        let off = builder(availableEdges: everyToolEdges,
                          visibility: ToolVisibility(overrides: ["image": ["strip-metadata": true, "half-size": true,
                                                                           "shelf": false]]))
        #expect(toolIDs(off, [url("/a.png")]).count == 8)
        #expect(!toolIDs(off, [url("/a.png")]).contains("action.shelf"))
    }

    /// R27: the Shelf ends the page even when a file tool after it in the catalog is switched on.
    @Test func theShelfEndsThePageAfterLaterFileTools() {
        let b = builder(availableEdges: everyToolEdges, visibility: ToolVisibility(overrides: ["pdf": ["copy-paths": true]]))
        #expect(toolIDs(b, [url("/a.pdf")]).suffix(2) == ["action.copyPaths", "action.shelf"])
    }

    @Test func openInTerminalNeedsOneFolder() {
        let on = ToolVisibility(overrides: ["pdf": ["open-in-terminal": true]])
        let b = builder(availableEdges: everyToolEdges, visibility: on)
        #expect(toolIDs(b, [url("/x/a.pdf"), url("/x/b.pdf")]).contains("action.openTerminal"))
        #expect(!toolIDs(b, [url("/x/a.pdf"), url("/y/b.pdf")]).contains("action.openTerminal"))
    }

    @Test func speedToolNameFollowsItsOption() {
        var settings = AppSettings()
        settings.toolOptions["speed-up"] = PresetOptions(speed: 1.5)
        let b = builder(availableEdges: everyToolEdges, settings: settings)
        #expect(b.tool(id: "speed-up")?.name == "Speed 1.5\u{00D7}")
        #expect(b.tool(id: "speed-up")?.nameSuffix == "1.5x")
        let slice = b.pages(for: [url("/a.m4a")]).first { $0.kind == .tools }?.slices.first { $0.id == "preset.speed-up" }
        #expect(slice?.title == "Speed 1.5\u{00D7}")
        #expect(b.tool(id: "slow-down")?.name == "Speed 0.5\u{00D7}")
        #expect(b.tool(id: "slow-down")?.nameSuffix == "0.5x")
        let defaults = builder(availableEdges: everyToolEdges)
        #expect(defaults.tool(id: "speed-up")?.name == "Speed 2\u{00D7}")
        #expect(defaults.tool(id: "speed-up")?.nameSuffix == "2x")
    }

    // MARK: Editors (P27, P31)

    private func slices(_ b: WheelContentBuilder, _ files: [URL]) -> [WheelSlice] {
        b.pages(for: files).first { $0.kind == .tools }?.slices ?? []
    }

    @Test func editorToolsAreToolsPageSlices() throws {
        let b = builder(availableEdges: ["mov>mp4"] + everyToolEdges)
        let pages = b.pages(for: [url("/a.mov")])
        #expect(pages.map(\.kind) == [.convert, .tools, .ai])
        #expect(ids(pages, .tools) == [
            "editor.trim", "editor.crop", "preset.compress", "editor.compress-to-size", "editor.rotate",
            "preset.extract-audio", "preset.remove-audio", "action.shelf",
        ])
        let tools = try #require(pages.first { $0.kind == .tools }).slices
        #expect(tools[0].kind == .editor(id: "trim") && tools[0].title == "Trim\u{2026}")
        #expect(tools[0].symbol == "timeline.selection" && tools[0].isEnabled)
        #expect(tools[1].kind == .editor(id: "crop") && tools[1].title == "Crop\u{2026}")
        #expect(tools[2].kind == .preset(id: "compress"))
        #expect(tools[3].kind == .editor(id: "compress-to-size"))
        #expect(tools[4].kind == .editor(id: "rotate") && tools[7].kind == .action(.shelf))
    }

    @Test func editorTitlesEndWithAnEllipsis() {
        let editors = ToolCatalog.all.filter { $0.editor != nil }
        #expect(editors.map(\.id) == [
            "trim", "split-video", "crop", "compress-to-size", "resize", "rotate", "redact", "organize-pages",
        ])
        for info in ToolCatalog.all {
            #expect(info.name.hasSuffix("\u{2026}") == (info.editor != nil), "\(info.id)")
        }
        for preset in ToolCatalog.presets(settings: AppSettings()) {
            #expect(preset.name.hasSuffix("\u{2026}") == (ToolCatalog.info(preset.id)?.editor != nil), "\(preset.id)")
        }
    }

    @Test func editorsCountTowardTheEightSlots() {
        var overrides: [String: [String: Bool]] = [:]
        for kind in FormatCategory.allCases {
            overrides[kind.rawValue] = Dictionary(uniqueKeysWithValues: ToolCatalog.all.map { ($0.id, true) })
        }
        let b = builder(availableEdges: everyToolEdges, visibility: ToolVisibility(overrides: overrides))
        #expect(slices(b, [url("/a.mp4")]).map(\.id) == [
            "editor.trim", "editor.split-video", "editor.crop", "preset.compress", "preset.compress-more",
            "editor.compress-to-size", "editor.resize", "action.shelf",
        ])
    }

    @Test func singleFileEditorsNeedOneFile() {
        let b = builder(availableEdges: everyToolEdges)
        let two = slices(b, [url("/a.mov"), url("/b.mov")]).map(\.id)
        #expect(!two.contains("editor.trim") && !two.contains("editor.crop") && !two.contains("editor.split-video"))
        #expect(two.contains("editor.compress-to-size"))
        let pdfs = slices(b, [url("/a.pdf"), url("/b.pdf")]).map(\.id)
        #expect(!pdfs.contains("editor.organize-pages") && pdfs.contains("editor.compress-to-size"))
        let photos = slices(b, [url("/a.jpg"), url("/b.jpg")]).map(\.id)
        #expect(!photos.contains("editor.crop") && !photos.contains("editor.redact"))
    }

    @Test func editorsNeedOneKind() {
        let on = ToolVisibility(overrides: ["image": ["compress-to-size": true]])
        let b = builder(availableEdges: everyToolEdges, visibility: on)
        let mixed = slices(b, [url("/a.jpg"), url("/b.pdf")]).map(\.id)
        #expect(!mixed.contains("editor.compress-to-size"))
        #expect(mixed.contains("preset.compress"))
        #expect(slices(b, [url("/a.jpg"), url("/b.jpg")]).map(\.id).contains("editor.compress-to-size"))
    }

    @Test func editorHintIsTheHubSubtitle() throws {
        let files = [url("/a.mov")]
        let b = builder(availableEdges: everyToolEdges)
        let all = slices(b, files)
        let trim = try #require(all.first { $0.id == "editor.trim" })
        let preview = b.preview(for: trim, files: files)
        #expect(preview.title == "Trim\u{2026}" && preview.subtitle == "Choose the part to keep" && preview.warning == nil)
        let hints = ["editor.crop": "Choose the area to keep", "editor.compress-to-size": "Choose a size",
                     "editor.rotate": "Choose a turn"]
        for (id, hint) in hints {
            #expect(b.preview(for: try #require(all.first { $0.id == id }), files: files).subtitle == hint, "\(id)")
        }
        let image = [url("/a.png")]
        let resize = try #require(slices(b, image).first { $0.id == "editor.resize" })
        #expect(b.preview(for: resize, files: image).subtitle == "Choose a size")
        let pdf = [url("/a.pdf")]
        let organize = try #require(slices(b, pdf).first { $0.id == "editor.organize-pages" })
        #expect(b.preview(for: organize, files: pdf).subtitle == "Reorder, rotate or remove pages")
        let redact = try #require(slices(b, [url("/a.jpg")]).first { $0.id == "editor.redact" })
        #expect(b.preview(for: redact, files: [url("/a.jpg")]).subtitle == "Choose what to hide")
    }

    @Test func anEditorSliceNeverGetsASizeEstimate() throws {
        let png = url("/x/big.png")
        let facts = [png: SourceFacts(bytes: 20_000_000, pixelWidth: 4000, pixelHeight: 3000)]
        let b = builder(availableEdges: everyToolEdges)
        let crop = try #require(slices(b, [png]).first { $0.id == "editor.crop" })
        #expect(b.preview(for: crop, files: [png], facts: facts).subtitle == "Choose the area to keep")
    }

    @Test func aDisabledEditorShowsItsInstallHint() throws {
        let b = builder(availableEdges: [], allEdges: ["mp3>mp3:trim@ffmpeg"],
                        hints: ["ffmpeg": "FFmpeg|brew install ffmpeg"])
        let files = [url("/a.mp3")]
        let trim = try #require(slices(b, files).first { $0.id == "editor.trim" })
        #expect(trim.isEnabled == false)
        #expect(trim.disabledReason == "Needs FFmpeg. Install it with brew install ffmpeg.")
        let preview = b.preview(for: trim, files: files)
        #expect(preview.title == "Trim\u{2026}")
        #expect(preview.subtitle == "Needs FFmpeg. Install it with brew install ffmpeg.")
    }

    @Test func anEditorNoEngineOffersIsNotShown() {
        let b = builder(availableEdges: [], allEdges: [])
        #expect(slices(b, [url("/a.mov")]).map(\.id) == ["action.shelf"])
    }

    @Test func hiddenEditorsAppearOnlyOnceEnabled() {
        let off = builder(availableEdges: everyToolEdges,
                          visibility: ToolVisibility(overrides: ["video": ["trim": false]]))
        #expect(!slices(off, [url("/a.mov")]).map(\.id).contains("editor.trim"))
        #expect(slices(off, [url("/a.m4a")]).map(\.id).contains("editor.trim"))

        let hidden = builder(availableEdges: everyToolEdges,
                             visibility: ToolVisibility(overrides: ["image": ["compress-to-size": false]]))
        #expect(!slices(hidden, [url("/a.jpg")]).map(\.id).contains("editor.compress-to-size"))
        let plain = builder(availableEdges: everyToolEdges)
        #expect(slices(plain, [url("/a.jpg")]).map(\.id).contains("editor.compress-to-size"))
    }

    @Test func aToolWithAMissingEngineIsDisabledWithItsHint() {
        let b = builder(availableEdges: [], allEdges: ["m4a>m4a:normalize-volume@ffmpeg"],
                        hints: ["ffmpeg": "FFmpeg|brew install ffmpeg"])
        let slice = b.pages(for: [url("/a.m4a")]).first { $0.kind == .tools }?.slices
            .first { $0.id == "preset.normalize-volume" }
        #expect(slice?.isEnabled == false)
        #expect(slice?.disabledReason == "Needs FFmpeg. Install it with brew install ffmpeg.")
        let preview = b.preview(for: slice!, files: [url("/a.m4a")])
        #expect(preview.title == "Normalize volume")
        #expect(preview.subtitle == "Needs FFmpeg. Install it with brew install ffmpeg.")
    }

    @Test func anUnsupportedEngineShowsItsReasonVerbatim() throws {
        let reason = "Apple Intelligence isn't turned on."
        let b = builder(availableEdges: [], allEdges: ["m4a>m4a:normalize-volume@old", "m4a>mp3@old"],
                        unsupported: ["old": reason])
        let files = [url("/a.m4a")]
        let tool = try #require(slices(b, files).first { $0.id == "preset.normalize-volume" })
        #expect(tool.isEnabled == false && tool.disabledReason == reason)
        #expect(b.preview(for: tool, files: files).subtitle == reason)
        let convert = b.pages(for: files).first { $0.kind == .convert }
        let mp3 = try #require(convert?.slices.first { $0.id == "convert.mp3" })
        #expect(mp3.isEnabled == false && mp3.disabledReason == reason)
    }

    /// Installing the missing engine would not make the route run, so the reason that can't be fixed wins.
    @Test func anUnsupportedEngineWinsOverAMissingOneOnTheSameRoute() throws {
        let b = builder(availableEdges: [], allEdges: ["m4a>flac@ffmpeg", "flac>wav@old"],
                        hints: ["ffmpeg": "FFmpeg|brew install ffmpeg"], unsupported: ["old": "Needs macOS 26."])
        let wav = try #require(b.pages(for: [url("/a.m4a")]).first { $0.kind == .convert }?.slices
            .first { $0.id == "convert.wav" })
        #expect(wav.disabledReason == "Needs macOS 26.")
    }

    @Test func aLoneCSVOrJSONIsDataWithTheFileTools() {
        let b = builder(availableEdges: everyToolEdges)
        for name in ["/a.csv", "/a.json"] {
            #expect(b.pages(for: [url(name)]).map(\.kind) == [.tools], "\(name)")
            #expect(toolIDs(b, [url(name)]) == fileToolsOfASparseKind, "\(name)")
        }
        // Its kind is data, not other: the data kind's own switches hide every file tool.
        let hidden = builder(availableEdges: [], visibility: ToolVisibility(overrides: ["data": [
            "make-zip": false, "shelf": false, "copy-paths": false, "copy-files": false, "reveal-in-finder": false,
            "open-in-terminal": false,
        ]]))
        #expect(hidden.pages(for: [url("/a.csv")]).isEmpty)
    }

    @Test func aToolNoEngineOffersIsNotShown() {
        let b = builder(availableEdges: [], allEdges: [])
        #expect(toolIDs(b, [url("/a.m4a")]) == ["action.makeZip", "action.shelf"])
    }

    @Test func combineToolsNeedTwoFiles() {
        let b = builder(availableEdges: everyToolEdges)
        #expect(!toolIDs(b, [url("/a.pdf")]).contains("preset.merge-pdfs"))
        #expect(toolIDs(b, [url("/a.pdf"), url("/b.pdf")]).contains("preset.merge-pdfs"))
        #expect(!toolIDs(b, [url("/a.png")]).contains("preset.images-to-pdf"))
    }

    @Test func combineToolsNeedOneCategory() {
        let b = builder(availableEdges: everyToolEdges)
        let mixed = toolIDs(b, [url("/a.pdf"), url("/b.png")])
        #expect(!mixed.contains("preset.merge-pdfs") && !mixed.contains("preset.images-to-pdf"))
    }

    @Test func toolPreviewWarnsWhenItReplacesTheOriginal() {
        let files = [url("/a.mp4")]
        let b = builder(availableEdges: everyToolEdges, replacesOriginals: true)
        let slices = b.pages(for: files).first { $0.kind == .tools }!.slices
        let compress = slices.first { $0.id == "preset.compress" }!
        let extract = slices.first { $0.id == "preset.extract-audio" }!
        #expect(b.preview(for: compress, files: files).warning == "Replaces the original")
        #expect(b.preview(for: extract, files: files).warning == nil)
        let off = builder(availableEdges: everyToolEdges)
        #expect(off.preview(for: compress, files: files).warning == nil)
    }

    /// P273: editors and conversions that keep the kind of file warn too; a conversion to another kind doesn't.
    @Test func editorAndSameKindConversionPreviewsWarnWhenTheyReplace() {
        let image = [url("/a.heic")]
        let b = builder(availableEdges: everyToolEdges + ["heic>jpg", "heic>pdf"],
                        replacesOriginals: true)
        let crop = WheelSlice(id: "editor.crop", title: "Crop\u{2026}", symbol: "crop", kind: .editor(id: "crop"))
        let jpg = WheelSlice(id: "convert.jpg", title: "JPG", symbol: "photo", kind: .convert("jpg"))
        let pdf = WheelSlice(id: "convert.pdf", title: "PDF", symbol: "doc", kind: .convert("pdf"))
        #expect(b.preview(for: crop, files: image).warning == "Replaces the original")
        #expect(b.preview(for: jpg, files: image).warning == "Replaces the original")
        #expect(b.preview(for: pdf, files: image).warning == nil)
        let psd = WheelSlice(id: "convert.png", title: "PNG", symbol: "photo", kind: .convert("png"))
        let layered = builder(availableEdges: ["psd>png"], replacesOriginals: true)
        #expect(layered.preview(for: psd, files: [url("/art.psd")]).warning == nil)
        let off = builder(availableEdges: everyToolEdges + ["heic>jpg"])
        #expect(off.preview(for: crop, files: image).warning == nil)
        #expect(off.preview(for: jpg, files: image).warning == nil)
    }

    @Test func toolLookupUsesTheConfiguredOptions() {
        var settings = AppSettings()
        settings.toolOptions["compress"] = PresetOptions(quality: 0.55)
        let b = builder(availableEdges: everyToolEdges, settings: settings)
        #expect(b.tool(id: "compress")?.options.quality == 0.55)
        #expect(builder(availableEdges: []).tool(id: "compress")?.options.quality == 0.7)
        #expect(b.tool(id: "nope") == nil)
    }
}

/// The size estimate under the hub's title.
@Suite struct WheelContentEstimateTests {
    private static let png = url("/x/big.png")
    private static let facts = [png: SourceFacts(bytes: 20_000_000, pixelWidth: 4000, pixelHeight: 3000)]

    private static func slice(_ id: String, in b: WheelContentBuilder, files: [URL]) -> WheelSlice {
        b.pages(for: files).flatMap(\.slices).first { $0.id == id }!
    }

    @Test func previewShowsTheEstimateAsTheSubtitle() {
        let b = builder(availableEdges: ["png>jpg", "png>png:x"])
        let jpg = Self.slice("convert.jpg", in: b, files: [Self.png])
        let preview = b.preview(for: jpg, files: [Self.png], facts: Self.facts)
        #expect(preview.title == "big.jpg")
        #expect(preview.subtitle == SizeEstimate.text(estimate: 3_000_000, source: 20_000_000))
        #expect(preview.subtitle?.hasSuffix("85% smaller") == true)
        // Without facts there is no subtitle.
        #expect(b.preview(for: jpg, files: [Self.png]).subtitle == nil)
    }

    @Test func aToolPreviewShowsItsEstimate() {
        let b = builder(availableEdges: ["png>png"], visibility: halfAndZip)
        let half = Self.slice("preset.half-size", in: b, files: [Self.png])
        let subtitle = b.preview(for: half, files: [Self.png], facts: Self.facts).subtitle
        #expect(subtitle == SizeEstimate.text(estimate: 6_000_000, source: 20_000_000))
    }

    @Test func theDisabledReasonAndTheMultiPageHintComeFirst() {
        let missing = builder(availableEdges: ["png>jpg"], allEdges: ["png>jpg", "png>webp@cwebp"],
                              hints: ["cwebp": "cwebp|brew install webp"])
        let webp = Self.slice("convert.webp", in: missing, files: [Self.png])
        #expect(missing.preview(for: webp, files: [Self.png], facts: Self.facts).subtitle
            == "Needs cwebp. Install it with brew install webp.")

        let b = builder(availableEdges: ["pdf>jpg"])
        let pdf = url("/x/doc.pdf")
        let jpg = Self.slice("convert.jpg", in: b, files: [pdf])
        let facts = [pdf: SourceFacts(bytes: 1_000_000, pixelWidth: 600, pixelHeight: 800)]
        #expect(b.preview(for: jpg, files: [pdf], facts: facts).subtitle == "One image per page")
    }

    @Test func noEstimateForActionsPDFsOrAFileWithoutFacts() {
        let b = builder(availableEdges: ["png>jpg", "png>png"], visibility: halfAndZip)
        let zip = Self.slice("action.makeZip", in: b, files: [Self.png])
        #expect(b.preview(for: zip, files: [Self.png], facts: Self.facts).subtitle == nil)
        let jpg = Self.slice("convert.jpg", in: b, files: [Self.png])
        #expect(b.preview(for: jpg, files: [Self.png], facts: [url("/x/other.png"): SourceFacts(bytes: 1)]).subtitle == nil)
    }

    @Test func estimatesOnlyCountTheFilesThatConvert() {
        let b = builder(availableEdges: ["png>jpg"])
        let already = url("/x/photo.jpg")
        let files = [Self.png, already]
        let jpg = Self.slice("convert.jpg", in: b, files: files)
        // The JPEG is not converted, so its missing facts do not matter and its bytes are not counted.
        let subtitle = b.preview(for: jpg, files: files, facts: Self.facts).subtitle
        #expect(subtitle == SizeEstimate.text(estimate: 3_000_000, source: 20_000_000))
    }
}
