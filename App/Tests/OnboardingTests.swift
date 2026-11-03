import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

/// A test's own practice root (never the real `$TMPDIR/Pomelo Practice`), removed with the test's scope.
private func makeScratchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PomeloOnboardingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A scratch root, a practice run's folder inside it and a stand-in "bundled sample".
private func makeScratch() throws -> (root: URL, folder: PracticeFolder, sample: URL) {
    let root = try makeScratchRoot()
    let sample = root.appendingPathComponent("bundled.heic")
    try Data("sample".utf8).write(to: sample)
    return (root, PracticeFolder.fresh(in: root), sample)
}

@Suite struct PracticeFolderTests {
    @Test func theStandardRootIsPomeloPracticeInTheTemporaryDirectory() {
        let root = PracticeFolder.standardRoot
        #expect(root.lastPathComponent == "Pomelo Practice")
        #expect(root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test func eachPracticeRunGetsAFreshUUIDFolderInsideTheRoot() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PracticeFolder.fresh(in: root)
        let second = PracticeFolder.fresh(in: root)
        #expect(first.directory != second.directory)
        #expect(first.directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(UUID(uuidString: first.directory.lastPathComponent) != nil)
    }

    @Test func prepareCreatesTheFolderAndCopiesTheSample() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try folder.prepare(copying: sample)
        #expect(copy == folder.sampleURL)
        #expect(copy.lastPathComponent == "Sample.heic")
        #expect(try Data(contentsOf: copy) == Data("sample".utf8))
        // The bundled original is untouched.
        #expect(FileManager.default.fileExists(atPath: sample.path))
    }

    /// P21: a new run starts clean because its folder is new, so nothing is ever removed.
    @Test func aNewPracticeRunStartsCleanAndLeavesAnEarlierOneInPlace() throws {
        let (root, earlier, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try earlier.prepare(copying: sample)
        try Data("old png".utf8).write(to: earlier.outputURL)
        try Data("edited".utf8).write(to: earlier.sampleURL)

        let next = PracticeFolder.fresh(in: root)
        try next.prepare(copying: sample)
        #expect(!next.hasConvertedOutput)
        #expect(try Data(contentsOf: next.sampleURL) == Data("sample".utf8))
        #expect(try Data(contentsOf: earlier.outputURL) == Data("old png".utf8))
        #expect(try Data(contentsOf: earlier.sampleURL) == Data("edited".utf8))
    }

    @Test func prepareFailsCleanlyWhenTheSampleIsMissing() throws {
        let (root, folder, _) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) {
            try folder.prepare(copying: root.appendingPathComponent("nope.heic"))
        }
    }

    @Test func convertedOutputIsDetectedByTheSamplePNGOnly() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try folder.prepare(copying: sample)
        #expect(!folder.hasConvertedOutput)
        try Data("x".utf8).write(to: folder.directory.appendingPathComponent("Other.png"))
        #expect(!folder.hasConvertedOutput)
        try Data("x".utf8).write(to: folder.outputURL)
        #expect(folder.hasConvertedOutput)
    }

    @Test func theAppBundlesTheSamplePhotoAsAReadableHEIC() throws {
        let url = try #require(Bundle.main.url(forResource: "Sample", withExtension: "heic"))
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 < 300_000)
        #expect(NSImage(contentsOf: url) != nil)
    }
}

@MainActor
@Suite struct PracticeFolderWatcherTests {
    @Test func reportsAFileAppearingInTheFolder() async throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try folder.prepare(copying: sample)
        var changes = 0
        let watcher = try #require(PracticeFolderWatcher(directory: folder.directory) { changes += 1 })
        defer { watcher.stop() }
        try Data("png".utf8).write(to: folder.outputURL)
        for _ in 0..<40 where changes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changes > 0)
    }

    @Test func stopsReportingAfterStop() async throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try folder.prepare(copying: sample)
        var changes = 0
        let watcher = try #require(PracticeFolderWatcher(directory: folder.directory) { changes += 1 })
        watcher.stop()
        watcher.stop()
        try Data("png".utf8).write(to: folder.outputURL)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)
    }

    @Test func aMissingFolderCannotBeWatched() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(PracticeFolderWatcher(directory: missing) {} == nil)
    }
}

