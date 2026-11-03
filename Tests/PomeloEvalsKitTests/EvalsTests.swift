import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport
@testable import PomeloEvalsKit

private func results(
    metrics: [String: Double] = [:], checks: [EvalResults.Check] = [], skipped: [String] = []
) -> EvalResults {
    EvalResults(metrics: metrics, checks: checks, skipped: skipped)
}

@Suite struct EvalsTests {
    @Test func lowerIsBetterRegressesOnlyPastToleranceAndSlack() {
        let m = Metric(value: 10, unit: "ms", better: .lower, tolerance: 0.25, slack: 3)
        #expect(!m.regressed(by: 15.4))
        #expect(m.regressed(by: 15.6))
    }

    @Test func higherIsBetterRegressesWhenItDrops() {
        let m = Metric(value: 300, unit: "tests", better: .higher, tolerance: 0, slack: 0)
        #expect(m.regressed(by: 299))
        #expect(!m.regressed(by: 301))
    }

    @Test func aFailedOutputCheckAlwaysFails() {
        let report = Compare.run(
            results: results(checks: [.init(name: "edge.png-jpg.ok", ok: false, detail: "width is 10, expected 20")]),
            baseline: Baseline()
        )
        #expect(report.exitCode == 1)
        #expect(report.lines == ["FAILED edge.png-jpg.ok: width is 10, expected 20"])
    }

    @Test func aSkippedCaseIsNotARegression() {
        let baseline = Baseline(metrics: [
            "edge.mov-mkv.seconds": MetricDefaults.metric(named: "edge.mov-mkv.seconds", value: 1)
        ])
        let report = Compare.run(results: results(skipped: ["edge.mov-mkv (needs ffmpeg)"]), baseline: baseline)
        #expect(report.exitCode == 0)
        #expect(report.lines == ["skipped edge.mov-mkv (needs ffmpeg)"])
    }

    @Test func aMetricMissingFromTheBaselineIsReportedNotFailed() {
        let report = Compare.run(results: results(metrics: ["edge.new.seconds": 2]), baseline: Baseline())
        #expect(report.exitCode == 0)
        #expect(report.lines == ["new edge.new.seconds = 2"])
    }

    @Test func idleWakeupsKeepSlackTwentyOnBaselineUpdates() {
        let metric = MetricDefaults.metric(named: "app.idle.wakeups_per_s", value: 2)
        #expect(metric.slack == 20)
        #expect(metric.tolerance == 0.5)
    }

    @Test func watchMetricsHaveTheirOwnDefaults() {
        let wakeups = MetricDefaults.metric(named: "app.watch.idle.wakeups_per_s", value: 2)
        #expect(wakeups.unit == "/s" && wakeups.slack == 20 && wakeups.tolerance == 0.5)
        let latency = MetricDefaults.metric(named: "app.watch.latency.p95_ms", value: 1100)
        #expect(latency.unit == "ms" && latency.better == .lower)
        #expect(!latency.regressed(by: 1400))
        #expect(latency.regressed(by: 2100))
    }

    @Test func aRegressionIsPrintedOnItsOwnLine() {
        let baseline = Baseline(metrics: [
            "app.idle.footprint_mb": MetricDefaults.metric(named: "app.idle.footprint_mb", value: 40),
            "app.binary_kb": MetricDefaults.metric(named: "app.binary_kb", value: 1000),
        ])
        let report = Compare.run(
            results: results(metrics: ["app.idle.footprint_mb": 80, "app.binary_kb": 1001]), baseline: baseline)
        #expect(report.exitCode == 1)
        #expect(report.lines.count == 1)
        #expect(report.lines[0].hasPrefix("REGRESSION app.idle.footprint_mb: 40 MB -> 80 MB"))
    }

    @Test func anyMetricOverItsBudgetFails() {
        let baseline = Baseline(metrics: ["app.launch.p95_ms": Metric(value: 200, unit: "ms", better: .lower,
                                                                       tolerance: 10, slack: 1000, budget: 500)])
        let report = Compare.run(results: results(metrics: ["app.launch.p95_ms": 600]), baseline: baseline)
        #expect(report.exitCode == 1)
        #expect(report.lines.contains { $0.hasPrefix("OVER BUDGET app.launch.p95_ms") })
        #expect(Compare.run(results: results(metrics: ["app.launch.p95_ms": 500]), baseline: baseline).exitCode == 0)
    }

    @Test func aHigherIsBetterBudgetIsAFloor() {
        let baseline = Baseline(metrics: ["edge.x.psnr_db": Metric(value: 45, unit: "dB", better: .higher,
                                                                    tolerance: 1, slack: 100, budget: 40)])
        let under = Compare.run(results: results(metrics: ["edge.x.psnr_db": 38]), baseline: baseline)
        #expect(under.exitCode == 1)
        #expect(under.lines.contains { $0.hasPrefix("OVER BUDGET edge.x.psnr_db") })
        #expect(Compare.run(results: results(metrics: ["edge.x.psnr_db": 41]), baseline: baseline).exitCode == 0)
    }

    @Test func overBudgetIsFalseWithoutABudget() {
        let metric = Metric(value: 1, unit: "ms", better: .lower, tolerance: 0, slack: 0)
        #expect(metric.budget == nil)
        #expect(!metric.overBudget(1_000_000))
    }

