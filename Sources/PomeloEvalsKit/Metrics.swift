import Foundation

public enum Better: String, Codable, Sendable {
    case lower, higher
}

/// One baselined number. A regression is a move in the wrong direction past `tolerance` (a fraction of the baseline)
/// plus `slack` (an absolute allowance for numbers too small for a fraction to mean anything).
public struct Metric: Codable, Equatable, Sendable {
    public var value: Double
    public var unit: String
    public var better: Better
    public var tolerance: Double
    public var slack: Double
    /// An absolute limit that holds whatever the baseline drifts to (nil: none): a ceiling for `.lower`, a floor for
    /// `.higher`. A baseline update never changes it.
    public var budget: Double?

    public init(value: Double, unit: String, better: Better, tolerance: Double, slack: Double, budget: Double? = nil) {
        self.value = value
        self.unit = unit
        self.better = better
        self.tolerance = tolerance
        self.slack = slack
        self.budget = budget
    }

    /// The worst `new` value that still passes.
    public var limit: Double {
        switch better {
        case .lower: return value * (1 + tolerance) + slack
        case .higher: return value * (1 - tolerance) - slack
        }
    }

    public func overBudget(_ value: Double) -> Bool {
        guard let budget else { return false }
        switch better {
        case .lower: return value > budget
        case .higher: return value < budget
        }
    }

    public func regressed(by new: Double) -> Bool {
        switch better {
        case .lower: return new > limit
        case .higher: return new < limit
        }
    }
}

/// The default unit, direction, tolerance and slack of a metric, by name.
public enum MetricDefaults {
    private typealias Spec = (unit: String, better: Better, tolerance: Double, slack: Double)

    private static let exact: [(names: [String], spec: Spec)] = [
        (["wheel.open.p50_ms", "wheel.open.p95_ms", "wheel.open_custom.p50_ms", "wheel.open_custom.p95_ms",
          "shelf.open.p50_ms", "shelf.open.p95_ms"], ("ms", .lower, 0.25, 3)),
        (["app.idle.cpu_percent"], ("%", .lower, 0.5, 0.2)),
        // Slack 20 (P46): unchanged code measured up to 19.5/s on a busy Mac; a stray poll timer (30 Hz or more) still fails.
        (["app.idle.wakeups_per_s", "app.watch.idle.wakeups_per_s", "app.shelf.idle.wakeups_per_s"], ("/s", .lower, 0.5, 20)),
        // The settle interval (1 s) plus one conversion; another settle round (+1 s) must fail.
        (["app.watch.latency.p95_ms"], ("ms", .lower, 0.25, 250)),
        (["app.idle.footprint_mb", "app.shelf.idle.footprint_mb"], ("MB", .lower, 0.15, 5)),
        // A launch of about 100 ms spreads widely on a busy laptop: the slack keeps that noise from failing.
        (["app.launch.p50_ms", "app.launch.p95_ms"], ("ms", .lower, 0.5, 100)),
        (["app.bundle_kb", "app.binary_kb", "cli.binary_kb"], ("KB", .lower, 0.1, 50)),
        (["build.warnings.package", "build.warnings.app", "build.warnings.app_debug"], ("warnings", .lower, 0, 0)),
        // The accessibility audit (P146): the in-process walk and the source lint together.
        (["a11y.findings"], ("findings", .lower, 0, 0)),
        (["tests.package.count", "tests.app.count"], ("tests", .higher, 0, 0)),
        (["tests.package.seconds", "tests.app.seconds"], ("s", .lower, 0.5, 5)),
        // Code health, no budgets yet. A count that grows is a regression; the percentages and line counts get
        // room to move, and the comment numbers are informational, so their tolerance is wide.
        (["code.duplication_percent"], ("%", .lower, 0.1, 0.1)),
        (["code.dead_declarations", "code.test_only_declarations"], ("declarations", .lower, 0, 0)),
        (["code.functions_over_ccn15"], ("functions", .lower, 0, 0)),
        (["code.max_ccn"], ("", .lower, 0, 0)),
        (["code.swift_lines"], ("lines", .lower, 0.05, 0)),
        (["comments.density_percent"], ("%", .lower, 0.5, 1)),
        (["comments.ruling_refs"], ("refs", .lower, 1, 20)),
    ]

