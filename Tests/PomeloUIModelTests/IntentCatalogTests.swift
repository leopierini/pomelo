import Foundation
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

@Suite struct IntentCatalogTests {
    private static let editors = ["trim", "split-video", "crop", "compress-to-size", "redact", "organize-pages"]

    @Test func targetFormatsAreWhatSomeFormatCanBecome() {
        let planner = RoutePlanner(
            edges: [
                ConversionEdge(from: "png", to: "jpg", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "jpg", to: "pdf", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "png", to: "png", engineID: "fake", cost: 1, flags: [], operation: "compress"),
                ConversionEdge(from: "mp4", to: "m4a", engineID: "fake", cost: 1, flags: [], operation: "extract"),
            ],
            enginePriority: ["fake"]
        )
        let targets = IntentCatalog.targetFormats(formats: .builtIn, planner: planner)
        // Image before PDF (FormatCategory order); an operation edge's target is not a conversion target.
        #expect(targets.map(\.id) == ["jpg", "pdf"])
    }

    @Test func targetFormatsAreOrderedByCategoryThenName() {
        let planner = RoutePlanner(
            edges: [
                ConversionEdge(from: "mp4", to: "mp3", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "png", to: "tiff", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "png", to: "heic", engineID: "fake", cost: 1, flags: []),
                ConversionEdge(from: "mp3", to: "aiff", engineID: "fake", cost: 1, flags: []),
            ],
            enginePriority: ["fake"]
        )
        let targets = IntentCatalog.targetFormats(formats: .builtIn, planner: planner)
        #expect(targets.map(\.id) == ["heic", "tiff", "aiff", "mp3"])
    }

    @Test func toolsLeaveOutTheEditors() {
        let ids = IntentCatalog.tools(settings: AppSettings()).map(\.id)
        for editor in Self.editors { #expect(!ids.contains(editor), "\(editor)") }
        #expect(ids.contains("compress"))
        #expect(ids.contains("remove-background"))
        #expect(ids.contains("smart-crop"))
        #expect(ids.contains("straighten"))
        #expect(ids.contains("find-duplicates"))
    }

    /// P119: an unattended job has no clipboard moment, so Read codes is not a Shortcuts tool.
    @Test func toolsLeaveOutClipboardTools() {
        let ids = IntentCatalog.tools(settings: AppSettings()).map(\.id)
        #expect(!ids.contains("read-codes"))
        #expect(IntentCatalog.tools(settings: AppSettings()).allSatisfy { $0.delivery == .file })
    }

    @Test func toolsKeepTheCatalogOrder() {
        let catalog = ToolCatalog.presets(settings: AppSettings()).map(\.id)
        let tools = IntentCatalog.tools(settings: AppSettings()).map(\.id)
        #expect(tools == catalog.filter { tools.contains($0) })
        #expect(tools.first == "compress")
    }

    @Test func toolsUseTheUsersOptions() throws {
        var settings = AppSettings()
        settings.toolOptions["compress"] = PresetOptions(quality: 0.4)
        let compress = try #require(IntentCatalog.tools(settings: settings).first { $0.id == "compress" })
        #expect(compress.options.quality == 0.4)
    }

    @Test func combinesCanBeLeftOut() {
        let all = IntentCatalog.tools(settings: AppSettings()).map(\.id)
        #expect(all.contains("merge-pdfs"))
        #expect(all.contains("images-to-pdf"))
        #expect(all.contains("find-duplicates"))
        let some = IntentCatalog.tools(settings: AppSettings(), includingCombines: false).map(\.id)
        #expect(!some.contains("merge-pdfs"))
        #expect(!some.contains("images-to-pdf"))
        #expect(!some.contains("find-duplicates"))
        #expect(some.contains("compress"))
    }

    @Test func failureMessageIsTwoSentences() {
        let one = ResultSummary(title: "Couldn't convert a.png", detail: "Can't become MP3", isFailure: true)
        #expect(IntentCatalog.failureMessage(one) == "Couldn't convert a.png. Can't become MP3.")
        let some = ResultSummary(title: "2 of 3 converted", detail: "bad.png may be damaged", isFailure: true)
        #expect(IntentCatalog.failureMessage(some) == "2 of 3 converted. bad.png may be damaged.")
        let bare = ResultSummary(title: "Cancelled", isFailure: true)
        #expect(IntentCatalog.failureMessage(bare) == "Cancelled.")
        for message in [one, some, bare].map(IntentCatalog.failureMessage) {
            #expect(!message.contains("\u{00B7}") && !message.contains("\u{2014}"), "\(message)")
        }
    }

    @Test func failureMessageNeverDoublesTheFullStop() {
        let cut = ResultSummary(title: "Couldn't convert 2 files", detail: "a-very-long\u{2026}", isFailure: true)
        #expect(IntentCatalog.failureMessage(cut) == "Couldn't convert 2 files. a-very-long\u{2026}")
    }

    @Test func failureMessageOfARealSummary() {
        let source = URL(fileURLWithPath: "/tmp/a.png")
        let summary = ResultSummary.make(results: [.failed(source: source, error: .noRoute(from: "png", to: "mp3"))])
        #expect(IntentCatalog.failureMessage(summary) == "Couldn't convert a.png. Can't become MP3.")
    }
}
