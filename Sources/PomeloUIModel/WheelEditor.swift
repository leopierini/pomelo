// The Settings wheel editor's model (P178, P179): every edit of a customized wheel is an operation here with its
// refusals, so the view only calls these and shows the message. Nothing is stored until `save(into:)`, and only an
// edit that changed something marks the wheel customized: looking at a built-in wheel creates nothing.
import Foundation
import PomeloCore

public struct WheelEditor: Equatable, Sendable {
    public enum Refusal: Equatable, Sendable {
        case pageFull, alreadyOnPage, lastSlot, lastPage

        public func message(for key: WheelKey) -> String {
            switch self {
            case .pageFull: "This page already has \(WheelContentBuilder.maxSlices) slots."
            case .alreadyOnPage: "It's already on this page."
            case .lastPage: "A wheel keeps at least one page."
            case .lastSlot:
                switch key {
                case .kind: "A wheel keeps at least one slot. Reset to default to go back to the built-in wheel."
                case .format(let id):
                    if let category = FormatRegistry.builtIn.format(id: id)?.category {
                        "A wheel keeps at least one slot. Use the \(category.wheelTitle) wheel to go back to it."
                    } else {
                        "A wheel keeps at least one slot. Use the wheel for its kind to go back to it."
                    }
                }
            }
        }
    }

    public let key: WheelKey
    public private(set) var wheel: CustomWheel
    public private(set) var isCustomized: Bool

    public init(key: WheelKey, settings: AppSettings, fallback: CustomWheel) {
        self.key = key
        if let stored = settings.wheels[key.rawValue] {
            wheel = stored
            isCustomized = true
        } else {
            wheel = fallback
            isCustomized = false
        }
    }

    private static let maxSlots = WheelContentBuilder.maxSlices

    @discardableResult
    public mutating func add(_ slot: String, page: Int, at index: Int) -> Refusal? {
        guard wheel.pages.indices.contains(page) else { return nil }
        let slots = wheel.pages[page].slots
        if slots.contains(slot) { return .alreadyOnPage }
        if slots.count >= Self.maxSlots { return .pageFull }
        wheel.pages[page].slots.insert(slot, at: min(max(index, 0), slots.count))
        isCustomized = true
        return nil
    }

    @discardableResult
    public mutating func replace(page: Int, at index: Int, with slot: String) -> Refusal? {
        guard wheel.pages.indices.contains(page), wheel.pages[page].slots.indices.contains(index) else { return nil }
        let slots = wheel.pages[page].slots
        if slots[index] == slot { return nil }
        if slots.contains(slot) { return .alreadyOnPage }
        wheel.pages[page].slots[index] = slot
        isCustomized = true
        return nil
    }

    /// `to` is an insertion index into the page as it is before the move (0 through count), the one
    /// `WheelGeometry.insertionIndex` gives; the slot lands at `to` adjusted for its own removal.
    @discardableResult
    public mutating func move(page: Int, from: Int, to: Int) -> Refusal? {
        guard wheel.pages.indices.contains(page), wheel.pages[page].slots.indices.contains(from) else { return nil }
        let count = wheel.pages[page].slots.count
        let target = min(max(to, 0), count)
        let destination = target > from ? target - 1 : target
        guard destination != from else { return nil }
        let slot = wheel.pages[page].slots.remove(at: from)
        wheel.pages[page].slots.insert(slot, at: destination)
        isCustomized = true
        return nil
    }

    @discardableResult
    public mutating func move(page: Int, at index: Int, toPage: Int) -> Refusal? {
        guard page != toPage, wheel.pages.indices.contains(page), wheel.pages.indices.contains(toPage),
              wheel.pages[page].slots.indices.contains(index) else { return nil }
        let slot = wheel.pages[page].slots[index]
        if wheel.pages[toPage].slots.contains(slot) { return .alreadyOnPage }
        if wheel.pages[toPage].slots.count >= Self.maxSlots { return .pageFull }
        wheel.pages[page].slots.remove(at: index)
        wheel.pages[toPage].slots.append(slot)
        isCustomized = true
        return nil
    }

    @discardableResult
    public mutating func remove(page: Int, at index: Int) -> Refusal? {
        guard wheel.pages.indices.contains(page), wheel.pages[page].slots.indices.contains(index) else { return nil }
        if wheel.slotCount <= 1 { return .lastSlot }
        wheel.pages[page].slots.remove(at: index)
        isCustomized = true
        return nil
    }

    /// The new page's index, or nil at the page cap.
    @discardableResult
    public mutating func addPage() -> Int? {
        guard wheel.pages.count < CustomWheel.maxPages else { return nil }
        wheel.pages.append(CustomPage(name: "Page \(wheel.pages.count + 1)", slots: []))
        isCustomized = true
        return wheel.pages.count - 1
    }

    public mutating func renamePage(_ page: Int, to name: String) {
        guard wheel.pages.indices.contains(page) else { return }
        let old = wheel.pages[page].name
        let new = CustomWheel.clampedName(name, fallback: old)
        guard new != old else { return }
        wheel.pages[page].name = new
        isCustomized = true
    }

    public mutating func movePage(from: Int, to: Int) {
        guard wheel.pages.indices.contains(from) else { return }
        let destination = min(max(to, 0), wheel.pages.count - 1)
        guard destination != from else { return }
        let moved = wheel.pages.remove(at: from)
        wheel.pages.insert(moved, at: destination)
        isCustomized = true
    }

    @discardableResult
    public mutating func deletePage(_ page: Int) -> Refusal? {
        guard wheel.pages.indices.contains(page) else { return nil }
        if wheel.pages.count == 1 { return .lastPage }
        if wheel.slotCount == wheel.pages[page].slots.count { return .lastSlot }
        wheel.pages.remove(at: page)
        isCustomized = true
        return nil
    }

    public func save(into settings: inout AppSettings) {
        guard isCustomized else { return }
        settings.wheels[key.rawValue] = wheel
    }

    /// Back to the built-in wheel. A kind also drops the older per-kind order and visibility, which would otherwise
    /// reappear on the built-in wheel the user just went back to.
    public static func reset(_ key: WheelKey, in settings: inout AppSettings) {
        settings.wheels[key.rawValue] = nil
        if case .kind(let category) = key {
            settings.wheelOrder[category.rawValue] = nil
            settings.toolVisibility[category.rawValue] = nil
        }
    }
}