    private static let byAffix: [(prefix: String, suffix: String, spec: Spec)] = [
        ("code.", ".duplication_percent", ("%", .lower, 0.1, 0.5)),
        ("code.", ".dead_declarations", ("declarations", .lower, 0, 0)),
        ("code.", ".test_only_declarations", ("declarations", .lower, 0, 0)),
        ("code.", ".functions_over_ccn15", ("functions", .lower, 0, 0)),
        // `editor.open.<kind>.p95_ms`: how long an editor panel takes to show its chrome.
        ("editor.open.", ".p95_ms", ("ms", .lower, 0.25, 3)),
        ("vision.", ".seconds", ("s", .lower, 0.3, 0.2)),
        ("edge.", ".seconds", ("s", .lower, 0.3, 0.2)),
        ("edge.", ".peak_rss_mb", ("MB", .lower, 0.25, 10)),
        ("edge.", ".psnr_db", ("dB", .higher, 0.03, 0)),
        ("edge.", ".ssim", ("", .higher, 0.01, 0)),
        // A fraction of the input's size: a creeping ratio means a codec stopped saving bytes.
        ("edge.", ".ratio", ("x", .lower, 0.1, 0.005)),
    ]

    /// Budgets live in the baseline file (`Metric.budget`), never here: a baseline update keeps them.
    public static func metric(named name: String, value: Double) -> Metric {
        let spec = exact.first { $0.names.contains(name) }?.spec
            ?? byAffix.first { name.hasPrefix($0.prefix) && name.hasSuffix($0.suffix) }?.spec
            ?? ("", .lower, 0.25, 0)
        return Metric(value: value, unit: spec.unit, better: spec.better, tolerance: spec.tolerance, slack: spec.slack)
    }
}

/// What `/usr/bin/time -l` reports about a run.
public struct TimeReport: Equatable, Sendable {
    public var seconds: Double
    public var peakRSSMB: Double

    public init(seconds: Double, peakRSSMB: Double) {
        self.seconds = seconds
        self.peakRSSMB = peakRSSMB
    }

    /// Parses the stderr of `/usr/bin/time -l`: a line `1.23 real 0.50 user 0.10 sys` and a line
    /// `52428800  maximum resident set size` (bytes on macOS). nil when either is missing.
    public static func parse(_ text: String) -> TimeReport? {
        var seconds: Double?
        var bytes: Double?
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2, words[1] == "real", let value = Double(words[0]) { seconds = value }
            if line.hasSuffix("maximum resident set size"), let first = words.first, let value = Double(first) {
                bytes = value
            }
        }
        guard let seconds, let bytes else { return nil }
        return TimeReport(seconds: seconds, peakRSSMB: bytes / 1_048_576)
    }
}

public enum Percentile {
    /// The value at fraction `p` (0...1) of `values` by linear interpolation; 0 for an empty list.
    public static func of(_ p: Double, in values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

/// The outputs of `Pomelo --eval-launch`, one file per launch.
public enum LaunchMeasurement {
    /// `url` lists one output path per line; gives `app.launch.p50_ms` and `app.launch.p95_ms`.
    public static func metrics(samplesList url: URL) throws -> [String: Double] {
        struct Sample: Decodable { var launchMs: Double }
        let paths = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        // No samples would read as a 0 ms launch, which no baseline could catch.
        guard !paths.isEmpty else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        let samples = try paths.map {
            try JSONDecoder().decode(Sample.self, from: Data(contentsOf: URL(fileURLWithPath: $0))).launchMs
        }
        return ["app.launch.p50_ms": Percentile.of(0.5, in: samples), "app.launch.p95_ms": Percentile.of(0.95, in: samples)]
    }
}
