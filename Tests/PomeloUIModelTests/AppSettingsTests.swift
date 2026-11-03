import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct AppSettingsTests {
    @Test func defaultsAndPartialDecode() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"trigger":"option"}"#.utf8))
        #expect(s.trigger == .option)
        #expect(s.hapticsEnabled == true)
        #expect(s.soundsEnabled == false)
        #expect(s.clickModeHotkeyEnabled == true)
        #expect(s.wheelOrder.isEmpty)
        #expect(s.hasCompletedOnboarding == false)
    }

    @Test func shelfShakeDefaultsToNormal() throws {
        #expect(AppSettings().shelfShake == .normal)
        var s = AppSettings()
        s.shelfShake = .careful
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.shelfShake == .careful)
    }

    @Test func olderBlobWithoutShelfShakeDecodes() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"trigger":"option","soundsEnabled":true}"#.utf8))
        #expect(s.shelfShake == .normal)
        #expect(s.trigger == .option && s.soundsEnabled)
    }

    @Test func unknownShelfShakeFallsBackToNormal() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shelfShake":"violent","soundsEnabled":true}"#.utf8))
        #expect(s.shelfShake == .normal)
        #expect(s.soundsEnabled)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
        #expect(AppSettings().trigger == .shift)
    }

    @Test func unknownKeysAndBadValuesFallBackToDefaults() throws {
        let json = #"{"trigger":"hyper","futureKey":1,"soundsEnabled":true,"hapticsEnabled":"yes"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.trigger == .shift)
        #expect(s.hapticsEnabled == true)
        #expect(s.soundsEnabled == true)
    }

    @Test func firstPageDefaultsToConvertAndKeepsTheOtherValues() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"trigger":"option","soundsEnabled":true}"#.utf8))
        #expect(old.firstPage == .convert)
        #expect(old.trigger == .option)
        #expect(old.soundsEnabled == true)

        let tools = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"firstPage":"tools","trigger":"option"}"#.utf8))
        #expect(tools.firstPage == .tools)
        #expect(tools.trigger == .option)

        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"firstPage":7,"trigger":"option"}"#.utf8))
        #expect(bad.firstPage == .convert)
        #expect(bad.trigger == .option)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"firstPage":"edit","soundsEnabled":true}"#.utf8))
        #expect(unknown.firstPage == .convert)
        #expect(unknown.soundsEnabled == true)
    }

    /// P23 removed the pill's `resultAutoHideSeconds`: a blob saved before still decodes, with every other value.
    @Test func aBlobWithTheRemovedAutoHideSettingStillDecodes() throws {
        let json = #"{"trigger":"option","hapticsEnabled":false,"soundsEnabled":true,"clickModeHotkeyEnabled":false,"resultAutoHideSeconds":9,"wheelOrder":{"image":["png"]},"hasCompletedOnboarding":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.trigger == .option)
        #expect(s.hapticsEnabled == false)
        #expect(s.soundsEnabled == true)
        #expect(s.clickModeHotkeyEnabled == false)
        #expect(s.wheelOrder == ["image": ["png"]])
        #expect(s.hasCompletedOnboarding == true)
        // Saving again drops the key.
        let encoded = try #require(String(data: JSONEncoder().encode(s), encoding: .utf8))
        #expect(!encoded.contains("resultAutoHideSeconds"))
    }

    @MainActor
    @Test func theStoreLoadsAnOlderBlobWithTheAutoHideSetting() {
        let defaults = EphemeralDefaults()
        defaults.set(Data(#"{"trigger":"command","resultAutoHideSeconds":4}"#.utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings.trigger == .command)
    }

    /// P40: a test's settings never reach ~/Library/Preferences, even once cfprefsd has been asked to write them.
    @MainActor
    @Test func ephemeralDefaultsLeaveNoPlistBehind() async throws {
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
        let name = autoreleasepool { () -> String in
            let defaults = EphemeralDefaults()
            let name = defaults.suiteName
            let store = SettingsStore(defaults: defaults)
            store.settings.trigger = .command
            #expect(SettingsStore(defaults: defaults).settings.trigger == .command)
            CFPreferencesAppSynchronize(name as CFString)
            #expect(!FileManager.default.fileExists(atPath: preferences.appending(path: "\(name).plist").path))
            return name
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: preferences.appending(path: "\(name).plist").path))
    }

    @Test func roundTrips() throws {
        var s = AppSettings()
        s.trigger = .control
        s.hapticsEnabled = false
        s.wheelOrder = ["image": ["jpg", "png"]]
        s.hasCompletedOnboarding = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }

    @MainActor
    @Test func storePersists() {
        let defaults = EphemeralDefaults()

        let store = SettingsStore(defaults: defaults)
        #expect(store.settings == AppSettings())
        store.settings.trigger = .command
        store.settings.wheelOrder = ["image": ["webp"]]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings.trigger == .command)
        #expect(reloaded.settings.wheelOrder == ["image": ["webp"]])
        #expect(defaults.data(forKey: "settings.v1") != nil)
    }

    @MainActor
    @Test func storeIgnoresCorruptData() {
        let defaults = EphemeralDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        #expect(SettingsStore(defaults: defaults).settings == AppSettings())
    }

    @Test func aPhase2BlobDecodesWithItsValuesAndTheDefaultTools() throws {
        let json = #"""
            {"trigger":"control","hapticsEnabled":false,"soundsEnabled":true,"clickModeHotkeyEnabled":true,
             "wheelOrder":{"image":["png","jpg"]},"hasCompletedOnboarding":true,"resultAutoHideSeconds":4}
            """#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.trigger == .control && !s.hapticsEnabled && s.soundsEnabled && s.clickModeHotkeyEnabled)
        #expect(s.wheelOrder == ["image": ["png", "jpg"]] && s.hasCompletedOnboarding)
        #expect(s.toolVisibility.isEmpty && s.toolOptions.isEmpty && !s.replaceOriginal)
    }

    @Test func settingsWithToolKeysRoundTripAndBadToolKeysFallBack() throws {
        var s = AppSettings()
        s.toolVisibility = ["video": ["compress": false]]
        s.toolOptions = ["compress": PresetOptions(quality: 0.55, videoMaxHeight: 720)]
        s.replaceOriginal = true
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(again == s)

        let bad = #"{"trigger":"option","toolVisibility":"nope","toolOptions":[1],"replaceOriginal":"yes","soundsEnabled":true}"#
        let fallback = try JSONDecoder().decode(AppSettings.self, from: Data(bad.utf8))
        #expect(fallback.toolVisibility.isEmpty && fallback.toolOptions.isEmpty && !fallback.replaceOriginal)
        #expect(fallback.trigger == .option && fallback.soundsEnabled)
    }

    @Test func editorMemoryRoundTripsAndOlderBlobsDecode() throws {
        #expect(AppSettings().editorMemory == EditorMemory())
        #expect(EditorMemory().targetBytes.isEmpty && EditorMemory().cropRatio == "free")
        #expect(EditorMemory().redactionStyle == .fill)

        var s = AppSettings()
        s.editorMemory = EditorMemory(targetBytes: ["image": 500_000, "video": 10_000_000], cropRatio: "16:9",
                                      redactionStyle: .pixelate)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.editorMemory.targetBytes["video"] == 10_000_000)

        let phase3 = #"{"trigger":"option","toolVisibility":{"video":{"compress":false}},"replaceOriginal":true}"#
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(phase3.utf8))
        #expect(old.editorMemory == EditorMemory())
        #expect(old.toolVisibility == ["video": ["compress": false]] && old.replaceOriginal && old.trigger == .option)
    }

    /// P197: the Resize editor's last size per kind joins `editorMemory` (a photo's square never opens a video's
    /// editor); a blob written before it still decodes, and one with an unreadable size keeps the other choices.
    @Test func resizeMemoryRoundTripsAndOlderBlobsDecode() throws {
        #expect(EditorMemory().resize.isEmpty)
        var s = AppSettings()
        s.editorMemory.resize = ["image": .exact(width: 1080, height: 1080), "video": .height(720)]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.editorMemory.resize == ["image": .exact(width: 1080, height: 1080), "video": .height(720)])

        let customWheel = #"{"editorMemory":{"targetBytes":{"image":300000},"cropRatio":"square","redactionStyle":"pixelate"}}"#
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(customWheel.utf8))
        #expect(old.editorMemory == EditorMemory(targetBytes: ["image": 300_000], cropRatio: "square",
                                                 redactionStyle: .pixelate))
        #expect(old.editorMemory.resize.isEmpty)
        // Nothing remembered writes nothing, so an older blob comes back as it was.
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.editorMemory)) as? NSDictionary
        #expect(written?["resize"] == nil)

        let bad = #"{"editorMemory":{"cropRatio":"square","resize":{"image":{"mode":"stretch","width":5}}}}"#
        let kept = try JSONDecoder().decode(AppSettings.self, from: Data(bad.utf8))
        #expect(kept.editorMemory.cropRatio == "square" && kept.editorMemory.resize.isEmpty)
    }

    /// The blob a Phase 5 build writes, every key set to a non-default value: a Phase 6 build must decode each one and
    /// write it back, or a person's settings silently reset on update.
    @Test func aPhase5SettingsBlobStillDecodes() throws {
        let json = #"""
            {"trigger":"control","firstPage":"tools","hapticsEnabled":false,"soundsEnabled":true,
             "clickModeHotkeyEnabled":false,"wheelOrder":{"image":["webp","png"]},"hasCompletedOnboarding":true,
             "toolVisibility":{"video":{"compress":false}},
             "toolOptions":{"compress":{"quality":0.55,"scale":0.5,"maxPixelSize":2048,"stripMetadata":true,
               "videoCodec":"hevc","videoMaxHeight":720,"audioBitrate":"128k","pdfRenderDPI":300,"speed":1.5,
               "loudness":-23,"edit":{"kind":"trim","start":1.5,"end":4.25},"targetBytes":5000000}},
             "replaceOriginal":true,
             "editorMemory":{"targetBytes":{"video":10000000},"cropRatio":"sixteenNine","redactionStyle":"pixelate"},
             "watchFolders":[
               {"id":"6F1B1E0E-0C3A-4D5B-9A39-0B7C5D1E2F34","path":"/Users/x/Downloads","bookmark":"AQID",
                "action":{"kind":"convert","format":"jpg"},"isEnabled":false},
               {"id":"B2C5A8D0-1F4E-4A6B-8C7D-9E0F1A2B3C4D","path":"/Users/x/Inbox",
                "action":{"kind":"tool","tool":"strip-metadata"},"isEnabled":true}]}
            """#
        let data = Data(json.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(s.trigger == .control && s.firstPage == .tools)
        #expect(!s.hapticsEnabled && s.soundsEnabled && !s.clickModeHotkeyEnabled && s.hasCompletedOnboarding)
        #expect(s.wheelOrder == ["image": ["webp", "png"]])
        #expect(s.toolVisibility == ["video": ["compress": false]])
        let options = PresetOptions(
            quality: 0.55, scale: 0.5, maxPixelSize: 2048, stripMetadata: true, videoCodec: .hevc, videoMaxHeight: 720,
            audioBitrate: "128k", pdfRenderDPI: 300, speed: 1.5, loudness: -23,
            edit: .trim(TimeRange(start: 1.5, end: 4.25)), targetBytes: 5_000_000)
        #expect(s.toolOptions == ["compress": options])
        #expect(s.replaceOriginal)
        #expect(s.editorMemory == EditorMemory(
            targetBytes: ["video": 10_000_000], cropRatio: "sixteenNine", redactionStyle: .pixelate))
        #expect(s.watchFolders.map(\.path) == ["/Users/x/Downloads", "/Users/x/Inbox"])
        #expect(s.watchFolders.map(\.action) == [.convert("jpg"), .tool("strip-metadata")])
        #expect(s.watchFolders.map(\.isEnabled) == [false, true] && s.watchFolders[0].bookmark == Data([1, 2, 3]))

        // The keys later builds add (P180, the Shelf's shake): written as defaults, everything else must come back unchanged.
        let written = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(s), options: .mutableContainers) as? NSMutableDictionary)
        #expect(written["wheels"] as? NSDictionary == [:])
        #expect(written["shelfShake"] as? String == "normal")
        written.removeObject(forKey: "wheels")
        written.removeObject(forKey: "shelfShake")
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        #expect(written == original)
    }

    /// Phase 6 wrote the same keys as Phase 5. 4b's `language` and `outputFormat` decode as nil from it, and the blob
    /// is written back unchanged.
    @Test func aPhase6SettingsBlobDecodesUnchanged() throws {
        let json = #"""
            {"trigger":"option","soundsEnabled":true,"replaceOriginal":false,
             "toolOptions":{"compress":{"quality":0.55,"stripMetadata":true,"videoCodec":"hevc","audioBitrate":"128k",
               "pdfRenderDPI":300,"loudness":-23,"targetBytes":5000000},
               "speed-up":{"quality":0.85,"stripMetadata":false,"videoCodec":"h264","audioBitrate":"192k",
               "pdfRenderDPI":150,"loudness":-16,"speed":1.5}},
             "toolVisibility":{"audio":{"mono":false}}}
            """#
        let data = Data(json.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(s.toolOptions.count == 2)
        #expect(s.toolOptions.values.allSatisfy { $0.language == nil && $0.outputFormat == nil })
        #expect(s.toolOptions["speed-up"]?.speed == 1.5 && s.toolOptions["compress"]?.targetBytes == 5_000_000)

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        #expect(written?["toolOptions"] as? NSDictionary == original?["toolOptions"] as? NSDictionary)
    }

    /// P266: Smart crop's Shape is stored in its tool options; a blob written before it decodes with no shape.
    @Test func smartCropsShapeIsStoredAndOlderBlobsHaveNone() throws {
        var settings = AppSettings()
        settings.toolOptions["smart-crop"] = PresetOptions(quality: 0.92, aspect: "4:5")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.toolOptions["smart-crop"]?.aspect == "4:5")

        let older = #"{"toolOptions":{"smart-crop":{"quality":0.92,"stripMetadata":false,"videoCodec":"h264","#
            + #""audioBitrate":"192k","pdfRenderDPI":150,"loudness":-16}}}"#
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(older.utf8))
        #expect(old.toolOptions["smart-crop"] != nil && old.toolOptions["smart-crop"]?.aspect == nil)
    }

    @Test func badEditorMemoryKeysFallBackOneByOne() throws {
        let json = #"{"soundsEnabled":true,"editorMemory":{"targetBytes":{"pdf":2000000},"cropRatio":3,"redactionStyle":"blur"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.soundsEnabled)
        #expect(s.editorMemory.targetBytes == ["pdf": 2_000_000])
        #expect(s.editorMemory.cropRatio == "free" && s.editorMemory.redactionStyle == .fill)

        let wrong = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"editorMemory":"nope","soundsEnabled":true}"#.utf8))
        #expect(wrong.editorMemory == EditorMemory() && wrong.soundsEnabled)
    }
}

/// P95: the pre-rename settings blob moves into the new domain once. Both sides are in-memory defaults: a test never
/// reads or writes the real `io.github.kumquat-app.Kumquat` or `io.github.pomelo-app.Pomelo` domains.
@Suite struct SettingsMigrationTests {
    private func blob(_ settings: AppSettings) throws -> Data { try JSONEncoder().encode(settings) }

    @Test func theLegacyDomainIsTheOldBundleID() {
        #expect(SettingsMigration.legacyDomain == "io.github.kumquat-app.Kumquat")
    }

    @Test @MainActor func copiesTheOldBlobWhenTheNewDomainHasNone() throws {
        let old = EphemeralDefaults(), new = EphemeralDefaults()
        var settings = AppSettings()
        settings.trigger = .option
        settings.hasCompletedOnboarding = true
        settings.wheelOrder = ["image": ["png", "jpg"]]
        let data = try blob(settings)
        old.set(data, forKey: SettingsStore.key)
        old.set("unrelated", forKey: "other.key")

        #expect(SettingsMigration.copyLegacySettings(into: new, from: old))

        #expect(new.data(forKey: SettingsStore.key) == data)
        #expect(new.object(forKey: "other.key") == nil)
        #expect(SettingsStore(defaults: new).settings == settings)
        #expect(old.data(forKey: SettingsStore.key) == data)
        #expect(old.object(forKey: "other.key") as? String == "unrelated")
    }

    @Test func neverOverwritesAnExistingNewBlob() throws {
        let old = EphemeralDefaults(), new = EphemeralDefaults()
        var oldSettings = AppSettings()
        oldSettings.soundsEnabled = true
        let oldData = try blob(oldSettings)
        let newData = try blob(AppSettings())
        old.set(oldData, forKey: SettingsStore.key)
        new.set(newData, forKey: SettingsStore.key)

        #expect(!SettingsMigration.copyLegacySettings(into: new, from: old))

        #expect(new.data(forKey: SettingsStore.key) == newData)
        #expect(old.data(forKey: SettingsStore.key) == oldData)
    }

    @Test func doesNothingWithoutAnOldBlob() {
        let old = EphemeralDefaults(), new = EphemeralDefaults()
        #expect(!SettingsMigration.copyLegacySettings(into: new, from: old))
        #expect(new.object(forKey: SettingsStore.key) == nil)
        #expect(old.object(forKey: SettingsStore.key) == nil)
    }

    @Test func runsOnceThenLeavesTheNewDomainToTheUser() throws {
        let old = EphemeralDefaults(), new = EphemeralDefaults()
        var settings = AppSettings()
        settings.trigger = .control
        old.set(try blob(settings), forKey: SettingsStore.key)
        #expect(SettingsMigration.copyLegacySettings(into: new, from: old))

        var changed = settings
        changed.trigger = .shift
        let changedData = try blob(changed)
        new.set(changedData, forKey: SettingsStore.key)
        #expect(!SettingsMigration.copyLegacySettings(into: new, from: old))
        #expect(new.data(forKey: SettingsStore.key) == changedData)
    }

    @Test func phase5BlobDecodesWithoutWheels() throws {
        let json = #"{"trigger":"option","wheelOrder":{"image":["png","jpg"]},"toolVisibility":{"image":{"x":false}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.wheels == [:])
        #expect(s.trigger == .option)
        #expect(s.wheelOrder == ["image": ["png", "jpg"]])
        #expect(s.toolVisibility == ["image": ["x": false]])
    }

    @Test func decodesMalformedWheelsClamped() throws {
        let nine = (1...9).map { #""s\#($0)""# }
        let firstSlots = (["\"dup\"", "\"dup\""] + nine).joined(separator: ",")
        let longName = String(repeating: "a", count: 40)
        let pages = [
            #"{"name":"  ","slots":[\#(firstSlots)]}"#,
            #"{"name":"\#(longName)","slots":["a"]}"#,
            #"{"name":"C","slots":["a"]}"#,
            #"{"name":"D","slots":["a"]}"#,
            #"{"name":"E","slots":["a"]}"#,
        ].joined(separator: ",")
        let json = """
        {"trigger":"option","wheels":{
          "kind.image":{"pages":[\(pages)]},
          "kind.banana":{"pages":[{"name":"X","slots":["a"]}]},
          "format.png":{"pages":[]},
          "kind.pdf":5,
          "kind.video":{},
          "kind.audio":{"pages":[{"name":"Keep","slots":["a"]}]}
        }}
        """
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.trigger == .option)
        let image = try #require(s.wheels["kind.image"])
        #expect(image.pages.count == 4)
        #expect(image.pages[0].name == "Page 1")
        #expect(image.pages[0].slots == ["dup", "s1", "s2", "s3", "s4", "s5", "s6", "s7"])
        #expect(image.pages[1].name == String(repeating: "a", count: 20))
        #expect(s.wheels["kind.audio"]?.pages.first?.name == "Keep")
        #expect(Set(s.wheels.keys) == ["kind.image", "kind.audio"])
    }

    @Test func wheelsRoundTrip() throws {
        var s = AppSettings()
        s.wheels["kind.image"] = CustomWheel(pages: [CustomPage(name: "Mine", slots: ["a", "b"]), CustomPage(name: "More", slots: ["c"])])
        s.wheels["format.png"] = CustomWheel(pages: [CustomPage(name: "Page 1", slots: ["d"])])
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.wheels.count == 2)
    }
}
