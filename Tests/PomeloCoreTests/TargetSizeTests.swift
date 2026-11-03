import Foundation
import Testing
import PomeloCore

@Suite struct TargetSizeTests {
    @Test func aMinuteOf1080pIn10MBPlays720p() {
        #expect(TargetSize.videoPlan(targetBytes: 10_000_000, durationSeconds: 60, sourceWidth: 1920, sourceHeight: 1080,
                                     frameRate: 30, hasAudio: true)
                == TargetSize.VideoPlan(videoBitsPerSecond: 1_125_333, audioBitsPerSecond: 128_000, maxHeight: 720))
    }

    @Test func tenMinutesDoNotFitIn10MB() {
        // Budget 125,333 b/s; 64,000 for the sound leaves 61,333 for the picture, under the 100,000 floor.
        #expect(TargetSize.videoPlan(targetBytes: 10_000_000, durationSeconds: 600, sourceWidth: 1920, sourceHeight: 1080,
                                     frameRate: 30, hasAudio: true) == nil)
    }

    @Test func aSmallBudgetGivesTheSoundLess() {
        // Budget 501,333 b/s, under 1,000,000, so the sound gets 64,000.
        let plan = TargetSize.videoPlan(targetBytes: 4_000_000, durationSeconds: 60, sourceWidth: 1920, sourceHeight: 1080,
                                        frameRate: 30, hasAudio: true)
        #expect(plan?.audioBitsPerSecond == 64_000)
        #expect(plan?.videoBitsPerSecond == 437_333)
    }

    @Test func silentVideoGivesTheVideoEverything() {
        let plan = TargetSize.videoPlan(targetBytes: 10_000_000, durationSeconds: 60, sourceWidth: 1920,
                                        sourceHeight: 1080, frameRate: 30, hasAudio: false)
        #expect(plan?.audioBitsPerSecond == 0)
        #expect(plan?.videoBitsPerSecond == 1_253_333)
    }

    @Test func thePlanNeverScalesUp() {
        let plan = TargetSize.videoPlan(targetBytes: 100_000_000, durationSeconds: 10, sourceWidth: 640,
                                        sourceHeight: 360, frameRate: 30, hasAudio: true)
        #expect(plan?.maxHeight == 360)
    }

    @Test func aStarvedBudgetFallsToTheLowestHeight() {
        // 161,600 b/s of picture is under 0.04 bits per pixel even at 640x360, so the last candidate wins.
        let plan = TargetSize.videoPlan(targetBytes: 300_000, durationSeconds: 10, sourceWidth: 1920, sourceHeight: 1080,
                                        frameRate: 30, hasAudio: true)
        #expect(plan == TargetSize.VideoPlan(videoBitsPerSecond: 161_600, audioBitsPerSecond: 64_000, maxHeight: 360))
    }

    @Test func aPlanForNothingIsNil() {
        #expect(TargetSize.videoPlan(targetBytes: 0, durationSeconds: 10, sourceWidth: 1920, sourceHeight: 1080,
                                     frameRate: 30, hasAudio: false) == nil)
        #expect(TargetSize.videoPlan(targetBytes: 10_000_000, durationSeconds: 0, sourceWidth: 1920, sourceHeight: 1080,
                                     frameRate: 30, hasAudio: false) == nil)
    }

    @Test func suffixesAndLabels() {
        #expect(TargetSize.nameSuffix(bytes: 10_000_000) == "under-10mb")
        #expect(TargetSize.nameSuffix(bytes: 1_500_000) == "under-1.5mb")
        #expect(TargetSize.nameSuffix(bytes: 500_000) == "under-500kb")
        #expect(TargetSize.nameSuffix(bytes: 1_000) == "under-1kb")
        // Rounded up: a file under 1,234,567 bytes is under 1.3 MB, not always under 1.2 MB.
        #expect(TargetSize.nameSuffix(bytes: 1_234_567) == "under-1.3mb")
        // A rounded-up 1000 KB is a megabyte.
        #expect(TargetSize.nameSuffix(bytes: 999_500) == "under-1mb")
        #expect(TargetSize.nameSuffix(bytes: 999_001) == "under-1mb")
        #expect(TargetSize.nameSuffix(bytes: 999_000) == "under-999kb")

        #expect(TargetSize.label(bytes: 10_000_000) == "10 MB")
        #expect(TargetSize.label(bytes: 500_000) == "500 KB")
        #expect(TargetSize.label(bytes: 1_000) == "1 KB")
        // The separator is the person's own, as Finder shows it.
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(TargetSize.label(bytes: 1_500_000) == "1\(separator)5 MB")
    }

    @Test func aLabelNeverSaysZero() {
        #expect(TargetSize.label(bytes: 400) == "1 KB")
        #expect(TargetSize.label(bytes: 1) == "1 KB")
        #expect(TargetSize.label(bytes: 0) == "1 KB")
        #expect(TargetSize.nameSuffix(bytes: 400) == "under-1kb")
        #expect(TargetSize.nameSuffix(bytes: 0) == "under-1kb")
    }

    @Test func aLabelAndItsSuffixRoundTheSameWay() {
        let us = Locale(identifier: "en_US")
        for (bytes, label, suffix) in [
            (Int64(1_234_567), "1.3 MB", "under-1.3mb"), (1_000_001, "1.1 MB", "under-1.1mb"),
            (1_500_000, "1.5 MB", "under-1.5mb"), (999_500, "1 MB", "under-1mb"),
            (999_000, "999 KB", "under-999kb"), (300_001, "301 KB", "under-301kb"),
            (25_000_000, "25 MB", "under-25mb"),
        ] {
            #expect(TargetSize.label(bytes: bytes, locale: us) == label)
            #expect(TargetSize.nameSuffix(bytes: bytes) == suffix)
        }
    }

    @Test func aLabelUsesTheGivenLocalesSeparator() {
        #expect(TargetSize.label(bytes: 1_500_000, locale: Locale(identifier: "it_IT")) == "1,5 MB")
        #expect(TargetSize.label(bytes: 1_500_000, locale: Locale(identifier: "en_US")) == "1.5 MB")
    }

    @Test func theConstantsAreThePlansOwn() {
        #expect(TargetSize.margin == 0.94)
        #expect(TargetSize.minimumVideoBitsPerSecond == 100_000)
        #expect(TargetSize.minimumBitsPerPixel == 0.04)
        #expect(TargetSize.heights == [1080, 720, 540, 360])
    }
}
