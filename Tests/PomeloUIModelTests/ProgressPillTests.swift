import CoreGraphics
import Foundation
import Testing
@testable import PomeloUIModel

private func job(
    _ files: [PillFile], isCombined: Bool = false, startedAt: ContinuousClock.Instant = .now, isHeld: Bool = false,
    phase: PillPhase = .running
) -> PillJob {
    PillJob(id: UUID(), verb: "Compressing", symbol: "rectangle.compress.vertical", files: files,
            isCombined: isCombined, anchor: CGPoint(x: 500, y: 500), startedAt: startedAt, isHeld: isHeld,
            phase: phase)
}

private func file(_ id: Int, _ name: String, _ state: PillFileState) -> PillFile {
    PillFile(id: id, name: name, state: state)
}

private func file(_ id: Int, _ state: PillFileState) -> PillFile {
    file(id, "photo.png", state)
}

@Suite struct ProgressPillTests {
    @Test func detailForOneFile() {
        let running = job([file(0, .running(fraction: 0.16))])
        #expect(running.detail == "photo.png")
        #expect(running.percentText == "16%")
        #expect(running.fraction == 0.16)

        let indeterminate = job([file(0, .running(fraction: nil))])
        #expect(indeterminate.detail == "photo.png")
        #expect(indeterminate.fraction == nil)
        #expect(indeterminate.percentText == nil)
    }

    @Test func detailForSeveralFiles() {
        // (3 done + 0.9 + 0.9) / 12 = 0.4
        var files = (0..<3).map { file($0, "f\($0).png", .done) }
        files.append(file(3, "f3.png", .running(fraction: 0.9)))
        files.append(file(4, "f4.png", .running(fraction: 0.9)))
        files += (5..<12).map { file($0, "f\($0).png", .waiting) }
        let several = job(files)
        #expect(several.detail == "3 of 12")
        #expect(abs((several.fraction ?? 0) - 0.4) < 1e-9)
        #expect(several.percentText == "40%")
    }

    @Test func failedAndCancelledFilesCountAsFinished() {
        let several = job([file(0, .done), file(1, .failed(reason: "The file may be damaged")), file(2, .cancelled),
                           file(3, .waiting)])
        #expect(several.detail == "3 of 4")
        #expect(several.fraction == 0.75)
    }

    @Test func aFailedOrNotedJobShowsItsSummary() {
        let summary = ResultSummary(title: "Couldn't convert a.png", detail: "The file may be damaged", isFailure: true)
        let failed = job([file(0, .failed(reason: "The file may be damaged"))], phase: .failed(summary))
        #expect(failed.detail == "The file may be damaged")
        #expect(failed.percentText == nil)

        let note = ResultSummary(title: "Copied 1 code", detail: "https://example.com")
        let noted = job([file(0, .done)], phase: .noted(note))
        #expect(noted.detail == "https://example.com")
        #expect(noted.percentText == nil)
    }

    @Test func aLongNameIsShortenedInTheMiddle() {
        let long = job([file(0, "a-very-long-holiday-photo-name.png", .running(fraction: nil))])
        #expect(long.detail.count == ResultSummary.maxTitleNameLength)
        #expect(long.detail == ResultSummary.shortened("a-very-long-holiday-photo-name.png", to: 24))
        #expect(long.detail.hasPrefix("a-very-long"))
        #expect(long.detail.hasSuffix("ame.png"))
        #expect(long.detail.contains("\u{2026}"))
    }

    @Test func invisibleWhileHeldOrYoung() {
        let now = ContinuousClock.now
        let one = [file(0, .running(fraction: nil))]
        #expect(!PillTiming.isVisible(job(one, startedAt: now - .seconds(5), isHeld: true), now: now))
        #expect(!PillTiming.isVisible(job(one, startedAt: now - .milliseconds(400)), now: now))
        #expect(PillTiming.isVisible(job(one, startedAt: now - .milliseconds(600)), now: now))
        let failure = ResultSummary(title: "Couldn't zip", detail: nil, isFailure: true)
        #expect(PillTiming.isVisible(job(one, startedAt: now, phase: .failed(failure)), now: now))
        #expect(!PillTiming.isVisible(job(one, startedAt: now, isHeld: true, phase: .failed(failure)), now: now))
    }

    @Test func theTimingsAreTheRulingsOnes() {
        #expect(PillTiming.showAfter == .milliseconds(500))
        #expect(PillTiming.noteStay == .milliseconds(2500))
    }

    @Test func combinedJobsDoNotExpand() {
        let files = [file(0, "a.png", .waiting), file(1, "b.png", .waiting)]
        #expect(!job(files, isCombined: true).canExpand)
        #expect(job(files).canExpand)
        #expect(!job([file(0, .waiting)]).canExpand)
    }
}

/// Where the pill stack sits: the first pill centred on the anchor, the stack growing downward, kept on screen.
@Suite struct PillLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func frameCentresTheFirstPillOnTheAnchor() {
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 48), anchor: CGPoint(x: 500, y: 500),
                                 visibleFrame: screen)
        #expect(f == CGRect(x: 350, y: 476, width: 300, height: 48))
    }

    @Test func theStackGrowsDownwardFromTheFirstPill() {
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 104), anchor: CGPoint(x: 500, y: 500),
                                 visibleFrame: screen)
        #expect(f == CGRect(x: 350, y: 420, width: 300, height: 104))
    }

    @Test func aTallStackMovesUpAtTheBottomEdge() {
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 400), anchor: CGPoint(x: 500, y: 100),
                                 visibleFrame: screen)
        #expect(f == CGRect(x: 350, y: 0, width: 300, height: 400))
    }

    @Test func aPillNearACornerMovesInside() {
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 48), anchor: CGPoint(x: 1430, y: 895),
                                 visibleFrame: screen)
        #expect(f == CGRect(x: 1140, y: 852, width: 300, height: 48))
        let left = PillLayout.frame(contentSize: CGSize(width: 300, height: 48), anchor: CGPoint(x: 10, y: 5),
                                    visibleFrame: screen)
        #expect(left == CGRect(x: 0, y: 0, width: 300, height: 48))
    }

    @Test func frameStaysOnASecondaryScreen() {
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 48), anchor: CGPoint(x: -100, y: -190),
                                 visibleFrame: secondary)
        #expect(f == CGRect(x: -300, y: -200, width: 300, height: 48))
        let middle = PillLayout.frame(contentSize: CGSize(width: 300, height: 48), anchor: CGPoint(x: -960, y: 300),
                                      visibleFrame: secondary)
        #expect(middle == CGRect(x: -1110, y: 276, width: 300, height: 48))
    }

    @Test func aStackTallerThanTheScreenKeepsItsTopOnScreen() {
        let f = PillLayout.frame(contentSize: CGSize(width: 300, height: 1000), anchor: CGPoint(x: 500, y: 500),
                                 visibleFrame: screen)
        #expect(f.maxY == screen.maxY)
    }

    @Test func theSizesAreThePlansOnes() {
        #expect(PillLayout.width == 300)
        #expect(PillLayout.collapsedHeight == 48)
        #expect(PillLayout.rowHeight == 28)
        #expect(PillLayout.spacing == 8)
        #expect(PillLayout.maxVisibleJobs == 5)
        #expect(PillLayout.maxVisibleRows == 6)
    }
}
