import Foundation
import PomeloCore
import Testing
@testable import PomeloUIModel

private func item(_ path: String, size: Int64? = 1000, identity: String? = nil, state: ShelfItemState = .present)
    -> ShelfItem
{
    let url = URL(fileURLWithPath: path)
    return ShelfItem(url: url, identity: identity ?? path, name: url.lastPathComponent, byteCount: size, state: state)
}

private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

private func make(_ url: URL) -> ShelfItem { item(url.path) }

private func shelf(_ paths: String...) -> ShelfModel {
    var model = ShelfModel()
    model.add(paths.map { item($0) })
    return model
}

private func names(_ model: ShelfModel) -> [String] { model.items.map(\.name) }

private func succeeded(_ source: String, _ outputs: String...) -> FileResult {
    .succeeded(source: URL(fileURLWithPath: source), outputs: outputs.map { URL(fileURLWithPath: $0) }, note: nil)
}

struct ShelfModelTests {
    @Test func addKeepsOrder() {
        var model = ShelfModel()
        let result = model.add([item("/t/a.heic"), item("/t/b.pdf")])
        model.add([item("/t/c.png")])
        #expect(names(model) == ["a.heic", "b.pdf", "c.png"])
        #expect(result.added.count == 2)
        #expect(result.existing.isEmpty)
        #expect(!model.isEmpty)
    }

    @Test func duplicateByIdentityIsNotAddedTwice() {
        var model = shelf("/t/a.heic")
        let first = model.items[0].id
        let result = model.add([item("/t/renamed.heic", identity: "/t/a.heic"), item("/t/b.pdf")])
        #expect(names(model) == ["a.heic", "b.pdf"])
        #expect(result.existing == [first])
        #expect(result.added.count == 1)
    }

    @Test func removeAndClearForget() {
        var model = shelf("/t/a", "/t/b", "/t/c")
        let a = model.items[0].id
        model.click(a)
        model.remove([a])
        #expect(names(model) == ["b", "c"])
        #expect(model.selection.isEmpty)
        model.selectAll()
        model.clear()
        #expect(model.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.title == "Shelf")
    }

    @Test func updateFollowsARename() {
        var model = shelf("/t/a.heic")
        let id = model.items[0].id
        model.update(id, url: URL(fileURLWithPath: "/t/new.heic"), name: "new.heic", state: .inTrash)
        #expect(model.items[0].url.path == "/t/new.heic")
        #expect(model.items[0].name == "new.heic")
        #expect(model.items[0].state == .inTrash)
        model.setBookmark(Data([1]), for: id, identity: "/t/a.heic")
        #expect(model.items[0].bookmark == Data([1]))
    }

    // MARK: Results

    @Test func applyReplacesInPlace() {
        var model = shelf("/t/a", "/t/b.heic", "/t/c")
        let announcement = model.apply(succeeded("/t/b.heic", "/t/b.jpg"), makeItem: make)
        #expect(names(model) == ["a", "b.jpg", "c"])
        #expect(announcement == "b.heic became b.jpg")
    }

    @Test func applySeveralOutputsInOrder() {
        var model = shelf("/t/a", "/t/doc.pdf", "/t/c")
        _ = model.apply(succeeded("/t/doc.pdf", "/t/doc-1.png", "/t/doc-2.png"), makeItem: make)
        #expect(names(model) == ["a", "doc-1.png", "doc-2.png", "c"])
    }

    @Test func applyMatchesTheSourceByStandardizedPath() {
        var model = shelf("/t/a.heic")
        _ = model.apply(succeeded("/t/x/../a.heic", "/t/a.jpg"), makeItem: make)
        #expect(names(model) == ["a.jpg"])
    }

    @Test func applyCombineKeepsOneOutputAtFirstSource() {
        var model = shelf("/t/b.pdf", "/t/a.pdf")
        _ = model.apply(succeeded("/t/b.pdf", "/t/merged.pdf"), makeItem: make)
        _ = model.apply(succeeded("/t/a.pdf", "/t/merged.pdf"), makeItem: make)
        #expect(names(model) == ["merged.pdf"])
    }

