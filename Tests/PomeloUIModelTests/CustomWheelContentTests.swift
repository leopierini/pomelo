import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

/// Half size and Make Zip left the image wheel's defaults (P202) but stay catalog tools one switch away.
private let halfAndZip = ToolVisibility(overrides: ["image": ["half-size": true, "make-zip": true]])

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

private func urls(_ paths: String...) -> [URL] { paths.map(url) }

private extension WheelContentBuilder {
    func wheelKey(for files: [URL]) -> WheelKey? { wheelKey(forFormats: files.map { formats.format(for: $0) }) }
}

private func wheel(_ pages: (String, [String])...) -> CustomWheel {
    CustomWheel(pages: pages.map { CustomPage(name: $0.0, slots: $0.1) })
}

private func settings(_ wheels: [String: CustomWheel]) -> AppSettings {
    var settings = AppSettings()
    settings.wheels = wheels
    return settings
}

private func builder(_ wheels: [String: CustomWheel], availableEdges: [String], allEdges: [String]? = nil,
                     hints: [EngineID: String] = [:]) -> WheelContentBuilder {
    WheelFixtures.builder(availableEdges: availableEdges, allEdges: allEdges, hints: hints, settings: settings(wheels))
}

private func slice(_ pages: [WheelPage], _ id: String) -> WheelSlice? {
    pages.lazy.flatMap(\.slices).first { $0.id == id }
}

@Suite struct CustomWheelContentTests {
    // MARK: Which wheel (P175)

    @Test func wheelChoiceFollowsP175() {
        let wheels = ["kind.image": wheel(("Images", ["convert.jpg"])), "format.png": wheel(("PNG", ["convert.jpg"]))]
        let b = builder(wheels, availableEdges: ["png>jpg", "jpg>png", "pdf>png"])
        #expect(b.wheelKey(for: urls("/a.png")) == .format("png"))
        #expect(b.wheelKey(for: urls("/a.png", "/b.png")) == .format("png"))
        #expect(b.wheelKey(for: urls("/a.png", "/b.jpg")) == .kind(.image))
        #expect(b.wheelKey(for: urls("/b.jpg")) == .kind(.image))
        #expect(b.wheelKey(for: urls("/a.png", "/notes.xyz")) == nil)
        #expect(b.wheelKey(for: urls("/a.png", "/b.pdf")) == nil)
        #expect(b.wheelKey(for: []) == nil)

        #expect(b.pages(for: urls("/a.png")).map(\.title) == ["PNG"])
        #expect(b.pages(for: urls("/a.png", "/b.jpg")).map(\.title) == ["Images"])
        #expect(b.pages(for: urls("/a.png", "/b.pdf")).map(\.id) == ["convert", "tools"])

        let formatOnly = builder(["format.png": wheels["format.png"]!], availableEdges: ["png>jpg", "jpg>png"])
        #expect(formatOnly.wheelKey(for: urls("/b.jpg")) == nil)
        #expect(formatOnly.wheelKey(for: urls("/a.png", "/b.jpg")) == nil)

        let other = builder(["kind.other": wheel(("Other", ["action.makeZip"]))], availableEdges: [])
        #expect(other.wheelKey(for: urls("/a.xyz", "/b.xyz")) == .kind(.other))
    }

    // MARK: Slots stay in place (P176, P178)

    @Test func customPagesKeepEverySlot() throws {
        let mine = wheel(("Mine", ["convert.png", "preset.merge-pdfs", "preset.compress", "action.makeZip"]))
        let b = builder(["kind.pdf": mine], availableEdges: ["pdf>png"] + WheelFixtures.everyToolEdges)
        let pages = b.pages(for: urls("/a.pdf"))
        #expect(pages.map(\.id) == ["custom.0"])
        let page = try #require(pages.first)
        #expect(page.title == "Mine" && page.kind == nil)
        #expect(page.slices.map(\.id) == ["convert.png", "preset.merge-pdfs", "preset.compress", "action.makeZip"])
        let merge = try #require(slice(pages, "preset.merge-pdfs"))
        #expect(!merge.isEnabled && merge.disabledReason == "Needs two or more files.")
        #expect(page.slices.filter(\.isEnabled).map(\.id) == ["convert.png", "preset.compress", "action.makeZip"])
        #expect(page.slices.filter(\.isEnabled).allSatisfy { $0.disabledReason == nil })
        #expect(slice(b.pages(for: urls("/a.pdf", "/b.pdf")), "preset.merge-pdfs")?.isEnabled == true)
    }