    @Test func aBaselineWithoutBudgetsStillDecodes() throws {
        let old = Data(#"{"metrics":{"a":{"value":1,"unit":"ms","better":"lower","tolerance":0.1,"slack":0}}}"#.utf8)
        #expect(try JSONDecoder().decode(Baseline.self, from: old).metrics["a"]?.budget == nil)
    }

    @Test func theWheelBudgetLivesInTheBaseline() {
        let baseline = Baseline(metrics: [
            "wheel.open.p95_ms": Metric(value: 30, unit: "ms", better: .lower, tolerance: 0.25, slack: 3, budget: 33.3)
        ])
        let over = Compare.run(results: results(metrics: ["wheel.open.p95_ms": 34]), baseline: baseline)
        #expect(over.exitCode == 1)
        #expect(over.lines.first?.hasPrefix("OVER BUDGET wheel.open.p95_ms") == true)
        #expect(over.lines.first?.contains("poll tick") == true)
        #expect(Compare.run(results: results(metrics: ["wheel.open.p95_ms": 30]), baseline: baseline).exitCode == 0)
        // No budget in the baseline, no budget check: the number is no longer hardcoded.
        let bare = Baseline(metrics: ["wheel.open.p95_ms": MetricDefaults.metric(named: "wheel.open.p95_ms", value: 40)])
        #expect(Compare.run(results: results(metrics: ["wheel.open.p95_ms": 45]), baseline: bare).exitCode == 0)
    }

    @Test func theCustomizedWheelHasTheWheelsBudgetRule() {
        let baseline = Baseline(metrics: [
            "wheel.open_custom.p95_ms": Metric(value: 1, unit: "ms", better: .lower, tolerance: 0.25, slack: 3, budget: 33.3)
        ])
        let over = Compare.run(results: results(metrics: ["wheel.open_custom.p95_ms": 34]), baseline: baseline)
        #expect(over.exitCode == 1)
        #expect(over.lines.first?.hasPrefix("OVER BUDGET wheel.open_custom.p95_ms") == true)
        #expect(Compare.run(results: results(metrics: ["wheel.open_custom.p95_ms": 2]), baseline: baseline).exitCode == 0)
        #expect(Compare.run(results: results(metrics: ["wheel.open_custom.p95_ms": 5]), baseline: baseline).exitCode == 1)
    }

    @Test func editorOpenBudgetComesFromTheBaseline() {
        let key = "editor.open.targetSize.p95_ms"
        var metric = MetricDefaults.metric(named: key, value: 40)
        metric.budget = 100
        let baseline = Baseline(metrics: [key: metric])
        let over = Compare.run(results: results(metrics: [key: 101]), baseline: baseline)
        #expect(over.exitCode == 1)
        #expect(over.lines.contains { $0.hasPrefix("OVER BUDGET \(key)") })
        // A move within the budget is still the baseline's call: 40 + slack 3 or 25% over.
        #expect(Compare.run(results: results(metrics: [key: 45]), baseline: baseline).exitCode == 0)
        #expect(Compare.run(results: results(metrics: [key: 99]), baseline: Baseline()).exitCode == 0)
    }

    @Test func updatingKeepsTheBudget() {
        var bundle = MetricDefaults.metric(named: "app.bundle_kb", value: 8000)
        bundle.budget = 12000
        let baseline = Baseline(metrics: ["app.bundle_kb": bundle])
        let updated = Compare.updated(baseline, with: results(metrics: ["app.bundle_kb": 9000]))
        #expect(updated.metrics["app.bundle_kb"]?.value == 9000)
        #expect(updated.metrics["app.bundle_kb"]?.budget == 12000)
    }

    @Test func updatingKeepsTheShelfsOpenSlack() {
        var open = Metric(value: 2.35, unit: "ms", better: .lower, tolerance: 0.25, slack: 3, budget: 33.3)
        let updated = Compare.updated(Baseline(metrics: ["shelf.open.p95_ms": open]),
                                      with: results(metrics: ["shelf.open.p95_ms": 2.5, "shelf.open.p50_ms": 2]))
        open.value = 2.5
        #expect(updated.metrics["shelf.open.p95_ms"] == open)
        #expect(updated.metrics["shelf.open.p50_ms"]?.slack == 3)
    }

    @Test func updatingTheBaselineKeepsMetricsTheRunDidNotMeasure() {
        let old = Baseline(metrics: [
            "tests.package.count": MetricDefaults.metric(named: "tests.package.count", value: 300),
            "app.binary_kb": MetricDefaults.metric(named: "app.binary_kb", value: 1000),
        ])
        let updated = Compare.updated(old, with: results(metrics: ["app.binary_kb": 900, "edge.x.psnr_db": 40]))
        #expect(updated.metrics["tests.package.count"]?.value == 300)
        #expect(updated.metrics["app.binary_kb"]?.value == 900)
        #expect(updated.metrics["edge.x.psnr_db"] == Metric(value: 40, unit: "dB", better: .higher, tolerance: 0.03, slack: 0))
    }

    @Test func timeOutputIsParsed() {
        let sample = """
                    1.23 real         0.80 user         0.20 sys
                52428800  maximum resident set size
                       0  average shared memory size
            """
        #expect(TimeReport.parse(sample) == TimeReport(seconds: 1.23, peakRSSMB: 50))
        #expect(TimeReport.parse("nothing here") == nil)
    }

    @Test func percentilesInterpolate() {
        #expect(Percentile.of(0.5, in: [4, 1, 3, 2]) == 2.5)
        #expect(Percentile.of(0.95, in: Array(stride(from: 1.0, through: 100, by: 1))) == 95.05)
        #expect(Percentile.of(0.5, in: []) == 0)
    }

    @Test func launchSamplesGiveP50AndP95() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = [212.5, 180, 640, 195, 201]
        var paths: [String] = []
        for (index, ms) in samples.enumerated() {
            let file = dir.appending(path: "launch-\(index).json")
            try Data(#"{"launchMs": \#(ms)}"#.utf8).write(to: file)
            paths.append(file.path)
        }
        let list = dir.appending(path: "launch-samples.txt")
        try Data((paths.joined(separator: "\n") + "\n").utf8).write(to: list)

        let metrics = try LaunchMeasurement.metrics(samplesList: list)
        #expect(metrics == [
            "app.launch.p50_ms": Percentile.of(0.5, in: samples), "app.launch.p95_ms": Percentile.of(0.95, in: samples),
        ])
        #expect(metrics["app.launch.p50_ms"] == 201)
    }

    @Test func aLaunchListWithoutSamplesThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = dir.appending(path: "launch-samples.txt")
        try Data("\n".utf8).write(to: list)
        #expect(throws: (any Error).self) { try LaunchMeasurement.metrics(samplesList: list) }
    }

    @Test func launchMetricsAllowHalfPlusAHundredMilliseconds() {
        for name in ["app.launch.p50_ms", "app.launch.p95_ms"] {
            let metric = MetricDefaults.metric(named: name, value: 200)
            #expect(metric.unit == "ms" && metric.better == .lower)
            #expect(metric.tolerance == 0.5 && metric.slack == 100)
            #expect(!metric.regressed(by: 400))
            #expect(metric.regressed(by: 401))
        }
    }

    @Test func outputChecksReadImagesMoviesAndPDFs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, in: dir))
        #expect(png.opens && png.width == 64 && png.height == 48 && png.frames == 1)

        let movie = await OutputCheck.inspect(try await Fixtures.movie(seconds: 1, withAudio: true, in: dir))
        #expect(movie.opens)
        #expect(abs((movie.durationSeconds ?? 0) - 1) < 0.15)
        #expect(movie.width == 320 && movie.height == 240 && movie.audioChannels == 1)

        let silent = await OutputCheck.inspect(try await Fixtures.movie(seconds: 1, withAudio: false, in: dir))
        #expect(silent.audioChannels == 0)

        // A video's size is the one players show: a portrait iPhone clip stored landscape reads portrait.
        let portrait = await OutputCheck.inspect(
            try await Fixtures.quadrantMovie(width: 320, height: 180, seconds: 1, rotated90: true, in: dir))
        #expect(portrait.width == 180 && portrait.height == 320)

        let pdf = await OutputCheck.inspect(try Fixtures.pdf(pages: 3, in: dir))
        #expect(pdf.opens && pdf.pages == 3)

        let gif = await OutputCheck.inspect(
            try Fixtures.animatedGIF(width: 8, height: 8, delays: [0.1, 0.1, 0.1], loopCount: 0, in: dir))
        #expect(gif.frames == 3)

        let folder = dir.appending(path: "items", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.png", "b.png", ".hidden"] { try Data("x".utf8).write(to: folder.appending(path: name)) }
        let items = await OutputCheck.inspect(folder)
        #expect(items.opens && items.folderItems == 2)

        let missing = await OutputCheck.inspect(dir.appending(path: "absent.png"))
        #expect(!missing.opens)
    }

    @Test func expectationsNameWhatDiffers() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, in: dir))

        #expect(OutputCheck.failures(png, expect: .init(width: 64, height: 48)).isEmpty)
        #expect(OutputCheck.failures(png, expect: .init(width: 65)) == ["width is 64, expected 65"])
        #expect(OutputCheck.failures(png, expect: .init(durationSeconds: 1)) == ["duration is missing s, expected 1.0 s"])
        #expect(OutputCheck.failures(png, expect: .init(psnrMinDB: 32)) == ["PSNR is missing dB, expected at least 32.0 dB"])
        #expect(OutputCheck.failures(png, expect: .init(opens: false)) == ["opens is true, expected false"])
    }

    /// R1: the ratio is the long side over the short side, so a portrait and a landscape output check alike.
    @Test func aspectRatioAndMaximumSidesAreChecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let landscape = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, in: dir))
        let portrait = await OutputCheck.inspect(try Fixtures.png(width: 48, height: 64, in: dir))
        let fourThree = EvalCase.Expect(aspectRatio: .init(value: 4.0 / 3, tolerance: 0.01))

        #expect(OutputCheck.failures(landscape, expect: fourThree).isEmpty)
        #expect(OutputCheck.failures(portrait, expect: fourThree).isEmpty)
        #expect(OutputCheck.failures(landscape, expect: .init(aspectRatio: .init(value: 1, tolerance: 0.01)))
                == ["aspect ratio is 1.333, expected 1.000 within 0.010"])
        #expect(OutputCheck.failures(landscape, expect: .init(maxWidth: 64, maxHeight: 48)).isEmpty)
        #expect(OutputCheck.failures(landscape, expect: .init(maxWidth: 63, maxHeight: 47))
                == ["width is 64, expected at most 63", "height is 48, expected at most 47"])
        let text = await OutputCheck.inspect(try Fixtures.textFile("x", ext: "txt", in: dir))
        #expect(OutputCheck.failures(text, expect: .init(aspectRatio: .init(value: 1, tolerance: 0.01), maxWidth: 1))
                == ["aspect ratio is missing, expected 1.000 within 0.010", "width is missing, expected at most 1"])
    }

    /// P268: the words Vision reads in an output image, read only when a case asks for them.
    @Test func imageTextIsReadOnlyWhenAskedAndChecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.textImage("Hello Pomelo", in: dir)
        var inspection = await OutputCheck.inspect(url)
        #expect(inspection.imageText == nil)

        inspection.imageText = OutputCheck.imageText(url)
        #expect(inspection.imageText?.contains("Hello Pomelo") == true)
        #expect(OutputCheck.failures(inspection, expect: .init(imageTextContains: "hello pomelo")).isEmpty)
        #expect(OutputCheck.failures(inspection, expect: .init(imageTextContains: "Goodbye"))
                == ["image text lacks \"Goodbye\""])
        let text = await OutputCheck.inspect(try Fixtures.textFile("Goodbye", ext: "txt", in: dir))
        #expect(OutputCheck.imageText(try Fixtures.textFile("Goodbye", ext: "txt", in: dir)) == nil)
        #expect(OutputCheck.failures(text, expect: .init(imageTextContains: "Goodbye"))
                == ["image text lacks \"Goodbye\""])
    }

    @Test func textStartsWithXlsxSheetsAndJSONFieldsAreChecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = await OutputCheck.inspect(try Fixtures.textFile("# Title\n\nBody", ext: "md", in: dir))
        #expect(OutputCheck.failures(summary, expect: .init(textStartsWith: "# ")).isEmpty)
        #expect(OutputCheck.failures(summary, expect: .init(textStartsWith: "## ")) == ["text does not start with \"## \""])

        let workbook = dir.appending(path: "t.xlsx")
        try await XLSXWriter.write(sheets: [[["a"]], [["b"]]], to: workbook)
        let sheets = await OutputCheck.inspect(workbook)
        #expect(sheets.opens && sheets.sheets == 2)
        #expect(OutputCheck.failures(sheets, expect: .init(xlsxSheets: 2)).isEmpty)
        #expect(OutputCheck.failures(sheets, expect: .init(xlsxSheets: 3)) == ["xlsxSheets is 2, expected 3"])
        let notAWorkbook = dir.appending(path: "bad.xlsx")
        try Data("not a zip".utf8).write(to: notAWorkbook)
        #expect(await !OutputCheck.inspect(notAWorkbook).opens)

        let json = await OutputCheck.inspect(try Fixtures.textFile(#"{"kind":"receipt","total":5.3}"#, ext: "json", in: dir))
        #expect(json.opens)
        let fields: [String: JSONValue] = ["total": .number(5.3), "kind": .string("receipt")]
        #expect(OutputCheck.failures(json, expect: .init(jsonFields: fields)).isEmpty)
        #expect(OutputCheck.failures(json, expect: .init(jsonFields: ["total": .number(5.4)])) == ["json total is 5.3, expected 5.4"])
        #expect(OutputCheck.failures(json, expect: .init(jsonFields: ["tax": .number(1)])) == ["json tax is missing, expected 1"])
        let broken = await OutputCheck.inspect(try Fixtures.textFile("{not json", ext: "json", in: dir))
        #expect(!broken.opens)
    }

    @Test func transparencyIsReadFromThePixels() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let opaque = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, in: dir))
        let clear = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, alpha: true, in: dir))

        #expect(OutputCheck.failures(clear, expect: .init(hasTransparency: true)).isEmpty)
        #expect(OutputCheck.failures(opaque, expect: .init(hasTransparency: true)) == ["hasTransparency is false, expected true"])
        #expect(OutputCheck.failures(opaque, expect: .init(hasTransparency: false)).isEmpty)
    }

    @Test func psnrOfAnImageWithItselfIsInfiniteAndOfANoisyCopyIsFinite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Fixtures.photo(width: 200, height: 150, type: "public.png", ext: "png", in: dir)
        #expect(OutputCheck.psnr(original, original) == .infinity)

        let lossy = try Fixtures.photo(width: 200, height: 150, type: "public.jpeg", ext: "jpg", in: dir)
        let psnr = try #require(OutputCheck.psnr(original, lossy))
        #expect(psnr.isFinite && psnr > 20 && psnr < 100)

        let other = try Fixtures.png(width: 200, height: 150, in: dir)
        let unrelated = try #require(OutputCheck.psnr(original, other))
        #expect(unrelated < psnr)
    }

    @Test func theCorpusIsWrittenOnceAndSkipsFilesAlreadyThere() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await Corpus.write(to: dir)
        #expect(first == Corpus.fileNames)
        for name in Corpus.fileNames { #expect(FileManager.default.fileExists(atPath: dir.appending(path: name).path)) }
        #expect(try await Corpus.write(to: dir).isEmpty)
    }

    /// A corpus written by older recipes is regenerated whole, so no edge checks stale content (the rename to Pomelo
    /// changed the text of eight files that an old corpus still held). Three cheap recipes: the whole corpus three
    /// times was this suite's slowest test (16.9 s); the test above writes every recipe once.
    @Test func aCorpusOfAnotherVersionIsWrittenAgain() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recipes = Corpus.recipes.filter { ["doc.rtf", "subs.srt", "logo.svg"].contains($0.name) }
        let names = recipes.map(\.name)
        try #require(names.count == 3)
        #expect(try await Corpus.write(to: dir, recipes: recipes) == names)
        let versionFile = dir.appending(path: ".version")
        #expect(try String(contentsOf: versionFile, encoding: .utf8) == "\(Corpus.version)\n")

        let rtf = dir.appending(path: "doc.rtf")
        try Data("stale".utf8).write(to: rtf)
        try Data("1\n".utf8).write(to: versionFile)
        #expect(try await Corpus.write(to: dir, recipes: recipes) == names)
        #expect(try Data(contentsOf: rtf) != Data("stale".utf8))
        #expect(try String(contentsOf: versionFile, encoding: .utf8) == "\(Corpus.version)\n")

        try FileManager.default.removeItem(at: versionFile)
        try Data("stale".utf8).write(to: rtf)
        #expect(try await Corpus.write(to: dir, recipes: recipes) == names)
        #expect(try Data(contentsOf: rtf) != Data("stale".utf8))
        #expect(try await Corpus.write(to: dir, recipes: recipes).isEmpty)
    }

    /// Final review: two renders of one scene need not give the same bytes, so Find duplicates' byte copy is copied
    /// from the corpus's own file, and is written again whenever that file is.
    @Test func aRecipeMadeFromAnotherCorpusFileFollowsIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recipes = [
            Corpus.Recipe("a.txt", { try Fixtures.textFile(UUID().uuidString, ext: "txt", in: $0) }),
            Corpus.Recipe("b.txt", from: "a.txt", { original, scratch in
                let copy = scratch.appending(path: "b.txt")
                try FileManager.default.copyItem(at: original, to: copy)
                return copy
            }),
        ]
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
        #expect(try await Corpus.write(to: dir, recipes: recipes) == ["a.txt", "b.txt"])
        let first = try bytes("a.txt")
        #expect(try bytes("b.txt") == first)
        #expect(try await Corpus.write(to: dir, recipes: recipes).isEmpty)

        try FileManager.default.removeItem(at: dir.appending(path: "a.txt"))
        #expect(try await Corpus.write(to: dir, recipes: recipes) == ["a.txt", "b.txt"])
        #expect(try bytes("a.txt") != first && bytes("b.txt") == bytes("a.txt"))

        let copies = Corpus.recipes.filter { ["dup-b.jpg", "dup-c.jpg", "dup-d.jpg"].contains($0.name) }
        #expect(copies.count == 3 && copies.allSatisfy { $0.source == "dup-a.jpg" })
    }

    @Test(.enabled(if: Installed.has("ffmpeg") && Installed.has("ffprobe")))
    func inspectionReadsAMatroskaFileWithFFprobe() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mkv = try await Fixtures.matroskaMovie(seconds: 2, in: dir)

        let inspection = await OutputCheck.inspect(mkv)

        #expect(inspection.opens)
        #expect(inspection.width == 320 && inspection.height == 240)
        #expect(inspection.audioChannels == 1)
        #expect(abs((inspection.durationSeconds ?? 0) - 2) <= 0.15)
    }

    /// The ffmpeg trim's outputs (mp3, flac) are measured like any recording, not merely found.
    @Test(.enabled(if: Installed.has("ffmpeg")), arguments: ["mp3", "flac"])
    func inspectionReadsTheDurationOfAnFFmpegRecording(_ ext: String) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = try Fixtures.ffmpegAudio(seconds: 2, channels: 2, ext: ext, in: dir)

        let inspection = await OutputCheck.inspect(tone)

        #expect(tone.pathExtension == ext)
        #expect(inspection.opens)
        #expect(inspection.audioChannels == 2)
        #expect(abs((inspection.durationSeconds ?? 0) - 2) <= 0.15, "\(inspection.durationSeconds ?? -1) s")
    }

    @Test func casesDecodeFromTheEdgesFile() throws {
        let json = """
            [{"name":"a","input":"photo.png","to":"jpg","expect":{"opens":true,"psnrMinDB":32}},
             {"name":"b","input":"clip.mov","preset":"extract-audio","requires":["ffmpeg"],"expect":{"opens":true,"durationSeconds":10}},
             {"name":"c","input":"doc.pdf","moreInputs":["photos.pdf"],"preset":"merge-pdfs","expect":{"opens":true,"pages":7}}]
            """
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
        #expect(cases.map(\.name) == ["a", "b", "c"])
        #expect(cases[0].expect.psnrMinDB == 32 && cases[1].requires == ["ffmpeg"])
        #expect(cases[0].moreInputs == nil && cases[2].moreInputs == ["photos.pdf"])
    }

    @Test func installedFindsAbsoluteExecutablesAndRejectsUnknownNames() {
        #expect(Installed.has("/bin/ls"))
        #expect(!Installed.has("/nonexistent/tool"))
        #expect(!Installed.has("definitely-not-a-pomelo-tool"))
    }

    /// Eval cases and corpus recipes say `"requires": ["engine:speech"]` for an engine only some Macs can run.
    @Test func installedAsksTheDefaultRegistryForAnEngine() {
        #expect(Installed.has("engine:imageio"))
        #expect(Installed.has("engine:subtitles"))
        #expect(!Installed.has("engine:pomelo-no-such-engine"))
        let recipe = Corpus.Recipe("x.txt", requires: "engine:imageio") { $0 }
        #expect(recipe.isAvailable)
    }

    /// `translation:<source>-<target>` for a case that needs a language pair; the answer comes from this Mac, so only
    /// the token's shape is checked.
    @Test func installedAnswersATranslationPairWithoutThrowing() {
        _ = Installed.has("translation:en-it")
        #expect(!Installed.has("translation:xx-yy"))
        #expect(!Installed.has("translation:en"))
        #expect(!Installed.has("translation:-"))
    }

    @Test func theCorpusHasTheDocumentFixtures() {
        #expect(Corpus.fileNames.contains("table.png") && Corpus.fileNames.contains("receipt.png"))
        #expect(Corpus.fileNames.contains("speech.m4a"))
    }

    /// `speech:<locale>` for a case that must not make the system download a model; a token without its region, or
    /// a language nobody speaks, is false.
    @Test func installedAnswersASpokenLanguageWithoutThrowing() {
        _ = Installed.has("speech:en-US")
        #expect(!Installed.has("speech:en"))
        #expect(!Installed.has("speech:xx-YY"))
        #expect(!Installed.has("speech:"))
    }

    @Test func theSpeechCasesNeedTheEnglishModelSoNothingDownloads() throws {
        let edges = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/edges.json")
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: edges))
        for name in ["transcribe", "make-subtitles"] {
            let speech = try #require(cases.first { $0.name == name }, "\(name)")
            #expect(speech.input == "speech.m4a" && speech.requires == ["engine:speech", "speech:en-US"], "\(name)")
        }
    }

    /// R4: the square case is the built-in preset with its Shape passed through `--options`, not an evals-only preset.
    @Test func theSmartCropCasesCropTheSubjectScene() throws {
        let edges = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/edges.json")
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: edges))
        #expect(Corpus.fileNames.contains("subject-scene.png"))
        let fit = try #require(cases.first { $0.name == "smart-crop" })
        let square = try #require(cases.first { $0.name == "smart-crop-square" })
        for smart in [fit, square] {
            #expect(smart.input == "subject-scene.png" && smart.preset == "smart-crop", "\(smart.name)")
            #expect(smart.expect.maxWidth != nil && smart.expect.maxHeight != nil, "\(smart.name)")
        }
        #expect(square.options == .object(["aspect": .string("1:1")]))
        #expect(square.expect.aspectRatio?.value == 1)
    }

    /// P268: the photographed page comes out with A4's ratio, either way up (R1), and its words still read.
    @Test func theStraightenCaseReadsThePagePhoto() throws {
        let edges = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/edges.json")
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: edges))
        #expect(Corpus.fileNames.contains("page-photo.jpg"))
        let straighten = try #require(cases.first { $0.name == "straighten" })
        #expect(straighten.input == "page-photo.jpg" && straighten.preset == "straighten")
        #expect(straighten.warmups == 1)
        #expect(straighten.expect.aspectRatio == .init(value: 1.414, tolerance: 0.06))
        #expect(straighten.expect.imageTextContains == Fixtures.pagePhotoHeading)
    }

    /// P268: the five images Find duplicates' case compares, an original, a byte copy, a resized and a re-encoded copy
    /// and an unrelated scene, and the case's expected report header.
    @Test func theFindDuplicatesCaseComparesFiveImages() async throws {
        let edges = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/edges.json")
        let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: edges))
        let duplicates = try #require(cases.first { $0.name == "find-duplicates" })
        #expect(duplicates.input == "dup-a.jpg" && duplicates.preset == "find-duplicates")
        #expect(duplicates.moreInputs == ["dup-b.jpg", "dup-c.jpg", "dup-d.jpg", "dup-e.jpg"])
        #expect(duplicates.expect.textContains == "1 group of identical files, 1 group that looks alike, 3 extra files")

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["dup-a.jpg", "dup-b.jpg", "dup-c.jpg", "dup-d.jpg", "dup-e.jpg"]
        let recipes = Corpus.recipes.filter { names.contains($0.name) }
        #expect(try await Corpus.write(to: dir, recipes: recipes) == names)
        func file(_ name: String) -> URL { dir.appending(path: name) }
        let original = try Data(contentsOf: file("dup-a.jpg"))
        #expect(try Data(contentsOf: file("dup-b.jpg")) == original)
        let size = try #require(Fixtures.imageSize(file("dup-a.jpg")))
        #expect(Fixtures.imageSize(file("dup-c.jpg")) == CGSize(width: size.width / 2, height: size.height / 2))
        #expect(Fixtures.imageSize(file("dup-d.jpg")) == size && Fixtures.imageSize(file("dup-e.jpg")) == size)
        for other in ["dup-c.jpg", "dup-d.jpg", "dup-e.jpg"] {
            #expect(try Data(contentsOf: file(other)) != original, "\(other)")
        }
    }

    @Test func installedLooksInThePomeloEnginesFolderToo() throws {
        let engines = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: engines) }
        let bin = engines.appending(path: "faketool/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appending(path: "pomelo-fake-tool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        #expect(!Installed.has("pomelo-fake-tool", enginesFolder: engines))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(Installed.has("pomelo-fake-tool", enginesFolder: engines))
        #expect(!Installed.has("another-tool", enginesFolder: engines))
        #expect(!Installed.has("pomelo-fake-tool", enginesFolder: engines.appending(path: "missing")))
    }

    /// Helpers that run a tool must run the one `has` found, the engines folder's first like the app's locator.
    @Test func installedPathPrefersTheEnginesFolderToHomebrew() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let engines = root.appending(path: "Engines", directoryHint: .isDirectory)
        let homebrew = root.appending(path: "homebrew/bin", directoryHint: .isDirectory)
        func makeTool(in folder: URL) throws -> URL {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tool = folder.appending(path: "pomelo-fake-tool")
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            return tool
        }
        #expect(Installed.path(of: "pomelo-fake-tool", enginesFolder: engines, searchFolders: [homebrew.path]) == nil)

        let brewed = try makeTool(in: homebrew)
        #expect(Installed.path(of: "pomelo-fake-tool", enginesFolder: engines, searchFolders: [homebrew.path])?.path
            == brewed.path)

        let installed = try makeTool(in: engines.appending(path: "faketool/bin", directoryHint: .isDirectory))
        #expect(Installed.path(of: "pomelo-fake-tool", enginesFolder: engines, searchFolders: [homebrew.path])?.path
            == installed.path)
        #expect(Installed.path(of: "/bin/ls")?.path == "/bin/ls")
        #expect(Installed.path(of: "/nonexistent/tool") == nil)
    }

    @Test func firstOutputReadsTheCLIJSON() {
        let json = #"{"results":[{"source":"/a.png","status":"succeeded","outputs":["/o/a.jpg"],"note":null,"error":null}]}"#
        #expect(EdgeRunner.firstOutput(of: json) == URL(fileURLWithPath: "/o/a.jpg"))
        let failed = #"{"results":[{"source":"/a.png","status":"failed","outputs":[],"note":null,"error":"x"}]}"#
        #expect(EdgeRunner.firstOutput(of: failed) == nil)
        #expect(EdgeRunner.firstOutput(of: "not json") == nil)
    }

    @Test func markedExpectationChecksEveryOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appending(path: "staged.txt")
        try Data("x".utf8).write(to: staged)
        let marked = try OutputPublisher.publish(
            staged: staged, to: dir, stem: "made", ext: "txt", suffix: nil, avoiding: [], namer: OutputNamer()
        )
        let plain = dir.appending(path: "plain.txt")
        try Data("y".utf8).write(to: plain)

        #expect(OutputCheck.markFailures([marked], expect: .init(marked: true)).isEmpty)
        #expect(OutputCheck.markFailures([marked, plain], expect: .init(marked: true)) == ["plain.txt is not marked"])
        #expect(OutputCheck.markFailures([plain], expect: .init()).isEmpty)
        let json = """
            {"results":[{"source":"/a.pdf","status":"succeeded","outputs":["/o/a-merged.pdf"]},
             {"source":"/b.pdf","status":"succeeded","outputs":["/o/a-merged.pdf"]},
             {"source":"/c.png","status":"succeeded","outputs":["/o/c.jpg","/o/c 2.jpg"]},
             {"source":"/d.png","status":"failed","outputs":[]}]}
            """
        #expect(EdgeRunner.outputs(of: json).map(\.path) == ["/o/a-merged.pdf", "/o/c.jpg", "/o/c 2.jpg"])
        let cases = try JSONDecoder().decode(
            [EvalCase].self, from: Data(#"[{"name":"m","input":"photo.png","to":"jpg","expect":{"opens":true,"marked":true}}]"#.utf8)
        )
        #expect(cases[0].expect.marked == true)
    }
}

