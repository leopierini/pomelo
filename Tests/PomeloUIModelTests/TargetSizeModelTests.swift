import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Compress to size editor's field, chips, blockers and notes (P27), in the person's locale.
@Suite struct TargetSizeModelTests {
    private let us = Locale(identifier: "en_US")
    private let italy = Locale(identifier: "it_IT")

    private func image(_ bytes: Int64 = 5_000_000) -> SourceSize { SourceSize(bytes: bytes) }

    private func video(seconds: Double, bytes: Int64 = 200_000_000) -> SourceSize {
        SourceSize(bytes: bytes, durationSeconds: seconds, width: 1920, height: 1080, frameRate: 30, hasAudio: true)
    }

    private func model(
        _ category: FormatCategory = .image, _ sources: [SourceSize]? = nil, remembered: Int64? = nil,
        locale: Locale? = nil
    ) -> TargetSizeModel {
        TargetSizeModel(category: category, sources: sources ?? [category == .video ? video(seconds: 60) : image()],
                        remembered: remembered, locale: locale ?? us)
    }

    private func typed(_ text: String, _ unit: SizeUnit, _ category: FormatCategory = .image,
                       sources: [SourceSize]? = nil, locale: Locale? = nil) -> TargetSizeModel {
        var m = model(category, sources, locale: locale)
        m.text = text
        m.unit = unit
        return m
    }

    /// With nothing remembered the field starts on a chip (P207): Discord's free limit for videos, a form's for images.
    @Test func defaultsDependOnTheKind() {
        let image = model(.image)
        #expect(image.text == "500" && image.unit == .kb && image.targetBytes == 500_000)
        #expect(image.chips.contains(500_000))
        let pdf = model(.pdf)
        #expect(pdf.text == "2" && pdf.unit == .mb)
        let video = model(.video)
        #expect(video.text == "20" && video.unit == .mb && video.targetBytes == 20_000_000)
        #expect(video.chips.contains(20_000_000))
        let remembered = model(.image, remembered: 500_000)
        #expect(remembered.text == "500" && remembered.unit == .kb && remembered.targetBytes == 500_000)
        let fraction = model(.pdf, remembered: 1_500_000)
        #expect(fraction.text == "1.5" && fraction.unit == .mb)
        #expect(model(.image, remembered: 1_500_000, locale: italy).text == "1,5")
    }

    /// Arabic, Persian and Devanagari locales format with their own digits, which the field can't read back.
    @Test func theFieldUsesLatinDigitsInEveryLocale() {
        for identifier in ["ar_SA", "fa_IR", "mr_IN"] {
            let locale = Locale(identifier: identifier)
            let whole = model(.image, locale: locale)
            #expect(whole.text == "500" && whole.targetBytes == 500_000, "\(identifier): \(whole.text)")
            let fraction = model(.pdf, remembered: 1_500_000, locale: locale)
            #expect(fraction.targetBytes == 1_500_000, "\(identifier): \(fraction.text)")
        }
    }

    @Test func aRememberedSizeThatIsNotWholeFallsBackToKilobytes() {
        let m = model(.image, remembered: 1_234_000)
        #expect(m.unit == .kb && m.text == "1234")
    }

    @Test func textParsesInTheUsersLocale() {
        #expect(typed("1,5", .mb, locale: italy).targetBytes == 1_500_000)
        #expect(typed("1.5", .mb, locale: us).targetBytes == 1_500_000)
        #expect(typed("1.5", .mb, locale: italy).targetBytes == 1_500_000)
        #expect(typed(" 300 ", .kb).targetBytes == 300_000)
        for bad in ["abc", "", "  ", "1.2.3", "-5", "1e3", "5 MB"] {
            let m = typed(bad, .mb)
            #expect(m.targetBytes == nil, "\(bad)")
            #expect(m.blocker == "Enter a size", "\(bad)")
        }
    }

    @Test func aTargetAboveEverySourceIsBlocked() {
        let one = typed("1", .mb, sources: [image(800_000)])
        #expect(one.blocker == "It's already under 1 MB")
        let several = typed("1", .mb, sources: [image(800_000), image(900_000)])
        #expect(several.blocker == "They're all under 1 MB")
        // One file still over the target is enough to go on.
        #expect(typed("1", .mb, sources: [image(800_000), image(3_000_000)]).blocker == nil)
        #expect(typed("1", .mb, sources: [image(1_000_000)]).blocker == "It's already under 1 MB")
    }

