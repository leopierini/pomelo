import Foundation

/// Find duplicates' grouping and its text report (P263). Entries are referred to by their index in the list given.
public enum DuplicateReport {
    /// The pairwise comparison stays at about 125,000 distance reads (n(n-1)/2).
    public static let maxImages = 500
    public static let fewerThanTwoReason = "Choose two or more images"
    public static let tooManyReason = "That's too many images to compare (500 at most)"
    public static let noneFoundReason = "No duplicates found"

    public struct Entry: Equatable, Sendable {
        public let url: URL
        /// Width times height of the primary image.
        public let pixels: Int
        public let bytes: Int64
        /// Where the file was in the order given.
        public let order: Int

        public init(url: URL, pixels: Int, bytes: Int64, order: Int) {
            self.url = url
            self.pixels = pixels
            self.bytes = bytes
            self.order = order
        }
    }

    /// Single-link groups of `0..<count`: two items share a group when a chain of pairs each closer than `threshold`
    /// joins them. Only groups of two or more, members ascending, groups ordered by their first member.
    public static func cluster(count: Int, threshold: Float, distance: (Int, Int) -> Float) -> [[Int]] {
        guard count > 1 else { return [] }
        var parent = Array(0..<count)
        func root(_ item: Int) -> Int {
            var item = item
            while parent[item] != item {
                parent[item] = parent[parent[item]]
                item = parent[item]
            }
            return item
        }
        for a in 0..<count {
            for b in (a + 1)..<count where distance(a, b) < threshold {
                let (rootA, rootB) = (root(a), root(b))
                if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for item in 0..<count { groups[root(item), default: []].append(item) }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    /// The member of `group` listed first: the largest picture, then the most bytes, then the first given.
    public static func representative(of group: [Int], in entries: [Entry]) -> Int {
        largestFirst(group, in: entries)[0]
    }

    /// The header line, a blank line, then the "Identical" and "Looks alike" sections (an empty one is left out),
    /// each group's files one per line and its groups apart by a blank line.
    public static func text(entries: [Entry], identical: [[Int]], lookAlike: [[Int]]) -> String {
        let extras = (identical + lookAlike).reduce(0) { $0 + $1.count - 1 }
        let header = [
            counted(identical.count, "group of identical files", "groups of identical files"),
            counted(lookAlike.count, "group that looks alike", "groups that look alike"),
            counted(extras, "extra file", "extra files"),
        ].compactMap { $0 }.joined(separator: ", ")
        let names = displayNames(entries)
        func section(_ title: String, _ groups: [[Int]]) -> String? {
            guard !groups.isEmpty else { return nil }
            let ordered = groups.sorted { firstGiven($0, entries) < firstGiven($1, entries) }
            let lines = ordered.map { largestFirst($0, in: entries).map { names[$0] }.joined(separator: "\n") }
            return title + "\n" + lines.joined(separator: "\n\n")
        }
        let sections = [section("Identical", identical), section("Looks alike", lookAlike)].compactMap { $0 }
        return ([header] + sections).joined(separator: "\n\n") + "\n"
    }

    private static func counted(_ count: Int, _ one: String, _ many: String) -> String? {
        switch count {
        case 0: nil
        case 1: "1 \(one)"
        default: "\(count) \(many)"
        }
    }

    private static func firstGiven(_ group: [Int], _ entries: [Entry]) -> Int {
        group.map { entries[$0].order }.min() ?? 0
    }

    private static func largestFirst(_ group: [Int], in entries: [Entry]) -> [Int] {
        group.sorted { a, b in
            let (left, right) = (entries[a], entries[b])
            if left.pixels != right.pixels { return left.pixels > right.pixels }
            if left.bytes != right.bytes { return left.bytes > right.bytes }
            return left.order < right.order
        }
    }

    /// Each entry's path from the deepest folder every entry shares: the name alone when they all share one folder,
    /// the full path when they share only the root. One line each, whatever the name holds.
    private static func displayNames(_ entries: [Entry]) -> [String] {
        let paths = entries.map { $0.url.standardizedFileURL.pathComponents }
        var shared = paths.first.map { Array($0.dropLast()) } ?? []
        for path in paths.dropFirst() {
            let folder = path.dropLast()
            let common = zip(shared, folder).prefix { $0 == $1 }.count
            shared.removeLast(shared.count - common)
        }
        return zip(entries, paths).map { entry, components in
            let shown = shared.count <= 1
                ? entry.url.standardizedFileURL.path
                : components.dropFirst(shared.count).joined(separator: "/")
            return oneLine(shown)
        }
    }

    /// Control characters and line or paragraph separators become a space, so a name can't break the report's lines.
    private static func oneLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: " "
            default: scalar
            }
        }))
    }
}
