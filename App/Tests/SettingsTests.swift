import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import ServiceManagement
import Testing
@testable import Pomelo

@Suite struct SettingsSupportTests {
    /// A kind's stored format order, which Reset to default clears (P179), still orders that kind's built-in wheel.
    @Test @MainActor func aStoredOrderReachesTheWheel() {
        #expect(AppEnvironment.wheelOrder(from: ["image": ["heic", "jpg"]])[.image] == ["heic", "jpg"])
        #expect(AppEnvironment.wheelOrder(from: ["image": []])[.image]?.first == "jpg")
        #expect(AppEnvironment.wheelOrder(from: [:])[.video] == WheelContentBuilder.defaultOrder[.video])
    }

    @Test func theAppHasItsIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
        #expect(NSImage(named: "AppIcon") != nil)
    }

    @Test func triggerTitlesNameEveryKey() {
        #expect(TriggerKey.allCases.map(\.settingsTitle) == ["⇧ Shift", "⌥ Option", "⌃ Control", "⌘ Command"])
    }

    @Test func versionStringComesFromTheBundleKeys() {
        #expect(AppInfo.versionString(from: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]) == "Version 0.1.0 (1)")
        #expect(AppInfo.versionString(from: ["CFBundleShortVersionString": "0.1.0"]) == "Version 0.1.0")
        #expect(AppInfo.versionString(from: nil) == "Version unknown")
    }

    @Test func engineVersionsShowJustTheNumber() {
        #expect(EngineVersionText.short("ffmpeg version 8.1.1 Copyright (c) 2000-2026 the FFmpeg developers") == "8.1.1")
        #expect(EngineVersionText.short("3.2.1\nextra") == "3.2.1")
        #expect(EngineVersionText.short("a very long version-less description of an engine")?.count == 24)
        #expect(EngineVersionText.short("") == nil)
    }

    @Test func versionTextTakesTheVersionShapedToken() {
        #expect(EngineVersionText.short("pandoc 3.13\nFeatures: +server") == "3.13")
        #expect(EngineVersionText.short("ffmpeg version 9.0.2 Copyright (c) 2000-2026") == "9.0.2")
        #expect(EngineVersionText.short("1.6.0") == "1.6.0")
        #expect(EngineVersionText.short("pngquant, 3.0.3 (January 2026)") == "3.0.3")
        #expect(EngineVersionText.short("no digits here") == "no digits here")
    }

    @Test func theTestBundleHasAVersionToShow() {
        #expect(AppInfo.versionString(from: Bundle(for: BundleToken.self).infoDictionary).hasPrefix("Version "))
    }

    @Test @MainActor func pluginsFolderIsCreatedOnDemandAndLeftAloneIfPresent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pomelo-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Pomelo/Plugins", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try EnginesModel.ensurePluginsFolder(at: folder) == folder)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        let marker = folder.appending(path: "x.json")
        try Data("{}".utf8).write(to: marker)
        _ = try EnginesModel.ensurePluginsFolder(at: folder)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}

private final class BundleToken {}

@MainActor
@Suite struct EnginesModelTests {
    private let before = [EngineStatus(id: "cwebp", displayName: "WebP", availability: .missing(installHint: "brew install webp"))]
    private let after = [EngineStatus(id: "cwebp", displayName: "WebP", availability: .available(version: "1.4"))]

    @Test func loadShowsTheRegistrysStatuses() async {
        let model = EnginesModel(loadStatuses: { [before] in before }, refresh: {})
        await model.load()
        #expect(model.statuses == before)
    }

    @Test func refreshRunsTheRefreshThenReloads() async {
        let state = RefreshState()
        let model = EnginesModel(
            loadStatuses: { [before, after] in await state.refreshed ? after : before },
            refresh: { await state.markRefreshed() }
        )
        await model.load()
        #expect(model.statuses == before)
        await model.refresh()
        #expect(model.statuses == after)
        #expect(!model.isRefreshing)
    }
}

private actor RefreshState {
    private(set) var refreshed = false
    func markRefreshed() { refreshed = true }
}

