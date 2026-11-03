import Foundation

public struct Baseline: Codable, Equatable, Sendable {
    public var metrics: [String: Metric]

    public init(metrics: [String: Metric] = [:]) { self.metrics = metrics }

    public static func load(from url: URL) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

public struct CompareReport: Equatable, Sendable {
    /// One line each for a regression, a failed check, a new metric or a skipped case.
    public var lines: [String]
    /// 0 for no regression, 1 for a regression or a failed check.
    public var exitCode: Int32
    /// True for a failed check, an over-budget value or a missing budgeted metric: `--update-baseline` refuses these,
    /// so a baseline can never be rewritten to values the budgets reject.
    public var blocksBaselineUpdate: Bool
}

public enum Compare {
    /// Measured and reported, never gating (P145): a ruling reference deleted with its code must not read as an
    /// improvement, and one added with new code must not read as a regression.
    public static let informational: Set<String> = ["comments.ruling_refs"]

    /// What a quick run does not measure (clean builds, warning counts, tests, the audit); a full run must have them.
    static let fullRunOnlyPrefixes = ["build.warnings.", "tests.", "code.", "comments."]

    /// The wheel's budget in the baseline is 50 ms minus the 16.7 ms poll tick that notices the trigger.
    public static let wheelP95Key = "wheel.open.p95_ms"

    public static func run(results: EvalResults, baseline: Baseline) -> CompareReport {
        var lines: [String] = []
        var failed = false
        var blocksUpdate = false
        for check in results.checks where !check.ok {
            failed = true
            blocksUpdate = true
            lines.append("FAILED \(check.name): \(check.detail)")
        }
        for (name, value) in results.metrics.sorted(by: { $0.key < $1.key }) {
            guard let metric = baseline.metrics[name] else {
                lines.append("new \(name) = \(format(value))")
                continue
            }
            if informational.contains(name) {
                if value != metric.value { lines.append("info \(name): \(format(metric.value)) -> \(format(value))") }
                continue
            }
            if let budget = metric.budget, metric.overBudget(value) {
                failed = true
                blocksUpdate = true
                let side = metric.better == .lower ? "over" : "under"
                let tick = name == wheelP95Key ? " (50 ms to the wheel minus the 16.7 ms poll tick)" : ""
                lines.append("OVER BUDGET \(name): \(format(value)) \(metric.unit) is \(side) its budget of \(format(budget)) \(metric.unit)\(tick)")
            }
            if metric.regressed(by: value) {
                failed = true
                lines.append("REGRESSION \(name): \(format(metric.value)) \(metric.unit) -> \(format(value)) \(metric.unit) (limit \(format(metric.limit)))")
            }
        }
        let missing = missingBudgeted(results: results, baseline: baseline)
        lines += missing
        if !missing.isEmpty {
            failed = true
            blocksUpdate = true
        }
        for name in results.skipped.sorted() { lines.append("skipped \(name)") }
        return CompareReport(lines: lines, exitCode: failed ? 1 : 0, blocksBaselineUpdate: blocksUpdate)
    }

    /// A renamed or dropped metric would otherwise take its budget with it without a word.
    private static func missingBudgeted(results: EvalResults, baseline: Baseline) -> [String] {
        let isFullRun = results.meta[EvalResults.modeKey] == "full"
        return baseline.metrics.sorted(by: { $0.key < $1.key }).compactMap { name, metric in
            guard metric.budget != nil, results.metrics[name] == nil, !informational.contains(name) else { return nil }
            guard isFullRun || !fullRunOnlyPrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            guard !results.skipped.contains(where: { skip($0, covers: name) }) else { return nil }
            return "MISSING \(name): the baseline budgets it, the \(isFullRun ? "full" : "quick") run did not measure it"
        }
    }

    /// `edge.mov-mkv (needs ffmpeg)` covers `edge.mov-mkv.seconds`; the audit's `code.dead_declarations` covers
    /// itself and every module's `code.<module>.dead_declarations`.
    private static func skip(_ skipped: String, covers metric: String) -> Bool {
        let name = skipped.split(separator: " ", maxSplits: 1).first.map(String.init) ?? skipped
        if metric == name || metric.hasPrefix(name + ".") { return true }
        guard name.hasPrefix("code."), metric.hasPrefix("code.") else { return false }
        return metric.hasSuffix("." + name.dropFirst("code.".count))
    }

    /// The baseline with every metric of `results` set to its new value and the default tolerances, keeping each
    /// metric's budget. Metrics the run did not measure (a quick run has no test counts) keep their entry.
    public static func updated(_ baseline: Baseline, with results: EvalResults) -> Baseline {
        var metrics = baseline.metrics
        for (name, value) in results.metrics {
            var metric = MetricDefaults.metric(named: name, value: value)
            metric.budget = baseline.metrics[name]?.budget
            metrics[name] = metric
        }
        return Baseline(metrics: metrics)
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}
