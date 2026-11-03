import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct WatchFolderTests {
    // MARK: - Coding

    @Test func actionsCodeFlatWithTheirKind() throws {
        let convert = try JSONEncoder().encode(WatchAction.convert("jpg"))
        let tool = try JSONEncoder().encode(WatchAction.tool("compress"))
        let convertObject = try #require(JSONSerialization.jsonObject(with: convert) as? [String: String])
        let toolObject = try #require(JSONSerialization.jsonObject(with: tool) as? [String: String])
        #expect(convertObject == ["kind": "convert", "format": "jpg"])
        #expect(toolObject == ["kind": "tool", "tool": "compress"])
        #expect(try JSONDecoder().decode(WatchAction.self, from: convert) == .convert("jpg"))
        #expect(try JSONDecoder().decode(WatchAction.self, from: tool) == .tool("compress"))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchAction.self, from: Data(#"{"kind":"blur"}"#.utf8))
        }
    }

    @Test func aFolderRoundTripsWithItsBookmark() throws {
        let folder = WatchFolder(
            id: UUID(), path: "/tmp/in", bookmark: Data([1, 2, 3]), action: .tool("compress"), isEnabled: false
        )
        let back = try JSONDecoder().decode(WatchFolder.self, from: JSONEncoder().encode(folder))
        #expect(back == folder)
    }

    @Test func aFolderWithoutIsEnabledIsOn() throws {
        let json = #"{"id":"\#(UUID().uuidString)","path":"/a","action":{"kind":"tool","tool":"compress"}}"#
        let folder = try JSONDecoder().decode(WatchFolder.self, from: Data(json.utf8))
        #expect(folder.isEnabled)
        #expect(folder.bookmark == nil)
    }

    @Test func anUnknownActionKindDropsOnlyThatFolder() throws {
        let good = #"{"id":"\#(UUID().uuidString)","path":"/a","action":{"kind":"convert","format":"png"},"isEnabled":true}"#
        let bad = #"{"id":"\#(UUID().uuidString)","path":"/b","action":{"kind":"blur"},"isEnabled":true}"#
        let alsoGood = #"{"id":"\#(UUID().uuidString)","path":"/c","action":{"kind":"tool","tool":"compress"},"isEnabled":false}"#
        let json = #"{"trigger":"option","watchFolders":[\#(good),\#(bad),\#(alsoGood)]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.watchFolders.map(\.path) == ["/a", "/c"])
        #expect(settings.watchFolders.map(\.isEnabled) == [true, false])
        #expect(settings.trigger == .option)
    }

    @Test func oldSettingsDecodeWithNoWatchFolders() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"trigger":"option"}"#.utf8))
        #expect(settings.watchFolders.isEmpty)
        let wrongType = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"watchFolders":7,"soundsEnabled":true}"#.utf8))
        #expect(wrongType.watchFolders.isEmpty)
        #expect(wrongType.soundsEnabled)
    }

    @Test func watchFoldersSurviveTheSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.watchFolders = [WatchFolder(path: "/in", action: .convert("webp"))]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.watchFolders == settings.watchFolders)
        #expect(back.watchFolders.first?.isEnabled == true)
    }

    // MARK: - ArrivalFilter

    @Test func partialDownloadNamesAreNeverCandidates() {
        for name in ["a.crdownload", "b.download", "c.part", ".DS_Store", "~$doc.docx", "A.PART", "d.partial",
                     "e.tmp", "f.opdownload", "g.!qb", "H.CrDownload"] {
            #expect(!candidate(name), "\(name)")
        }
        #expect(candidate("photo.jpg"))
        #expect(candidate("report.part.pdf"))
        #expect(candidate("my~$file.txt"))
    }

    @Test func markedFilesAndLinksAreNeverCandidates() {
        #expect(!candidate("photo.jpg", isMarked: true))
        #expect(!candidate("photo.jpg", isSymbolicLink: true))
        #expect(!candidate("photo.jpg", isRegularFile: false))
        #expect(!candidate("photo.jpg", isRegularFile: true, isSymbolicLink: true))
    }

    private func candidate(
        _ name: String, isRegularFile: Bool = true, isSymbolicLink: Bool = false, isMarked: Bool = false
    ) -> Bool {
        ArrivalFilter.isCandidate(
            name: name, isRegularFile: isRegularFile, isSymbolicLink: isSymbolicLink, isMarked: isMarked
        )
    }

    // MARK: - SettleTracker

    /// `#expect` can't take a mutating call on a struct.
    private final class Probe {
        var tracker = SettleTracker()
        var pending: Set<URL> { tracker.pending }
        func observe(_ url: URL, size: Int64, modified: Date, isLocal: Bool, at now: ContinuousClock.Instant) -> Bool {
            tracker.observe(url, size: size, modified: modified, isLocal: isLocal, at: now)
        }
        func forget(_ url: URL) { tracker.forget(url) }
        func nextLook(at now: ContinuousClock.Instant) -> Duration? { tracker.nextLook(at: now) }
    }

    private let file = URL(fileURLWithPath: "/watched/a.jpg")
    private let date = Date(timeIntervalSince1970: 1_000)

    @Test func aSteadyFileIsReadyAfterTheInterval() {
        let tracker = Probe()
        let t0 = ContinuousClock.now
        #expect(!tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0))
        #expect(!tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .milliseconds(500)))
        #expect(tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .seconds(1)))
        #expect(tracker.pending.isEmpty)
        // Ready once per state; a change makes it ready again after the interval.
        #expect(!tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .seconds(2)))
        #expect(!tracker.observe(file, size: 11, modified: date, isLocal: true, at: t0 + .seconds(3)))
        #expect(tracker.observe(file, size: 11, modified: date, isLocal: true, at: t0 + .seconds(4)))
    }

    @Test func aGrowingFileIsNotReady() {
        let tracker = Probe()
        let t0 = ContinuousClock.now
        for (second, size) in [(0, 10), (1, 20), (2, 30)] as [(Int, Int64)] {
            #expect(!tracker.observe(file, size: size, modified: date, isLocal: true, at: t0 + .seconds(second)))
        }
        #expect(tracker.pending == [file])
        #expect(tracker.observe(file, size: 30, modified: date, isLocal: true, at: t0 + .seconds(3)))
    }

    @Test func aRewrittenFileWithTheSameSizeIsNotReady() {
        let tracker = Probe()
        let t0 = ContinuousClock.now
        #expect(!tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0))
        #expect(!tracker.observe(file, size: 10, modified: date + 1, isLocal: true, at: t0 + .seconds(1)))
        #expect(tracker.observe(file, size: 10, modified: date + 1, isLocal: true, at: t0 + .seconds(2)))
    }

    @Test func anEmptyOrRemoteFileIsNotReady() {
        let tracker = Probe()
        let t0 = ContinuousClock.now
        #expect(!tracker.observe(file, size: 0, modified: date, isLocal: true, at: t0))
        #expect(!tracker.observe(file, size: 0, modified: date, isLocal: true, at: t0 + .seconds(5)))
        let cloud = URL(fileURLWithPath: "/watched/cloud.jpg")
        #expect(!tracker.observe(cloud, size: 10, modified: date, isLocal: false, at: t0))
        #expect(!tracker.observe(cloud, size: 10, modified: date, isLocal: false, at: t0 + .seconds(5)))
        // It downloads: the clock starts when the content is local.
        #expect(!tracker.observe(cloud, size: 10, modified: date, isLocal: true, at: t0 + .seconds(6)))
        #expect(tracker.observe(cloud, size: 10, modified: date, isLocal: true, at: t0 + .seconds(7)))
    }

    @Test func forgetDropsAFileAndFilesSettleIndependently() {
        let tracker = Probe()
        let other = URL(fileURLWithPath: "/watched/b.jpg")
        let t0 = ContinuousClock.now
        _ = tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0)
        _ = tracker.observe(other, size: 5, modified: date, isLocal: true, at: t0 + .milliseconds(600))
        #expect(tracker.pending == [file, other])
        #expect(tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .seconds(1)))
        #expect(!tracker.observe(other, size: 5, modified: date, isLocal: true, at: t0 + .seconds(1)))
        tracker.forget(other)
        #expect(tracker.pending.isEmpty)
        #expect(!tracker.observe(other, size: 5, modified: date, isLocal: true, at: t0 + .seconds(3)))
    }

    /// A file that can't settle (empty, not local, still marked as being copied) is looked at less and less often,
    /// doubling up to a minute; anything that can settle, or a change, brings back the second.
    @Test func aFileThatCannotSettleIsLookedAtLessOften() throws {
        let tracker = Probe()
        let t0 = ContinuousClock.now
        #expect(tracker.nextLook(at: t0) == nil)
        _ = tracker.observe(file, size: 0, modified: date, isLocal: true, at: t0)
        #expect(tracker.nextLook(at: t0) == SettleTracker.interval)
        var waits: [Duration] = []
        var now = t0
        for _ in 0..<12 {
            let wait = try #require(tracker.nextLook(at: now))
            waits.append(wait)
            now += wait
            #expect(!tracker.observe(file, size: 0, modified: date, isLocal: true, at: now))
        }
        #expect(waits == [1, 1, 2, 4, 8, 16, 32, 60, 60, 60, 60, 60].map { Duration.seconds($0) })
        // Written to at last: the next look is a second away again, and it settles.
        #expect(!tracker.observe(file, size: 10, modified: date + 1, isLocal: true, at: now))
        #expect(tracker.nextLook(at: now) == SettleTracker.interval)
        #expect(tracker.observe(file, size: 10, modified: date + 1, isLocal: true, at: now + .seconds(1)))
        #expect(tracker.nextLook(at: now + .seconds(1)) == nil)
    }

    @Test func aFileThatCanSettleKeepsTheSecondBesideAStuckOne() {
        let tracker = Probe()
        let cloud = URL(fileURLWithPath: "/watched/cloud.jpg")
        let t0 = ContinuousClock.now
        _ = tracker.observe(cloud, size: 10, modified: date, isLocal: false, at: t0)
        _ = tracker.observe(cloud, size: 10, modified: date, isLocal: false, at: t0 + .seconds(40))
        #expect(tracker.nextLook(at: t0 + .seconds(40)) == .seconds(40))
        _ = tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .seconds(40))
        #expect(tracker.nextLook(at: t0 + .seconds(40)) == SettleTracker.interval)
        // A file reported ready is no longer pending, so only the stuck one sets the pace.
        #expect(tracker.observe(file, size: 10, modified: date, isLocal: true, at: t0 + .seconds(41)))
        #expect(tracker.nextLook(at: t0 + .seconds(41)) == .seconds(41))
    }

    // MARK: - WatchRules

    private static let planner = RoutePlanner(
        edges: [
            ConversionEdge(from: "png", to: "jpg", engineID: "fake", cost: 1, flags: []),
            ConversionEdge(from: "jpg", to: "png", engineID: "fake", cost: 1, flags: []),
            ConversionEdge(from: "jpg", to: "jpg", engineID: "fake", cost: 1, flags: []),
            ConversionEdge(from: "jpg", to: "jpg", engineID: "fake", cost: 1, flags: [], operation: "compress"),
            ConversionEdge(from: "txt", to: "txt", engineID: "fake", cost: 1, flags: [], operation: "compress"),
        ],
        enginePriority: ["fake"]
    )
    private static let tools = IntentCatalog.tools(settings: AppSettings(), includingCombines: false)

    private func request(_ action: WatchAction, _ name: String) -> ConversionRequest? {
        WatchRules.request(
            for: action, file: URL(fileURLWithPath: "/watched/\(name)"), formats: .builtIn,
            planner: Self.planner, tools: Self.tools
        )
    }

    @Test func aConvertRuleBuildsAPlainRequest() throws {
        let made = try #require(request(.convert("jpg"), "shot.PNG"))
        #expect(made.target == "jpg")
        #expect(made.inputs == [URL(fileURLWithPath: "/watched/shot.PNG")])
        #expect(made.operation == nil)
    }

    @Test func aRuleSkipsFilesAlreadyInItsTarget() {
        #expect(request(.convert("jpg"), "a.jpg") == nil)
        #expect(request(.convert("jpg"), "a.jpeg") == nil)
    }

    @Test func aRuleSkipsFilesWithoutARoute() {
        #expect(request(.convert("jpg"), "a.txt") == nil)
        #expect(request(.convert("jpg"), "a.unknownext") == nil)
        #expect(request(.convert("nonsense"), "a.png") == nil)
    }

    @Test func aToolRuleNeedsTheCategoryAndTheEdge() throws {
        // .txt has a compress edge here, but compress does not take the text category.
        #expect(request(.tool("compress"), "a.txt") == nil)
        // .png is an image but has no compress edge.
        #expect(request(.tool("compress"), "a.png") == nil)
        let made = try #require(request(.tool("compress"), "a.jpg"))
        #expect(made.nameSuffix == "compressed")
        #expect(made.operation == "compress")
        #expect(made.target == nil)
        #expect(made.onlyIfSmaller)
        #expect(request(.tool("no-such-tool"), "a.jpg") == nil)
    }

    @Test func aRuleNeverReplacesTheOriginal() throws {
        var settings = AppSettings()
        settings.replaceOriginal = true
        let tools = IntentCatalog.tools(settings: settings, includingCombines: false)
        let made = try #require(WatchRules.request(
            for: .tool("compress"), file: URL(fileURLWithPath: "/watched/a.jpg"), formats: .builtIn,
            planner: Self.planner, tools: tools
        ))
        #expect(!made.replaceOriginal)
        #expect(try #require(request(.convert("png"), "a.jpg")).replaceOriginal == false)
    }

    @Test func aToolRuleOnACombineOrEditorIsNil() {
        let merge = Preset(id: "merge", name: "Merge", target: "pdf", categories: [.pdf], combinesInputs: true)
        let editor = Preset(id: "e", name: "E", target: nil, categories: [.image], operation: "compress", needsInput: true)
        for preset in [merge, editor] {
            #expect(WatchRules.request(
                for: .tool(preset.id), file: URL(fileURLWithPath: "/w/a.jpg"), formats: .builtIn,
                planner: Self.planner, tools: [preset]
            ) == nil)
        }
    }

    @Test func choicesLeaveOutEditorsAndCombines() {
        let all = ToolCatalog.presets(settings: AppSettings())
        let choices = WatchRules.choices(formats: .builtIn, planner: Self.planner, tools: all)
        let ids = choices.tools.map(\.id)
        for hidden in ["trim", "split-video", "crop", "compress-to-size", "redact", "organize-pages", "merge-pdfs",
                       "images-to-pdf", "find-duplicates", "read-codes"] {
            #expect(!ids.contains(hidden), "\(hidden)")
        }
        #expect(ids.contains("compress"))
        #expect(choices.formats.map(\.id) == ["jpg", "png"])
    }
}
