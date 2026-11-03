import Foundation
import PomeloEngines
import PomeloTestSupport
import Testing
@testable import PomeloCore
@testable import PomeloUIModel

private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

@Suite struct ResultSummaryTests {
    @Test func singleSuccess() {
        let s = ResultSummary.make(results: [.succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil)])
        #expect(s.title == "Converted a.png")
        #expect(s.detail == nil)
        #expect(!s.isFailure)
    }

    @Test func multipleSuccesses() {
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil),
            .succeeded(source: u("/b.png"), outputs: [u("/b.jpg")], note: .fellBackToDownloads),
        ])
        #expect(s.title == "Converted 2 files")
        #expect(s.detail == nil)
        #expect(!s.isFailure)
    }

    @Test func partialFailureNamesTheFile() {
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil),
            .failed(source: u("/b.png"), error: .sourceMissing),
            .succeeded(source: u("/c.png"), outputs: [u("/c.jpg")], note: nil),
        ])
        #expect(s.title == "2 of 3 converted")
        #expect(s.isFailure)
        #expect(s.detail == "b.png was moved or deleted")
    }

    @Test func partialFailureCountsMoreFailures() {
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil),
            .failed(source: u("/b.png"), error: .sourceMissing),
            .failed(source: u("/c.png"), error: .isDirectory),
        ])
        #expect(s.title == "1 of 3 converted")
        #expect(s.detail == "b.png was moved or deleted (and 1 more)")
    }

    /// One file: the title names it, so the detail is just the reason.
    @Test func allFailedSingleAndMany() {
        let one = ResultSummary.make(results: [.failed(source: u("/b.png"), error: .noRoute(from: FormatID("png"), to: FormatID("mp3")))])
        #expect(one.title == "Couldn't convert b.png")
        #expect(one.isFailure)
        #expect(one.detail == "Can't become MP3")

        let many = ResultSummary.make(results: [
            .failed(source: u("/b.png"), error: .sourceMissing),
            .failed(source: u("/c.png"), error: .sourceMissing),
        ])
        #expect(many.title == "Couldn't convert 2 files")
        #expect(many.detail == "b.png was moved or deleted (and 1 more)")
        #expect(many.isFailure)
    }

    /// Checks 2 and 3: the archive and spreadsheet engines' own sentences (§3.11) reach the hub as written, not
    /// "The file may be damaged".
    @Test func theEnginesSentencesReachTheHub() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A RAR 5 signature and nothing after it: no end-of-archive block.
        let cut = dir.appending(path: "cut.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]).write(to: cut)
        // An encrypted workbook is an OLE file, not a zip.
        let locked = dir.appending(path: "locked.xlsx")
        try (Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 256)).write(to: locked)
        // One column past Excel's 16,384.
        let wide = dir.appending(path: "wide.csv")
        try Data((String(repeating: ",", count: 16_384) + "x").utf8).write(to: wide)
        let cases: [(URL, any ConversionEngine, FormatID, String)] = [
            (cut, ArchiveEngine(), "zip", "Pomelo can't read this RAR"),
            (locked, SpreadsheetEngine(), "csv", "It's password-protected"),
            (wide, SpreadsheetEngine(), "xlsx", "It's too large to convert"),
        ]

        for (file, engine, target, sentence) in cases {
            let staging = dir.appending(path: "staging-\(file.lastPathComponent)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let step = ConversionStep(
                input: file, stagingDirectory: staging, from: try #require(FormatRegistry.builtIn.format(for: file)),
                to: try #require(FormatRegistry.builtIn.format(id: target)), options: PresetOptions())
            let error = await #expect(throws: ConversionError.self) { _ = try await engine.convert(step) { _ in } }
            let summary = ResultSummary.make(results: [.failed(source: file, error: try #require(error))])
            #expect(summary.title == "Couldn't convert \(file.lastPathComponent)")
            #expect(summary.detail == sentence, "\(file.lastPathComponent)")
            #expect(summary.isFailure)
            let two = ResultSummary.make(results: [.failed(source: file, error: try #require(error)),
                                                   .succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil)])
            #expect(two.detail == "\(file.lastPathComponent): \(sentence)")
        }
    }

    /// The hub never shows an engine's ID or a tool's raw output (P23): every error has a short human reason.
    @Test func everyErrorReadsAsAShortHumanReason() {
        let png = FormatID("png")
        let cases: [(ConversionError, String, String)] = [
            (.sourceMissing, "The file was moved or deleted", "bad.png was moved or deleted"),
            (.isDirectory, "It's a folder", "bad.png is a folder"),
            (.notARegularFile, "It's not a regular file", "bad.png isn't a regular file"),
            (.unknownFormat(ext: "xyz"), "Pomelo doesn't know this format", "bad.png has an unknown format"),
            (.noRoute(from: png, to: FormatID("jpg")), "Can't become JPEG", "bad.png can't become JPEG"),
            (.engineFailed(engine: "imageio", message: "cannot open bad.png as an image"),
             "The file may be damaged", "bad.png may be damaged"),
            (.engineFailed(engine: "ffmpeg", message: "exited with code 1: [png @ 0x7f] Invalid PNG signature"),
             "The file may be damaged", "bad.png may be damaged"),
            (.converterTimedOut(engine: "ffmpeg"),
             "The converter stopped responding", "bad.png: the converter stopped responding"),
            (.converterUnavailable(engine: "cwebp", message: "executable not found"),
             "The converter isn't available", "bad.png: the converter isn't available"),
            (.converterFault(engine: "x", message: "produced no output"),
             "The converter failed", "bad.png: the converter failed"),
            (.notApplicable(reason: "No code found"), "No code found", "bad.png: No code found"),
            (.publishFailed(message: "The disk is full."), "Couldn't save the result", "bad.png: couldn't save the result"),
        ]
        for (error, alone, named) in cases {
            let one = ResultSummary.make(results: [.failed(source: u("/x/bad.png"), error: error)])
            #expect(one.detail == alone)
            let two = ResultSummary.make(results: [
                .succeeded(source: u("/x/a.png"), outputs: [], note: nil), .failed(source: u("/x/bad.png"), error: error),
            ])
            #expect(two.detail == named)
            #expect((two.detail?.count ?? 0) <= ResultSummary.maxDetailLength)
        }
    }

    /// M5: the reason comes from the error's case, never from matching its message.
    @Test func typedErrorsHaveTheirOwnReasons() {
        #expect(ResultSummary.reason(for: .converterUnavailable(engine: "ffmpeg", message: "executable not found"))
                == "The converter isn't available")
        #expect(ResultSummary.reason(for: .converterTimedOut(engine: "ffmpeg")) == "The converter stopped responding")
        #expect(ResultSummary.reason(for: .converterFault(engine: "x", message: "produced no output"))
                == "The converter failed")
        #expect(ResultSummary.reason(for: .notApplicable(reason: "No code found")) == "No code found")
        // A tool's message that used to be matched as text is now just a failure of the file.
        #expect(ResultSummary.reason(for: .engineFailed(engine: "ffmpeg", message: "timed out"))
                == "The file may be damaged")
    }

    @Test func anUnsupportedEnginesReasonIsShownAsWritten() {
        let error = ConversionError.engineUnsupported(engine: "intelligence", reason: "Apple Intelligence isn't turned on.")
        #expect(ResultSummary.reason(for: error) == "Apple Intelligence isn't turned on.")
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/x/b.pdf"), outputs: [], note: nil),
            .failed(source: u("/x/a.pdf"), error: .engineUnsupported(engine: "speech", reason: "Needs macOS 26.")),
        ])
        #expect(s.detail == "a.pdf: Needs macOS 26.")
    }

    @Test func aNamedNotApplicableReasonIsShownAsWritten() {
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/x/b.png"), outputs: [], note: nil),
            .failed(source: u("/x/a.png"), error: .notApplicable(reason: "No code found")),
        ])
        #expect(s.detail == "a.png: No code found")
    }

    /// A tool isn't a conversion: its titles name the tool (an editor's without its "…"), and a lone file's title
    /// leaves the name to the hub's thumbnail so it fits.
    @Test func aToolsSummaryNamesTheTool() {
        let one = ResultSummary.make(results: [.failed(source: u("/landscape.jpg"), error: .notApplicable(reason: "No text found"))],
                                     tool: "Extract data")
        #expect(one.title == "Couldn't run Extract data")
        #expect(one.detail == "No text found")
        #expect(one.isFailure)

        let many = ResultSummary.make(results: [
            .failed(source: u("/b.png"), error: .sourceMissing),
            .failed(source: u("/c.png"), error: .sourceMissing),
        ], tool: "Crop\u{2026}")
        #expect(many.title == "Couldn't run Crop on 2 files")

        let some = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [], note: nil),
            .failed(source: u("/b.png"), error: .sourceMissing),
        ], tool: "Compress")
        #expect(some.title == "1 of 2 finished")

        let done = ResultSummary.make(results: [.succeeded(source: u("/a.png"), outputs: [], note: nil)],
                                      tool: "Compress")
        #expect(done.title == "Finished a.png")
        let doneMany = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [], note: nil),
            .succeeded(source: u("/b.png"), outputs: [], note: nil),
        ], tool: "Compress")
        #expect(doneMany.title == "Finished 2 files")
    }

    @Test func aLongFileNameIsShortenedInTheMiddleToFitTheHub() throws {
        let name = "a-really-quite-long-holiday-photo-name-from-2025.png"
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [], note: nil),
            .failed(source: u("/\(name)"), error: .engineFailed(engine: "imageio", message: "x")),
            .failed(source: u("/c.png"), error: .sourceMissing),
        ])
        let detail = try #require(s.detail)
        #expect(detail.count == ResultSummary.maxDetailLength)
        #expect(detail.hasPrefix("a-really"))
        #expect(detail.hasSuffix(".png may be damaged (and 1 more)"))
        #expect(detail.contains("\u{2026}"))

        let one = ResultSummary.make(results: [.failed(source: u("/\(name)"), error: .sourceMissing)])
        #expect(one.title == "Couldn't convert " + ResultSummary.shortened(name, to: ResultSummary.maxTitleNameLength))
        #expect(ResultSummary.shortened(name, to: 24).count == 24)
        #expect(ResultSummary.shortened("short.png", to: 24) == "short.png")
    }

    @Test func allCancelled() {
        let s = ResultSummary.make(results: [.cancelled(source: u("/a.png")), .cancelled(source: u("/b.png"))])
        #expect(s.title == "Cancelled")
        #expect(s.detail == nil)
        #expect(!s.isFailure)
    }

    @Test func successPlusCancelledCountsAgainstTheTotal() {
        let s = ResultSummary.make(results: [
            .succeeded(source: u("/a.png"), outputs: [u("/a.jpg")], note: nil),
            .cancelled(source: u("/b.png")),
        ])
        #expect(s.title == "1 of 2 converted")
        #expect(!s.isFailure)
    }

    @Test func emptyResults() {
        let s = ResultSummary.make(results: [])
        #expect(s.title == "Nothing to convert")
        #expect(!s.isFailure)
    }
}

