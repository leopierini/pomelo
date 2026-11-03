import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

/// A folder of the test's own under the temporary folder, spelled as `/var/folders/…` unless `resolved`.
private func makeTempDir(resolved: Bool = true) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-shelf-results-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return resolved ? url.resolvingSymlinksInPath() : url
}

private func makeFiles(_ names: String..., in dir: URL) throws -> [URL] {
    try names.map { name in
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("shelf \(name)".utf8).write(to: url)
        return url
    }
}

private func succeeded(_ source: URL, _ outputs: URL..., note: ResultNote? = nil) -> FileResult {
    .succeeded(source: source, outputs: outputs, note: note)
}

/// Results of jobs started from the Shelf take their sources' places (S18, S37). Off-screen, with injected runners
/// and temp folders: nothing here starts a real drag, posts an event or touches the real Trash.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShelfResultsTests {
    private let clock = ManualClock()
    private let cursor = CGPoint(x: -29_500, y: -29_500)

    private func makeShelf(announce: @escaping (String) -> Void = { _ in }) -> ShelfController {
        ShelfController(desktop: .offScreen, announce: announce, clock: clock.timerClock, pasteboard: .withUniqueName(),
                        reveal: { _ in }, preview: RecordingPreview())
    }

    private func names(_ shelf: ShelfController) -> [String] {
        shelf.model.items.map(\.name)
    }

    /// What a drag starting now on the stack would carry, as AppKit gets it.
    private func dragged(_ shelf: ShelfController) -> [URL] {
        let view = shelf.panel.itemsView
        return view.draggingItems(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
            .compactMap { ($0.item as? NSURL) as URL? }
    }

    /// A wheel off-screen whose PNGs convert to JPG, and whose files always read as healthy.
    private func makeWheel() -> WheelController {
        let settings = SettingsStore(defaults: EphemeralDefaults())
        settings.settings.hapticsEnabled = false
        let wheel = WheelController(settings: settings, desktop: .offScreen, readabilityCheck: { _, _ in .clean },
                                    clock: clock.timerClock)
        let planner = RoutePlanner(
            edges: [ConversionEdge(from: "png", to: "jpg", engineID: "gated", cost: 1, flags: [])],
            enginePriority: ["gated"]
        )
        wheel.contentBuilder = WheelContentBuilder(formats: .builtIn, available: planner, all: planner,
                                                   installHints: [:], tools: [])
        return wheel
    }

    @Test func takeResultSwapsAndAnnounces() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("photo.heic", "photo.jpg", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        shelf.summon(.tools(files: [files[0]], at: cursor))
        let source = shelf.model.items[0].id

        shelf.takeResult(succeeded(files[0], files[1]))

        #expect(names(shelf) == ["photo.jpg"])
        #expect(shelf.model.items[0].id != source)
        #expect(shelf.model.items[0].url == files[1])
        #expect(announced.last == "photo.heic became photo.jpg")
        // The output is bookmarked like any dropped file, so a rename in Finder is followed (S15).
        #expect(await eventually { shelf.model.items.first?.bookmark != nil })
        // Pomelo changed nothing on disk.
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        shelf.close()
    }

    /// Review Focus 5: of three files, only the one that converted swaps.
    @Test func mixedOutcomesSwapOnlySuccesses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", "b.png", "c.png", "a.jpg", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        shelf.summon(.tools(files: Array(files[0...2]), at: cursor))
        let ids = shelf.model.items.map(\.id)
        announced = []

        shelf.takeResult(succeeded(files[0], files[3]))
        shelf.takeResult(.failed(source: files[1], error: .engineFailed(engine: "x", message: "damaged")))
        shelf.takeResult(.failed(source: files[2], error: .notApplicable(reason: "Already compressed")))
        shelf.takeResult(.cancelled(source: files[2]))

        #expect(names(shelf) == ["a.jpg", "b.png", "c.png"])
        #expect(Array(shelf.model.items.map(\.id)[1...]) == Array(ids[1...]))
        #expect(announced == ["a.png became a.jpg"])
        shelf.close()
    }

    @Test func resultForARemovedSourceIsIgnored() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", "b.png", "a.jpg", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        shelf.summon(.tools(files: Array(files[0...1]), at: cursor))
        shelf.expand()
        shelf.select(shelf.model.items[0].id)
        shelf.removeSelection()
        announced = []

        shelf.takeResult(succeeded(files[0], files[2]))

        #expect(names(shelf) == ["b.png"])
        #expect(announced.isEmpty)
        shelf.close()
    }

    /// Settings › Tools' "Replace the original": the output sits at the source's path and the source went to the
    /// Trash. The item stays (same id), found again at that path: its old bookmark would follow the source into the
    /// Trash and grey it.
    @Test func replaceOriginalOutputAtTheSamePathStillSwaps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: files, at: cursor))
        #expect(await eventually { shelf.model.items.allSatisfy { $0.bookmark != nil } })
        let id = shelf.model.items[0].id
        // What the runner does, in a Trash folder of the test's own.
        let trash = dir.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: files[0], to: trash.appending(path: "a.png"))
        try Data("the compressed a".utf8).write(to: files[0])

        shelf.takeResult(succeeded(files[0], files[0], note: .replacedOriginal))

        #expect(shelf.model.items.map(\.id) == [id])
        #expect(shelf.model.items[0].state == .present)
        #expect(shelf.model.items[0].identity == ShelfFiles.live.item(files[0]).identity)
        await shelf.resolve([id])
        #expect(shelf.model.items[0].state == .present)
        #expect(shelf.model.items[0].url.standardizedFileURL == files[0].standardizedFileURL)
        // The new bookmark is the output's: renamed in Finder, the item follows it.
        #expect(await eventually { shelf.model.items.first?.bookmark != nil })
        let renamed = dir.appending(path: "renamed.png", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: files[0], to: renamed)
        await shelf.resolve([id])
        #expect(shelf.model.items[0].name == "renamed.png")
        #expect(shelf.model.items[0].state == .present)
        shelf.close()
    }

    /// The job's URLs may spell the Shelf's `/var/folders/…` as `/private/var/folders/…`: the same files.
    @Test func resultMatchesTheItemsOtherSpelling() throws {
        let dir = try makeTempDir(resolved: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #require(dir.path.hasPrefix("/var/"))
        let files = try makeFiles("a.png", "b.png", "a.jpg", in: dir)
        let shelf = makeShelf()
        shelf.summon(.tools(files: Array(files[0...1]), at: cursor))
        let b = shelf.model.items[1].id
        func privately(_ url: URL) -> URL { URL(fileURLWithPath: "/private" + url.path) }

        shelf.takeResult(succeeded(privately(files[0]), privately(files[2])))
        shelf.takeResult(succeeded(privately(files[1]), privately(files[1]), note: .replacedOriginal))

        #expect(names(shelf) == ["a.jpg", "b.png"])
        // Replaced in place across the two spellings: the same item.
        #expect(shelf.model.items[1].id == b)
        shelf.close()
    }

    /// Review Focus 2: the drag out of the Shelf dropped on the wheel ends as `.copy`; the items stay, then each
    /// swaps to its output as the job finishes.
    @Test func wheelDropFromShelfKeepsThenSwaps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("slow-a.png", in: dir)
        var announced: [String] = []
        let shelf = makeShelf { announced.append($0) }
        let wheel = makeWheel()
        defer { wheel.close() }
        let gates = Gates()
        let jobs = makeCoordinator(engines: [GatedEngine(gates: gates)])
        AppEnvironment.connect(wheel: wheel, jobs: jobs, shelf: shelf, clickMode: ClickModeController(wheel: wheel)) {
            _, _, _, _ in
        }
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)

        #expect(dragged(shelf) == files)
        AppEnvironment.route(.openWheel(files: files, at: cursor), wheel: wheel, shelf: shelf)
        let slice = try #require(wheel.model.pages.flatMap(\.slices).first { $0.id == "convert.jpg" })
        wheel.choose(slice, files: files)
        shelf.dragOutEnded(operation: .copy)

        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)
        await gates.open("slow-a")
        #expect(await eventually { names(shelf) == ["slow-a.jpg"] })
        #expect(announced.last == "slow-a.png became slow-a.jpg")
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        shelf.close()
    }

    /// S5's second way in, through the app's wiring: the Tools page's Shelf slice puts the wheel's files on the Shelf
    /// at the wheel's centre.
    @Test func theToolsSliceShelvesThroughTheAppsWiring() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", "b.png", in: dir)
        let shelf = makeShelf()
        let wheel = makeWheel()
        defer { wheel.close() }
        AppEnvironment.connect(wheel: wheel, jobs: makeCoordinator(engines: []), shelf: shelf,
                               clickMode: ClickModeController(wheel: wheel)) { _, _, _, _ in }

        AppEnvironment.route(.openWheel(files: files, at: cursor), wheel: wheel, shelf: shelf)
        let centre = CGPoint(x: wheel.panel.frame.midX, y: wheel.panel.frame.midY)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))
        let slice = try #require(wheel.model.slices.first { $0.id == "action.shelf" })
        wheel.choose(slice, files: files)

        #expect(shelf.isShown)
        #expect(shelf.model.items.map(\.url) == files)
        #expect(shelf.drawerFrame.contains(centre))
        shelf.close()
    }

    /// The drag out of the Shelf dropped on its own wheel's Shelf slice is a landing in Pomelo (S13, S31): the drop
    /// answers `.copy`, and the items stay.
    @Test func theToolsSliceKeepsADragOutThroughTheAppsWiring() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", "b.png", in: dir)
        let shelf = makeShelf()
        let wheel = makeWheel()
        defer { wheel.close() }
        AppEnvironment.connect(wheel: wheel, jobs: makeCoordinator(engines: []), shelf: shelf,
                               clickMode: ClickModeController(wheel: wheel)) { _, _, _, _ in }
        shelf.summon(.tools(files: files, at: cursor))
        let before = shelf.model.items.map(\.id)

        #expect(dragged(shelf) == files)
        AppEnvironment.route(.openWheel(files: files, at: cursor), wheel: wheel, shelf: shelf)
        wheel.model.setPage(try #require(wheel.model.pages.firstIndex { $0.kind == .tools }))
        let slice = try #require(wheel.model.slices.first { $0.id == "action.shelf" })
        wheel.choose(slice, files: files)
        shelf.dragOutEnded(operation: .copy)

        #expect(shelf.model.items.map(\.id) == before)
        #expect(shelf.isShown)
        shelf.close()
    }

    /// S37: a wheel is the Shelf's until the next open. Open the Wheel and a drag out of the Shelf make it so; click
    /// mode, a Finder drag and a drag after the Shelf's has ended never do.
    @Test func everyWheelOpenSaysWhetherItIsTheShelfs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try makeFiles("a.png", "b.png", in: dir)
        let shelf = makeShelf()
        let wheel = makeWheel()
        defer { wheel.close() }
        let clickMode = ClickModeController(wheel: wheel)
        var editorResults: [Bool] = []
        AppEnvironment.connect(wheel: wheel, jobs: makeCoordinator(engines: []), shelf: shelf, clickMode: clickMode) {
            _, _, _, onResult in editorResults.append(onResult != nil)
        }
        shelf.summon(.tools(files: [files[0]], at: cursor))
        func openEditor() { wheel.onOpenEditor?(jpgSlice(), [files[0]], cursor) }

        #expect(shelf.openWheel())
        #expect(wheel.isOpen)
        #expect(shelf.wheelResults != nil)
        openEditor()

        clickMode.openFiles([files[0]])
        #expect(shelf.wheelResults == nil)
        openEditor()

        #expect(dragged(shelf) == [files[0]])
        AppEnvironment.route(.openWheel(files: [files[0]], at: cursor), wheel: wheel, shelf: shelf)
        #expect(shelf.wheelResults != nil)
        AppEnvironment.route(.openWheel(files: [files[1]], at: cursor), wheel: wheel, shelf: shelf)
        #expect(shelf.wheelResults == nil)
        shelf.dragOutEnded(operation: [])
        AppEnvironment.route(.openWheel(files: [files[0]], at: cursor), wheel: wheel, shelf: shelf)
        #expect(shelf.wheelResults == nil)

        #expect(editorResults == [true, false])
        shelf.close()
    }
}