@MainActor
@Suite struct LoginItemModelTests {
    private final class FakeService: LoginItemService {
        var status: SMAppService.Status
        var failure: Error?
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0
        init(_ status: SMAppService.Status) { self.status = status }

        func register() throws {
            registerCalls += 1
            if let failure { throw failure }
            status = .enabled
        }

        func unregister() throws {
            unregisterCalls += 1
            if let failure { throw failure }
            status = .notRegistered
        }
    }

    @Test func togglingOnRegistersAndOffUnregisters() {
        let service = FakeService(.notRegistered)
        let model = LoginItemModel(service: service)
        #expect(!model.isOn)
        model.setEnabled(true)
        #expect(model.isOn && service.registerCalls == 1)
        model.setEnabled(false)
        #expect(!model.isOn && service.unregisterCalls == 1)
        #expect(model.errorMessage == nil)
    }

    @Test func requiresApprovalReadsOnAndAsksForApproval() {
        let model = LoginItemModel(service: FakeService(.requiresApproval))
        #expect(model.isOn && model.needsApproval)
    }

    @Test func aRefusalShowsItsMessageAndLeavesTheStatus() {
        let service = FakeService(.notRegistered)
        service.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let model = LoginItemModel(service: service)
        model.setEnabled(true)
        #expect(model.errorMessage == "Operation not permitted")
        #expect(!model.isOn)
        service.failure = nil
        model.setEnabled(true)
        #expect(model.errorMessage == nil && model.isOn)
    }
}

@Suite struct ToolsPaneModelTests {
    @Test func qualitySliderWritesTheToolsOptions() {
        var model = ToolsPaneModel(settings: AppSettings())
        #expect(model.options(of: "compress").quality == 0.7)
        model.setQuality(0.4, for: "compress")
        let stored = model.settings.toolOptions["compress"]
        #expect(stored?.quality == 0.4)
        #expect(stored?.videoMaxHeight == 1080 && stored?.videoCodec == .hevc)
        #expect(model.settings.toolOptions["compress-more"] == nil)
        model.setVideoMaxHeight(720, for: "compress")
        #expect(model.settings.toolOptions["compress"]?.videoMaxHeight == 720)
        #expect(model.settings.toolOptions["compress"]?.quality == 0.4)
    }

    @Test func theOtherControlsWriteTheirOwnOption() {
        var model = ToolsPaneModel(settings: AppSettings())
        model.setAudioBitrate("256k", for: "extract-audio")
        model.setLoudness(-23, for: "normalize-volume")
        model.setSpeed(1.5, for: "speed-up")
        #expect(model.settings.toolOptions["extract-audio"]?.audioBitrate == "256k")
        #expect(model.settings.toolOptions["normalize-volume"]?.loudness == -23)
        #expect(model.settings.toolOptions["speed-up"]?.speed == 1.5)
    }

    // ToolCatalog.presets renames a speed tool only for stored options that carry a speed.
    @Test func aChangedSpeedRenamesItsEntryAndKeepsTheOtherOptionsComplete() throws {
        var model = ToolsPaneModel(settings: AppSettings())
        model.setSpeed(1.5, for: "speed-up")
        let entry = try #require(model.defaults.first { $0.info.id == "speed-up" })
        #expect(entry.name == "Speed 1.5\u{00D7}")
        #expect(try #require(model.defaults.first { $0.info.id == "slow-down" }).name == "Speed 0.5\u{00D7}")
    }

