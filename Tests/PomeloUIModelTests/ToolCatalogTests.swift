import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct ToolCatalogTests {
    private var engineTools: [ToolInfo] { ToolCatalog.all.filter { $0.action == nil } }

    @Test func catalogIDsAreUnique() {
        #expect(Set(ToolCatalog.all.map(\.id)).count == ToolCatalog.all.count)
    }

    @Test func catalogMatchesTheBuiltInPresets() {
        let presetIDs = Set(Preset.builtIns.map(\.id))
        for tool in engineTools { #expect(presetIDs.contains(tool.id), "\(tool.id) has no built-in preset") }
        for tool in ToolCatalog.all where tool.action != nil {
            #expect(!presetIDs.contains(tool.id), "\(tool.id) is a file tool")
        }
        #expect(ToolCatalog.presets(settings: AppSettings()).map(\.id) == engineTools.map(\.id))
    }

    @Test func catalogKindsMatchThePresets() throws {
        for tool in engineTools {
            let preset = try #require(Preset.builtIns.first { $0.id == tool.id })
            #expect(tool.kinds == Set(preset.categories ?? []), "\(tool.id)")
        }
    }

    @Test func noKindShowsMoreThanEightByDefaultWithEditorsOnEitherPage() {
        for kind in FormatCategory.allCases {
            for ai in [false, true] {
                let shown = ToolCatalog.all.filter { $0.isAI == ai && $0.shownByDefault.contains(kind) }
                #expect(shown.count <= ToolCatalog.maxShownPerKind, "\(kind) ai=\(ai)")
            }
        }
    }

    @Test func aiToolsAreFlagged() {
        let ai: Set<String> = [
            "transcribe", "make-subtitles", "translate", "scan-document", "extract-tables", "summarize",
            "extract-data", "remove-background", "smart-crop", "straighten", "find-duplicates",
        ]
        #expect(Set(ToolCatalog.all.filter(\.isAI).map(\.id)) == ai)
        for tool in ToolCatalog.all where tool.isAI {
            #expect(tool.shownByDefault == (tool.kinds ?? []), "\(tool.id)")
        }
    }

    @Test func aToolIsOnlyShownByDefaultForKindsItAppliesTo() {
        for tool in ToolCatalog.all {
            #expect(tool.shownByDefault.isSubset(of: tool.kinds ?? Set(FormatCategory.allCases)), "\(tool.id)")
        }
    }

    @Test func fileToolDefaults() {
        for action in FileActionKind.allCases {
            #expect(ToolCatalog.all.filter { $0.action == action }.count == 1)
            let info = ToolCatalog.info(for: action)
            #expect(info.kinds == nil)
            let expected: Set<FormatCategory> = switch action {
            case .shelf: Set(FormatCategory.allCases)
            case .makeZip: Set(FormatCategory.allCases).subtracting([.archive, .video, .image])
            case .copyPaths, .copyFiles, .revealInFinder, .openTerminal:
                [.document, .text, .archive, .data, .subtitle, .font, .other]
            }
            #expect(info.shownByDefault == expected, "\(action)")
        }
    }

    @Test func shelfIsTheFileToolRightAfterMakeZip() throws {
        let info = ToolCatalog.info(for: .shelf)
        #expect(FileActionKind.shelf.rawValue == "shelf")
        #expect(info.id == "shelf" && info.name == "Shelf" && info.symbol == "tray.and.arrow.down")
        #expect(info.verb == "Adding to the Shelf" && !info.isAI && info.editor == nil)
        let ids = ToolCatalog.all.map(\.id)
        let zip = try #require(ids.firstIndex(of: "make-zip"))
        #expect(ids[zip + 1] == "shelf")
    }

    @Test func removeMetadataShownForAudioNotImages() {
        let info = ToolCatalog.info("strip-metadata")
        #expect(info?.shownByDefault == [.audio])
        #expect(info?.kinds == [.image, .video, .audio])
    }

    @Test func resizeIsShownForImagesOnly() {
        #expect(ToolCatalog.info("resize")?.shownByDefault == [.image])
    }

    @Test func defaultCountsPerKind() {
        func shown(_ kind: FormatCategory, ai: Bool = false) -> Int {
            ToolCatalog.all.filter { $0.isAI == ai && $0.shownByDefault.contains(kind) }.count
        }
        #expect(shown(.image) == 8)
        #expect(shown(.video) == 8)
        #expect(shown(.audio) == 8)
        #expect(shown(.pdf) == 8)
        // Make Zip (not for archives), the four clipboard and Finder tools and the Shelf: a bare wheel looks empty.
        #expect(shown(.archive) == 6)  // Extract, not Make Zip
        for kind in [FormatCategory.document, .text, .subtitle, .data, .font, .other] {
            #expect(shown(kind) == 6, "\(kind)")
        }
        #expect(shown(.image, ai: true) == 7 && shown(.video, ai: true) == 2 && shown(.audio, ai: true) == 2)
        #expect(shown(.pdf, ai: true) == 4)
    }

    @Test func everyEditorToolHasAPresetThatNeedsInput() throws {
        let editors = ToolCatalog.all.filter { $0.editor != nil }
        #expect(Set(editors.compactMap(\.editor)) == Set(EditorKind.allCases))
        for tool in editors {
            let preset = try #require(Preset.builtIns.first { $0.id == tool.id })
            #expect(preset.needsInput, "\(tool.id)")
            #expect(preset.name == tool.name, "\(tool.id)")
            #expect(tool.action == nil && tool.canReplaceOriginal == (tool.id != "split-video") && tool.settings.isEmpty, "\(tool.id)")
            #expect(tool.hint?.isEmpty == false, "\(tool.id)")
        }
        for preset in Preset.builtIns where preset.needsInput {
            #expect(ToolCatalog.info(preset.id)?.editor != nil, "\(preset.id)")
        }
    }

    @Test func theEditorsHaveTheirBriefedDetails() throws {
        func editor(_ id: String) throws -> ToolInfo { try #require(ToolCatalog.info(id)) }
        let video: Set<FormatCategory> = [.video], image: Set<FormatCategory> = [.image], pdf: Set<FormatCategory> = [.pdf]
        let rows: [(String, EditorKind, String, String, String, Bool, Set<FormatCategory>, Set<FormatCategory>)] = [
            ("trim", .trim, "timeline.selection", "Trimming", "Choose the part to keep", false,
             [.video, .audio], [.video, .audio]),
            ("crop", .crop, "crop", "Cropping", "Choose the area to keep", false, [.image, .video], [.image, .video]),
            ("split-video", .split, "scissors", "Splitting", "Choose where to cut", false, video, []),
            ("compress-to-size", .targetSize, "gauge.with.dots.needle.33percent", "Compressing", "Choose a size", true,
             [.image, .pdf, .video], [.image, .pdf, .video]),
            ("resize", .resize, "arrow.up.left.and.arrow.down.right", "Resizing", "Choose a size", true,
             [.image, .video], [.image]),
            ("rotate", .rotate, "rotate.right", "Rotating", "Choose a turn", true, [.image, .video],
             [.image, .video]),
            ("redact", .redact, "eye.slash", "Redacting", "Choose what to hide", false, image, image),
            ("organize-pages", .organizePages, "square.grid.2x2", "Saving pages", "Reorder, rotate or remove pages",
             false, pdf, pdf),
        ]
        for (id, kind, symbol, verb, hint, several, kinds, shown) in rows {
            let info = try editor(id)
            #expect(info.editor == kind && info.symbol == symbol && info.verb == verb && info.hint == hint, "\(id)")
            #expect(info.acceptsSeveralFiles == several && info.kinds == kinds && info.shownByDefault == shown, "\(id)")
        }
    }

    @Test func theCatalogOrderPutsEachEditorNextToItsRelatives() {
        #expect(ToolCatalog.all.map(\.id) == [
            "trim", "split-video", "crop", "compress", "compress-more", "compress-to-size", "resize", "rotate",
            "half-size", "remove-background", "smart-crop", "straighten", "redact", "extract-audio", "remove-audio", "transcribe", "make-subtitles", "snapshot",
            "normalize-volume", "speed-up",
            "slow-down", "mono", "strip-metadata", "read-codes", "translate", "summarize", "scan-document",
            "extract-tables", "extract-data", "find-duplicates", "images-to-pdf", "merge-pdfs", "split-pdf",
            "organize-pages", "extract-archive", "make-zip", "shelf", "copy-paths", "copy-files", "reveal-in-finder",
            "open-in-terminal",
        ])
    }

    @Test func phase3DefaultsMadeRoomForTheEditors() {
        let defaults = ToolVisibility.defaults
        #expect(ToolCatalog.info("compress-more")?.shownByDefault == [])
        #expect(defaults.isShown("read-codes", for: .pdf) && !defaults.isShown("read-codes", for: .image))
        #expect(defaults.isShown("speed-up", for: .audio) && !defaults.isShown("speed-up", for: .video))
        #expect(!defaults.isShown("strip-metadata", for: .image) && defaults.isShown("strip-metadata", for: .audio))
        #expect(!defaults.isShown("strip-metadata", for: .video))
        #expect(defaults.isShown("make-zip", for: .audio) && !defaults.isShown("make-zip", for: .video))
        #expect(!defaults.isShown("make-zip", for: .archive))
        // A choice the user already made still wins.
        let kept = ToolVisibility(overrides: ["video": ["strip-metadata": true, "compress-more": true]])
        #expect(kept.isShown("strip-metadata", for: .video) && kept.isShown("compress-more", for: .video))
    }

    @Test func visibilityFollowsOverridesAndIgnoresUnknowns() {
        let v = ToolVisibility(overrides: ["image": ["compress": false, "copy-paths": true, "bogus": true],
                                           "nonsense": ["compress": true]])
        #expect(!v.isShown("compress", for: .image))
        #expect(v.isShown("compress", for: .video))
        #expect(v.isShown("copy-paths", for: .image))
        #expect(!v.isShown("copy-paths", for: .video))
        #expect(!v.isShown("bogus", for: .image))
    }

    @Test func compressDefaultsAndSettings() throws {
        let compress = try #require(ToolCatalog.presets(settings: AppSettings()).first { $0.id == "compress" })
        #expect(compress.options.quality == 0.7 && compress.options.videoCodec == .hevc)
        #expect(compress.options.videoMaxHeight == 1080 && compress.onlyIfSmaller)
        #expect(ToolCatalog.info("compress")?.settings
                == [.imageQuality(range: 0.4...0.9, step: 0.05), .videoMaxHeight([2160, 1080, 720])])
        #expect(ToolCatalog.info("speed-up")?.settings == [.speed([1.25, 1.5, 2, 3])])
    }

    @Test func replaceableToolsAreTheOnesTheBriefNames() {
        let replaceable = Set(ToolCatalog.all.filter(\.canReplaceOriginal).map(\.id))
        #expect(replaceable == ["compress", "compress-more", "half-size", "remove-audio", "normalize-volume",
                                "trim", "crop", "compress-to-size", "resize", "rotate", "redact", "organize-pages",
                                "remove-background", "smart-crop", "straighten",
                                "speed-up", "slow-down", "mono", "strip-metadata"])
    }

    /// P273: every editor that makes one file may replace it; Split… makes several.
    @Test func editorsReplaceTheOriginalButSplit() {
        let editors = ToolCatalog.all.filter { $0.editor != nil }
        #expect(editors.filter { !$0.canReplaceOriginal }.map(\.id) == ["split-video"])
    }

    // MARK: - Vision tools (P261, P264 to P266)

    @Test func smartCropIsAnImageAIToolRightAfterRemoveBackground() throws {
        let info = try #require(ToolCatalog.info("smart-crop"))
        #expect(info.name == "Smart crop" && info.symbol == "viewfinder" && info.verb == "Cropping")
        #expect(info.isAI && info.kinds == [.image] && info.shownByDefault == [.image])
        #expect(info.editor == nil && info.canReplaceOriginal && info.action == nil && info.acceptsSeveralFiles)
        #expect(info.settings == [.cropShape(["", "1:1", "4:5", "4:3", "16:9"])])
        let ids = ToolCatalog.all.map(\.id)
        let background = try #require(ids.firstIndex(of: "remove-background"))
        #expect(ids[background + 1] == "smart-crop")
        #expect(ToolVisibility.defaults.isShown("smart-crop", for: .image))
        #expect(!ToolVisibility.defaults.isShown("smart-crop", for: .video))

        let preset = try #require(Preset.builtIns.first { $0.id == "smart-crop" })
        #expect(preset.name == "Smart crop" && preset.target == nil && preset.operation == "smart-crop")
        #expect(preset.nameSuffix == "cropped" && preset.categories == [.image] && !preset.needsInput)
        #expect(preset.options.quality == 0.92 && preset.options.aspect == nil)
    }

    @Test func straightenIsAnImageAIToolRightAfterSmartCrop() throws {
        let info = try #require(ToolCatalog.info("straighten"))
        #expect(info.name == "Straighten document" && info.symbol == "doc.viewfinder" && info.verb == "Straightening")
        #expect(info.isAI && info.kinds == [.image] && info.shownByDefault == [.image] && info.settings.isEmpty)
        #expect(info.editor == nil && info.canReplaceOriginal && info.action == nil && info.acceptsSeveralFiles)
        let ids = ToolCatalog.all.map(\.id)
        let smartCrop = try #require(ids.firstIndex(of: "smart-crop"))
        #expect(ids[smartCrop + 1] == "straighten")

        let preset = try #require(Preset.builtIns.first { $0.id == "straighten" })
        #expect(preset.name == "Straighten document" && preset.target == nil && preset.operation == "straighten")
        #expect(preset.nameSuffix == "straightened" && preset.categories == [.image] && !preset.needsInput)
        #expect(preset.options == PresetOptions(quality: 0.92))
    }

    @Test func findDuplicatesIsAnImageAIToolRightAfterExtractData() throws {
        let info = try #require(ToolCatalog.info("find-duplicates"))
        #expect(info.name == "Find duplicates" && info.symbol == "square.on.square" && info.verb == "Looking for duplicates")
        #expect(info.isAI && info.kinds == [.image] && info.shownByDefault == [.image] && info.settings.isEmpty)
        #expect(info.editor == nil && !info.canReplaceOriginal && info.action == nil && info.acceptsSeveralFiles)
        let ids = ToolCatalog.all.map(\.id)
        let extractData = try #require(ids.firstIndex(of: "extract-data"))
        #expect(ids[extractData + 1] == "find-duplicates")

        let preset = try #require(Preset.builtIns.first { $0.id == "find-duplicates" })
        #expect(preset.name == "Find duplicates" && preset.target == "txt" && preset.operation == "find-duplicates")
        #expect(preset.nameSuffix == "duplicates" && preset.categories == [.image] && preset.combinesInputs)
        #expect(!preset.needsInput && preset.delivery == .file && preset.options == PresetOptions())
    }

    @Test func smartCropRunsWithTheStoredShape() throws {
        var settings = AppSettings()
        settings.toolOptions["smart-crop"] = PresetOptions(quality: 0.92, aspect: "4:5")
        let preset = try #require(ToolCatalog.presets(settings: settings).first { $0.id == "smart-crop" })
        #expect(preset.options.aspect == "4:5" && preset.nameSuffix == "cropped")
    }

    // MARK: - On-device tools (Phase 4b)

    @Test func theOnDeviceToolsHaveTheirBriefedDetails() throws {
        let rows: [(String, String, String, String, Set<FormatCategory>, Set<FormatCategory>)] = [
            ("translate", "Translate", "character.bubble", "Translating", [.subtitle, .text, .document],
             [.subtitle, .text, .document]),
            ("summarize", "Summarize", "text.append", "Summarizing", [.document, .text, .pdf],
             [.document, .text, .pdf]),
            ("scan-document", "Scan to Markdown", "doc.text.viewfinder", "Scanning", [.image, .pdf], [.image, .pdf]),
            ("extract-tables", "Extract tables", "tablecells", "Extracting tables", [.image, .pdf], [.image, .pdf]),
            ("extract-data", "Extract data", "list.bullet.rectangle", "Extracting data", [.image, .pdf],
             [.image, .pdf]),
        ]
        for (id, name, symbol, verb, kinds, shown) in rows {
            let info = try #require(ToolCatalog.info(id))
            #expect(info.name == name && info.symbol == symbol && info.verb == verb, "\(id)")
            #expect(info.kinds == kinds && info.shownByDefault == shown, "\(id)")
            #expect(info.editor == nil && !info.canReplaceOriginal && info.action == nil, "\(id)")
        }
        #expect(ToolCatalog.info("translate")?.settings == [.targetLanguage])
        #expect(ToolCatalog.info("extract-tables")?.settings == [.outputFormat(["xlsx", "csv"])])
        #expect(ToolCatalog.info("extract-data")?.settings == [.outputFormat(["json", "csv"])])
        #expect(ToolCatalog.info("summarize")?.settings == [] && ToolCatalog.info("scan-document")?.settings == [])
    }

    /// P177: the speech tools are on the AI page for audio and video alike; Snapshot stays one switch away.
    @Test func theSpeechToolsHaveTheirBriefedDetails() throws {
        let rows: [(String, String, String, String, Set<FormatCategory>)] = [
            ("transcribe", "Transcribe", "text.bubble", "Transcribing", [.audio, .video]),
            ("make-subtitles", "Make subtitles", "captions.bubble", "Making subtitles", [.audio, .video]),
        ]
        for (id, name, symbol, verb, shown) in rows {
            let info = try #require(ToolCatalog.info(id))
            #expect(info.name == name && info.symbol == symbol && info.verb == verb, "\(id)")
            #expect(info.kinds == [.audio, .video] && info.shownByDefault == shown, "\(id)")
            #expect(info.editor == nil && !info.canReplaceOriginal && info.action == nil, "\(id)")
        }
        #expect(ToolCatalog.info("transcribe")?.settings == [.spokenLanguage])
        #expect(ToolCatalog.info("make-subtitles")?.settings == [.spokenLanguage, .outputFormat(["srt", "vtt"])])
        #expect(ToolCatalog.info("snapshot")?.shownByDefault == [])
        let order = ToolCatalog.all.map(\.id)
        #expect(try #require(order.firstIndex(of: "make-subtitles")) < #require(order.firstIndex(of: "snapshot")))
        for kind in [FormatCategory.audio, .video] {
            let shown = ToolCatalog.all.filter { !$0.isAI && ToolVisibility.defaults.isShown($0.id, for: kind) }
            #expect(shown.count <= ToolCatalog.maxShownPerKind, "\(kind)")
        }
    }

    @Test func makeSubtitlesWritesVTTWhenItsSettingSaysSo() throws {
        var settings = AppSettings()
        settings.toolOptions["make-subtitles"] = PresetOptions(language: "it-IT", outputFormat: "vtt")
        let preset = try #require(ToolCatalog.presets(settings: settings).first { $0.id == "make-subtitles" })
        #expect(preset.target == "vtt" && preset.nameSuffix == nil && preset.options.language == "it-IT")
        let plain = try #require(ToolCatalog.presets(settings: AppSettings()).first { $0.id == "make-subtitles" })
        #expect(plain.target == "srt" && plain.operation == "subtitles")
        let transcribe = try #require(ToolCatalog.presets(settings: AppSettings()).first { $0.id == "transcribe" })
        #expect(transcribe.target == "txt" && transcribe.nameSuffix == "transcript" && transcribe.operation == "transcribe")
    }

    /// The first choice is the preset's own target, so a picker with nothing stored shows what the tool makes.
    @Test func anOutputFormatSettingStartsWithThePresetsTarget() throws {
        for info in ToolCatalog.all where !ToolCatalog.outputFormats(of: info).isEmpty {
            let preset = try #require(Preset.builtIns.first { $0.id == info.id })
            #expect(ToolCatalog.outputFormats(of: info).first == preset.target, "\(info.id)")
        }
        #expect(ToolCatalog.outputFormats(of: try #require(ToolCatalog.info("compress"))).isEmpty)
    }

    @Test func theOutputFormatSettingBecomesTheTarget() throws {
        var settings = AppSettings()
        settings.toolOptions["extract-data"] = PresetOptions(outputFormat: "csv")
        settings.toolOptions["extract-tables"] = PresetOptions(outputFormat: "csv")
        let presets = ToolCatalog.presets(settings: settings)
        let data = try #require(presets.first { $0.id == "extract-data" })
        #expect(data.target == "csv" && data.nameSuffix == "data" && data.operation == "extract-data")
        #expect(try #require(presets.first { $0.id == "extract-tables" }).target == "csv")
        let untouched = ToolCatalog.presets(settings: AppSettings())
        #expect(try #require(untouched.first { $0.id == "extract-data" }).target == "json")
        #expect(try #require(untouched.first { $0.id == "extract-tables" }).target == "xlsx")
    }

    /// Task 0's deferred minor: the CLI checks a format against the union over every source; the wheel only runs
    /// what the tool's own setting offers.
    @Test func aStoredFormatTheToolDoesNotOfferIsDropped() throws {
        var settings = AppSettings()
        settings.toolOptions["extract-data"] = PresetOptions(outputFormat: "xlsx")
        settings.toolOptions["compress"] = PresetOptions(quality: 0.6, outputFormat: "png")
        let presets = ToolCatalog.presets(settings: settings)
        let data = try #require(presets.first { $0.id == "extract-data" })
        #expect(data.target == "json" && data.options.outputFormat == nil)
        let compress = try #require(presets.first { $0.id == "compress" })
        #expect(compress.target == nil && compress.options.outputFormat == nil && compress.options.quality == 0.6)
    }

    @Test func translateIsNamedAfterItsTarget() throws {
        let english = Locale(identifier: "en_US")
        func translate(_ language: String?, preferred: [String]) throws -> Preset {
            var settings = AppSettings()
            if let language { settings.toolOptions["translate"] = PresetOptions(language: language) }
            return try #require(ToolCatalog.presets(settings: settings, preferredLanguages: preferred, locale: english)
                .first { $0.id == "translate" })
        }
        let italian = try translate("it", preferred: ["de-DE"])
        #expect(italian.name == "Translate to Italian" && italian.nameSuffix == "it")
        let system = try translate(nil, preferred: ["de-DE"])
        #expect(system.name == "Translate to German" && system.nameSuffix == "de")
        // The job runs into the language the name says, whatever the system's language is by then.
        #expect(system.options.language == "de-DE" && italian.options.language == "it")
        let portugal = try translate("pt-PT", preferred: [])
        #expect(portugal.name == "Translate to Portuguese (Portugal)" && portugal.nameSuffix == "pt-PT")
        #expect(italian.nameSuffix == TranslationTarget.suffix("it"))
    }

    @Test func aToolWhoseEnginesCantRunHereHasTheirReason() throws {
        func planner(_ edges: [ConversionEdge]) -> RoutePlanner { RoutePlanner(edges: edges, enginePriority: []) }
        let srt = ConversionEdge(from: "srt", to: "srt", engineID: "translation", cost: 10, flags: [], operation: "translate")
        let txt = ConversionEdge(from: "txt", to: "txt", engineID: "other", cost: 10, flags: [], operation: "translate")
        let translate = try #require(Preset.builtIns.first { $0.id == "translate" })
        let reasons: [EngineID: String] = ["translation": "Needs macOS 26."]
        #expect(ToolCatalog.unsupportedReason(of: translate, formats: .builtIn, planner: planner([srt]),
                                              reasons: reasons) == "Needs macOS 26.")
        // One route that runs is enough to use the tool, so no reason.
        #expect(ToolCatalog.unsupportedReason(of: translate, formats: .builtIn, planner: planner([srt, txt]),
                                              reasons: reasons) == nil)
        #expect(ToolCatalog.unsupportedReason(of: translate, formats: .builtIn, planner: planner([srt]),
                                              reasons: [:]) == nil)
        #expect(ToolCatalog.unsupportedReason(of: translate, formats: .builtIn, planner: planner([]),
                                              reasons: reasons) == nil)
    }
}
