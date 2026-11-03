import Foundation
import Testing
@testable import PomeloEvalsKit

private func budgeted(_ name: String, value: Double = 10, budget: Double = 100) -> (String, Metric) {
    var metric = MetricDefaults.metric(named: name, value: value)
    metric.budget = budget
    return (name, metric)
}

private func run(_ mode: String?, metrics: [String: Double] = [:], skipped: [String] = [], baseline: [(String, Metric)])
    -> CompareReport {
    var results = EvalResults(metrics: metrics, skipped: skipped)
    if let mode { results.meta[EvalResults.modeKey] = mode }
    return Compare.run(results: results, baseline: Baseline(metrics: Dictionary(uniqueKeysWithValues: baseline)))
}

@Suite struct BudgetTests {
    @Test func rulingRefsAreInformationalNeverGating() {
        // P145: a deleted safety "why" must not read as an improvement, nor an added one as a regression.
        let ruling = MetricDefaults.metric(named: "comments.ruling_refs", value: 205)
        let baseline = Baseline(metrics: ["comments.ruling_refs": ruling])
        let grown = Compare.run(results: EvalResults(metrics: ["comments.ruling_refs": 5000]), baseline: baseline)
        #expect(grown.exitCode == 0 && !grown.blocksBaselineUpdate)
        #expect(!grown.lines.contains { $0.hasPrefix("REGRESSION") || $0.hasPrefix("OVER BUDGET") })
        var budgetedRuling = ruling
        budgetedRuling.budget = 1
        let capped = Compare.run(results: EvalResults(metrics: ["comments.ruling_refs": 5000]),
                                 baseline: Baseline(metrics: ["comments.ruling_refs": budgetedRuling]))
        #expect(capped.exitCode == 0)
        let missing = run("full", baseline: [("comments.ruling_refs", budgetedRuling)])
        #expect(missing.exitCode == 0)
    }

    @Test func aBudgetedMetricMissingFromAFullRunFails() {
        let report = run("full", metrics: ["app.binary_kb": 5], baseline: [budgeted("wheel.open.p95_ms")])
        #expect(report.exitCode == 1)
        #expect(report.lines.contains { $0.hasPrefix("MISSING wheel.open.p95_ms") })
        #expect(report.blocksBaselineUpdate)
    }

    @Test func aBaselineEntryWithoutABudgetMayBeMissing() {
        let report = run("full", baseline: [("app.launch.p50_ms", MetricDefaults.metric(named: "app.launch.p50_ms", value: 100))])
        #expect(report.exitCode == 0)
    }

    @Test func aQuickRunMayLackOnlyTheFullRunOnlyMetrics() {
        let fullOnly = ["tests.package.count", "tests.app.seconds", "build.warnings.app", "code.swift_lines",
                        "code.App.dead_declarations", "comments.density_percent"].map { budgeted($0) }
        #expect(run("quick", baseline: fullOnly).exitCode == 0)
        #expect(run(nil, baseline: fullOnly).exitCode == 0)
        for name in ["wheel.open.p95_ms", "wheel.open_custom.p95_ms", "app.binary_kb", "edge.png-jpg.seconds", "editor.open.crop.p95_ms",
                     "vision.redact_detect.photo.seconds", "a11y.findings", "app.idle.cpu_percent"] {
            let report = run("quick", baseline: [budgeted(name)])
            #expect(report.exitCode == 1, "\(name) missing from a quick run")
        }
    }

    @Test func aFullRunNeedsTheFullRunOnlyMetricsToo() {
        let report = run("full", baseline: [budgeted("tests.package.count")])
        #expect(report.exitCode == 1)
        #expect(report.lines.contains { $0.hasPrefix("MISSING tests.package.count") })
    }

