import Foundation
import PomeloCore
import PomeloUIModel
import Testing

/// The Resize editor's fields, lock, chips, blockers and notes (P197).
@Suite struct ResizeModelTests {
    private let photo = (width: 4032, height: 3024)

    private func model(_ category: FormatCategory = .image, _ sources: [(width: Int, height: Int)]? = nil,
                       remembered: ResizeSpec? = nil) -> ResizeModel {
        ResizeModel(category: category, sources: sources ?? [photo], remembered: remembered)
    }

    @Test func lockedWidthComputesHeight() {
        var m = model()
        #expect(m.isLocked)
        m.typeWidth("1000")
        #expect(m.widthText == "1000" && m.heightText == "750")
        #expect(m.spec == .width(1000))
        // The side typed last is the one stored, so every file of a batch keeps its own proportions.
        m.typeHeight("600")
        #expect(m.heightText == "600" && m.widthText == "800")
        #expect(m.spec == .height(600))
    }

    @Test func unlockedIsExact() {
        var m = model()
        m.toggleLock()
        #expect(!m.isLocked)
        m.typeWidth("1080")
        m.typeHeight("1080")
        #expect(m.widthText == "1080" && m.heightText == "1080")
        #expect(m.spec == .exact(width: 1080, height: 1080))
        // Locking again keeps the side typed last and follows it.
        m.toggleLock()
        #expect(m.spec == .height(1080) && m.widthText == "1440")
    }

