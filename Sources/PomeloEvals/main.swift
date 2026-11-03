import ArgumentParser
import Foundation
import PomeloEvalsKit

struct PomeloEvals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pomelo-evals",
        abstract: "Pomelo's measurement harness: corpus, edge cases, results and the comparison with the baseline.",
        subcommands: [CorpusCommand.self, EdgesCommand.self, DetectCommand.self, BundleCommand.self, AuditCommand.self, AccessibilityLintCommand.self, ResultsCommand.self, CompareCommand.self]
    )
}

struct CorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "corpus", abstract: "Write the evals corpus into a folder, skipping files already there.")

    @Argument(help: "The corpus folder.") var directory: String

    func run() async throws {
        let written = try await PomeloEvalsKit.Corpus.write(to: URL(fileURLWithPath: directory, isDirectory: true))
        print(written.isEmpty ? "corpus up to date" : "wrote \(written.joined(separator: ", "))")
    }
}

struct EdgesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edges", abstract: "Run the edge cases through the CLI and check their outputs.")

    @Option(help: "The pomelo executable.") var cli: String
    @Option(help: "The corpus folder.") var corpus: String
    @Option(help: "The cases file (evals/edges.json).") var cases: String
    @Option(help: "Where to write the edges' results JSON.") var out: String

    func run() async throws {
        let runner = EdgeRunner(cli: URL(fileURLWithPath: cli), corpus: URL(fileURLWithPath: corpus, isDirectory: true))
        let results = await runner.run(try EvalCase.load(from: URL(fileURLWithPath: cases)))
        try results.write(to: URL(fileURLWithPath: out))
        for check in results.checks { print("\(check.ok ? "ok    " : "FAILED") \(check.name) \(check.detail)") }
        for name in results.skipped { print("skipped \(name)") }
    }
}

struct DetectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect", abstract: "Time the redaction detector on corpus pictures; prints name=value lines."
    )

    @Option(help: "The corpus folder.") var corpus: String

    func run() async throws {
        let metrics = try await DetectTiming.measure(corpus: URL(fileURLWithPath: corpus, isDirectory: true))
        for (name, value) in metrics.sorted(by: { $0.key < $1.key }) { print("\(name)=\(value)") }
    }
}

struct BundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Check the structure of a built app bundle: architectures, signature, entitlements, appex, App Intents, weak links, linked SDK."
    )

    @Option(help: "The built .app.") var app: String
    @Option(help: "The folder with Pomelo.entitlements and PomeloQuickAction.entitlements (App/).") var entitlements: String
    @Option(help: "The built pomelo executable, checked for its linked SDK too.") var cli: String?
    @Option(help: "Where to write the checks as a results JSON.") var out: String
    @Option(help: "The build's configuration: release, or debug (which may carry get-task-allow).")
    var configuration: BundleCheck.Configuration = .release

    func run() throws {
        let checks = BundleCheck.run(
            app: URL(fileURLWithPath: app, isDirectory: true),
            expectedEntitlements: URL(fileURLWithPath: entitlements, isDirectory: true),
            configuration: configuration,
            cli: cli.map { URL(fileURLWithPath: $0) }
        )
        try EvalResults(date: ISO8601DateFormatter().string(from: Date()), checks: checks).write(to: URL(fileURLWithPath: out))
        for check in checks { print("\(check.ok ? "ok    " : "FAILED") \(check.name) \(check.detail)") }
    }
}

