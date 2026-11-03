import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import SwiftUI
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

/// What the folder chooser answers, in order: nil is a cancel.
@MainActor
private final class Chooser {
    var answers: [URL?]
    var asked = 0
    init(_ answers: [URL?]) { self.answers = answers }

    func choose() -> URL? {
        asked += 1
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

private let jpeg = FormatRegistry.builtIn.format(id: "jpg")!
private let png = FormatRegistry.builtIn.format(id: "png")!
private let compress = Preset.builtIns.first { $0.id == "compress" }!

@MainActor
@Suite struct WatchFoldersPaneModelTests {
    private struct Setup {
        let model: WatchFoldersPaneModel
        let store: SettingsStore
        let chooser: Chooser
    }

    private func makeModel(
        choosing answers: [URL?], manager: WatchFolderManager? = nil, store: SettingsStore? = nil
    ) -> Setup {
        let store = store ?? SettingsStore(defaults: EphemeralDefaults())
        let chooser = Chooser(answers)
        let model = WatchFoldersPaneModel(
            store: store, manager: manager, chooseFolder: { chooser.choose() },
            loadChoices: { (formats: [jpeg, png], tools: [compress]) }
        )
        return Setup(model: model, store: store, chooser: chooser)
    }

    @Test func addingAFolderStoresItsPathAndBookmark() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = makeModel(choosing: [dir])
        await setup.model.add()
        let folder = try #require(setup.store.settings.watchFolders.first)
        #expect(setup.store.settings.watchFolders.count == 1)
        #expect(folder.path == dir.path)
        #expect(folder.isEnabled)
        #expect(folder.action == .convert("jpg"))
        var isStale = false
        let resolved = try URL(resolvingBookmarkData: try #require(folder.bookmark), bookmarkDataIsStale: &isStale)
        #expect(canonical(resolved.path) == canonical(dir.path))
        #expect(setup.model.message == nil)
    }

    @Test func addingTheSameFolderTwiceIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = makeModel(choosing: [dir, dir.appending(path: "../\(dir.lastPathComponent)", directoryHint: .isDirectory)])
        await setup.model.add()
        await setup.model.add()
        #expect(setup.store.settings.watchFolders.count == 1)
        #expect(setup.model.message == "That folder is already watched")
    }

    @Test func aRenamedFolderIsStillTheSameFolder() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let before = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        let after = parent.appending(path: "Inbox 2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: false)
        let setup = makeModel(choosing: [before, after])
        await setup.model.add()
        try FileManager.default.moveItem(at: before, to: after)
        await setup.model.add()
        #expect(setup.store.settings.watchFolders.count == 1)
        #expect(setup.model.message == WatchFoldersPaneModel.alreadyWatched)
    }

    @Test func aRefusalClearsWhenTheNextFolderIsAdded() async throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let setup = makeModel(choosing: [first, first, second])
        await setup.model.add()
        await setup.model.add()
        #expect(setup.model.message != nil)
        await setup.model.add()
        #expect(setup.store.settings.watchFolders.count == 2)
        #expect(setup.model.message == nil)
    }

    @Test func cancellingTheChooserAddsNothing() async {
        let setup = makeModel(choosing: [nil])
        await setup.model.add()
        #expect(setup.chooser.asked == 1)
        #expect(setup.store.settings.watchFolders.isEmpty)
        #expect(setup.model.message == nil)
    }