    @Test func applyCombineWhateverOrderTheResultsArrive() {
        var model = shelf("/t/b.pdf", "/t/c.pdf", "/t/a.pdf")
        _ = model.apply(succeeded("/t/a.pdf", "/t/merged.pdf"), makeItem: make)
        #expect(names(model) == ["b.pdf", "c.pdf", "merged.pdf"])
        _ = model.apply(succeeded("/t/b.pdf", "/t/merged.pdf"), makeItem: make)
        #expect(names(model) == ["merged.pdf", "c.pdf"])
    }

    @Test func applyOutputAlreadyOnShelfRemovesSource() {
        var model = shelf("/t/a.jpg", "/t/b.heic")
        let announcement = model.apply(succeeded("/t/b.heic", "/t/a.jpg"), makeItem: make)
        #expect(names(model) == ["a.jpg"])
        #expect(announcement != nil)
    }

    @Test func applyFailureCancelOrNoOutputChangesNothing() {
        var model = shelf("/t/a", "/t/b")
        let before = model
        let source = URL(fileURLWithPath: "/t/a")
        #expect(model.apply(.failed(source: source, error: .notApplicable(reason: "Already compressed")),
                            makeItem: make) == nil)
        #expect(model.apply(.cancelled(source: source), makeItem: make) == nil)
        #expect(model.apply(.succeeded(source: source, outputs: [], note: nil), makeItem: make) == nil)
        #expect(model == before)
    }

    @Test func applyForARemovedSourceAddsNothing() {
        var model = shelf("/t/a", "/t/b")
        model.remove([model.items[0].id])
        let before = model
        #expect(model.apply(succeeded("/t/a", "/t/a.jpg"), makeItem: make) == nil)
        #expect(model == before)
    }

    @Test func applyMovesTheSelectionToTheOutputs() {
        var model = shelf("/t/a.heic", "/t/b")
        model.click(model.items[0].id)
        _ = model.apply(succeeded("/t/a.heic", "/t/a.jpg"), makeItem: make)
        #expect(model.selection == [model.items[0].id])
    }

    // MARK: Fix round 1

    @Test func applyAtTheSourcesOwnPathKeepsTheItem() {
        var model = shelf("/t/a", "/t/b.jpg", "/t/c")
        let id = model.items[1].id
        model.click(id)
        let announcement = model.apply(succeeded("/t/b.jpg", "/t/b.jpg"), makeItem: { _ in
            ShelfItem(url: URL(fileURLWithPath: "/t/b.jpg"), identity: "new-identity", name: "b.jpg", byteCount: 42)
        })
        #expect(announcement == nil)
        #expect(model.items.map(\.id)[1] == id)
        #expect(model.items.count == 3)
        #expect(model.items[1].identity == "new-identity")
        #expect(model.items[1].byteCount == 42)
        #expect(model.selection == [id])
    }

    @Test func applyAtTheSourcesPathWithAnotherOutputAnnouncesOnlyTheOther() {
        var model = shelf("/t/a.png", "/t/b")
        let id = model.items[0].id
        let announcement = model.apply(succeeded("/t/a.png", "/t/a.png", "/t/a.webp"), makeItem: make)
        #expect(names(model) == ["a.png", "a.webp", "b"])
        #expect(model.items[0].id == id)
        #expect(announcement == "Added a.webp to the Shelf")
    }

    /// Replace original: the source went to the Trash, and its bookmark with it; the app bookmarks the output.
    @Test func applyAtTheSourcesOwnPathDropsTheOldBookmark() {
        var model = ShelfModel()
        model.add([item("/t/b.jpg", state: .missing)])
        let id = model.items[0].id
        model.setBookmark(Data([1]), for: id, identity: "/t/b.jpg")
        _ = model.apply(succeeded("/t/b.jpg", "/t/b.jpg"), makeItem: make)
        #expect(model.items[0].id == id)
        #expect(model.items[0].bookmark == nil)
        #expect(model.items[0].state == .present)
    }

    /// The original's drop-time bookmark lands after a replace original: it names the file now in the Trash (M4b).
    @Test func aLateBookmarkForAReplacedFileIsDropped() {
        var model = ShelfModel()
        model.add([item("/t/b.jpg", identity: "id:old")])
        let id = model.items[0].id
        _ = model.apply(succeeded("/t/b.jpg", "/t/b.jpg"), makeItem: { item($0.path, identity: "id:new") })
        model.setBookmark(Data([1]), for: id, identity: "id:old")
        #expect(model.items[0].bookmark == nil)
        model.setBookmark(Data([2]), for: id, identity: "id:new")
        #expect(model.items[0].bookmark == Data([2]))
    }

    @Test func applySelectsOutputsAlreadyOnTheShelf() {
        var model = shelf("/t/b.pdf", "/t/merged.pdf", "/t/a.pdf")
        model.click(model.items[0].id)
        _ = model.apply(succeeded("/t/b.pdf", "/t/merged.pdf"), makeItem: make)
        #expect(names(model) == ["merged.pdf", "a.pdf"])
        #expect(model.selection == [model.items[0].id])
    }

    @Test func removingTheAnchorMovesItToTheNearestSelected() {
        var model = shelf("/t/a", "/t/b", "/t/c", "/t/d", "/t/e")
        let ids = model.items.map(\.id)
        model.click(ids[1])
        model.commandClick(ids[3])
        model.commandClick(ids[4])
        model.remove([ids[4]])
        #expect(model.selection == [ids[1], ids[3]])
        model.shiftClick(ids[0])
        #expect(model.selection == Set(ids[0...3]))
    }

    @Test func totalsCountOnlyPresentItemsAndNeverAPartialSum() {
        var model = ShelfModel()
        model.add([item("/t/a", size: 1_000_000), item("/t/b", size: 2_000_000),
                   item("/t/c", size: 5_000_000, state: .missing)])
        #expect(model.subtitle == size(3_000_000))
        model.add([item("/t/d", size: nil)])
        #expect(model.subtitle == nil)
        #expect(model.accessibilityValue == "4 files")
        var onlyMissingUnknown = ShelfModel()
        onlyMissingUnknown.add([item("/t/a", size: 1_000_000), item("/t/b", size: nil, state: .missing)])
        #expect(onlyMissingUnknown.subtitle == size(1_000_000))
    }

    @Test func theStackReadsAsAList() {
        #expect(shelf("/t/a", "/t/b").stackAccessibilityValue == "a and b")
        #expect(shelf("/t/a", "/t/b", "/t/c").stackAccessibilityValue == "a, b and 1 more")
        #expect(shelf("/t/a").stackAccessibilityValue == "a")
    }

    // MARK: Selection

    @Test func selectionRules() {
        var model = shelf("/t/a", "/t/b", "/t/c", "/t/d", "/t/e")
        let ids = model.items.map(\.id)
        model.click(ids[1])
        #expect(model.selection == [ids[1]])
        model.commandClick(ids[3])
        #expect(model.selection == [ids[1], ids[3]])
        model.commandClick(ids[1])
        #expect(model.selection == [ids[3]])
        model.commandClick(ids[3])
        model.shiftClick(ids[0])
        #expect(model.selection == Set(ids[0...3]))
        model.selectAll()
        #expect(model.selection == Set(ids))

        model.click(ids[1])
        model.moveSelection(by: 1, extending: false)
        #expect(model.selection == [ids[2]])
        model.moveSelection(by: 1, extending: true)
        #expect(model.selection == [ids[2], ids[3]])
        model.moveSelection(by: -1, extending: true)
        #expect(model.selection == [ids[2]])
        model.moveSelection(by: -1, extending: true)
        #expect(model.selection == [ids[1], ids[2]])
        model.moveSelection(by: -10, extending: false)
        #expect(model.selection == [ids[0]])

        model.remove([ids[0]])
        #expect(model.selection.isEmpty)
    }

    /// The item the arrow keys move from, for the list to scroll to (S17).
    @Test func focusFollowsClicksAndArrows() {
        var model = shelf("/t/a", "/t/b", "/t/c")
        let ids = model.items.map(\.id)
        #expect(model.focused == nil)
        model.click(ids[1])
        #expect(model.focused == ids[1])
        model.moveSelection(by: 1, extending: true)
        #expect(model.focused == ids[2])
        model.selectAll()
        #expect(model.focused == ids[2])
        model.commandClick(ids[0])
        #expect(model.focused == ids[0])
        model.clear()
        #expect(model.focused == nil)
    }

    /// A row's second label and VoiceOver value: the size, or why the file is greyed (S8, S22).
    @Test func detailIsTheSizeOrTheReason() {
        #expect(item("/t/a", size: 2_100_000).detail == size(2_100_000))
        #expect(item("/t/a", size: nil).detail == nil)
        #expect(item("/t/a", state: .inTrash).detail == "Moved to the Trash")
        #expect(item("/t/a", size: nil, state: .missing).detail == "Can't be found")
    }

    @Test func arrowsWithNothingSelectedStartAtTheEnds() {
        var model = shelf("/t/a", "/t/b", "/t/c")
        model.moveSelection(by: 1, extending: false)
        #expect(model.selection == [model.items[0].id])
        model.clear()
        model.add([item("/t/a"), item("/t/b")])
        model.moveSelection(by: -1, extending: false)
        #expect(model.selection == [model.items[1].id])
    }

    // MARK: Drag out

    @Test func dragOutCollapsedIsEveryPresentItem() {
        var model = shelf("/t/a", "/t/b")
        model.click(model.items[0].id)
        #expect(model.dragOut(pressed: nil, expanded: false).map(\.name) == ["a", "b"])
    }

    @Test func dragOutExpandedSelectedOrPressed() {
        var model = shelf("/t/a", "/t/b", "/t/c")
        let ids = model.items.map(\.id)
        model.click(ids[0])
        model.commandClick(ids[1])
        #expect(model.dragOut(pressed: ids[1], expanded: true).map(\.name) == ["a", "b"])
        #expect(model.dragOut(pressed: ids[2], expanded: true).map(\.name) == ["c"])
    }

    @Test func missingItemsAreNeverDragged() {
        var model = ShelfModel()
        model.add([item("/t/a"), item("/t/b", state: .missing), item("/t/c", state: .inTrash)])
        let ids = model.items.map(\.id)
        #expect(model.dragOut(pressed: nil, expanded: false).map(\.name) == ["a"])
        model.selectAll()
        model.click(ids[0])
        #expect(model.dragOut(pressed: ids[1], expanded: true).isEmpty)
        #expect(model.dragOut(pressed: ids[0], expanded: true).map(\.name) == ["a"])
        model.selectAll()
        #expect(model.dragOut(pressed: ids[1], expanded: true).map(\.name) == ["a"])
        var allMissing = ShelfModel()
        allMissing.add([item("/t/x", state: .missing)])
        #expect(allMissing.dragOut(pressed: nil, expanded: false).isEmpty)
    }

    @Test func stackIsTheThreeMostRecentPresent() {
        var model = ShelfModel()
        model.add([item("/t/a"), item("/t/b"), item("/t/c"), item("/t/d", state: .missing), item("/t/e"),
                   item("/t/f")])
        #expect(model.stack.map(\.name) == ["c", "e", "f"])
        #expect(shelf("/t/a").stack.map(\.name) == ["a"])
        #expect(ShelfModel().stack.isEmpty)
    }

    // MARK: Labels

    @Test func labels() {
        let mb = Int64(1_000_000)
        var model = ShelfModel()
        #expect(model.title == "Shelf")
        #expect(model.subtitle == nil)
        #expect(model.accessibilityValue == "Empty")
        #expect(model.stackAccessibilityValue == "Empty")

        model.add([item("/t/a.heic", size: 2_100_000)])
        #expect(model.title == "a.heic")
        #expect(model.subtitle == ByteCountFormatter.string(fromByteCount: 2_100_000, countStyle: .file))
        #expect(model.accessibilityValue == "a.heic, \(size(2_100_000))")

        model.add([item("/t/b.pdf", size: 4 * mb), item("/t/c", size: 2 * mb), item("/t/d", size: 2 * mb),
                   item("/t/e", size: 2_300_000)])
        #expect(model.title == "5 files")
        #expect(model.subtitle == size(12_400_000))
        #expect(model.accessibilityValue == "5 files, \(size(12_400_000))")
        #expect(model.stackAccessibilityValue == "a.heic, b.pdf and 3 more")

        var unknown = ShelfModel()
        unknown.add([item("/t/a", size: nil), item("/t/b", size: nil)])
        #expect(unknown.subtitle == nil)
        #expect(unknown.accessibilityValue == "2 files")
        #expect(unknown.stackAccessibilityValue == "a and b")
    }

    @Test func copyAnnouncements() {
        #expect(ShelfCopy.added(["a.heic"]) == "Added a.heic to the Shelf")
        #expect(ShelfCopy.added(["a", "b", "c"]) == "Added 3 files to the Shelf")
        #expect(ShelfCopy.left(2) == "2 files left the Shelf")
        #expect(ShelfCopy.left(1) == "1 file left the Shelf")
        #expect(ShelfCopy.became("photo.heic", "photo.jpg") == "photo.heic became photo.jpg")
        #expect(ShelfCopy.dragHint == "Drag to copy. Hold Command to move.")
        #expect(ShelfItemState.present.reason == nil)
        #expect(ShelfItemState.inTrash.reason == "Moved to the Trash")
        #expect(ShelfItemState.missing.reason == "Can't be found")
        // S17's context menu and S22's actions, as the spec writes them.
        #expect([ShelfCopy.openWheel, ShelfCopy.quickLook, ShelfCopy.showInFinder, ShelfCopy.copy, ShelfCopy.remove,
                 ShelfCopy.tuckAway, ShelfCopy.clearShelf, ShelfCopy.expand]
            == ["Open the Wheel", "Quick Look", "Show in Finder", "Copy", "Remove from Shelf", "Tuck Away",
                "Clear Shelf", "Expand"])
    }

    @Test func copyHasNoSeparators() {
        var model = ShelfModel()
        model.add([item("/t/a"), item("/t/b"), item("/t/c"), item("/t/d")])
        let strings = [
            ShelfCopy.shelf, ShelfCopy.dropHere, ShelfCopy.dragHint, ShelfCopy.movedToTrash, ShelfCopy.cantBeFound,
            ShelfCopy.empty, ShelfCopy.added(["a"]), ShelfCopy.added(["a", "b"]), ShelfCopy.left(1), ShelfCopy.left(3),
            ShelfCopy.became("a", "b"), model.title, model.subtitle ?? "", model.accessibilityValue,
            model.stackAccessibilityValue, ShelfModel().title, ShelfModel().accessibilityValue,
            ShelfCopy.openWheel, ShelfCopy.quickLook, ShelfCopy.showInFinder, ShelfCopy.copy, ShelfCopy.remove,
            ShelfCopy.tuckAway, ShelfCopy.expand, ShelfCopy.collapse,
        ]
        for string in strings {
            #expect(!string.contains("·"))
            #expect(!string.contains("—"))
        }
    }
}