struct AuditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Turn the reports of Periphery, jscpd and lizard, and a count of the comments, into code-health metrics.",
        discussion: "A report that is not given skips its metrics. evals/audit.sh runs the tools and calls this."
    )

    @Option(help: "Periphery's JSON report (tests indexed).") var periphery: String?
    @Option(help: "Periphery's JSON report with the tests left out of the index.") var peripheryWithoutTests: String?
    @Option(help: "jscpd's JSON report.") var jscpd: String?
    @Option(help: "lizard's CSV report.") var lizard: String?
    @Option(help: "A folder of Swift sources. Repeatable.") var sources: [String]
    @Option(help: "Where to write the metrics as a results JSON.") var out: String
    @Option(help: "Where to write the findings as text.") var report: String?

    func run() throws {
        func data(_ path: String?) throws -> Data? { try path.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } }
        let outcome = try Audit.run(Audit.Inputs(
            periphery: try data(periphery), peripheryWithoutTests: try data(peripheryWithoutTests), jscpd: try data(jscpd),
            lizardCSV: try lizard.map { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) },
            sourceDirectories: sources.map { URL(fileURLWithPath: $0, isDirectory: true) }))
        try outcome.results.write(to: URL(fileURLWithPath: out))
        if let report { try outcome.report.write(to: URL(fileURLWithPath: report), atomically: true, encoding: .utf8) }
        // Per-module numbers are in the file; the terminal gets the totals.
        for (name, value) in outcome.results.metrics.sorted(by: { $0.key < $1.key }) where name.filter({ $0 == "." }).count == 1 {
            print("\(name)=\(value)")
        }
        for name in outcome.results.skipped.sorted() { print("skipped \(name)") }
    }
}

struct AccessibilityLintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "a11y-lint",
        abstract: "Find SwiftUI controls and images VoiceOver would read badly (an icon-only button, an unlabeled image).",
        discussion: "A heuristic over the source; `// a11y: <why>` on the line or the line before silences a finding."
    )

    @Option(parsing: .upToNextOption, help: "Folders of Swift sources.") var sources: [String]
    @Option(help: "Where to write {\"findings\", \"count\"} as JSON.") var out: String?

    struct Report: Codable {
        var findings: [AccessibilityLint.Finding]
        var count: Int
    }

    func run() throws {
        let findings = try AccessibilityLint.run(sources: sources.map { URL(fileURLWithPath: $0, isDirectory: true) })
        for finding in findings { print("\(finding.file):\(finding.line) \(finding.rule.rawValue) \(finding.snippet)") }
        print("count=\(findings.count)")
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(findings: findings, count: findings.count)).write(to: URL(fileURLWithPath: out))
        }
    }
}

struct ResultsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "results",
        abstract: "Merge the pieces of one harness run into a results file.",
        discussion: "The wheel numbers come from the signpost export when it holds samples, otherwise from the app's own clock."
    )

    @Option(help: "Where to write the results JSON.") var out: String
    @Option(help: "The edges' results JSON.") var edges: String?
    @Option(help: "The app's --eval-wheel-open output.") var wheelHook: String?
    @Option(help: "The app's --eval-wheel-open output for a customized wheel (its own clock).") var customWheelHook: String?
    @Option(help: "The xctrace export of the os-signpost interval table.") var signpostExport: String?
    @Option(help: "The app's --eval-idle output.") var idle: String?
    @Option(help: "The bundle check's results JSON.") var bundle: String?
    @Option(help: "The audit's results JSON (metrics and skipped).") var audit: String?
    @Option(help: "A file listing the app's --eval-launch outputs, one path per line.") var launchSamples: String?
    @Option(help: "quick or full: a full run must measure every budgeted metric (compare reports the missing ones).")
    var mode: String?
    @Option(name: .customLong("metric"), help: "An extra metric, name=value. Repeatable.") var extraMetrics: [String] = []

    func run() throws {
        var results = EvalResults(date: ISO8601DateFormatter().string(from: Date()))
        if let mode {
            guard ["quick", "full"].contains(mode) else { throw ValidationError("--mode expects quick or full, got \(mode)") }
            results.meta[EvalResults.modeKey] = mode
        }
        if let edges {
            let part = try EvalResults.load(from: URL(fileURLWithPath: edges))
            results.metrics.merge(part.metrics) { $1 }
            results.checks += part.checks
            results.skipped += part.skipped
        }
        if let bundle {
            results.checks += try EvalResults.load(from: URL(fileURLWithPath: bundle)).checks
        }
        if let audit {
            let part = try EvalResults.load(from: URL(fileURLWithPath: audit))
            results.metrics.merge(part.metrics) { $1 }
            results.skipped += part.skipped
        }
        if let wheelHook {
            let hook = try WheelMeasurement.load(hook: URL(fileURLWithPath: wheelHook))
            var wheel = hook
            var source = "hook"
            if let signpostExport,
               let exported = try? WheelMeasurement.load(signpostExport: URL(fileURLWithPath: signpostExport)) {
                wheel = exported
                source = "signpost"
            }
            results.metrics["wheel.open.p50_ms"] = wheel.p50Ms
            results.metrics["wheel.open.p95_ms"] = wheel.p95Ms
            results.meta["wheelSource"] = source
            results.meta["wheelSamples"] = String(wheel.count)
        }
        if let customWheelHook {
            let custom = try WheelMeasurement.load(hook: URL(fileURLWithPath: customWheelHook))
            results.metrics["wheel.open_custom.p50_ms"] = custom.p50Ms
            results.metrics["wheel.open_custom.p95_ms"] = custom.p95Ms
        }
        if let idle {
            let sample = try IdleMeasurement.load(URL(fileURLWithPath: idle))
            results.metrics["app.idle.cpu_percent"] = sample.cpuPercent
            results.metrics["app.idle.wakeups_per_s"] = sample.wakeupsPerSecond
            results.metrics["app.idle.footprint_mb"] = sample.footprintMB
        }
        if let launchSamples {
            results.metrics.merge(try LaunchMeasurement.metrics(samplesList: URL(fileURLWithPath: launchSamples))) { $1 }
        }
        for pair in extraMetrics {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else {
                throw ValidationError("--metric expects name=value, got \(pair)")
            }
            results.metrics[String(parts[0])] = value
        }
        try results.write(to: URL(fileURLWithPath: out))
    }
}

