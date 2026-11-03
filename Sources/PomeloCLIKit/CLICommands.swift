import Foundation
import PomeloCore

public struct CLIOutput: Sendable, Equatable {
    /// Everything the command prints, without a trailing newline.
    public var stdout: String
    public var exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

/// The logic behind each `pomelo` subcommand. Pure of process state: it returns what to print and the exit code.
///
/// Exit codes: 0 success; 1 at least one file failed or was cancelled, or `routes` found no route; 2 usage error
/// (including an `--output-dir` that does not exist or is not a folder).
public enum CLICommands {
    private static let formats = FormatRegistry.builtIn

    // MARK: - convert

    public static func convert(
        files: [URL], to target: String?, preset presetID: String?, options: String? = nil, outputDir: URL?,
        registry: EngineRegistry, downloads: URL, json: Bool, presets: [Preset] = Preset.builtIns
    ) async -> CLIOutput {
        var request: ConversionRequest
        let preset: Preset?
        switch makeRequest(files: files, to: target, preset: presetID, outputDir: outputDir, presets: presets) {
        case .success(let made): (request, preset) = made
        case .failure(let problem): return usageError(problem.reason, json: json)
        }
        if let problem = await applyOptions(options, to: &request, preset: preset, registry: registry) {
            return usageError(problem, json: json)
        }
        if let problem = outputFolderProblem(outputDir) { return usageError(problem, json: json) }

        let destinations = DestinationResolver(
            downloadsFolder: downloads, isWritable: { FileManager.default.isWritableFile(atPath: $0.path) }
        )
        let runner = JobRunner(registry: registry, destinations: destinations)
        let results = await runner.run(request)
        let exitCode: Int32 = results.allSatisfy { if case .succeeded = $0 { true } else { false } } ? 0 : 1

        if json {
            return CLIOutput(stdout: CLIJSON.string(CLIConvertJSON(results: results.map(fileResultJSON))), exitCode: exitCode)
        }
        return CLIOutput(stdout: results.map(humanLine).joined(separator: "\n"), exitCode: exitCode)
    }

    /// The request for `--to` or `--preset`, with the preset it came from.
    private static func makeRequest(
        files: [URL], to target: String?, preset presetID: String?, outputDir: URL?, presets: [Preset]
    ) -> Result<(ConversionRequest, Preset?), OptionsProblem> {
        if files.isEmpty { return .failure(OptionsProblem(reason: "No files given")) }
        if target != nil && presetID != nil { return .failure(OptionsProblem(reason: "Pass either --to or --preset, not both")) }
        let inputs = files.map(\.standardizedFileURL)
        if let target {
            guard let format = resolveFormat(target) else { return .failure(OptionsProblem(reason: "Unknown format: \(target)")) }
            return .success((ConversionRequest(inputs: inputs, target: format.id, outputFolder: outputDir), nil))
        }
        guard let presetID else { return .failure(OptionsProblem(reason: "Pass --to <format> or --preset <id>")) }
        guard let preset = presets.first(where: { $0.id == presetID }) else {
            let available = presets.map(\.id).joined(separator: ", ")
            return .failure(OptionsProblem(reason: "Unknown preset: \(presetID) (available: \(available))"))
        }
        var request = ConversionRequest.from(preset, inputs: inputs)
        request.outputFolder = outputDir
        return .success((request, preset))
    }

    /// Lays `--options` over the request's and settles what follows from them: an editor's input, the name suffix
    /// of target-size and translate, and the output format a tool's setting picks. The usage problem, if any.
    private static func applyOptions(
        _ options: String?, to request: inout ConversionRequest, preset: Preset?, registry: EngineRegistry
    ) async -> String? {
        if let options {
            switch overlay(options, onto: request.options) {
            case .success(let merged): request.options = merged
            case .failure(let problem): return "invalid --options: \(problem.reason)"
            }
        }
        guard let preset else { return nil }
        if preset.needsInput, request.options.edit == nil, request.options.targetBytes == nil {
            return "the \(preset.id) preset needs --options with \"edit\" or \"targetBytes\" (see docs/cli-json.md)"
        }
        if preset.operation == "target-size", let targetBytes = request.options.targetBytes {
            request.nameSuffix = TargetSize.nameSuffix(bytes: targetBytes)
        }
        if preset.operation == "translate" {
            request.nameSuffix = TranslationTarget.suffix(request.options.language)
        }
        guard let wanted = request.options.outputFormat else { return nil }
        // P159: a tool's setting picks its target among the formats its edges make, the same in the CLI, Shortcuts
        // and the wheel.
        let allowed = await outputFormats(of: preset, registry: registry)
        guard let format = resolveFormat(wanted.rawValue), allowed.contains(format.id) else {
            let choices = allowed.map(\.rawValue).sorted().joined(separator: ", ")
            return "the \(preset.id) preset can't make \(wanted)" + (choices.isEmpty ? "" : " (it makes: \(choices))")
        }
        request.target = format.id
        request.options.outputFormat = format.id
        return nil
    }

