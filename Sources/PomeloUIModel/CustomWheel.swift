// Customized wheels (P180): the user's own pages of slots for one kind of file or one format, stored in `settings.v1`.
// Decoding never fails on what a future or hand-edited blob holds: it clamps to the caps (P178) instead.
import Foundation
import PomeloCore

/// Which file type a customized wheel belongs to: a whole kind, or one format with its own wheel (P175).
public enum WheelKey: Hashable, Sendable {
    case kind(FormatCategory)
    case format(FormatID)

    private static let kindPrefix = "kind."
    private static let formatPrefix = "format."

    public var rawValue: String {
        switch self {
        case .kind(let category): Self.kindPrefix + category.rawValue
        case .format(let id): Self.formatPrefix + id.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.kindPrefix) {
            guard let category = FormatCategory(rawValue: String(rawValue.dropFirst(Self.kindPrefix.count))) else { return nil }
            self = .kind(category)
        } else if rawValue.hasPrefix(Self.formatPrefix) {
            let id = String(rawValue.dropFirst(Self.formatPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .format(FormatID(id))
        } else {
            return nil
        }
    }
}

/// One page of a customized wheel: a name and the slot ids (tool or conversion) in order.
public struct CustomPage: Codable, Equatable, Sendable {
    public var name: String
    public var slots: [String]

    public init(name: String, slots: [String]) {
        self.name = name
        self.slots = slots
    }

    private enum CodingKeys: String, CodingKey {
        case name, slots
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        // Element by element: one slot that isn't a string is dropped alone, never the page's other slots.
        slots = (try? c.decodeIfPresent([Unreadable<String>].self, forKey: .slots))?
            .compactMap(\.value) ?? []
    }
}

public struct CustomWheel: Codable, Equatable, Sendable {
    public static let maxPages = 4
    public static let maxNameLength = 20

    public var pages: [CustomPage]

    public init(pages: [CustomPage]) {
        self.pages = pages
    }

    public var slotCount: Int { pages.reduce(0) { $0 + $1.slots.count } }

    /// The name trimmed, cut to `maxNameLength` and trimmed again (the cut can end on a space); `fallback` when
    /// nothing is left.
    public static func clampedName(_ name: String, fallback: String) -> String {
        let cut = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? fallback : cut
    }

    private enum CodingKeys: String, CodingKey {
        case pages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let readable = (try? c.decodeIfPresent([Unreadable<CustomPage>].self, forKey: .pages))?.compactMap(\.value) ?? []
        pages = readable.prefix(Self.maxPages).enumerated().map { index, page in
            var seen = Set<String>()
            let slots = page.slots.filter { seen.insert($0).inserted }.prefix(WheelContentBuilder.maxSlices)
            return CustomPage(name: Self.clampedName(page.name, fallback: "Page \(index + 1)"), slots: Array(slots))
        }
    }
}

extension FormatCategory {
    /// The plural name the wheel editor lists and its sentences use.
    public var wheelTitle: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .text: "Text"
        case .data: "Data"
        case .subtitle: "Subtitles"
        case .archive: "Archives"
        case .font: "Fonts"
        case .other: "Other"
        }
    }
}
