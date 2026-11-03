import Foundation
import PomeloTestSupport

/// Runs each case through the CLI under `/usr/bin/time -l` and checks what it produced.
public struct EdgeRunner: Sendable {
    public var cli: URL
    public var corpus: URL
    /// A case that runs longer is killed and fails.
    public var timeout: TimeInterval = 600

    public init(cli: URL, corpus: URL) {
        self.cli = cli
        self.corpus = corpus
    }

    public func run(_ cases: [EvalCase]) async -> EvalResults {
        var results = EvalResults()
        for evalCase in cases {
            if let missing = evalCase.requires?.first(where: { !Installed.has($0) }) {
                results.skipped.append("edge.\(evalCase.name) (needs \(missing))")
                continue
            }
            await run(evalCase, into: &results)
        }
        return results
    }

    private func run(_ evalCase: EvalCase, into results: inout EvalResults) async {
        let prefix = "edge.\(evalCase.name)"
        func fail(_ detail: String) { results.checks.append(.init(name: "\(prefix).ok", ok: false, detail: detail)) }

        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appending(path: "pomelo-evals-\(UUID().uuidString)", directoryHint: .isDirectory)
        let outputs = folder.appending(path: "outputs", directoryHint: .isDirectory)
        do { try manager.createDirectory(at: outputs, withIntermediateDirectories: true) } catch {
            return fail("cannot create \(folder.path)")
        }
        defer { try? manager.removeItem(at: folder) }

        let input = corpus.appending(path: evalCase.input, directoryHint: .notDirectory)
        guard manager.fileExists(atPath: input.path) else { return fail("no corpus file \(evalCase.input)") }
        let more = (evalCase.moreInputs ?? []).map { corpus.appending(path: $0, directoryHint: .notDirectory) }
        if let absent = more.first(where: { !manager.fileExists(atPath: $0.path) }) {
            return fail("no corpus file \(absent.lastPathComponent)")
        }
        let arguments = arguments(for: evalCase, input: input, more: more, outputs: outputs)

        for _ in 0..<(evalCase.warmups ?? 0) {
            _ = launch(arguments: arguments, in: folder)
            try? manager.removeItem(at: outputs)
            try? manager.createDirectory(at: outputs, withIntermediateDirectories: true)
        }
        let launched = launch(arguments: arguments, in: folder)
        guard let launched else { return fail("cannot launch /usr/bin/time") }
        guard let report = TimeReport.parse(launched.stderr) else {
            return fail("no timing in the output of /usr/bin/time: \(launched.stderr.suffix(200))")
        }
        guard let output = Self.firstOutput(of: launched.stdout) else {
            return fail("the conversion produced no output: \(launched.stdout.prefix(300))")
        }
        var inspection = await OutputCheck.inspect(output)
        if evalCase.expect.frameCount != nil { inspection.videoFrames = OutputCheck.frameCount(output) }
        if evalCase.expect.imageTextContains != nil { inspection.imageText = OutputCheck.imageText(output) }
        var psnr: Double?
        if evalCase.expect.psnrMinDB != nil {
            psnr = OutputCheck.psnr(input, output)
            if let psnr { results.metrics["\(prefix).psnr_db"] = min(psnr, 100) }
        }
        var ssim: Double?
        if evalCase.expect.ssimMin != nil {
            ssim = OutputCheck.ssim(input, output)
            if let ssim { results.metrics["\(prefix).ssim"] = ssim }
        }
        if let ratio = Self.sizeRatio(of: output, to: input, extraInputs: more) { results.metrics["\(prefix).ratio"] = ratio }
        let failures = OutputCheck.failures(inspection, expect: evalCase.expect, psnr: psnr, ssim: ssim)
            + OutputCheck.markFailures(Self.outputs(of: launched.stdout), expect: evalCase.expect)
        results.metrics["\(prefix).seconds"] = report.seconds
        results.metrics["\(prefix).peak_rss_mb"] = report.peakRSSMB.rounded()
        results.checks.append(.init(name: "\(prefix).ok", ok: failures.isEmpty, detail: failures.joined(separator: "; ")))
    }

    /// The output's bytes over the input's, for a case that turns one file into one file; nil for a combine, a folder
    /// or an empty input.
    static func sizeRatio(of output: URL, to input: URL, extraInputs: [URL]) -> Double? {
        func fileBytes(_ url: URL) -> Int? {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true ? values?.fileSize : nil
        }
        guard extraInputs.isEmpty, let before = fileBytes(input), before > 0, let after = fileBytes(output) else { return nil }
        return Double(after) / Double(before)
    }

    func arguments(for evalCase: EvalCase, input: URL, more: [URL], outputs: URL) -> [String] {
        var arguments = ["-l", cli.path, "convert", input.path] + more.map(\.path) + ["-o", outputs.path, "--json"]
        if let to = evalCase.to { arguments += ["--to", to] } else if let preset = evalCase.preset {
            arguments += ["--preset", preset]
        }
        if let options = evalCase.options { arguments += ["--options", options.compactString] }
        return arguments
    }

    private func launch(arguments: [String], in folder: URL) -> (stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = arguments
        let stdoutURL = folder.appending(path: "stdout.txt")
        let stderrURL = folder.appending(path: "stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL), let stderr = try? FileHandle(forWritingTo: stderrURL)
        else { return nil }
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        try? stdout.close()
        try? stderr.close()
        return (
            (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
            (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        )
    }

    /// Every output of every succeeded result of `pomelo convert --json`, each once, in order (a combine lists its
    /// one output under every input).
    static func outputs(of json: String) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return [] }
        var seen: Set<String> = []
        return results.filter { $0["status"] as? String == "succeeded" }
            .flatMap { $0["outputs"] as? [String] ?? [] }
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The first output of the first result of `pomelo convert --json`, when that result succeeded.
    static func firstOutput(of json: String) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = (object["results"] as? [[String: Any]])?.first,
              result["status"] as? String == "succeeded",
              let path = (result["outputs"] as? [String])?.first
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
