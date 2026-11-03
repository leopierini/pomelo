// The Redact editor's boxes (P27): what detection proposed and what the person drew, which are on, and the spec the
// engine gets. Everything is a `UnitRect` of the upright picture (global constraints, Coordinates). No AppKit.
import CoreGraphics
import Foundation
import PomeloCore

public enum RedactionKind: Sendable {
    case face, email, text, manual
}

public struct RedactionBox: Equatable, Sendable, Identifiable {
    public let id: Int
    public var kind: RedactionKind
    public var rect: UnitRect
    public var isOn: Bool
}

public enum RedactionCorner: Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct RedactionModel: Equatable, Sendable {
    /// The smallest side of a drawn box, as a fraction of the picture's side.
    public static let minimumSide = 0.01
    public static let nothingToHide = "Choose something to hide"
    public static let lookingStatus = "Looking for faces and text\u{2026}"

    public private(set) var boxes: [RedactionBox] = []
    public var style: RedactionStyle
    public private(set) var selected: Int?
    private var nextID = 0

    /// Faces and emails start on, lines of text off: hiding everything is one tap on its toggle, but a screenshot's
    /// every line is not hidden unasked.
    public init(regions: [(RedactionKind, UnitRect)], style: RedactionStyle) {
        self.style = style
        boxes = regions.map { makeBox($0.0, $0.1) }
    }

    /// Puts what detection found before the boxes already drawn, which keep their ids and the selection.
    public mutating func insertDetected(_ regions: [(RedactionKind, UnitRect)]) {
        let drawn = boxes
        boxes = regions.map { makeBox($0.0, $0.1) } + drawn
    }

    public var blocker: String? {
        boxes.contains(where: \.isOn) ? nil : Self.nothingToHide
    }

    public var spec: EditSpec? {
        let on = boxes.filter(\.isOn).map(\.rect)
        return on.isEmpty ? nil : .redact(RedactionSpec(boxes: on, style: style))
    }

    // MARK: Reading

    public func count(_ kind: RedactionKind) -> Int {
        boxes.filter { $0.kind == kind }.count
    }

    /// "Face 1", "Email 2", "Text 3", "Box 1": the number counts the boxes of its kind.
    public func label(of id: Int) -> String {
        guard let box = boxes.first(where: { $0.id == id }) else { return "" }
        let number = boxes.filter { $0.kind == box.kind }.firstIndex { $0.id == id }.map { $0 + 1 } ?? 1
        let name: String = switch box.kind {
        case .face: "Face"
        case .email: "Email"
        case .text: "Text"
        case .manual: "Box"
        }
        return "\(name) \(number)"
    }

    /// The box under `point`: a drawn one first (the latest on top), else the smallest that holds it, so an address
    /// is reachable inside its line.
    public func box(at point: CGPoint) -> Int? {
        func holds(_ box: RedactionBox) -> Bool {
            let rect = box.rect
            return point.x >= rect.x && point.x <= rect.x + rect.width
                && point.y >= rect.y && point.y <= rect.y + rect.height
        }
        if let drawn = boxes.last(where: { $0.kind == .manual && holds($0) }) { return drawn.id }
        return boxes.filter(holds).min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.id
    }

    // MARK: Choosing