@Suite struct SignpostExportTests {
    /// The shape of `xctrace export`: later rows refer to earlier values by `ref`.
    private static let export = """
        <?xml version="1.0"?><trace-query-result><node><schema name="os-signpost"></schema>
        <row><event-time id="1" fmt="00:01.000.000">1000000000</event-time><thread id="2" fmt="Main"><tid id="3">1</tid></thread><event-type id="4" fmt="Begin">Begin</event-type><os-signpost-identifier id="5" fmt="OS_SIGNPOST_ID_EXCLUSIVE">99</os-signpost-identifier><signpost-name id="6" fmt="open">open</signpost-name><subsystem id="7" fmt="io.github.pomelo-app.Pomelo">io.github.pomelo-app.Pomelo</subsystem><category id="8" fmt="wheel">wheel</category></row>
        <row><event-time id="9" fmt="x">1003000000</event-time><thread ref="2"/><event-type id="10" fmt="End">End</event-type><os-signpost-identifier ref="5"/><signpost-name ref="6"/><subsystem ref="7"/><category ref="8"/></row>
        <row><event-time id="11" fmt="x">2000000000</event-time><thread ref="2"/><event-type ref="4"/><os-signpost-identifier ref="5"/><signpost-name ref="6"/><subsystem ref="7"/><category ref="8"/></row>
        <row><event-time id="12" fmt="x">2009000000</event-time><thread ref="2"/><event-type ref="10"/><os-signpost-identifier ref="5"/><signpost-name ref="6"/><subsystem ref="7"/><category ref="8"/></row>
        <row><event-time id="13" fmt="x">3000000000</event-time><thread ref="2"/><event-type ref="4"/><os-signpost-identifier ref="5"/><signpost-name id="14" fmt="other">other</signpost-name><subsystem ref="7"/><category ref="8"/></row>
        <row><event-time id="15" fmt="x">3500000000</event-time><thread ref="2"/><event-type ref="10"/><os-signpost-identifier ref="5"/><signpost-name ref="14"/><subsystem ref="7"/><category ref="8"/></row>
        <row><event-time id="16" fmt="x">4000000000</event-time><thread ref="2"/><event-type ref="4"/><os-signpost-identifier ref="5"/><signpost-name ref="6"/><subsystem ref="7"/><category ref="8"/></row>
        </node></trace-query-result>
        """