@Suite struct CombinedSummaryTests {
    @Test func combinedSummaryNamesTheFailure() {
        let s = ResultSummary.makeCombined(results: [
            .cancelled(source: u("/a.pdf")),
            .failed(source: u("/b.pdf"), error: .engineFailed(engine: "pdfkit", message: "b.pdf is locked")),
            .cancelled(source: u("/c.pdf")),
        ])
        #expect(s == ResultSummary(title: "Couldn't combine 3 files", detail: "b.pdf may be damaged", isFailure: true))
    }

    @Test func combinedSummaryShortensALongName() {
        let s = ResultSummary.makeCombined(results: [
            .failed(
                source: u("/an-extraordinarily-long-scanned-contract-name.pdf"),
                error: .engineFailed(engine: "x", message: "")
            ),
            .cancelled(source: u("/b.pdf")),
        ])
        #expect(s.title == "Couldn't combine 2 files")
        #expect(s.detail == "an-extraordinarily-lon\u{2026}ame.pdf may be damaged")
    }

    @Test func combinedSuccessCountsTheInputs() {
        let output = u("/a-merged.pdf")
        let s = ResultSummary.makeCombined(results: [
            .succeeded(source: u("/a.pdf"), outputs: [output], note: nil),
            .succeeded(source: u("/b.pdf"), outputs: [output], note: nil),
        ])
        #expect(s == ResultSummary(title: "Combined 2 files", detail: nil, isFailure: false))
    }

