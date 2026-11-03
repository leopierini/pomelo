import CoreGraphics
import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Redact editor's boxes (P27): what is proposed, what the person toggles, draws and moves, and what is saved.
@Suite struct RedactionModelTests {
    private let face = UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
    private let email = UnitRect(x: 0.4, y: 0.5, width: 0.3, height: 0.05)
    private let line = UnitRect(x: 0.35, y: 0.48, width: 0.5, height: 0.09)
    private let other = UnitRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)

    private var model: RedactionModel {
        RedactionModel(regions: [(.face, face), (.email, email), (.text, line), (.text, other)], style: .fill)
    }

    private struct Refused: Error {}

    private func draw(_ model: inout RedactionModel, _ rect: UnitRect) throws -> Int {
        guard let id = model.addManual(rect) else { throw Refused() }
        return id
    }

    private func ids(_ model: RedactionModel, _ kind: RedactionKind) -> [Int] {
        model.boxes.filter { $0.kind == kind }.map(\.id)
    }

    @Test func facesAndEmailsStartOnAndTextOff() {
        let model = model
        #expect(model.boxes.map(\.kind) == [.face, .email, .text, .text])
        #expect(model.boxes.map(\.isOn) == [true, true, false, false])
        #expect(Set(model.boxes.map(\.id)).count == 4, "every box has its own id")
        #expect(model.selected == nil)
        #expect(model.style == .fill)
    }

    @Test func countsTheBoxesOfAKind() {
        #expect(model.count(.face) == 1)
        #expect(model.count(.text) == 2)
        #expect(model.count(.manual) == 0)
    }

    @Test func aManualBoxIsClampedOnAndSelected() throws {
        var model = model
        let id = try draw(&model, UnitRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3))
        let box = try #require(model.boxes.first { $0.id == id })
        #expect(box.kind == .manual)
        #expect(box.isOn)
        #expect(model.selected == id)
        #expect(box.rect.x == 0.9 && box.rect.y == 0.9)
        #expect(abs(box.rect.width - 0.1) < 1e-9 && abs(box.rect.height - 0.1) < 1e-9)
        #expect(model.boxes.last?.id == id)
    }

    @Test func tinyManualBoxesAreRefused() {
        var model = model
        let thin = model.addManual(UnitRect(x: 0.2, y: 0.2, width: 0.005, height: 0.3))
        let flat = model.addManual(UnitRect(x: 0.2, y: 0.2, width: 0.3, height: 0.005))
        let outside = model.addManual(UnitRect(x: 1.2, y: 0.2, width: 0.3, height: 0.3))
        #expect(thin == nil && flat == nil)
        #expect(outside == nil, "wholly outside")
        #expect(model.boxes.count == 4)
        #expect(model.selected == nil)
    }

    @Test func hitTestingPrefersManualThenTheSmallest() throws {
        var model = model
        // The email sits inside its line: the smaller box wins.
        let emailID = ids(model, .email)[0]
        let lineID = ids(model, .text)[0]
        #expect(model.box(at: CGPoint(x: 0.5, y: 0.52)) == emailID)
        #expect(model.box(at: CGPoint(x: 0.8, y: 0.52)) == lineID)
        #expect(model.box(at: CGPoint(x: 0.95, y: 0.05)) == nil)
        let manual = try draw(&model, UnitRect(x: 0.45, y: 0.5, width: 0.4, height: 0.3))
        #expect(model.box(at: CGPoint(x: 0.5, y: 0.52)) == manual, "a manual box is on top whatever its size")
        #expect(model.box(at: CGPoint(x: 0.36, y: 0.5)) == lineID)
        let newer = try draw(&model, UnitRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
        #expect(model.box(at: CGPoint(x: 0.52, y: 0.52)) == newer, "the later manual box is on top")
    }

    @Test func onlyManualBoxesMoveResizeOrGo() throws {
        var model = model
        let faceID = ids(model, .face)[0]
        model.select(faceID)
        let before = model
        model.moveSelected(dx: 0.1, dy: 0.1)
        model.resizeSelected(dw: 0.1, dh: 0.1)
        model.removeSelected()
        #expect(model == before, "a detected box stays where it was found")

        let id = try draw(&model, UnitRect(x: 0.5, y: 0.125, width: 0.25, height: 0.25))
        model.moveSelected(dx: 0.125, dy: -0.5)
        #expect(model.boxes.last?.rect == UnitRect(x: 0.625, y: 0, width: 0.25, height: 0.25), "moved, held inside the picture")
        model.moveSelected(dx: 0.9, dy: 0)
        #expect(model.boxes.last?.rect.x == 0.75)
        model.resizeSelected(dw: 0.5, dh: -1)
        let rect = try #require(model.boxes.last?.rect)
        #expect(abs(rect.width - 0.25) < 1e-9, "grown only to the edge")
        #expect(abs(rect.height - 0.01) < 1e-9, "never under the smallest side")
        model.removeSelected()
        #expect(!model.boxes.contains { $0.id == id })
        #expect(model.boxes.count == 4)
    }

    @Test func dragsACornerWithTheOppositeOneFixed() throws {
        let start = UnitRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let grown = try #require(RedactionModel.rect(dragging: .topLeft, of: start, to: CGPoint(x: 0.3, y: 0.2)))
        #expect(abs(grown.x - 0.3) < 1e-9 && abs(grown.y - 0.2) < 1e-9)
        #expect(abs(grown.width - 0.3) < 1e-9 && abs(grown.height - 0.4) < 1e-9)
        // Dragged past the opposite corner, the box is flipped over it.
        let flipped = try #require(RedactionModel.rect(dragging: .topLeft, of: grown, to: CGPoint(x: 0.8, y: 0.9)))
        #expect(abs(flipped.x - 0.6) < 1e-9 && abs(flipped.y - 0.6) < 1e-9)
        #expect(abs(flipped.width - 0.2) < 1e-9 && abs(flipped.height - 0.3) < 1e-9)
        let clamped = try #require(RedactionModel.rect(dragging: .bottomRight, of: flipped, to: CGPoint(x: 5, y: 5)))
        #expect(clamped.x + clamped.width <= 1 + 1e-9 && clamped.y + clamped.height <= 1 + 1e-9)
    }

    @Test func aDragWorksFromWhereItBeganOnTheModelAsItIsNow() throws {
        var model = RedactionModel(regions: [], style: .fill)
        let id = try draw(&model, UnitRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25))
        let start = try #require(model.boxes.first?.rect)
        model.insertDetected([(.face, face), (.text, line)])
        // Past the edge and back from the same start: the drawn box follows, the found ones are untouched.
        model.setRect(of: id, to: RedactionModel.rect(moving: start, dx: 3, dy: 0))
        #expect(model.boxes.first { $0.id == id }?.rect.x == 0.75)
        model.setRect(of: id, to: RedactionModel.rect(moving: start, dx: 0.125, dy: 0))
        #expect(model.boxes.first { $0.id == id }?.rect.x == 0.625)
        #expect(model.boxes.map(\.kind) == [.face, .text, .manual])
        let found = model.boxes.first { $0.kind == .face }?.id ?? -1
        model.setRect(of: found, to: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(model.boxes.first { $0.id == found }?.rect == face, "a found box is not set by hand")
        // A corner dragged past the opposite one flips over it, from the start rectangle each time.
        let flipped = try #require(RedactionModel.rect(dragging: .topLeft, of: start, to: CGPoint(x: 0.9, y: 0.9)))
        #expect(abs(flipped.x - 0.75) < 1e-9 && abs(flipped.width - 0.15) < 1e-9)
        #expect(RedactionModel.rect(dragging: .topLeft, of: start, to: CGPoint(x: 0.745, y: 0.495)) == nil, "under the smallest side")
    }

    @Test func nothingOnBlocks() {
        var model = model
        #expect(model.blocker == nil)
        for box in model.boxes { model.setOn(box.id, false) }
        #expect(model.blocker == "Choose something to hide")
        #expect(model.spec == nil)
        #expect(RedactionModel(regions: [], style: .fill).blocker == "Choose something to hide")
    }

    @Test func theSpecCarriesTheBoxesThatAreOnAndTheStyle() throws {
        var model = model
        model.style = .pixelate
        #expect(model.spec == .redact(RedactionSpec(boxes: [face, email], style: .pixelate)))
        model.toggle(ids(model, .text)[1])
        model.toggle(ids(model, .face)[0])
        #expect(model.spec == .redact(RedactionSpec(boxes: [email, other], style: .pixelate)))
        let manual = UnitRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
        _ = try draw(&model, manual)
        #expect(model.spec == .redact(RedactionSpec(boxes: [email, other, manual], style: .pixelate)))
    }

    @Test func selectionStepsThroughTheBoxesAndStopsAtTheEnds() {
        var model = model
        let all = model.boxes.map(\.id)
        let first = model.selectNext()
        #expect(first)
        #expect(model.selected == all[0])
        let beforeFirst = model.selectPrevious()
        #expect(!beforeFirst, "nothing before the first")
        #expect(model.selected == all[0])
        for id in all.dropFirst() {
            let stepped = model.selectNext()
            #expect(stepped)
            #expect(model.selected == id)
        }
        let pastLast = model.selectNext()
        #expect(!pastLast)
        #expect(model.selected == all.last)
        model.select(nil)
        let fromNothing = model.selectPrevious()
        #expect(fromNothing)
        #expect(model.selected == all.last, "from nothing, previous starts at the last box")
        model.select(999)
        #expect(model.selected == all.last, "an unknown id selects nothing new")
    }

    @Test func boxesAreNamedByKindAndNumber() throws {
        var model = model
        #expect(model.boxes.map { model.label(of: $0.id) } == ["Face 1", "Email 1", "Text 1", "Text 2"])
        let id = try draw(&model, UnitRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2))
        #expect(model.label(of: id) == "Box 1")
    }

    @Test func foundBoxesJoinTheOnesAlreadyDrawn() throws {
        var model = RedactionModel(regions: [], style: .fill)
        let drawn = try draw(&model, UnitRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2))
        model.insertDetected([(.face, face), (.text, line)])
        #expect(model.boxes.map(\.kind) == [.face, .text, .manual])
        #expect(model.boxes.map(\.isOn) == [true, false, true])
        #expect(model.selected == drawn, "the drawn box keeps its id and the selection")
        #expect(Set(model.boxes.map(\.id)).count == 3)
    }

    @Test func statusReads() {
        #expect(RedactionModel.status(faces: 2, emails: 1, text: 0) == "Found 2 faces and 1 email address")
        #expect(RedactionModel.status(faces: 0, emails: 0, text: 3) == "Found 3 lines of text")
        #expect(RedactionModel.status(faces: 1, emails: 0, text: 1) == "Found 1 face and 1 line of text")
        #expect(RedactionModel.status(faces: 1, emails: 2, text: 14) == "Found 1 face, 2 email addresses and 14 lines of text")
        #expect(RedactionModel.status(faces: 0, emails: 0, text: 0) == "Nothing found. Drag over what to hide.")
        #expect(RedactionModel.lookingStatus == "Looking for faces and text\u{2026}")
    }
}