@MainActor
@Suite struct OnboardingModelTests {
    @Test func startsUnconvertedWithTheSampleReady() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // An earlier run's PNG, in its own folder, does not count for this run.
        let earlier = PracticeFolder.fresh(in: root)
        try earlier.prepare(copying: sample)
        try Data("old png".utf8).write(to: earlier.outputURL)
        let model = OnboardingModel(trigger: .shift, folder: folder, bundledSample: sample)
        defer { model.teardown() }
        #expect(model.practiceFile == folder.sampleURL)
        #expect(model.errorMessage == nil)
        #expect(!model.converted)
        #expect(!model.triggerHeld)
    }

    @Test func theCheckmarkAppearsWhenThePNGLands() async throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = OnboardingModel(trigger: .shift, folder: folder, bundledSample: sample)
        defer { model.teardown() }
        try Data("png".utf8).write(to: folder.outputURL)
        for _ in 0..<40 where !model.converted { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.converted)
    }

    @Test func aMissingBundledSampleIsReportedNotCrashed() throws {
        let (root, folder, _) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = OnboardingModel(trigger: .shift, folder: folder, bundledSample: nil)
        defer { model.teardown() }
        #expect(model.practiceFile == nil)
        #expect(model.errorMessage != nil)
    }

    @Test func theTriggerGlyphFollowsTheModifierFlags() {
        #expect(OnboardingModel.isHeld(.shift, in: [.shift]))
        #expect(!OnboardingModel.isHeld(.shift, in: [.option]))
        #expect(OnboardingModel.isHeld(.option, in: [.option, .shift]))
        #expect(OnboardingModel.isHeld(.control, in: [.control]))
        #expect(OnboardingModel.isHeld(.command, in: [.command]))
        #expect(!OnboardingModel.isHeld(.command, in: []))
    }

    @Test func theDragItemIsAFileURLTheDragMonitorCanRead() async throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try folder.prepare(copying: sample)
        let provider = OnboardingView.provider(for: file)
        #expect(provider.hasItemConformingToTypeIdentifier("public.file-url"))
        // Write it to a private pasteboard the way a drag does, then read it back the way DragMonitor does.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.pomelo-app.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(read?.map(\.lastPathComponent) == ["Sample.heic"])
    }
}

@MainActor
@Suite struct OnboardingPageTests {
    private func makeModel(in root: URL, sample: URL, folder: PracticeFolder,
                           wheelContent: @escaping @MainActor () -> WheelContentBuilder? = { nil }) -> OnboardingModel {
        OnboardingModel(trigger: .shift, folder: folder, bundledSample: sample, wheelContent: wheelContent)
    }

    @Test func thePagesGoInOrder() {
        #expect(OnboardingPage.allCases == [.practice, .morePages, .makeItYours])
        #expect(OnboardingPage.practice.previous == nil)
        #expect(OnboardingPage.practice.next == .morePages)
        #expect(OnboardingPage.makeItYours.next == nil)
        #expect(OnboardingPage.allCases.filter(\.isLast) == [.makeItYours])
    }

    @Test func nextAndBackMoveOnePageAndDoneFinishesOnlyOnTheLast() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(in: root, sample: sample, folder: folder)
        defer { model.teardown() }
        var finished = 0
        #expect(model.page == .practice)
        model.goBack()
        #expect(model.page == .practice)

        model.advance { finished += 1 }
        #expect(model.page == .morePages)
        model.advance { finished += 1 }
        #expect(model.page == .makeItYours)
        #expect(finished == 0)

        model.goBack()
        #expect(model.page == .morePages)
        model.advance { finished += 1 }
        model.advance { finished += 1 }
        #expect(model.page == .makeItYours)
        #expect(finished == 1)
    }

    @Test func theSecondPageDrawsTheRealWheelForThePracticePhoto() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let planner = RoutePlanner(edges: [ConversionEdge(from: "heic", to: "png", engineID: "x", cost: 1, flags: [])],
                                   enginePriority: ["x"])
        let builder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner, installHints: [:],
                                          tools: [])
        var asked = 0
        let model = makeModel(in: root, sample: sample, folder: folder) {
            asked += 1
            return builder
        }
        defer { model.teardown() }
        // Read when the page is first shown, not before: the first launch's welcome opens before the content exists.
        #expect(asked == 0)
        model.show(.morePages)
        #expect(asked == 1)
        let convert = try #require(model.wheels[.convert])
        #expect(convert.page?.kind == .convert)
        #expect(convert.files == [folder.sampleURL])
        #expect(convert.slices.map(\.id).contains("convert.png"))
        #expect(model.wheels[.tools]?.page?.kind == .tools)
        // No AI tool can run with this content: that card falls back to its symbol.
        #expect(model.wheels[.ai] == nil)
        model.goBack()
        model.show(.morePages)
        #expect(asked == 1)
    }

    @Test func withoutWheelContentTheSecondPageFallsBackToCards() throws {
        let (root, folder, sample) = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(in: root, sample: sample, folder: folder)
        defer { model.teardown() }
        model.show(.morePages)
        #expect(model.page == .morePages)
        #expect(model.wheels.isEmpty)
    }
}

@Suite struct OnboardingCopyTests {
    @Test func lastStepMentionsTheShelf() {
        #expect(OnboardingView.shelfSentence == "Shake files while you drag them to keep them on the Shelf.")
    }

    @Test func theLastPageKeepsThePrivacySentence() {
        #expect(OnboardingView.privacySentence == "Everything stays on your Mac, and your originals are never changed.")
    }

