import Foundation
import Testing
@testable import PomeloCore

/// Find duplicates' report (P263): the single-link groups, the header's counts, the order of a group's files and the
/// paths it prints.
@Suite struct DuplicateReportTests {
    private func entry(_ path: String, pixels: Int = 100, bytes: Int64 = 10, order: Int) -> DuplicateReport.Entry {
        DuplicateReport.Entry(url: URL(filePath: path), pixels: pixels, bytes: bytes, order: order)
    }

    /// Entries `/photos/<name>` in the order given, all the same size.
    private func entries(_ names: String...) -> [DuplicateReport.Entry] {
        names.enumerated().map { entry("/photos/\($0.element)", order: $0.offset) }
    }

    /// A distance read from `close` pairs (0.1) and far for every other pair (0.9), whichever way round it is asked.
    private func distance(close: Set<[Int]>) -> (Int, Int) -> Float {
        { a, b in close.contains([min(a, b), max(a, b)]) ? 0.1 : 0.9 }
    }

    // MARK: Clustering

    @Test func clusterIsSingleLink() {
        // 0 and 2 are far apart, but 1 is close to both: one group. 3 is far from all of them.
        let groups = DuplicateReport.cluster(count: 4, threshold: 0.5, distance: distance(close: [[0, 1], [1, 2]]))
        #expect(groups == [[0, 1, 2]])
    }

    @Test func clusterIgnoresSingletons() {
        #expect(DuplicateReport.cluster(count: 3, threshold: 0.5, distance: distance(close: [])).isEmpty)
        #expect(DuplicateReport.cluster(count: 0, threshold: 0.5, distance: distance(close: [])).isEmpty)
        #expect(DuplicateReport.cluster(count: 1, threshold: 0.5, distance: distance(close: [])).isEmpty)
    }

    @Test func clusterOrdersGroupsByTheirFirstMemberAndMembersAscending() {
        let groups = DuplicateReport.cluster(
            count: 7, threshold: 0.5, distance: distance(close: [[4, 6], [3, 5], [1, 5]])
        )
        #expect(groups == [[1, 3, 5], [4, 6]])
    }

    @Test func clusterNeedsADistanceUnderTheThreshold() {
        let groups = DuplicateReport.cluster(count: 3, threshold: 0.1, distance: distance(close: [[0, 1]]))
        #expect(groups.isEmpty)
    }

    // MARK: Header

    @Test func headerCounts() {
        let five = entries("a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg")
        let both = DuplicateReport.text(entries: five, identical: [[0, 1]], lookAlike: [[0, 2, 3]])
        #expect(both.hasPrefix("1 group of identical files, 1 group that looks alike, 3 extra files\n\n"))

        let identicalOnly = DuplicateReport.text(entries: five, identical: [[0, 1], [2, 3, 4]], lookAlike: [])
        #expect(identicalOnly.hasPrefix("2 groups of identical files, 3 extra files\n\n"))

        let lookAlikeOnly = DuplicateReport.text(entries: five, identical: [], lookAlike: [[1, 4]])
        #expect(lookAlikeOnly.hasPrefix("1 group that looks alike, 1 extra file\n\n"))

        let twoLookAlike = DuplicateReport.text(entries: five, identical: [], lookAlike: [[0, 1], [2, 3]])
        #expect(twoLookAlike.hasPrefix("2 groups that look alike, 2 extra files\n\n"))
    }

    @Test func theWholeReport() {
        let five = entries("a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg")
        let text = DuplicateReport.text(entries: five, identical: [[3, 4], [0, 1]], lookAlike: [[0, 2]])
        #expect(text == """
            2 groups of identical files, 1 group that looks alike, 3 extra files

            Identical
            a.jpg
            b.jpg

            d.jpg
            e.jpg

            Looks alike
            a.jpg
            c.jpg

            """)
    }

    // MARK: Order and names

    @Test func largestPictureFirst() {
        let files = [
            entry("/p/small.jpg", pixels: 100, bytes: 900, order: 0),
            entry("/p/big-light.jpg", pixels: 400, bytes: 5, order: 1),
            entry("/p/big-heavy.jpg", pixels: 400, bytes: 9, order: 2),
            entry("/p/big-heavy-later.jpg", pixels: 400, bytes: 9, order: 3),
        ]
        let text = DuplicateReport.text(entries: files, identical: [], lookAlike: [[0, 1, 2, 3]])
        #expect(text.split(separator: "\n").suffix(4) == [
            "big-heavy.jpg", "big-heavy-later.jpg", "big-light.jpg", "small.jpg",
        ])
        #expect(DuplicateReport.representative(of: [0, 1, 3, 2], in: files) == 2)
        #expect(DuplicateReport.representative(of: [3, 1], in: files) == 3)
    }

    @Test func groupsAreListedInTheOrderTheirFirstFileWasGiven() {
        let files = [
            entry("/p/late.jpg", order: 4), entry("/p/early.jpg", order: 0), entry("/p/mid.jpg", order: 2),
            entry("/p/other.jpg", order: 3),
        ]
        let text = DuplicateReport.text(entries: files, identical: [], lookAlike: [[0, 3], [1, 2]])
        #expect(text.split(separator: "\n").suffix(4) == ["early.jpg", "mid.jpg", "other.jpg", "late.jpg"])
    }

    @Test func pathsAreRelativeToTheSharedFolder() {
        let files = [
            entry("/Users/me/Pictures/trip/a.jpg", order: 0),
            entry("/Users/me/Pictures/trip/day 2/b.jpg", order: 1),
            entry("/Users/me/Pictures/other/c.jpg", order: 2),
            entry("/Users/me/Pictures/unrelated.jpg", order: 3),
        ]
        let text = DuplicateReport.text(entries: files, identical: [[0, 1, 2]], lookAlike: [])
        #expect(text.split(separator: "\n").suffix(3) == ["trip/a.jpg", "trip/day 2/b.jpg", "other/c.jpg"])
    }

    @Test func namesWhenTheyShareAFolder() {
        let files = [entry("/Users/me/Pictures/a.jpg", order: 0), entry("/Users/me/Pictures/./b.jpg", order: 1)]
        let text = DuplicateReport.text(entries: files, identical: [[0, 1]], lookAlike: [])
        #expect(text.split(separator: "\n").suffix(2) == ["a.jpg", "b.jpg"])
    }

    @Test func fullPathsWhenOnlyTheRootIsShared() {
        let files = [entry("/Volumes/Card/a.jpg", order: 0), entry("/Users/me/b.jpg", order: 1)]
        let text = DuplicateReport.text(entries: files, identical: [[0, 1]], lookAlike: [])
        #expect(text.split(separator: "\n").suffix(2) == ["/Volumes/Card/a.jpg", "/Users/me/b.jpg"])
    }

    @Test func newlinesInNamesStayOnOneLine() {
        let files = [
            entry("/p/two\nlines.jpg", order: 0), entry("/p/carriage\rbell\u{07}.jpg", order: 1),
            entry("/p/line\u{2028}separator.jpg", order: 2),
        ]
        let text = DuplicateReport.text(entries: files, identical: [[0, 1, 2]], lookAlike: [])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 7)
        #expect(lines.suffix(4) == ["two lines.jpg", "carriage bell .jpg", "line separator.jpg", ""])
    }

    @Test func sentences() {
        #expect(DuplicateReport.fewerThanTwoReason == "Choose two or more images")
        #expect(DuplicateReport.tooManyReason == "That's too many images to compare (500 at most)")
        #expect(DuplicateReport.noneFoundReason == "No duplicates found")
        #expect(DuplicateReport.maxImages == 500)
    }
}