    @Test func tooSmallIsBlockedPerKind() {
        #expect(typed("9", .kb, .image).blocker == "At least 10 KB")
        #expect(typed("5", .kb, .image).blocker == "At least 10 KB")
        #expect(typed("10", .kb, .image).blocker == nil)
        #expect(typed("20", .kb, .image).blocker == nil)
        #expect(typed("99", .kb, .pdf).blocker == "At least 100 KB")
        #expect(typed("100", .kb, .pdf).blocker == nil)
        #expect(typed("900", .kb, .video, sources: [video(seconds: 5)]).blocker == "At least 1 MB")
        #expect(typed("1", .mb, .video, sources: [video(seconds: 5)]).blocker == nil)
        #expect(typed("0", .mb, .image).blocker == "At least 10 KB")
    }

    @Test func theBlockersComeInOrder() {
        // A size too small for a file that is under it: the minimum is reported first.
        #expect(typed("9", .kb, sources: [image(5_000)]).blocker == "At least 10 KB")
        #expect(typed("", .kb, sources: [image(10_000)]).blocker == "Enter a size")
    }

    @Test func chipsFillTheField() {
        var m = model(.image)
        #expect(m.chips == [20_000, 50_000, 100_000, 500_000])
        m.choose(5_000_000)
        #expect(m.text == "5" && m.unit == .mb && m.targetBytes == 5_000_000)
        m.choose(20_000)
        #expect(m.text == "20" && m.unit == .kb && m.targetBytes == 20_000)
        m.choose(500_000)
        #expect(m.text == "500" && m.unit == .kb && m.targetBytes == 500_000)
        #expect(model(.pdf).chips == [1_000_000, 2_000_000, 5_000_000, 10_000_000])
        #expect(model(.video).chips == [10_000_000, 20_000_000, 50_000_000, 100_000_000])
        var it = model(.image, locale: italy)
        it.choose(1_500_000)
        #expect(it.text == "1,5" && it.targetBytes == 1_500_000)
    }

    @Test func videoNoteShowsThePlan() {
        let m = typed("10", .mb, .video, sources: [video(seconds: 60)])
        #expect(m.blocker == nil)
        #expect(m.note == "About 1.1 Mbps at 720p")
        #expect(typed("10", .mb, .video, sources: [video(seconds: 60)], locale: italy).note
                == "About 1,1 Mbps at 720p")

        let long = typed("10", .mb, .video, sources: [video(seconds: 600)])
        #expect(long.blocker == "It's too long to fit in 10 MB")
    }

    @Test func aVideoNotReadYetHasNeitherNoteNorPlanBlocker() {
        let unread = typed("10", .mb, .video, sources: [SourceSize(bytes: 200_000_000)])
        #expect(unread.blocker == nil)
        #expect(unread.note == nil)
    }

    @Test func severalFilesSayEachFile() {
        let three = [image(), image(), image()]
        let m = model(.image, three)
        #expect(m.note == "Each file under 500 KB")
        #expect(m.confirmTitle == "Save 3 Smaller Copies")
        #expect(model(.image).confirmTitle == "Save Smaller Copy")
        // Several videos are not planned one by one.
        let videos = typed("10", .mb, .video, sources: [video(seconds: 60), video(seconds: 600)])
        #expect(videos.blocker == nil)
        #expect(videos.note == "Each file under 10 MB")
    }

    @Test func notesForImagesAndPDFs() {
        #expect(model(.image).note == "Lowers the quality first, then the size in pixels")
        #expect(model(.pdf).note == "Shrinks the images inside; text stays sharp")
    }

    @Test func theSourceSizeIsTold() {
        let one = model(.image, [image(3_400_000)])
        let finder = ByteCountFormatter.string(fromByteCount: 3_400_000, countStyle: .file)
        #expect(one.sourceLabel == "Now \(finder)")
        let two = model(.image, [image(3_400_000), image(1_000_000)])
        #expect(two.sourceLabel == "Now \(ByteCountFormatter.string(fromByteCount: 4_400_000, countStyle: .file)) in total")
    }

    @Test func loadedSourcesReplaceTheGuess() {
        var m = typed("10", .mb, .video, sources: [SourceSize(bytes: 200_000_000)])
        m.update(sources: [video(seconds: 600)])
        #expect(m.blocker == "It's too long to fit in 10 MB")
    }
}