    private static func outputFolderProblem(_ outputDir: URL?) -> String? {
        guard let outputDir else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDirectory) else {
            return "Output folder not found: \(outputDir.path)"
        }
        return isDirectory.boolValue ? nil : "Not a folder: \(outputDir.path)"
    }

    /// The formats a tool preset's operation edges produce, over every engine (an engine that can't run here fails
    /// the file with its reason later). A conversion preset has no choice to make.
    private static func outputFormats(of preset: Preset, registry: EngineRegistry) async -> Set<FormatID> {
        guard let operation = preset.operation else { return [] }
        return await registry.planner(includingMissing: true).targets(ofOperation: operation)
    }

    /// A usage error's sentence.
    private struct OptionsProblem: Error {
        var reason: String
    }

    /// `base` with the top-level keys of the JSON object `given` laid over it; the merge is decoded as
    /// `PresetOptions`, which is what validates an edit.
    private static func overlay(_ given: String, onto base: PresetOptions) -> Result<PresetOptions, OptionsProblem> {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(given.utf8)) else {
            return .failure(OptionsProblem(reason: "not valid JSON"))
        }
        guard let overrides = parsed as? [String: Any] else {
            return .failure(OptionsProblem(reason: "expected a JSON object"))
        }
        do {
            let encoded = try JSONEncoder().encode(base)
            var merged = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            for (key, value) in overrides { merged[key] = value }
            let data = try JSONSerialization.data(withJSONObject: merged)
            let options = try JSONDecoder().decode(PresetOptions.self, from: data)
            if let bytes = options.targetBytes, bytes <= 0 {
                return .failure(OptionsProblem(reason: "targetBytes must be more than 0"))
            }
            return .success(options)
        } catch let error as DecodingError {
            return .failure(OptionsProblem(reason: describe(error)))
        } catch {
            return .failure(OptionsProblem(reason: "could not be read"))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : " at \(path)"
        }
        switch error {
        case .dataCorrupted(let context): return context.debugDescription
        case .keyNotFound(let key, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "missing \"\(key.stringValue)\"" + (path.isEmpty ? "" : " in \(path)")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type" + location(context)
        @unknown default: return "could not be read"
        }
    }

    private static func fileResultJSON(_ result: FileResult) -> CLIFileResultJSON {
        switch result {
        case .succeeded(let source, let outputs, let note):
            CLIFileResultJSON(
                source: source.path, status: .succeeded, outputs: outputs.map(\.path),
                note: note.map(noteName), error: nil
            )
        case .failed(let source, let error):
            CLIFileResultJSON(source: source.path, status: .failed, outputs: [], note: nil, error: error.description)
        case .cancelled(let source):
            CLIFileResultJSON(source: source.path, status: .cancelled, outputs: [], note: nil, error: nil)
        }
    }

    private static func noteName(_ note: ResultNote) -> String {
        switch note {
        case .fellBackToDownloads: "fellBackToDownloads"
        case .replacedOriginal: "replacedOriginal"
        }
    }

    private static func humanLine(_ result: FileResult) -> String {
        switch result {
        case .succeeded(let source, let outputs, let note):
            let names = outputs.map(\.lastPathComponent).joined(separator: ", ")
            let suffix = note == .fellBackToDownloads ? " (saved to Downloads — source folder not writable)" : ""
            return "✓ \(source.lastPathComponent) → \(names)\(suffix)"
        case .failed(let source, let error):
            return "✗ \(source.lastPathComponent): \(error)"
        case .cancelled(let source):
            return "↩︎ \(source.lastPathComponent): cancelled"
        }
    }

    // MARK: - targets