    public mutating func toggle(_ id: Int) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[index].isOn.toggle()
    }

    public mutating func setOn(_ id: Int, _ on: Bool) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[index].isOn = on
    }

    /// An id that is not a box selects nothing new.
    public mutating func select(_ id: Int?) {
        guard let id else {
            selected = nil
            return
        }
        if boxes.contains(where: { $0.id == id }) { selected = id }
    }

    /// False at the last box, so Tab can go on to the next control. From nothing it selects the first.
    @discardableResult
    public mutating func selectNext() -> Bool {
        guard !boxes.isEmpty else { return false }
        guard let current = selected.flatMap({ id in boxes.firstIndex { $0.id == id } }) else {
            selected = boxes[0].id
            return true
        }
        guard current + 1 < boxes.count else { return false }
        selected = boxes[current + 1].id
        return true
    }

    /// False at the first box. From nothing it selects the last.
    @discardableResult
    public mutating func selectPrevious() -> Bool {
        guard !boxes.isEmpty else { return false }
        guard let current = selected.flatMap({ id in boxes.firstIndex { $0.id == id } }) else {
            selected = boxes[boxes.count - 1].id
            return true
        }
        guard current > 0 else { return false }
        selected = boxes[current - 1].id
        return true
    }

    // MARK: Drawing

    /// The box clamped into the picture, on and selected; nil when under 1% of the picture on either side.
    @discardableResult
    public mutating func addManual(_ rect: UnitRect) -> Int? {
        let clamped = rect.clamped()
        guard clamped.width >= Self.minimumSide, clamped.height >= Self.minimumSide else { return nil }
        let box = makeBox(.manual, clamped, on: true)
        boxes.append(box)
        selected = box.id
        return box.id
    }

    /// Moves the selected drawn box by fractions of the picture, keeping its size and staying inside.
    public mutating func moveSelected(dx: Double, dy: Double) {
        guard let index = selectedManualIndex, dx.isFinite, dy.isFinite else { return }
        var rect = boxes[index].rect
        rect.x = min(max(rect.x + dx, 0), 1 - rect.width)
        rect.y = min(max(rect.y + dy, 0), 1 - rect.height)
        boxes[index].rect = rect
    }

    /// Grows or shrinks the selected drawn box from its bottom-right corner, within the picture and the smallest side.
    public mutating func resizeSelected(dw: Double, dh: Double) {
        guard let index = selectedManualIndex, dw.isFinite, dh.isFinite else { return }
        var rect = boxes[index].rect
        rect.width = min(max(rect.width + dw, Self.minimumSide), 1 - rect.x)
        rect.height = min(max(rect.height + dh, Self.minimumSide), 1 - rect.y)
        boxes[index].rect = rect
    }

    /// Gives the drawn box `id` the rectangle a drag worked out from where it began, so the drag acts on the model as
    /// it is now (detection may have added boxes since the drag began) and not on a copy.
    public mutating func setRect(of id: Int, to rect: UnitRect) {
        guard let index = boxes.firstIndex(where: { $0.id == id }), boxes[index].kind == .manual else { return }
        boxes[index].rect = rect
    }

    /// `start` moved by fractions of the picture, keeping its size and staying inside.
    public static func rect(moving start: UnitRect, dx: Double, dy: Double) -> UnitRect {
        guard dx.isFinite, dy.isFinite else { return start }
        var rect = start
        rect.x = min(max(start.x + dx, 0), 1 - start.width)
        rect.y = min(max(start.y + dy, 0), 1 - start.height)
        return rect
    }

    /// `start` with one corner dragged to `point` and the opposite corner fixed; nil when the result would be under
    /// the smallest side or `point` is not a number.
    public static func rect(dragging corner: RedactionCorner, of start: UnitRect, to point: CGPoint) -> UnitRect? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let fixed: CGPoint = switch corner {
        case .topLeft: CGPoint(x: start.x + start.width, y: start.y + start.height)
        case .topRight: CGPoint(x: start.x, y: start.y + start.height)
        case .bottomLeft: CGPoint(x: start.x + start.width, y: start.y)
        case .bottomRight: CGPoint(x: start.x, y: start.y)
        }
        let moved = rect(from: fixed, to: CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)))
        return moved.width >= minimumSide && moved.height >= minimumSide ? moved : nil
    }

    /// The selection moves to the box beside it.
    public mutating func removeSelected() {
        guard let index = selectedManualIndex else { return }
        boxes.remove(at: index)
        selected = boxes.isEmpty ? nil : boxes[min(index, boxes.count - 1)].id
    }

    /// The rectangle between two corners, whichever way they lie.
    public static func rect(from a: CGPoint, to b: CGPoint) -> UnitRect {
        UnitRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)),
                 width: Double(abs(a.x - b.x)), height: Double(abs(a.y - b.y)))
    }

    // MARK: Status

    /// "Found 2 faces and 1 email address", "Found 3 lines of text", or the way to add boxes by hand.
    public static func status(faces: Int, emails: Int, text: Int) -> String {
        var parts: [String] = []
        if faces > 0 { parts.append(faces == 1 ? "1 face" : "\(faces) faces") }
        if emails > 0 { parts.append(emails == 1 ? "1 email address" : "\(emails) email addresses") }
        if text > 0 { parts.append(text == 1 ? "1 line of text" : "\(text) lines of text") }
        guard let last = parts.last else { return "Nothing found. Drag over what to hide." }
        let front = parts.dropLast().joined(separator: ", ")
        return "Found " + (front.isEmpty ? last : "\(front) and \(last)")
    }

    // MARK: Private

    private var selectedManualIndex: Int? {
        guard let selected, let index = boxes.firstIndex(where: { $0.id == selected }),
              boxes[index].kind == .manual else { return nil }
        return index
    }

    private mutating func makeBox(_ kind: RedactionKind, _ rect: UnitRect, on: Bool? = nil) -> RedactionBox {
        defer { nextID += 1 }
        return RedactionBox(id: nextID, kind: kind, rect: rect, isOn: on ?? (kind != .text))
    }
}