    @Test func slicesLookAsOnTheBuiltInWheel() throws {
        let edges = ["png>jpg", "png>pdf"] + WheelFixtures.everyToolEdges
        let mine = wheel(("Mine", ["convert.jpg", "editor.crop", "preset.half-size", "action.makeZip"]))
        let custom = builder(["kind.image": mine], availableEdges: edges).pages(for: urls("/a.png"))
        // Seven tools plus the two switched on would overflow the built-in Tools page's eight slots.
        let room = ToolVisibility(overrides: ["image": ["half-size": true, "make-zip": true, "rotate": false,
                                                        "resize": false]])
        let builtIn = WheelFixtures.builder(availableEdges: edges, visibility: room).pages(for: urls("/a.png"))
        for id in ["convert.jpg", "editor.crop", "preset.half-size", "action.makeZip"] {
            #expect(slice(custom, id) == slice(builtIn, id), "\(id)")
        }
    }

    @Test func ownFormatGreys() throws {
        let b = builder(["kind.image": wheel(("Mine", ["convert.png", "convert.jpg"]))],
                        availableEdges: ["png>jpg", "jpg>png"])
        let one = b.pages(for: urls("/a.png"))
        let png = try #require(slice(one, "convert.png"))
        #expect(!png.isEnabled && png.disabledReason == "Already a PNG file.")
        #expect(slice(one, "convert.jpg")?.isEnabled == true)
        let both = b.pages(for: urls("/a.png", "/b.jpg"))
        #expect(both.first?.slices.map(\.isEnabled) == [true, true])
        let three = b.pages(for: urls("/a.png", "/b.png", "/c.png"))
        #expect(slice(three, "convert.png")?.disabledReason == "Already PNG files.")
    }