    @Test func theSecondPageNamesTheTriggerAndTheThreeWheelPages() {
        #expect(OnboardingView.morePagesTitle == "More than converting")
        #expect(OnboardingView.morePagesSubtitle(glyph: "\u{21E7}")
            == "Tap \u{21E7} again while you drag to flip the wheel between its pages.")
        #expect(OnboardingView.wheelCaptions.map(\.kind) == [.convert, .tools, .ai])
        #expect(OnboardingView.wheelCaptions.map(\.title) == ["Convert", "Tools", "AI"])
        #expect(OnboardingView.wheelCaptions.map(\.detail) == [
            "50+ formats", "Compress, crop, resize, redact", "On device: remove background, smart crop, scan text",
        ])
    }

    /// The captions name tools the image wheel shows by default (`ToolCatalog`), so they stay true.
    @Test func theCaptionsNameToolsTheImageWheelShowsByDefault() throws {
        for id in ["compress", "crop", "resize", "redact"] {
            let tool = try #require(ToolCatalog.info(id))
            #expect(tool.shownByDefault.contains(.image) && !tool.isAI, "\(id)")
        }
        for id in ["remove-background", "smart-crop", "scan-document"] {
            let tool = try #require(ToolCatalog.info(id))
            #expect(tool.shownByDefault.contains(.image) && tool.isAI, "\(id)")
        }
    }

    @Test func theLastPageCopy() {
        #expect(OnboardingView.makeItYoursTitle == "Make it yours")
        #expect(OnboardingView.wheelSentence
            == "Choose what the wheel shows for each kind of file, on up to four pages you name.")
        #expect(OnboardingView.automationSentence
            == "Convert from Shortcuts, from watch folders, or with the Finder Quick Action.")
    }

    /// P32: no "·" or "—" as a separator in the welcome's copy.
    @Test func theCopyHasNoSeparatorGlyphs() {
        let copy = [OnboardingView.shelfSentence, OnboardingView.hotkeySentence, OnboardingView.privacySentence,
                    OnboardingView.morePagesTitle, OnboardingView.morePagesSubtitle(glyph: "\u{21E7}"),
                    OnboardingView.makeItYoursTitle, OnboardingView.makeItYoursSubtitle,
                    OnboardingView.wheelSentence, OnboardingView.automationSentence]
            + OnboardingView.wheelCaptions.map(\.detail)
        for text in copy {
            #expect(!text.contains("\u{00B7}") && !text.contains("\u{2014}"), "\(text)")
        }
    }

    @Test func theWelcomeMentionsTheClickModeHotkey() {
        #expect(OnboardingView.hotkeySentence == "No drag needed: select files in Finder and press \u{2325}\u{2318}K.")
    }
}

@MainActor
@Suite struct OnboardingControllerTests {
    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: EphemeralDefaults())
    }

    /// A controller whose practice runs go to the test's own root, never the real `$TMPDIR/Pomelo Practice`.
    private func makeController(store: SettingsStore, root: URL) -> OnboardingController {
        OnboardingController(settings: store, practiceRoot: root)
    }

    @Test func pressingDoneRecordsOnboardingAndClosesTheWindow() async throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        controller.show()
        #expect(controller.isShowing)

        controller.finish()
        #expect(store.settings.hasCompletedOnboarding)
        // The close happens on the next main-actor turn, after the button's action has returned.
        for _ in 0..<40 where controller.isShowing { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!controller.isShowing)
        #expect(controller.window == nil)
    }

    /// The welcome shows once, at the first launch: it counts as seen as soon as it opens, so quitting Pomelo with
    /// the window still open (no close is sent then) doesn't bring it back. The menu's Show Welcome still opens it.
    @Test func showingTheWelcomeCountsAsSeenAtOnce() throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        #expect(!store.settings.hasCompletedOnboarding)
        controller.show()
        #expect(controller.isShowing)
        #expect(store.settings.hasCompletedOnboarding)
        controller.window?.close()
        #expect(!controller.isShowing)
        #expect(store.settings.hasCompletedOnboarding)
    }

    @Test func theWindowOpensOnTheFirstPageAndDoneOnTheLastPageCloses() async throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        controller.show()
        let model = try #require(controller.model)
        #expect(model.page == .practice)
        model.advance(finish: controller.finish)
        model.advance(finish: controller.finish)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.isShowing)
        #expect(model.page == .makeItYours)
        model.advance(finish: controller.finish)
        for _ in 0..<40 where controller.isShowing { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!controller.isShowing)
    }

    /// The window's close button works on any page.
    @Test func closingOnTheMiddlePageClosesTheWelcome() throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        controller.show()
        controller.model?.show(.morePages)
        controller.window?.performClose(nil)
        #expect(!controller.isShowing)
        #expect(controller.model == nil)
        #expect(store.settings.hasCompletedOnboarding)
    }

    @Test func aShownWelcomeReadsTheAppsWheelContent() throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        var asked = 0
        controller.wheelContent = {
            asked += 1
            return nil
        }
        controller.show()
        defer { controller.window?.close() }
        controller.model?.show(.morePages)
        #expect(asked == 1)
    }

    @Test func showingAgainAfterClosingOpensAFreshWindow() throws {
        let store = makeStore()
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(store: store, root: root)
        controller.show()
        let first = try #require(try FileManager.default.contentsOfDirectory(atPath: root.path).first)
        controller.window?.close()
        controller.show()
        #expect(controller.isShowing)
        // The second run has its own folder; the first run's is still there, untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(first).appendingPathComponent(PracticeFolder.sampleName).path))
        controller.window?.close()
    }
}