    @Test func combinedCancelReadsCancelled() {
        let s = ResultSummary.makeCombined(results: [.cancelled(source: u("/a.pdf")), .cancelled(source: u("/b.pdf"))])
        #expect(s == ResultSummary(title: "Cancelled", detail: nil, isFailure: false))
    }

    /// The runner fails a whole-set "doesn't apply" on the first input; the reason concerns the set, not that file.
    private func notApplicable(_ reason: String, _ names: [String]) -> [FileResult] {
        names.enumerated().map { index, name in
            index == 0 ? .failed(source: u("/\(name)"), error: .notApplicable(reason: reason)) : .cancelled(source: u("/\(name)"))
        }
    }

    private let images = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]

    /// Final review: Find duplicates combines nothing, and "No duplicates found" is about all five images.
    @Test func aToolsCombineSaysItCouldNotRunAndGivesTheReasonBare() {
        let s = ResultSummary.makeCombined(results: notApplicable("No duplicates found", images), tool: "Find duplicates")
        #expect(s == ResultSummary(title: "Couldn't run Find duplicates", detail: "No duplicates found", isFailure: true))
        for reason in ["Choose two or more images", "That's too many images to compare (500 at most)"] {
            let few = ResultSummary.makeCombined(results: notApplicable(reason, ["a.jpg"]), tool: "Find duplicates")
            #expect(few.detail == reason)
        }
    }

    @Test func aToolsCombineStillNamesADamagedFile() {
        let s = ResultSummary.makeCombined(results: [
            .cancelled(source: u("/a.jpg")),
            .failed(source: u("/b.jpg"), error: .engineFailed(engine: "vision", message: "cannot read b.jpg")),
        ], tool: "Find duplicates")
        #expect(s == ResultSummary(title: "Couldn't run Find duplicates", detail: "b.jpg may be damaged", isFailure: true))
    }

    @Test func aToolsCombineFinishes() {
        let output = u("/a-duplicates.txt")
        let s = ResultSummary.makeCombined(
            results: images.map { .succeeded(source: u("/\($0)"), outputs: [output], note: nil) }, tool: "Find duplicates"
        )
        #expect(s == ResultSummary(title: "Finished 5 files", detail: nil, isFailure: false))
    }

    /// Combine into PDF and Merge PDFs keep their words; a reason that doesn't apply is the set's there too.
    @Test func theJobsSummaryKeepsThePDFCombinesWords() throws {
        let merge = try #require(Preset.builtIns.first { $0.id == "merge-pdfs" })
        let toPDF = try #require(Preset.builtIns.first { $0.id == "images-to-pdf" })
        let duplicates = try #require(Preset.builtIns.first { $0.id == "find-duplicates" })
        let damaged: [FileResult] = [
            .failed(source: u("/a.pdf"), error: .engineFailed(engine: "pdfkit", message: "")), .cancelled(source: u("/b.pdf")),
        ]
        func summary(_ preset: Preset, _ results: [FileResult]) -> ResultSummary {
            ResultSummary.make(results: results, of: ConversionRequest.from(preset, inputs: results.map(\.source)),
                               tool: preset.name)
        }
        for preset in [merge, toPDF] {
            #expect(summary(preset, damaged) == ResultSummary(
                title: "Couldn't combine 2 files", detail: "a.pdf may be damaged", isFailure: true
            ), "\(preset.id)")
            let done: [FileResult] = [u("/a.pdf"), u("/b.pdf")].map {
                .succeeded(source: $0, outputs: [u("/a-merged.pdf")], note: nil)
            }
            #expect(summary(preset, done).title == "Combined 2 files", "\(preset.id)")
            #expect(summary(preset, notApplicable("Nothing to combine", ["a.pdf", "b.pdf"])).detail == "Nothing to combine")
        }
        #expect(summary(duplicates, notApplicable("No duplicates found", images)).title == "Couldn't run Find duplicates")
        let one: [FileResult] = [.failed(source: u("/a.png"), error: .engineFailed(engine: "imageio", message: ""))]
        let compress = try #require(Preset.builtIns.first { $0.id == "compress" })
        #expect(summary(compress, one) == ResultSummary.make(results: one, tool: compress.name))
    }
}