    public static func targets(file: URL, registry: EngineRegistry, json: Bool) async -> CLIOutput {
        guard let sourceFormat = formats.format(for: file) else {
            let name = file.pathExtension.isEmpty ? file.lastPathComponent : file.pathExtension
            return usageError("Unknown format: \(name)", json: json)
        }
        let planner = await registry.planner()
        let entries = planner.reachableTargets(from: sourceFormat.id)
            .map { id, route in
                (category: formats.format(id: id)?.category ?? .other, id: id, route: route)
            }
            .sorted { ($0.category.rawValue, $0.id.rawValue) < ($1.category.rawValue, $1.id.rawValue) }

        if json {
            let targets = entries.map { entry in
                CLITargetJSON(
                    format: entry.id.rawValue, category: entry.category.rawValue, hops: entry.route.edges.count,
                    engines: entry.route.edges.map(\.engineID.rawValue), flags: flagNames(entry.route.flags)
                )
            }
            let payload = CLITargetsJSON(source: file.standardizedFileURL.path, targets: targets)
            return CLIOutput(stdout: CLIJSON.string(payload), exitCode: 0)
        }

        if entries.isEmpty {
            return CLIOutput(stdout: "No conversions available for \(file.lastPathComponent)", exitCode: 0)
        }
        var lines: [String] = []
        var currentCategory: FormatCategory?
        for entry in entries {
            if entry.category != currentCategory {
                currentCategory = entry.category
                lines.append("\(entry.category.rawValue):")
            }
            let hops = entry.route.edges.count
            let via = entry.route.edges.map(\.engineID.rawValue).joined(separator: " → ")
            var line = "  \(entry.id)  (\(hops) \(hops == 1 ? "hop" : "hops") via \(via))"
            if entry.route.flags.contains(.lossy) { line += " [lossy]" }
            if entry.route.flags.contains(.layoutRisk) { line += " [layout may shift]" }
            lines.append(line)
        }
        return CLIOutput(stdout: lines.joined(separator: "\n"), exitCode: 0)
    }

    private static func flagNames(_ flags: EdgeFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.lossy) { names.append("lossy") }
        if flags.contains(.layoutRisk) { names.append("layoutRisk") }
        if flags.contains(.directOnly) { names.append("directOnly") }
        return names
    }

    // MARK: - engines

    public static func engines(registry: EngineRegistry, json: Bool, pluginFailures: [URL] = []) async -> CLIOutput {
        let statuses = await registry.statuses()
        if json {
            let engines = statuses.map { status in
                switch status.availability {
                case .available(let version):
                    CLIEngineJSON(id: status.id.rawValue, name: status.displayName, status: .available, version: version, install: nil)
                case .missing(let hint):
                    CLIEngineJSON(id: status.id.rawValue, name: status.displayName, status: .missing, version: nil, install: hint)
                case .unsupported(let reason):
                    CLIEngineJSON(id: status.id.rawValue, name: status.displayName, status: .unsupported, version: nil,
                                  install: nil, reason: reason)
                }
            }
            let payload = CLIEnginesJSON(engines: engines, pluginErrors: pluginFailures.map(\.path))
            return CLIOutput(stdout: CLIJSON.string(payload), exitCode: 0)
        }

        var lines = statuses.map { status in
            let state: String
            switch status.availability {
            case .available(let version): state = version.map { "available \($0)" } ?? "available"
            case .missing(let hint): state = "missing — \(hint)"
            case .unsupported(let reason): state = "unsupported: \(reason)"
            }
            return "\(status.id)  \(status.displayName)  \(state)"
        }
        lines += pluginFailures.map { "⚠︎ Could not load plugin: \($0.path)" }
        return CLIOutput(stdout: lines.joined(separator: "\n"), exitCode: 0)
    }

    // MARK: - routes

    public static func routes(from: String, to: String, registry: EngineRegistry, json: Bool) async -> CLIOutput {
        guard let source = resolveFormat(from) else { return usageError("Unknown format: \(from)", json: json) }
        guard let target = resolveFormat(to) else { return usageError("Unknown format: \(to)", json: json) }
        let planner = await registry.planner()
        let route = planner.route(from: source.id, to: target.id)

        if json {
            let payload = CLIRoutesJSON(
                from: source.id.rawValue, to: target.id.rawValue, cost: route?.totalCost,
                steps: route?.edges.map {
                    CLIRouteStepJSON(from: $0.from.rawValue, to: $0.to.rawValue, engine: $0.engineID.rawValue)
                } ?? []
            )
            return CLIOutput(stdout: CLIJSON.string(payload), exitCode: route == nil ? 1 : 0)
        }
        guard let route else {
            return CLIOutput(stdout: "No route from \(source.id) to \(target.id)", exitCode: 1)
        }
        let via = route.edges.map(\.engineID.rawValue).joined(separator: " → ")
        return CLIOutput(stdout: "\(source.id) → \(target.id) via \(via) (cost \(route.totalCost))", exitCode: 0)
    }

    // MARK: - Shared

    /// A format id or any of its extension aliases (`jpeg` is `jpg`), with or without a leading dot.
    private static func resolveFormat(_ name: String) -> FileFormat? {
        let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
        return formats.format(forExtension: trimmed) ?? formats.format(id: FormatID(trimmed))
    }

    private static func usageError(_ message: String, json: Bool) -> CLIOutput {
        CLIOutput(stdout: json ? CLIJSON.string(CLIErrorJSON(error: message)) : message, exitCode: 2)
    }
}