    @Test func defaultsListEveryToolThatOffersASetting() {
        let model = ToolsPaneModel(settings: AppSettings())
        #expect(model.defaults.map(\.info.id) == [
            "compress", "compress-more", "smart-crop", "extract-audio", "transcribe", "make-subtitles", "normalize-volume",
            "speed-up", "slow-down", "translate", "extract-tables", "extract-data",
        ])
    }

    /// P266: "Fit the subject" is stored as no shape, so the preset keeps fitting.
    @Test func theShapePickerStoresSmartCropsAspect() {
        var model = ToolsPaneModel(settings: AppSettings())
        #expect(model.shape(of: "smart-crop") == "")
        model.setShape("4:5", for: "smart-crop")
        #expect(model.settings.toolOptions["smart-crop"]?.aspect == "4:5")
        #expect(model.settings.toolOptions["smart-crop"]?.quality == 0.92)
        #expect(model.shape(of: "smart-crop") == "4:5")
        model.setShape("", for: "smart-crop")
        #expect(model.settings.toolOptions["smart-crop"]?.aspect == nil)
        // A stored shape the tool doesn't offer (a hand-edited blob) shows as the default.
        model.setShape("3:2", for: "smart-crop")
        #expect(model.shape(of: "smart-crop") == "")
        #expect(["", "1:1", "4:5", "4:3", "16:9"].map(ToolsPaneModel.shapeLabel)
            == ["Fit the subject", "Square", "4:5", "4:3", "16:9"])
    }

    // MARK: Phase 4b

    @Test func theLanguagePickerWritesTheLanguageAndRenamesTranslate() throws {
        var model = ToolsPaneModel(settings: AppSettings())
        #expect(model.options(of: "translate").language == nil)
        model.setLanguage("it", for: "translate")
        #expect(model.settings.toolOptions["translate"]?.language == "it")
        let entry = try #require(model.defaults.first { $0.info.id == "translate" })
        #expect(entry.name == "Translate to \(TranslationTarget.name("it"))")
        model.setLanguage(nil, for: "translate")
        #expect(model.settings.toolOptions["translate"]?.language == nil)
        #expect(ToolsPaneModel.systemLanguageLabel == "System language")
    }

    @Test func theFormatPickerStoresOnlyAFormatOtherThanTheToolsOwn() {
        var model = ToolsPaneModel(settings: AppSettings())
        #expect(model.outputFormat(of: "extract-data") == "json")
        #expect(model.outputFormat(of: "extract-tables") == "xlsx")
        #expect(model.outputFormat(of: "compress") == nil)
        model.setOutputFormat("csv", for: "extract-data")
        #expect(model.settings.toolOptions["extract-data"]?.outputFormat == "csv")
        #expect(model.outputFormat(of: "extract-data") == "csv")
        model.setOutputFormat("json", for: "extract-data")
        #expect(model.settings.toolOptions["extract-data"]?.outputFormat == nil)
        #expect(model.outputFormat(of: "extract-data") == "json")
        #expect(ToolsPaneModel.formatLabel("xlsx") == "Excel" && ToolsPaneModel.formatLabel("csv") == "CSV")
        #expect(ToolsPaneModel.formatLabel("json") == "JSON")
    }

    @Test func theSpokenLanguageAndSubtitleFormatAreStoredPerTool() throws {
        var model = ToolsPaneModel(settings: AppSettings())
        model.setLanguage("it-IT", for: "transcribe")
        model.setOutputFormat("vtt", for: "make-subtitles")
        #expect(model.settings.toolOptions["transcribe"]?.language == "it-IT")
        #expect(model.settings.toolOptions["make-subtitles"]?.language == nil)
        #expect(model.outputFormat(of: "make-subtitles") == "vtt")
        model.setOutputFormat("srt", for: "make-subtitles")
        #expect(model.settings.toolOptions["make-subtitles"]?.outputFormat == nil)
        #expect(ToolsPaneModel.formatLabel("srt") == "SubRip" && ToolsPaneModel.formatLabel("vtt") == "WebVTT")
    }

    @Test @MainActor func theLanguageNotesArePlainSentences() {
        #expect(ToolsPane.speechNote.hasSuffix(".") && !ToolsPane.speechNote.contains("\u{00B7}")
            && !ToolsPane.speechNote.contains("\u{2014}"))
        #expect(ToolsPane.translationNote.hasSuffix("System Settings, General, Language & Region."))
        #expect(!ToolsPane.translationNote.contains("\u{00B7}") && !ToolsPane.translationNote.contains("\u{2014}"))
    }

    @Test func restoreDefaultsClearsToolKeysOnly() {
        var settings = AppSettings()
        settings.trigger = .option
        settings.soundsEnabled = true
        settings.wheelOrder = ["image": ["png"]]
        var model = ToolsPaneModel(settings: settings)
        model.setQuality(0.5, for: "compress")
        model.setReplaceOriginal(true)
        model.restoreDefaults()
        #expect(model.settings.toolOptions.isEmpty)
        #expect(model.settings.replaceOriginal == false)
        #expect(model.settings.trigger == .option && model.settings.soundsEnabled)
        #expect(model.settings.wheelOrder == ["image": ["png"]])
    }

    @Test func restoreDefaultsKeepsVisibility() {
        var settings = AppSettings()
        settings.toolVisibility = ["image": ["snapshot": true]]
        var model = ToolsPaneModel(settings: settings)
        model.setQuality(0.4, for: "compress")
        model.restoreDefaults()
        #expect(model.options(of: "compress").quality == 0.7)
        #expect(model.settings.toolVisibility == ["image": ["snapshot": true]])
    }

    @Test func everyToolSymbolExists() {
        for tool in ToolCatalog.all {
            #expect(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil) != nil, "\(tool.symbol)")
        }
        #expect(NSImage(systemSymbolName: SettingsPane.tools.symbol, accessibilityDescription: nil) != nil)
    }

    @Test func theToolsPaneSitsBetweenWheelAndWatchFolders() {
        let panes = SettingsPane.allCases
        #expect(SettingsPane.tools.title == "Tools" && SettingsPane.tools.symbol == "wrench.and.screwdriver")
        #expect(panes.firstIndex(of: .tools) == panes.firstIndex(of: .wheel)! + 1)
        #expect(panes.firstIndex(of: .watchFolders) == panes.firstIndex(of: .tools)! + 1)
    }

    @Test func theWatchFoldersPaneSitsBetweenToolsAndEngines() {
        let panes = SettingsPane.allCases
        #expect(SettingsPane.watchFolders.title == "Watch Folders")
        #expect(SettingsPane.watchFolders.symbol == "folder.badge.gearshape")
        #expect(NSImage(systemSymbolName: SettingsPane.watchFolders.symbol, accessibilityDescription: nil) != nil)
        #expect(panes.firstIndex(of: .engines) == panes.firstIndex(of: .watchFolders)! + 1)
        #expect(panes.map(\.title) == ["General", "Wheel", "Tools", "Watch Folders", "Engines", "About"])
    }

    @Test func theOptionLabelsAreWordedForPeople() {
        #expect(ToolsPaneModel.videoSizeLabel(2160) == "4K" && ToolsPaneModel.videoSizeLabel(720) == "720p")
        #expect(ToolsPaneModel.bitrateLabel("192k") == "192 kbps")
        #expect(ToolsPaneModel.speedLabel(1.25) == "1.25\u{00D7}" && ToolsPaneModel.speedLabel(2) == "2\u{00D7}")
        #expect(ToolsPaneModel.loudnessLabel(-16) == "Voice and podcasts (\u{2212}16 LUFS)")
        #expect(ToolsPaneModel.loudnessLabel(-14) == "Music streaming (\u{2212}14 LUFS)")
        #expect(ToolsPaneModel.loudnessLabel(-23) == "Broadcast (\u{2212}23 LUFS)")
        #expect(ToolsPaneModel.percentLabel(0.7) == "70%")
    }

    @Test func changingToolSettingsRebuildsTheWheel() {
        let base = AppSettings()
        var tool = base
        tool.toolOptions["compress"] = PresetOptions(quality: 0.4)
        var hidden = base
        hidden.toolVisibility = ["video": ["compress": false]]
        var replacing = base
        replacing.replaceOriginal = true
        var order = base
        order.wheelOrder = ["image": ["png"]]
        var trigger = base
        trigger.trigger = .option
        for changed in [tool, hidden, replacing, order] { #expect(AppEnvironment.changesWheelContent(from: base, to: changed)) }
        #expect(!AppEnvironment.changesWheelContent(from: base, to: trigger))
        #expect(!AppEnvironment.changesWheelContent(from: base, to: base))
    }

    @Test @MainActor func generalShowsTheShakePicker() {
        #expect(GeneralPane.shakeChoices.map(\.title) == ["Off", "Careful", "Normal", "Easy"])
        #expect(GeneralPane.shakeLabel == "Shake to open the Shelf")
        let store = SettingsStore(defaults: EphemeralDefaults())
        let binding = GeneralPane.shakeBinding(store)
        #expect(binding.wrappedValue == .normal)
        binding.wrappedValue = .careful
        #expect(store.settings.shelfShake == .careful)
    }

    @Test func restartsDragMonitorOnShakeChange() {
        let base = AppSettings()
        var shake = base
        shake.shelfShake = .easy
        var trigger = base
        trigger.trigger = .option
        var other = base
        other.soundsEnabled = true
        #expect(AppEnvironment.restartsDragMonitor(from: base, to: shake))
        #expect(AppEnvironment.restartsDragMonitor(from: base, to: trigger))
        #expect(!AppEnvironment.restartsDragMonitor(from: base, to: other))
        #expect(!AppEnvironment.restartsDragMonitor(from: base, to: base))
    }

    @Test func changesWheelContentSeesWheels() {
        let base = AppSettings()
        var customized = base
        customized.wheels = ["kind.image": CustomWheel(pages: [CustomPage(name: "Mine", slots: ["convert.jpg"])])]
        #expect(AppEnvironment.changesWheelContent(from: base, to: customized))
        var renamed = customized
        renamed.wheels["kind.image"]?.pages[0].name = "Ours"
        #expect(AppEnvironment.changesWheelContent(from: customized, to: renamed))
    }

    /// The running app's wheel opens the user's wheels (P175): the builder it plans is given them.
    @Test func theWheelContentTakesTheCustomizedWheels() {
        var settings = AppSettings()
        settings.wheels = ["kind.image": CustomWheel(pages: [CustomPage(name: "Mine", slots: ["convert.jpg"])])]
        let empty = RoutePlanner(edges: [], enginePriority: [])
        let builder = AppEnvironment.makeContentBuilder(
            settings: settings, available: empty, all: empty, installHints: [:], unsupportedReasons: [:],
            installable: []
        )
        #expect(builder.pages(for: [URL(fileURLWithPath: "/tmp/a.png")]).map(\.title) == ["Mine"])
    }
}