    @Test func aSkippedCaseOrAuditToolExcusesItsMetrics() {
        let report = run("full", skipped: ["edge.mov-mkv (needs ffmpeg)", "code.dead_declarations"],
                         baseline: [budgeted("edge.mov-mkv.seconds"), budgeted("edge.mov-mkv.peak_rss_mb"),
                                    budgeted("code.dead_declarations"), budgeted("code.App.dead_declarations")])
        #expect(report.exitCode == 0, "\(report.lines)")
        let other = run("full", skipped: ["edge.mov-mkv (needs ffmpeg)"], baseline: [budgeted("edge.mov-mp4.seconds")])
        #expect(other.exitCode == 1)
    }

    @Test func aNameThatMerelyStartsLikeASkippedCaseIsNotExcused() {
        let report = run("full", skipped: ["edge.mov (needs ffmpeg)"], baseline: [budgeted("edge.mov-mkv.seconds")])
        #expect(report.exitCode == 1)
    }

    @Test func anUpdateIsRefusedForAnOverBudgetValueOrAFailedCheck() {
        let baseline = Baseline(metrics: ["app.binary_kb": Metric(value: 90, unit: "KB", better: .lower, tolerance: 0, slack: 0, budget: 100)])
        let over = Compare.run(results: EvalResults(metrics: ["app.binary_kb": 101]), baseline: baseline)
        #expect(over.blocksBaselineUpdate)
        let failed = Compare.run(
            results: EvalResults(metrics: ["app.binary_kb": 91], checks: [.init(name: "c", ok: false)]), baseline: baseline)
        #expect(failed.blocksBaselineUpdate)
        // A regression within the budget is what --update-baseline exists to accept.
        let regressed = Compare.run(results: EvalResults(metrics: ["app.binary_kb": 99]), baseline: baseline)
        #expect(regressed.exitCode == 1 && !regressed.blocksBaselineUpdate)
        let clean = Compare.run(results: EvalResults(metrics: ["app.binary_kb": 90]), baseline: baseline)
        #expect(!clean.blocksBaselineUpdate)
    }

    @Test func everyMetricInTheShippedBaselineHasABudget() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/baseline.json")
        let baseline = try Baseline.load(from: url)
        let without = baseline.metrics.filter { $0.value.budget == nil && !Compare.informational.contains($0.key) }
        #expect(without.isEmpty, "no budget: \(without.keys.sorted())")
    }

    @Test func everyMetricInTheShippedBaselineKeepsItsSpecThroughAnUpdate() throws {
        // `Compare.updated` rebuilds each metric from `MetricDefaults`: a hand-set slack it doesn't know is lost.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/baseline.json")
        let baseline = try Baseline.load(from: url)
        for (name, metric) in baseline.metrics {
            let spec = MetricDefaults.metric(named: name, value: metric.value)
            #expect(spec.unit == metric.unit && spec.better == metric.better && spec.tolerance == metric.tolerance
                && spec.slack == metric.slack, "\(name): baseline \(metric), defaults \(spec)")
        }
    }

    @Test func budgetsNeverSitInsideTheirOwnRegressionLimitTheWrongWay() throws {
        // A budget tighter than the baseline's own limit would fail a run the baseline calls clean (flaky CI gate).
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/baseline.json")
        let baseline = try Baseline.load(from: url)
        for (name, metric) in baseline.metrics {
            guard let budget = metric.budget else { continue }
            switch metric.better {
            case .lower: #expect(budget >= metric.value, "\(name): budget \(budget) below its value \(metric.value)")
            case .higher: #expect(budget <= metric.value, "\(name): floor \(budget) above its value \(metric.value)")
            }
            // P152: the budgets derived from a noisy value (2x, +25 %) start at the regression limit at least.
            let derived = name.hasPrefix("edge.") || name.hasPrefix("vision.")
            if derived && [".seconds", ".peak_rss_mb", ".ratio"].contains(where: name.hasSuffix) {
                #expect(budget >= metric.limit, "\(name): budget \(budget) inside its regression limit \(metric.limit)")
            }
        }
    }
}