    @Test func removingKeepsTheFolderOnDisk() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "keep.txt")
        try Data("x".utf8).write(to: file)
        let setup = makeModel(choosing: [dir])
        await setup.model.add()
        let id = try #require(setup.store.settings.watchFolders.first?.id)
        setup.model.remove(id)
        #expect(setup.store.settings.watchFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func changingTheActionAndTheSwitchIsSaved() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = EphemeralDefaults()
        let setup = makeModel(choosing: [dir], store: SettingsStore(defaults: defaults))
        await setup.model.add()
        let id = try #require(setup.store.settings.watchFolders.first?.id)
        setup.model.setAction(.tool("compress"), for: id)
        setup.model.setEnabled(false, for: id)
        let reopened = SettingsStore(defaults: defaults).settings.watchFolders
        #expect(reopened.count == 1)
        #expect(reopened.first?.action == .tool("compress"))
        #expect(reopened.first?.isEnabled == false)
        setup.model.setEnabled(true, for: id)
        #expect(setup.store.settings.watchFolders.first?.isEnabled == true)
    }

    @Test func editingAnUnknownFolderChangesNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = makeModel(choosing: [dir])
        await setup.model.add()
        let before = setup.store.settings.watchFolders
        setup.model.setAction(.tool("compress"), for: UUID())
        setup.model.setEnabled(false, for: UUID())
        setup.model.remove(UUID())
        #expect(setup.store.settings.watchFolders == before)
    }

    // MARK: - Loading

    @Test func loadingFillsTheChoices() async {
        let setup = makeModel(choosing: [])
        await setup.model.load()
        #expect(setup.model.formats.map(\.id) == ["jpg", "png"])
        #expect(setup.model.tools.map(\.id) == ["compress"])
    }

    @Test func loadingFollowsAFolderThatWasRenamed() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let before = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        let after = parent.appending(path: "Renamed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: false)
        let setup = makeModel(choosing: [before])
        await setup.model.add()
        try FileManager.default.moveItem(at: before, to: after)
        await setup.model.load()
        let folder = try #require(setup.store.settings.watchFolders.first)
        #expect(canonical(folder.path) == canonical(after.path))
        #expect(WatchFoldersPaneModel.name(of: folder) == "Renamed")
    }

    @Test func loadingLeavesAFolderThatDidNotMoveAsItIs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = makeModel(choosing: [dir])
        await setup.model.add()
        let before = setup.store.settings.watchFolders
        await setup.model.load()
        #expect(setup.store.settings.watchFolders == before)
    }

    @Test func loadingKeepsThePathOfAFolderThatIsGone() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let gone = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: false)
        let setup = makeModel(choosing: [gone])
        await setup.model.add()
        try FileManager.default.removeItem(at: gone)
        let before = setup.store.settings.watchFolders
        await setup.model.load()
        #expect(setup.store.settings.watchFolders == before)
    }

    // MARK: - What the pane shows

    @Test func theStateLineIsMissingOrTheProblemAndNothingWhileOff() {
        let problem = "Couldn't convert IMG_1.heic. The file may be damaged."
        #expect(WatchFoldersPaneModel.status(isEnabled: true, state: .missing, problem: nil) == .missing)
        #expect(WatchFoldersPaneModel.status(isEnabled: true, state: .missing, problem: problem) == .missing)
        #expect(WatchFoldersPaneModel.status(isEnabled: true, state: .watching, problem: problem) == .problem(problem))
        #expect(WatchFoldersPaneModel.status(isEnabled: true, state: .watching, problem: nil) == nil)
        #expect(WatchFoldersPaneModel.status(isEnabled: true, state: nil, problem: nil) == nil)
        #expect(WatchFoldersPaneModel.status(isEnabled: false, state: .off, problem: problem) == nil)
    }

    @Test func aFolderTheManagerCannotFindShowsAsMissing() async throws {
        let store = SettingsStore(defaults: EphemeralDefaults())
        let lost = WatchFolder(path: "/nonexistent/pomelo-test-\(UUID().uuidString)", action: .convert("jpg"))
        store.settings.watchFolders = [lost]
        let manager = WatchFolderManager(
            settings: store, registry: EngineRegistry(engines: [], priority: []), run: { _, _ in [] }
        )
        manager.start()
        defer { manager.stop() }
        #expect(await eventually { manager.states[lost.id] == .missing })
        let setup = makeModel(choosing: [], manager: manager, store: store)
        #expect(setup.model.status(of: lost) == .missing)
    }

    @Test func aFolderDeletedWhileThePaneIsShownReadsMissing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(defaults: EphemeralDefaults())
        let manager = WatchFolderManager(
            settings: store, registry: EngineRegistry(engines: [], priority: []), run: { _, _ in [] }
        )
        let setup = makeModel(choosing: [dir], manager: manager, store: store)
        await setup.model.add()
        let folder = try #require(store.settings.watchFolders.first)
        manager.start()
        defer { manager.stop() }
        #expect(await eventually { manager.states[folder.id] == .watching })
        await setup.model.load()
        #expect(setup.model.status(of: folder) == nil)

        try FileManager.default.removeItem(at: dir)
        await setup.model.refreshStates()
        #expect(setup.model.status(of: folder) == .missing)
    }

    @Test func refreshingFindsAFolderThatCameBack() async throws {
        let parent = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appending(path: "Inbox", directoryHint: .isDirectory)
        let store = SettingsStore(defaults: EphemeralDefaults())
        store.settings.watchFolders = [WatchFolder(path: dir.path, action: .convert("jpg"))]
        let folder = store.settings.watchFolders[0]
        let manager = WatchFolderManager(
            settings: store, registry: EngineRegistry(engines: [], priority: []), run: { _, _ in [] }
        )
        manager.start()
        defer { manager.stop() }
        let setup = makeModel(choosing: [], manager: manager, store: store)
        #expect(await eventually { manager.states[folder.id] == .missing })

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        await setup.model.refreshStates()
        #expect(await eventually { manager.states[folder.id] == .watching })
        #expect(setup.model.status(of: folder) == nil)
    }

    @Test func withoutAManagerNothingIsReported() {
        let folder = WatchFolder(path: "/tmp/x", action: .convert("jpg"))
        #expect(makeModel(choosing: []).model.status(of: folder) == nil)
    }

    @Test func theActionMenuListsConversionsThenToolsAndKeepsTheCurrentAction() async {
        let setup = makeModel(choosing: [])
        await setup.model.load()
        let plain = WatchFolder(path: "/tmp/a", action: .convert("jpg"))
        let options = setup.model.actionOptions(for: plain)
        #expect(options.formats.map(\.title) == ["JPEG", "PNG"])
        #expect(options.tools.map(\.title) == [compress.name])
        #expect(options.formats.map(\.key) == ["convert:jpg", "convert:png"])
        #expect(options.tools.map(\.key) == ["tool:compress"])
        // An action the engines no longer offer stays selectable, so the picker never shows a blank.
        let stale = WatchFolder(path: "/tmp/b", action: .convert("avif"))
        #expect(setup.model.actionOptions(for: stale).formats.map(\.key) == ["convert:jpg", "convert:png", "convert:avif"])
        let gone = WatchFolder(path: "/tmp/c", action: .tool("nonsense"))
        #expect(setup.model.actionOptions(for: gone).tools.map(\.key) == ["tool:compress", "tool:nonsense"])
    }

    @Test func actionKeysRoundTrip() {
        for action in [WatchAction.convert("jpg"), .tool("compress"), .tool("a:b")] {
            #expect(WatchFoldersPaneModel.action(forKey: WatchFoldersPaneModel.key(of: action)) == action)
        }
        #expect(WatchFoldersPaneModel.action(forKey: "nonsense") == nil)
    }

    @Test func aFolderShowsItsNameOverItsPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = WatchFolder(path: home + "/Pictures/Inbox", action: .convert("jpg"))
        #expect(WatchFoldersPaneModel.name(of: folder) == "Inbox")
        #expect(WatchFoldersPaneModel.displayPath(of: folder) == "~/Pictures/Inbox")
    }

    @Test func theFooterIsPlainSentences() {
        let footer = WatchFoldersPaneModel.footer
        #expect(footer.hasPrefix("New files in these folders are converted as they arrive."))
        #expect(footer.contains("Files already there are left alone."))
        // P136: a conversion takes every file it can, PDFs included for JPEG.
        #expect(footer.contains("A rule takes every file it can convert, so Convert to JPEG takes PDFs too."))
        #expect(footer.contains("Folders on network drives only notice files added from this Mac."))
        #expect(!footer.contains("\u{00B7}") && !footer.contains("\u{2014}"))
        #expect(!WatchFoldersPaneModel.alreadyWatched.contains("\u{00B7}"))
    }

    // MARK: - The pane

    @Test func theWatchFoldersPaneRenders() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = makeModel(choosing: [dir])
        await setup.model.add()
        await setup.model.load()
        let host = NSHostingView(rootView: WatchFoldersPane(model: setup.model).formStyle(.grouped))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
        #expect(!host.subviews.isEmpty)
    }

    @Test func theSettingsViewHostsTheWatchFoldersPane() {
        let host = NSHostingView(rootView: SettingsView(environment: .shared, pane: .watchFolders))
        host.frame = NSRect(origin: .zero, size: SettingsView.size)
        host.layoutSubtreeIfNeeded()
        #expect(!host.subviews.isEmpty)
    }
}