    /// P183 (amended by ruling 17): "an" before a vowel, and before an initialism read with a vowel sound (an MP4,
    /// an SVG, an HTML).
    @Test func ownFormatReasonReadsAsASentence() {
        let ids = ["avif", "mp4", "heic", "aiff", "ico", "xlsx", "exr", "m4a", "svg", "rtf", "png", "flac", "webp",
                   "jpg", "gif", "tiff", "mkv", "docx", "html", "txt"]
        let mine = wheel(("Mine", ids.map { "convert.\($0)" }))
        let b = builder(["kind.image": mine, "kind.video": mine, "kind.audio": mine, "kind.document": mine,
                         "kind.text": mine], availableEdges: [])
        func reason(_ id: String) -> String? {
            let ext = FormatRegistry.builtIn.format(id: FormatID(id))!.extensions[0]
            return slice(b.pages(for: urls("/a.\(ext)")), "convert.\(id)")?.disabledReason
        }
        let expected = [
            "avif": "Already an AVIF file.", "mp4": "Already an MP4 file.", "heic": "Already a HEIC file.",
            "aiff": "Already an AIFF file.", "ico": "Already an ICO file.", "xlsx": "Already an Excel file.",
            "exr": "Already an OpenEXR file.", "m4a": "Already an M4A file.", "svg": "Already an SVG file.",
            "rtf": "Already an RTF file.", "png": "Already a PNG file.", "flac": "Already a FLAC file.",
            "webp": "Already a WebP file.", "jpg": "Already a JPEG file.", "gif": "Already a GIF file.",
            "tiff": "Already a TIFF file.", "mkv": "Already a Matroska file.", "docx": "Already a Word file.",
            "html": "Already an HTML file.", "txt": "Already a Plain Text file.",
        ]
        for id in ids { #expect(reason(id) == expected[id], "\(id)") }
    }

    @Test func reasonsForFilesAndFolders() {
        let mine = wheel(("Mine", ["editor.crop", "action.openTerminal", "convert.mp3", "preset.normalize-volume"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg"] + WheelFixtures.everyToolEdges)
        func reason(_ id: String, _ files: [URL]) -> String? {
            slice(b.pages(for: files), id).flatMap { $0.isEnabled ? nil : $0.disabledReason }
        }
        #expect(reason("editor.crop", urls("/x/a.png", "/x/b.png")) == "Needs one file.")
        #expect(reason("editor.crop", urls("/x/a.png")) == nil)
        #expect(reason("action.openTerminal", urls("/x/a.png", "/y/b.png")) == "Needs files from one folder.")
        #expect(reason("action.openTerminal", urls("/x/a.png", "/x/b.png")) == nil)
        #expect(reason("convert.mp3", urls("/x/a.png")) == "Can't convert this file.")
        #expect(reason("convert.mp3", urls("/x/a.png", "/x/b.png")) == "Can't convert these files.")
        #expect(reason("preset.normalize-volume", urls("/x/a.png")) == "Doesn't work on this file.")
        #expect(reason("preset.normalize-volume", urls("/x/a.png", "/x/b.png")) == "Doesn't work on these files.")
    }

    @Test func missingEngineGreysWithHint() throws {
        let available = ["png>jpg"]
        let all = ["png>jpg", "png>webp@cwebp", "png>png@cwebp"]
        let hints: [EngineID: String] = ["cwebp": "cwebp|brew install webp"]
        let b = builder(["kind.image": wheel(("Mine", ["convert.webp", "preset.half-size"]))],
                        availableEdges: available, allEdges: all, hints: hints)
        let builtIn = WheelFixtures.builder(availableEdges: available, allEdges: all, hints: hints,
                                            visibility: halfAndZip).pages(for: urls("/a.png"))
        let pages = b.pages(for: urls("/a.png"))
        let expected = WheelContentBuilder.missingEngineReason(name: "cwebp", hint: "brew install webp",
                                                               installable: false)
        for id in ["convert.webp", "preset.half-size"] {
            let custom = try #require(slice(pages, id))
            #expect(!custom.isEnabled && custom.disabledReason == expected, "\(id)")
            #expect(custom == slice(builtIn, id), "\(id)")
        }
    }

    /// Review Focus 2: a vanished format or tool keeps its place, greyed, on the wheel and in the editor.
    @Test func unknownSlotStaysGreyed() {
        let mine = wheel(("Mine", ["convert.jpg", "convert.qoi", "preset.gone", "action.makeZip"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg"] + WheelFixtures.everyToolEdges)
        for pages in [b.pages(for: urls("/a.png")), b.editorPages(for: mine)] {
            #expect(pages.first?.slices.map(\.id) == ["convert.jpg", "convert.qoi", "preset.gone", "action.makeZip"])
            #expect(pages.first?.slices.map(\.isEnabled) == [true, false, false, true])
            for id in ["convert.qoi", "preset.gone"] {
                #expect(slice(pages, id)?.disabledReason == "Not available.", "\(id)")
            }
        }
        #expect(WheelContentBuilder.unavailableReason == "Not available.")
    }

    /// An empty slot id from a hand-edited blob resolves to nothing: kept in place, greyed.
    @Test func emptySlotIDStaysGreyed() {
        let mine = wheel(("Mine", ["", "action.makeZip"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg"])
        for pages in [b.pages(for: urls("/a.png")), b.editorPages(for: mine)] {
            #expect(pages.first?.slices.map(\.id) == ["", "action.makeZip"])
            #expect(pages.first?.slices.map(\.isEnabled) == [false, true])
            #expect(pages.first?.slices.first?.disabledReason == "Not available.")
        }
    }

    @Test func emptyCustomPageSkipped() {
        let mine = wheel(("A", []), ("B", ["action.makeZip"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg"])
        #expect(b.pages(for: urls("/a.png")).map(\.id) == ["custom.1"])
        #expect(b.pages(for: urls("/a.png")).map(\.title) == ["B"])
        // The editor draws every page, so an empty one can still be filled.
        #expect(b.editorPages(for: mine).map(\.id) == ["custom.0", "custom.1"])
    }

    @Test func allGreyedPageStillShown() {
        let b = builder(["kind.pdf": wheel(("Merge", ["preset.merge-pdfs"]))],
                        availableEdges: WheelFixtures.everyToolEdges)
        let pages = b.pages(for: urls("/a.pdf"))
        #expect(pages.map(\.id) == ["custom.0"])
        #expect(pages.first?.slices.map(\.isEnabled) == [false])
    }

    @Test func greyedOwnFormatPreview() throws {
        let b = builder(["kind.image": wheel(("Mine", ["convert.png", "convert.jpg"]))],
                        availableEdges: ["png>jpg", "jpg>png"])
        let files = urls("/a.png")
        let png = try #require(slice(b.pages(for: files), "convert.png"))
        let preview = b.preview(for: png, files: files)
        #expect(preview.title == "PNG")
        #expect(preview.subtitle == "Already a PNG file.")
        let jpg = try #require(slice(b.pages(for: files), "convert.jpg"))
        #expect(b.preview(for: jpg, files: files).title == "a.jpg")
    }

    /// Review Focus 3: a customized wheel plans over the same route cache as the built-in one.
    @Test func customizedWheelSearchesOncePerFormat() {
        let mine = wheel(("Mine", ["convert.jpg", "convert.webp", "preset.compress", "preset.half-size"]),
                         ("More", ["convert.heic", "editor.crop", "action.makeZip"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg", "png>heic"] + WheelFixtures.everyToolEdges)
        let files = (0..<300).map { url("/x/\($0).png") }
        let pages = b.pages(for: files)
        #expect(pages.map(\.id) == ["custom.0", "custom.1"])
        #expect(b.routeSearches == 1)
    }

    // MARK: The first edit's copy (P179)

    @Test func builtInLayoutForPDF() {
        let b = WheelFixtures.builder(availableEdges: WheelFixtures.everyToolEdges
            + ["pdf>png", "pdf>jpg", "pdf>txt", "pdf>docx", "pdf>html"])
        let layout = b.builtInLayout(for: .pdf)
        #expect(layout.pages.map(\.name) == ["Convert", "Tools", "AI"])
        #expect(layout.pages[0].slots == ["convert.docx", "convert.jpg", "convert.png", "convert.txt", "convert.html"])
        #expect(layout.pages[1].slots == [
            "preset.compress", "editor.compress-to-size", "preset.read-codes", "preset.merge-pdfs", "preset.split-pdf",
            "editor.organize-pages", "action.makeZip", "action.shelf",
        ])
        #expect(layout.pages[2].slots == [
            "preset.summarize", "preset.scan-document", "preset.extract-tables", "preset.extract-data",
        ])
    }

    /// P176: a customized wheel never moves, so the Shelf is only there when its owner placed it.
    @Test func customizedWheelGainsNoShelf() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/settings/custom-wheel.json")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fixture))
        let mine = try #require(decoded.wheels["kind.image"])
        let b = WheelFixtures.builder(availableEdges: ["png>jpg", "png>webp", "png>heic", "png>pdf"]
                                      + WheelFixtures.everyToolEdges, settings: decoded)
        let pages = b.pages(for: urls("/a.png"))
        #expect(pages.map(\.slices).map { $0.map(\.id) } == mine.pages.map(\.slots))
        #expect(pages.flatMap(\.slices).allSatisfy { $0.id != "action.shelf" })
    }

    /// The first edit copies what the wheel showed (P179): the Shelf slice included.
    @Test func firstEditCopiesShelf() {
        let b = WheelFixtures.builder(availableEdges: WheelFixtures.everyToolEdges + ["png>jpg"])
        let tools = b.builtInLayout(for: .image).pages.first { $0.name == "Tools" }
        #expect(tools?.slots.last == "action.shelf")
        #expect(tools?.slots.count == 8)
    }

    /// R27: the copy keeps the Shelf as the wheel did, whatever an old override switched on.
    @Test func firstEditCopiesShelfPastAnOldOverride() {
        let old = ToolVisibility(overrides: ["image": ["strip-metadata": true, "half-size": true]])
        let b = WheelFixtures.builder(availableEdges: WheelFixtures.everyToolEdges + ["png>jpg"], visibility: old)
        let tools = b.builtInLayout(for: .image).pages.first { $0.name == "Tools" }
        #expect(tools?.slots.last == "action.shelf")
        #expect(tools?.slots.count == 8)
    }

    @Test func builtInLayoutHonoursOldSettings() {
        var order = WheelContentBuilder.defaultOrder
        order[.image] = ["webp", "png"]
        let visibility = ToolVisibility(overrides: ["image": ["copy-paths": true, "half-size": false, "rotate": false]])
        let b = WheelFixtures.builder(availableEdges: ["png>jpg", "png>webp", "jpg>png", "png>bmp", "png>gif"]
                                      + WheelFixtures.everyToolEdges, order: order, visibility: visibility)
        let layout = b.builtInLayout(for: .image)
        #expect(layout.pages.map(\.name) == ["Convert", "Tools", "AI"])
        // The user's order first, then the rest by display name: BMP, GIF, JPEG.
        #expect(layout.pages[0].slots == ["convert.webp", "convert.png", "convert.bmp", "convert.gif", "convert.jpg"])
        #expect(layout.pages[1].slots.contains("action.copyPaths"))
        #expect(!layout.pages[1].slots.contains("preset.half-size"))
        #expect(layout.pages[1].slots.contains("editor.crop"))
        #expect(layout.pages[2].slots == ["preset.remove-background", "preset.smart-crop", "preset.straighten",
                                         "preset.scan-document", "preset.extract-tables", "preset.extract-data",
                                         "preset.find-duplicates"])
    }

    /// P185: the copy has an AI page only when the built-in wheel would show one.
    @Test func builtInLayoutCopiesAIOnlyWhenItRuns() {
        let aiOperations = Set(ToolCatalog.presets(settings: AppSettings())
            .filter { ToolCatalog.info($0.id)?.isAI == true }.compactMap(\.operation))
        let plain = WheelFixtures.everyToolEdges.filter { spec in !aiOperations.contains { spec.contains(":\($0)@") } }
        let none = WheelFixtures.builder(availableEdges: plain, allEdges: WheelFixtures.everyToolEdges)
        #expect(none.builtInLayout(for: .pdf).pages.map(\.name) == ["Tools"])
        let scanOnly = plain + ["pdf>md:scan-document@ffmpeg"]
        let some = WheelFixtures.builder(availableEdges: scanOnly, allEdges: WheelFixtures.everyToolEdges)
        #expect(some.builtInLayout(for: .pdf).pages.map(\.name) == ["Tools", "AI"])
        #expect(some.builtInLayout(for: .pdf).pages.last?.slots.count == 4)
    }

    @Test func builtInLayoutLeavesOutEmptyPagesAndCapsAtEight() {
        let targets = ["jpg", "heic", "webp", "pdf", "avif", "tiff", "gif", "ico", "icns", "bmp"]
        let b = WheelFixtures.builder(availableEdges: targets.map { "png>\($0)" })
        let layout = b.builtInLayout(for: .image)
        #expect(layout.pages.first?.slots.count == WheelContentBuilder.maxSlices)
        #expect(WheelFixtures.builder(availableEdges: []).builtInLayout(for: .font).pages.map(\.name) == ["Tools"])
    }

    // MARK: The editor's chips and pages

    @Test func candidatesForKindAndFormat() {
        let b = WheelFixtures.builder(availableEdges: ["png>webp"], allEdges: ["png>webp", "png>gif", "jpg>bmp"]
                                      + WheelFixtures.everyToolEdges)
        let kind = b.candidates(for: .kind(.image))
        let convert = kind.convert.map(\.id)
        for id in ["convert.webp", "convert.gif", "convert.bmp"] { #expect(convert.contains(id), "\(id)") }
        let format = b.candidates(for: .format("png")).convert.map(\.id)
        #expect(format.contains("convert.webp") && format.contains("convert.gif"))
        #expect(!format.contains("convert.bmp"))
        #expect(kind.convert.allSatisfy { $0.isEnabled && $0.disabledReason == nil })
        #expect(kind.convert.first { $0.id == "convert.gif" }?.title == "GIF")
        #expect(kind.fileTools.map(\.id) == ["action.makeZip", "action.shelf", "action.copyPaths",
                                            "action.copyFiles", "action.revealInFinder", "action.openTerminal"])
        #expect(kind.tools.map(\.id).contains("editor.crop") && kind.tools.map(\.id).contains("preset.half-size"))
        #expect(!kind.tools.map(\.id).contains("preset.merge-pdfs"))
        #expect(!kind.tools.contains { $0.id.hasPrefix("action.") })
        #expect(kind.ai.map(\.id) == ["preset.remove-background", "preset.smart-crop", "preset.straighten",
                                     "preset.scan-document", "preset.extract-tables", "preset.extract-data",
                                     "preset.find-duplicates"])
        #expect(kind.tools.first { $0.id == "editor.crop" }?.title == "Crop\u{2026}")
    }

    @Test func malformedSlotIDsAreTitledWithTheID() {
        let mine = wheel(("Mine", ["convert.", "preset.", "", "action.makeZip"]))
        let b = builder(["kind.image": mine], availableEdges: ["png>jpg"])
        for pages in [b.pages(for: urls("/a.png")), b.editorPages(for: mine)] {
            let slices = pages.first?.slices ?? []
            #expect(slices.map(\.id) == ["convert.", "preset.", "", "action.makeZip"])
            #expect(slices.prefix(3).map(\.title) == ["convert.", "preset.", ""])
            #expect(slices.prefix(3).allSatisfy { !$0.isEnabled && $0.disabledReason == "Not available." })
        }
    }

    @Test func editorPagesResolveWithoutFiles() {
        let mine = wheel(("Mine", ["preset.merge-pdfs", "convert.png"]), ("Two", []))
        let b = WheelFixtures.builder(availableEdges: WheelFixtures.everyToolEdges)
        let pages = b.editorPages(for: mine)
        #expect(pages.map(\.title) == ["Mine", "Two"])
        #expect(pages[0].slices.map(\.title) == ["Merge PDFs", "PNG"])
        #expect(pages[0].slices.allSatisfy { $0.isEnabled })
    }

    @Test func formatsOfAKindFollowItsOrder() {
        let b = WheelFixtures.builder(availableEdges: [])
        let images = b.formats(of: .image).map(\.id.rawValue)
        // The order list names pdf and txt, which are not images.
        #expect(Array(images.prefix(6)) == ["jpg", "png", "gif", "ico", "webp", "heic"])
        #expect(images.count == FormatRegistry.builtIn.all.filter { $0.category == .image }.count)
        // After the order list, by display name: BMP before ICNS before ICO.
        let rest = Array(images.dropFirst(6))
        #expect(rest == rest.sorted { FormatRegistry.builtIn.format(id: FormatID($0))!.displayName
            < FormatRegistry.builtIn.format(id: FormatID($1))!.displayName })
    }
}