struct CompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare a results file with the baseline.",
        discussion: "Exit 0: no regression. Exit 1: a regression or a failed check, each printed on its own line. Exit 2: usage error."
    )

    @Option(help: "The results JSON.") var results: String
    @Option(help: "The baseline JSON (evals/baseline.json).") var baseline: String
    @Flag(help: "Rewrite the baseline with this run's values and the default tolerances.") var updateBaseline = false

    func run() throws {
        let resultsURL = URL(fileURLWithPath: results)
        let baselineURL = URL(fileURLWithPath: baseline)
        let loaded: EvalResults
        do { loaded = try EvalResults.load(from: resultsURL) } catch {
            throw usage("cannot read results at \(results): \(error)")
        }
        let current: Baseline
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            do { current = try Baseline.load(from: baselineURL) } catch { throw usage("cannot read baseline at \(baseline): \(error)") }
        } else if updateBaseline {
            current = Baseline()
        } else {
            throw usage("no baseline at \(baseline); create it with --update-baseline")
        }
        let report = PomeloEvalsKit.Compare.run(results: loaded, baseline: current)
        report.lines.forEach { print($0) }
        if updateBaseline {
            // Never baseline a failed check, a value over its budget or a budgeted metric the run lost.
            guard !report.blocksBaselineUpdate else {
                print("not updating the baseline: a check failed, a value is over its budget or a budgeted metric is missing")
                throw ExitCode(1)
            }
            try PomeloEvalsKit.Compare.updated(current, with: loaded).write(to: baselineURL)
            print("baseline updated")
            return
        }
        print(report.exitCode == 0 ? "no regression" : "regression")
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }

    private func usage(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return ExitCode(2)
    }
}

/// Like ArgumentParser's own `main()`, except that every usage error exits 2.
func runEvals() async {
    do {
        var command = try PomeloEvals.parseAsRoot()
        if var asyncCommand = command as? any AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    } catch {
        if PomeloEvals.exitCode(for: error) == .validationFailure {
            FileHandle.standardError.write(Data((PomeloEvals.fullMessage(for: error) + "\n").utf8))
            exit(2)
        }
        PomeloEvals.exit(withError: error)
    }
}

await runEvals()

extension BundleCheck.Configuration: ExpressibleByArgument {}
