import Foundation
import Testing
import PomeloTestSupport
@testable import PomeloEvalsKit

/// Periphery's JSON, trimmed to the fields the audit reads. Locations are absolute, like the real ones.
private let peripheryReport = #"""
[
  {"kind": "function.method.instance", "name": "unusedHelper()", "hints": ["unused"],
   "location": "/Users/x/Pomelo/Sources/PomeloCore/Jobs/JobRunner.swift:34:29"},
  {"kind": "var.instance", "name": "pill", "hints": ["assignOnlyProperty"],
   "location": "/Users/x/Pomelo/App/Sources/AppEnvironment.swift:28:9"},
  {"kind": "function.method.static", "name": "pdf(pageTexts:)", "hints": ["unused"],
   "location": "/Users/x/Pomelo/Sources/PomeloTestSupport/Fixtures.swift:490:24"}
]
"""#

@Suite struct AuditPeripheryTests {
    @Test func countsUnusedAndAssignOnlyDeclarationsOutsideTheAllowList() throws {
        let findings = try Audit.deadDeclarations(periphery: Data(peripheryReport.utf8))
        #expect(findings.map(\.name) == ["pill", "unusedHelper()"])
        #expect(findings.map(\.module) == ["App", "PomeloCore"])
        #expect(findings.last?.path == "Sources/PomeloCore/Jobs/JobRunner.swift")
        #expect(findings.last?.line == 34)
    }

    @Test func aNamedAllowListReplacesTheDefaultOne() throws {
        let findings = try Audit.deadDeclarations(periphery: Data(peripheryReport.utf8), allowedPaths: ["/App/Sources/"])
        #expect(findings.map(\.name) == ["unusedHelper()", "pdf(pageTexts:)"])
    }

    @Test func accessibilityAdviceAndImportsAreNotDeadCode() throws {
        let report = #"""
        [
          {"kind": "struct", "name": "CLIConvertJSON", "hints": ["redundantPublicAccessibility"],
           "location": "/Users/x/Pomelo/Sources/PomeloCLIKit/CLIJSON.swift:6:15"},
          {"kind": "module", "name": "PomeloUIModel", "hints": ["unused"],
           "location": "/Users/x/Pomelo/App/Sources/Intents/FormatEntity.swift:4:1"},
          {"kind": "function.free", "name": "dead()", "hints": ["unused"],
           "location": "/Users/x/Pomelo/Sources/PomeloCLIKit/CLIJSON.swift:9:1"}
        ]
        """#
        let findings = try Audit.deadDeclarations(periphery: Data(report.utf8))
        #expect(findings.map(\.name) == ["dead()"])
    }

    @Test func aReportThatIsNotAnArrayThrows() {
        #expect(throws: (any Error).self) { try Audit.deadDeclarations(periphery: Data("{}".utf8)) }
    }
}

@Suite struct AuditDuplicationTests {
    private static let report = #"""
    {
      "duplicates": [
        {"lines": 6, "tokens": 86,
         "firstFile": {"name": "/Users/x/Pomelo/App/Sources/Editors/CropEditor.swift", "start": 10, "end": 15},
         "secondFile": {"name": "/Users/x/Pomelo/App/Sources/Editors/RedactionEditor.swift", "start": 20, "end": 25}},
        {"lines": 10, "tokens": 120,
         "firstFile": {"name": "/Users/x/Pomelo/Sources/PomeloCore/A.swift", "start": 1, "end": 10},
         "secondFile": {"name": "/Users/x/Pomelo/App/Sources/Wheel/B.swift", "start": 5, "end": 14}}
      ],
      "statistics": {"total": {"clones": 2, "duplicatedLines": 16, "lines": 3200, "percentage": 0.5}}
    }
    """#

    @Test func readsTheTotalPercentageAndTheClones() throws {
        let summary = try Audit.duplication(jscpd: Data(Self.report.utf8))
        #expect(summary.percentage == 0.5)
        #expect(summary.clones.count == 2)
        #expect(summary.clones[0].lines == 6)
        #expect(summary.clones[0].first.path == "App/Sources/Editors/CropEditor.swift")
    }

    @Test func aCloneCountsOnceInAModuleThatHoldsBothSidesAndOnceInEachModuleItSpans() throws {
        let summary = try Audit.duplication(jscpd: Data(Self.report.utf8))
        #expect(summary.duplicatedLines(inModule: "App") == 16)
        #expect(summary.duplicatedLines(inModule: "PomeloCore") == 10)
        #expect(summary.duplicatedLines(inModule: "QuickAction") == 0)
    }

    @Test func aReportWithoutStatisticsThrows() {
        #expect(throws: (any Error).self) { try Audit.duplication(jscpd: Data(#"{"duplicates": []}"#.utf8)) }
    }
}

@Suite struct AuditComplexityTests {
    // NLOC, CCN, tokens, params, length, location, file, name, long name, start, end
    private static let csv = """
    4,1,21,1,4,"init@9-12@Sources/PomeloCore/Jobs/AsyncSemaphore.swift","Sources/PomeloCore/Jobs/AsyncSemaphore.swift","init","init value : Int",9,12
    80,16,500,2,90,"convert@10-99@App/Sources/Jobs/JobCoordinator.swift","App/Sources/Jobs/JobCoordinator.swift","convert","convert a , b",10,99
    30,15,200,1,32,"edges@1-32@Sources/PomeloEngines/X.swift","Sources/PomeloEngines/X.swift","edges","edges (a: [Int], b: Int)",1,32
    60,22,400,0,70,"run@5-74@App/Sources/Wheel/WheelController.swift","App/Sources/Wheel/WheelController.swift","run","run",5,74
    """

    @Test func countsFunctionsOverCCN15AndFindsTheMax() {
        let functions = Audit.complexity(lizardCSV: Self.csv)
        #expect(functions.count == 4)
        #expect(Audit.functionsOver(15, in: functions).count == 2)
        #expect(functions.map(\.ccn).max() == 22)
    }

    @Test func attributesAFunctionToItsModule() {
        let over = Audit.functionsOver(15, in: Audit.complexity(lizardCSV: Self.csv))
        #expect(over.map(\.module) == ["App", "App"])
    }

    @Test func aQuotedFieldMayHoldCommas() {
        let functions = Audit.complexity(lizardCSV: Self.csv)
        #expect(functions[2].name == "edges")
        #expect(functions[2].line == 1)
    }

    @Test func blankLinesAndShortRowsAreSkipped() {
        #expect(Audit.complexity(lizardCSV: "\n1,2,3\n").isEmpty)
    }
}

@Suite struct AuditCommentTests {
    private static let fixture = #"""
    import Foundation

    /// Doc comment about P12.
    struct Thing {
        let url = "https://x.test/a"
        let a = 1 // trailing R7 note
        /* block
           spans two lines P3 */
        let b = 2 /* inline */ + 3
        let raw = #"// not a comment "# // real
        let text = """
        // inside a multiline string
        """
    }
    let s = "a \("//x") b"
    // Rect2 PDF1 XP9 are not rulings
    """#

    @Test func countsCodeCommentAndRulingLinesExactly() {
        let stats = Audit.commentStats(in: Self.fixture)
        #expect(stats == CommentStats(codeLines: 11, commentLines: 7, rulingRefLines: 3))
    }

    @Test func readsAFile() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Thing.swift")
        try Self.fixture.write(to: file, atomically: true, encoding: .utf8)
        #expect(Audit.commentStats(of: file) == CommentStats(codeLines: 11, commentLines: 7, rulingRefLines: 3))
    }

    @Test func aMissingFileCountsNothing() {
        #expect(Audit.commentStats(of: URL(fileURLWithPath: "/nonexistent/Nope.swift")) == CommentStats())
    }

    @Test func nestedBlockCommentsClose() {
        let stats = Audit.commentStats(in: "/* a /* b */ still comment */\nlet x = 1\n")
        #expect(stats == CommentStats(codeLines: 1, commentLines: 1, rulingRefLines: 0))
    }

    @Test func blankLinesAreNeitherCodeNorComments() {
        #expect(Audit.commentStats(in: "\n\n   \n") == CommentStats())
    }
}

@Suite struct AuditReportTests {
    private func sources() throws -> (root: URL, directories: [URL]) {
        let root = try makeTempDir()
        let fm = FileManager.default
        for (path, text) in [
            ("Sources/PomeloCore/A.swift", "// P1 why\nlet a = 1\nlet b = 2\n"),
            ("Sources/PomeloEvalsKit/B.swift", "// tooling\nlet c = 3\n"),
            ("App/Sources/C.swift", "let d = 4\n"),
        ] {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return (root, ["Sources", "App/Sources"].map { root.appending(path: $0, directoryHint: .isDirectory) })
    }

    @Test func metricsFromEveryToolAndPerModule() throws {
        let (root, directories) = try sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let periphery = #"[{"kind":"var.instance","name":"x","hints":["unused"],"location":"\#(root.path)/Sources/PomeloCore/A.swift:2:1"}]"#
        let jscpd = #"""
        {"duplicates": [{"lines": 2, "tokens": 60,
          "firstFile": {"name": "\#(root.path)/App/Sources/C.swift", "start": 1, "end": 2},
          "secondFile": {"name": "\#(root.path)/Sources/PomeloCore/A.swift", "start": 1, "end": 2}}],
         "statistics": {"total": {"percentage": 1.5}}}
        """#
        let lizard = """
        5,18,1,0,5,"f@1-5@Sources/PomeloCore/A.swift","\(root.path)/Sources/PomeloCore/A.swift","f","f",1,5
        5,3,1,0,5,"g@1-5@App/Sources/C.swift","\(root.path)/App/Sources/C.swift","g","g",1,5
        """
        let outcome = try Audit.run(Audit.Inputs(
            periphery: Data(periphery.utf8), peripheryWithoutTests: Data(periphery.utf8), jscpd: Data(jscpd.utf8),
            lizardCSV: lizard, sourceDirectories: directories))
        let metrics = outcome.results.metrics
        #expect(metrics["code.dead_declarations"] == 1)
        #expect(metrics["code.PomeloCore.dead_declarations"] == 1)
        #expect(metrics["code.App.dead_declarations"] == 0)
        #expect(metrics["code.duplication_percent"] == 1.5)
        // PomeloCore has 3 physical lines, App 1, PomeloEvalsKit 2.
        #expect(abs((metrics["code.PomeloCore.duplication_percent"] ?? 0) - 2.0 / 3.0 * 100) < 1e-9)
        #expect(metrics["code.App.duplication_percent"] == 200)
        #expect(metrics["code.functions_over_ccn15"] == 1)
        #expect(metrics["code.PomeloCore.functions_over_ccn15"] == 1)
        #expect(metrics["code.App.functions_over_ccn15"] == 0)
        #expect(metrics["code.max_ccn"] == 18)
        #expect(metrics["code.swift_lines"] == 4)
        // Production sources only: PomeloEvalsKit's comment and code are left out.
        #expect(metrics["comments.density_percent"] == 1.0 / 3.0 * 100)
        #expect(metrics["comments.ruling_refs"] == 1)
        #expect(outcome.results.skipped.isEmpty)
    }

    @Test func aMissingToolSkipsItsMetricsOnly() throws {
        let (root, directories) = try sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try Audit.run(Audit.Inputs(sourceDirectories: directories))
        #expect(Set(outcome.results.skipped) == [
            "code.dead_declarations", "code.test_only_declarations", "code.duplication_percent",
            "code.functions_over_ccn15", "code.max_ccn",
        ])
        #expect(outcome.results.metrics["code.dead_declarations"] == nil)
        #expect(outcome.results.metrics["code.PomeloCore.dead_declarations"] == nil)
        #expect(outcome.results.metrics["code.swift_lines"] == 4)
    }

    @Test func testOnlyDeclarationsAreTheOnesOnlyTheTestsUse() throws {
        let (root, directories) = try sources()
        defer { try? FileManager.default.removeItem(at: root) }
        func entry(_ name: String) -> String {
            #"{"kind":"var.instance","name":"\#(name)","hints":["unused"],"location":"\#(root.path)/Sources/PomeloCore/A.swift:2:1"}"#
        }
        let withTests = "[\(entry("a"))]"
        let withoutTests = "[\(entry("a")),\(entry("b")),\(entry("c"))]"
        let outcome = try Audit.run(Audit.Inputs(
            periphery: Data(withTests.utf8), peripheryWithoutTests: Data(withoutTests.utf8), sourceDirectories: directories))
        #expect(outcome.results.metrics["code.dead_declarations"] == 1)
        #expect(outcome.results.metrics["code.test_only_declarations"] == 2)
        #expect(outcome.report.contains("test-only"))
    }

    @Test func theReportListsWhatToLookAt() throws {
        let (root, directories) = try sources()
        defer { try? FileManager.default.removeItem(at: root) }
        let periphery = #"[{"kind":"var.instance","name":"leftover","hints":["unused"],"location":"\#(root.path)/Sources/PomeloCore/A.swift:2:1"}]"#
        let outcome = try Audit.run(Audit.Inputs(
            periphery: Data(periphery.utf8), peripheryWithoutTests: Data(periphery.utf8), sourceDirectories: directories))
        #expect(outcome.report.contains("Sources/PomeloCore/A.swift:2"))
        #expect(outcome.report.contains("leftover"))
    }
}

@Suite struct AuditMetricDefaultsTests {
    @Test func countsAreStrictForTheTotalsAndForEveryModule() {
        for name in ["code.dead_declarations", "code.test_only_declarations", "code.PomeloCore.dead_declarations",
                     "code.App.functions_over_ccn15", "code.functions_over_ccn15", "code.max_ccn"] {
            let metric = MetricDefaults.metric(named: name, value: 3)
            #expect(metric.better == .lower, "\(name)")
            #expect(!metric.regressed(by: 3), "\(name)")
            #expect(metric.regressed(by: 4), "\(name)")
        }
    }

    @Test func sizeAndDuplicationHaveRoomAndCommentsAreInformational() {
        let lines = MetricDefaults.metric(named: "code.swift_lines", value: 20000)
        #expect(!lines.regressed(by: 20900))
        #expect(lines.regressed(by: 21100))
        let duplication = MetricDefaults.metric(named: "code.PomeloCore.duplication_percent", value: 1)
        #expect(!duplication.regressed(by: 1.5))
        #expect(duplication.regressed(by: 2))
        let rulings = MetricDefaults.metric(named: "comments.ruling_refs", value: 400)
        #expect(!rulings.regressed(by: 700))
    }

    @Test func everyDefaultKeepsItsUnitDirectionToleranceAndSlack() {
        let expected: [(String, String, Better, Double, Double)] = [
            ("wheel.open.p50_ms", "ms", .lower, 0.25, 3), ("wheel.open.p95_ms", "ms", .lower, 0.25, 3),
            ("wheel.open_custom.p50_ms", "ms", .lower, 0.25, 3), ("wheel.open_custom.p95_ms", "ms", .lower, 0.25, 3),
            ("shelf.open.p50_ms", "ms", .lower, 0.25, 3), ("shelf.open.p95_ms", "ms", .lower, 0.25, 3),
            ("app.idle.cpu_percent", "%", .lower, 0.5, 0.2),
            ("app.idle.wakeups_per_s", "/s", .lower, 0.5, 20), ("app.watch.idle.wakeups_per_s", "/s", .lower, 0.5, 20),
            ("app.watch.latency.p95_ms", "ms", .lower, 0.25, 250), ("app.idle.footprint_mb", "MB", .lower, 0.15, 5),
            ("app.shelf.idle.wakeups_per_s", "/s", .lower, 0.5, 20), ("app.shelf.idle.footprint_mb", "MB", .lower, 0.15, 5),
            ("app.launch.p50_ms", "ms", .lower, 0.5, 100), ("app.launch.p95_ms", "ms", .lower, 0.5, 100),
            ("app.bundle_kb", "KB", .lower, 0.1, 50), ("app.binary_kb", "KB", .lower, 0.1, 50),
            ("cli.binary_kb", "KB", .lower, 0.1, 50),
            ("build.warnings.package", "warnings", .lower, 0, 0), ("build.warnings.app", "warnings", .lower, 0, 0),
            ("build.warnings.app_debug", "warnings", .lower, 0, 0), ("a11y.findings", "findings", .lower, 0, 0),
            ("tests.package.count", "tests", .higher, 0, 0), ("tests.app.count", "tests", .higher, 0, 0),
            ("tests.package.seconds", "s", .lower, 0.5, 5), ("tests.app.seconds", "s", .lower, 0.5, 5),
            ("code.duplication_percent", "%", .lower, 0.1, 0.1), ("code.dead_declarations", "declarations", .lower, 0, 0),
            ("code.test_only_declarations", "declarations", .lower, 0, 0), ("code.functions_over_ccn15", "functions", .lower, 0, 0),
            ("code.max_ccn", "", .lower, 0, 0), ("code.swift_lines", "lines", .lower, 0.05, 0),
            ("comments.density_percent", "%", .lower, 0.5, 1), ("comments.ruling_refs", "refs", .lower, 1, 20),
            ("code.App.duplication_percent", "%", .lower, 0.1, 0.5),
            ("code.App.dead_declarations", "declarations", .lower, 0, 0),
            ("code.App.test_only_declarations", "declarations", .lower, 0, 0),
            ("code.App.functions_over_ccn15", "functions", .lower, 0, 0),
            ("editor.open.trim.p95_ms", "ms", .lower, 0.25, 3), ("vision.redact_detect.photo.seconds", "s", .lower, 0.3, 0.2),
            ("edge.mov-mkv.seconds", "s", .lower, 0.3, 0.2), ("edge.mov-mkv.peak_rss_mb", "MB", .lower, 0.25, 10),
            ("edge.png-jpg.psnr_db", "dB", .higher, 0.03, 0), ("edge.png-jpg.ssim", "", .higher, 0.01, 0),
            ("edge.compress-jpg.ratio", "x", .lower, 0.1, 0.005),
            ("edge.mov-mkv.other", "", .lower, 0.25, 0), ("something.else", "", .lower, 0.25, 0),
        ]
        for (name, unit, better, tolerance, slack) in expected {
            let metric = MetricDefaults.metric(named: name, value: 7)
            #expect(metric.unit == unit && metric.better == better && metric.tolerance == tolerance && metric.slack == slack, "\(name)")
            #expect(metric.value == 7 && metric.budget == nil, "\(name)")
        }
    }
}