/// P95, P100: only a user's launch copies the pre-rename settings or touches the real defaults; the test host and the
/// snapshots get in-memory defaults, the evals their quiet in-memory settings.
@MainActor
@Suite struct LegacySettingsLaunchTests {
    private func kind(_ arguments: [String], tests: Bool = false) -> AppEnvironment.LaunchDefaults {
        AppEnvironment.launchDefaults(arguments: arguments, isRunningTests: tests)
    }

    @Test func aUsersLaunchUsesTheRealDefaults() {
        #expect(kind(["/Applications/Pomelo.app/Contents/MacOS/Pomelo"]) == .user)
        #expect(kind(["Pomelo", "-NSDocumentRevisionsDebugMode", "YES"]) == .user)
    }

    @Test func theTestHostAndSnapshotsGetInMemoryDefaults() {
        #expect(kind(["Pomelo"], tests: true) == .ephemeral)
        for flag in ["--snapshot-wheel", "--snapshot-settings", "--snapshot-onboarding", "--snapshot-pill",
                     "--snapshot-editor", "--record-drags"] {
            #expect(kind(["Pomelo", flag, "x"]) == .ephemeral)
        }
    }

    @Test func measurementsGetTheEvalsDefaults() {
        for flag in [EvalHooks.wheelFlag, EvalHooks.editorFlag, EvalHooks.idleFlag, EvalHooks.watchFlag, EvalHooks.launchFlag] {
            #expect(kind(["Pomelo", flag, "x"]) == .evals)
            #expect(kind(["Pomelo", flag, "x"], tests: true) == .evals)
        }
    }

    @Test func theFlagsAreReadAfterTheExecutable() {
        #expect(kind(["--snapshot-wheel"]) == .user)
    }

    /// This very process is the app tests' host: its shared environment must not be on the real defaults.
    @Test func theTestHostsSettingsAreInMemory() {
        #expect(AppEnvironment.shared.settingsStore.defaults is EphemeralDefaults)
    }
}