    @Test func chipsByKind() {
        let image = model(.image)
        #expect(image.chips == [.percent(50), .percent(25), .exact(width: 1080, height: 1080), .width(1920)])
        #expect(image.chips.map(\.title) == ["50 %", "25 %", "1080 \u{00D7} 1080", "1920 wide"])
        #expect(image.chips.map(\.spec) == [.scale(percent: 50), .scale(percent: 25),
                                            .exact(width: 1080, height: 1080), .width(1920)])
        let video = model(.video, [(width: 3840, height: 2160)])
        #expect(video.chips == [.height(2160), .height(1080), .height(720), .height(480)])
        #expect(video.chips.map(\.title) == ["2160p", "1080p", "720p", "480p"])
        #expect(video.chips.map(\.spec) == [.height(2160), .height(1080), .height(720), .height(480)])
    }

    @Test func choosingAChipFillsTheFields() {
        var m = model()
        m.choose(.percent(50))
        #expect(m.spec == .scale(percent: 50) && m.isLocked)
        #expect(m.widthText == "2016" && m.heightText == "1512")
        m.choose(.exact(width: 1080, height: 1080))
        #expect(!m.isLocked && m.spec == .exact(width: 1080, height: 1080))
        #expect(m.widthText == "1080" && m.heightText == "1080")
        m.choose(.width(1920))
        #expect(m.isLocked && m.spec == .width(1920) && m.heightText == "1440")
        // A field handing back the text it shows (as it ends editing) keeps the percentage.
        m.choose(.percent(50))
        m.typeWidth("2016")
        #expect(m.spec == .scale(percent: 50))
        // Typing after a percentage stores pixels again.
        m.choose(.percent(25))
        m.typeWidth("500")
        #expect(m.spec == .width(500) && m.heightText == "375")
        var video = model(.video, [(width: 1920, height: 1080)])
        video.choose(.height(720))
        #expect(video.spec == .height(720) && video.widthText == "1280" && video.heightText == "720")
    }

    /// A video's following side is the one the engine writes: rounded down to an even number.
    @Test func aVideosFollowingSideIsWhatTheEngineWrites() {
        var video = model(.video, [(width: 1920, height: 1080)])
        video.typeWidth("1919")
        #expect(video.heightText == "1078")
        video.typeHeight("721")
        #expect(video.widthText == "1280")
        video.choose(.percent(33))
        #expect(video.widthText == "632" && video.heightText == "356")
        // Already that size: the field shows the file's own side.
        video.typeHeight("1081")
        #expect(video.widthText == "1920")
        // Out of range: the image rounding, and the blocker says why.
        video.typeWidth("20000")
        #expect(video.heightText == "11250" && video.blocker == "Between 1 and 16,384 pixels")
        // An image keeps the nearest pixel.
        var image = model(.image, [(width: 1920, height: 1080)])
        image.typeWidth("1919")
        #expect(image.heightText == "1079")
    }

    @Test func blockers() {
        var empty = model()
        #expect(empty.spec == nil)
        #expect(empty.blocker == ResizeEdit.chooseSizeReason && empty.blocker == "Choose a size")
        empty.typeWidth("  ")
        #expect(empty.blocker == "Choose a size")

        var huge = model()
        huge.typeWidth("20000")
        #expect(huge.blocker == ResizeEdit.pixelRangeReason && huge.blocker == "Between 1 and 16,384 pixels")
        huge.typeWidth("0")
        #expect(huge.blocker == "Between 1 and 16,384 pixels")
        huge.typeWidth("12abc")
        #expect(huge.blocker == "Between 1 and 16,384 pixels")
        // A pasted run of digits is out of range, not a crash, on the side that follows too.
        var tallHuge = model(.image, [(width: 1000, height: 3000)])
        tallHuge.typeWidth("99999999999999999999")
        #expect(tallHuge.blocker == "Between 1 and 16,384 pixels" && tallHuge.heightText == "1000000000000")
        #expect(model(remembered: .scale(percent: 1e300)).blocker == "Between 1 and 400 %")
        // In range itself, but the side that follows would not be.
        var tall = model(.image, [(width: 1000, height: 3000)])
        tall.typeWidth("10000")
        #expect(tall.blocker == "Between 1 and 16,384 pixels")

        var exact = model()
        exact.toggleLock()
        exact.typeWidth("1080")
        #expect(exact.blocker == "Choose a size")

        var same = model()
        same.typeWidth("4032")
        #expect(same.blocker == ResizeEdit.alreadyThatSizeReason && same.blocker == "It's already that size")
        same.choose(.percent(50))
        #expect(same.blocker == nil)

        // Already that size only when every file is.
        var batch = model(.image, [photo, (width: 2000, height: 1500)])
        batch.typeWidth("4032")
        #expect(batch.blocker == nil)
        batch.typeWidth("2000")
        #expect(batch.blocker == nil)

        var valid = model()
        valid.typeWidth("1000")
        #expect(valid.blocker == nil)

        // A video's sides round down to even numbers, as the engine writes them.
        var video = model(.video, [(width: 1920, height: 1080)])
        video.typeHeight("1081")
        #expect(video.blocker == "It's already that size")
    }

    @Test func percentagesOutsideTheRangeAreBlocked() {
        let m = model(remembered: .scale(percent: 500))
        #expect(m.blocker == ResizeEdit.percentRangeReason && m.blocker == "Between 1 and 400 %")
    }

    @Test func noteWhenEnlarging() {
        var m = model()
        m.typeWidth("8000")
        #expect(m.blocker == nil)
        #expect(m.note == "Larger than the original, so it may look soft")
        m.typeWidth("2000")
        #expect(m.note == nil)
        var video = model(.video, [(width: 1920, height: 1080)])
        video.choose(.height(720))
        #expect(video.note == "Re-encodes the video")
        video.choose(.height(2160))
        #expect(video.note == "Larger than the original, so it may look soft")
    }

    @Test func sourceLabel() {
        #expect(model().sourceLabel == "Now 4032 \u{00D7} 3024")
        let three = model(.image, [photo, (width: 100, height: 100), (width: 200, height: 100)])
        #expect(three.sourceLabel == "Now 4032 \u{00D7} 3024 and 2 more")
        #expect(model(.image, []).sourceLabel == "")
        // Before the files are read, and when one of them can't be, the count is every file's.
        let unread = ResizeModel(category: .image, sources: [], remembered: nil, fileCount: 3)
        #expect(unread.sourceLabel == "" && unread.confirmTitle == "Save 3 Resized Copies")
        let oneUnreadable = ResizeModel(category: .image, sources: [photo], remembered: nil, fileCount: 2)
        #expect(oneUnreadable.sourceLabel == "Now 4032 \u{00D7} 3024 and 1 more")
        #expect(model().confirmTitle == "Save Resized Copy")
        #expect(three.confirmTitle == "Save 3 Resized Copies")
    }

    @Test func sizesReadLaterFillTheFollowingSide() {
        var m = model(.image, [])
        m.typeWidth("1000")
        #expect(m.heightText == "" && m.spec == .width(1000))
        m.update(sources: [photo])
        #expect(m.heightText == "750")
        #expect(m.sourceLabel == "Now 4032 \u{00D7} 3024")
    }

    @Test func rememberedSpecRestores() {
        let width = model(remembered: .width(1000))
        #expect(width.isLocked && width.spec == .width(1000) && width.widthText == "1000" && width.heightText == "750")
        let height = model(remembered: .height(600))
        #expect(height.spec == .height(600) && height.widthText == "800")
        let exact = model(remembered: .exact(width: 600, height: 600))
        #expect(!exact.isLocked && exact.spec == .exact(width: 600, height: 600))
        #expect(exact.widthText == "600" && exact.heightText == "600")
        let scale = model(remembered: .scale(percent: 25))
        #expect(scale.isLocked && scale.spec == .scale(percent: 25))
        #expect(scale.widthText == "1008" && scale.heightText == "756")
        let none = model()
        #expect(none.spec == nil && none.widthText == "" && none.heightText == "")
    }

    @Test func noSeparatorGlyphInAnyString() {
        var strings: [String] = []
        for category in [FormatCategory.image, .video] {
            for sources in [[photo], [photo, photo, photo], []] {
                var m = model(category, sources)
                strings += m.chips.map(\.title) + m.chips.map(\.spokenTitle)
                strings += [m.sourceLabel, m.confirmTitle, m.blocker, m.note].compactMap { $0 }
                for text in ["", "20000", "4032", "8000", "100"] {
                    m.typeWidth(text)
                    strings += [m.blocker, m.note].compactMap { $0 }
                }
            }
        }
        strings += [model(remembered: .scale(percent: 900)).blocker].compactMap { $0 }
        let glyphs: [Character] = ["\u{00B7}", "\u{2014}"]
        #expect(!strings.isEmpty)
        #expect(strings.allSatisfy { !$0.contains { glyphs.contains($0) } }, "\(strings)")
    }
}