    @Test func intervalsOfTheWheelOpenAreReadAcrossRefs() {
        let durations = SignpostIntervals.durationsMs(
            exportData: Data(Self.export.utf8), subsystem: "io.github.pomelo-app.Pomelo", category: "wheel", name: "open")
        #expect(durations == [3, 9])
    }

    @Test func aMeasurementOfAnExportWithoutTheIntervalThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "empty.xml")
        try Data("<trace-query-result></trace-query-result>".utf8).write(to: file)
        #expect(throws: (any Error).self) { try WheelMeasurement.load(signpostExport: file) }
        let good = dir.appending(path: "good.xml")
        try Data(Self.export.utf8).write(to: good)
        #expect(try WheelMeasurement.load(signpostExport: good) == WheelMeasurement(p50Ms: 6, p95Ms: 8.7, count: 2))
    }
}

@Suite struct EditOptionsEvalTests {
    @Test func aCaseWithOptionsPassesThem() throws {
        let json = #"""
            [{"name":"trim-clip","input":"clip.mov","preset":"trim",
              "options":{"edit":{"kind":"trim","start":1,"end":2.5},"targetBytes":9000},
              "expect":{"opens":true,"maxBytes":5000,"noMetadata":true}}]
            """#
        let url = FileManager.default.temporaryDirectory.appending(path: "edges-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let evalCase = try #require(try EvalCase.load(from: url).first)
        #expect(evalCase.expect.maxBytes == 5000)
        #expect(evalCase.expect.noMetadata == true)

        let runner = EdgeRunner(cli: URL(fileURLWithPath: "/cli"), corpus: URL(fileURLWithPath: "/corpus"))
        let arguments = runner.arguments(
            for: evalCase, input: URL(fileURLWithPath: "/corpus/clip.mov"), more: [],
            outputs: URL(fileURLWithPath: "/out"))
        #expect(arguments == [
            "-l", "/cli", "convert", "/corpus/clip.mov", "-o", "/out", "--json", "--preset", "trim",
            "--options", #"{"edit":{"end":2.5,"kind":"trim","start":1},"targetBytes":9000}"#,
        ])
    }

    @Test func aCaseWithoutOptionsPassesNone() {
        let evalCase = EvalCase(name: "n", input: "a.png", to: "jpg", expect: .init())
        let runner = EdgeRunner(cli: URL(fileURLWithPath: "/cli"), corpus: URL(fileURLWithPath: "/corpus"))
        let arguments = runner.arguments(
            for: evalCase, input: URL(fileURLWithPath: "/corpus/a.png"), more: [], outputs: URL(fileURLWithPath: "/out"))
        #expect(!arguments.contains("--options"))
    }

    @Test func maxBytesAndNoMetadataAreChecked() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gps = await OutputCheck.inspect(try Fixtures.jpgWithGPS(in: dir))
        let bare = await OutputCheck.inspect(try Fixtures.png(width: 64, height: 48, in: dir))
        #expect(gps.noMetadata == false)
        #expect(bare.noMetadata == true)
        #expect((gps.bytes ?? 0) > 0)

        #expect(OutputCheck.failures(bare, expect: .init(noMetadata: true)).isEmpty)
        #expect(OutputCheck.failures(gps, expect: .init(noMetadata: true)).count == 1)
        #expect(OutputCheck.failures(bare, expect: .init(maxBytes: (bare.bytes ?? 0))).isEmpty)
        let tooBig = OutputCheck.failures(bare, expect: .init(maxBytes: (bare.bytes ?? 0) - 1))
        #expect(tooBig.count == 1 && tooBig[0].contains("bytes"), "\(tooBig)")
    }

    @Test func aFileThatIsNotAnImageHasNoMetadataVerdict() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = await OutputCheck.inspect(try Fixtures.pdf(pages: 1, in: dir))
        #expect(pdf.noMetadata == nil)
        #expect(OutputCheck.failures(pdf, expect: .init(noMetadata: true)).count == 1)
    }
}

@Suite struct DetectTimingTests {
    @Test func visionTimingsAreSecondsWithTheEdgeTolerance() {
        let metric = MetricDefaults.metric(named: "vision.redact_detect.photo.seconds", value: 0.5)
        #expect(metric.unit == "s" && metric.better == .lower && metric.tolerance == 0.3 && metric.slack == 0.2)
    }

    @Test func detectionIsTimedOnThePhotoAndTheText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(
            at: try Fixtures.photo(width: 400, height: 300, type: "public.jpeg", ext: "jpg", in: dir),
            to: dir.appending(path: "photo.jpg"))
        try FileManager.default.moveItem(
            at: try Fixtures.textImage("Hello Pomelo", in: dir), to: dir.appending(path: "text.png"))

        let metrics = try await DetectTiming.measure(corpus: dir)

        #expect(Set(metrics.keys) == ["vision.redact_detect.photo.seconds", "vision.redact_detect.text.seconds"])
        #expect(metrics.values.allSatisfy { $0 > 0 && $0 < 30 })
    }

    @Test func aTextPictureWithoutTextFails() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let blank = try Fixtures.png(width: 300, height: 100, in: dir)
        try FileManager.default.copyItem(at: blank, to: dir.appending(path: "photo.jpg"))
        try FileManager.default.moveItem(at: blank, to: dir.appending(path: "text.png"))
        await #expect(throws: DetectTiming.Failure.self) { try await DetectTiming.measure(corpus: dir) }
    }
}
