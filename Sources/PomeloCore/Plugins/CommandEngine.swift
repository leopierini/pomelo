import Foundation

/// A `ConversionEngine` driven by a `PluginManifest`: it runs the external tool directly (no shell) with the
/// edge's argument template expanded inside single argv elements.
public struct CommandEngine: ConversionEngine {
    public static let defaultVersionProbeTimeout: Duration = .seconds(5)

    private let manifest: PluginManifest
    private let locator: ExecutableLocator
    private let runner: ProcessRunner
    private let registry: FormatRegistry
    private let versionProbeTimeout: Duration

    /// `versionProbeTimeout` is how long the version command may stay silent; tests that run under load raise it.
    public init(
        manifest: PluginManifest, locator: ExecutableLocator, runner: ProcessRunner = .init(),
        registry: FormatRegistry = .builtIn, versionProbeTimeout: Duration = CommandEngine.defaultVersionProbeTimeout
    ) {
        self.versionProbeTimeout = versionProbeTimeout
        self.manifest = manifest
        self.locator = locator
        self.runner = runner
        self.registry = registry
    }

    public var id: EngineID { EngineID(manifest.id) }
    public var displayName: String { manifest.displayName }
    public var maxConcurrentJobs: Int { manifest.maxConcurrentJobs ?? 2 }

    public func edges() -> [ConversionEdge] { manifest.conversionEdges(registry: registry) }

    /// Only the locate: running the version command here cost every CLI call 50 ms and Pandoc's 37 MB (P143).
    public func availability() async -> EngineAvailability {
        guard locator.locate(manifest.executable, pluginID: manifest.id) != nil else {
            return .missing(installHint: installHint)
        }
        return .available(version: nil)
    }

    public func version() async -> String? {
        guard let executable = locator.locate(manifest.executable, pluginID: manifest.id),
              let versionArguments = manifest.executable.versionArguments else { return nil }
        let probe = ProcessRunner(timeout: versionProbeTimeout)
        guard let result = try? await probe.run(executable: executable, arguments: versionArguments) else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let executable = locator.locate(manifest.executable, pluginID: manifest.id) else {
            throw ConversionError.converterUnavailable(engine: id, message: "executable not found")
        }
        guard let edge = manifest.edge(from: step.from.id, to: step.to.id, operation: step.operation, registry: registry) else {
            throw ConversionError.converterFault(
                engine: id, message: "no conversion from \(step.from.id) to \(step.to.id)"
            )
        }

        let fileManager = FileManager.default
        let tempDir = step.stagingDirectory.appending(path: ".tmp", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // With `{output}` the tool writes exactly there; with `{outputDir}` it must name its file by the same
        // convention (`<stem>.<extension>`). A folder edge's result is instead the `{outputFolder}` made here.
        let output = step.suggestedOutput
        // A percent-encoded `file://` URL ending in `/`, for tools that take a URL rather than a path (LibreOffice's
        // `-env:UserInstallation`); staging paths contain spaces ("(A Document Being Saved By ...)").
        let tempDirURL = tempDir.absoluteString.hasSuffix("/") ? tempDir.absoluteString : tempDir.absoluteString + "/"
        var values = [
            "input": step.input.path,
            "output": output.path,
            "outputDir": step.stagingDirectory.path,
            "tempDir": tempDir.path,
            "tempDirURL": tempDirURL,
            "inputStem": OutputNamer.stem(of: step.input),
        ]
        let folder = step.suggestedFolder
        let produced = edge.producesFolder ? folder : output
        if edge.producesFolder {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            values["outputFolder"] = folder.path
        }
        let arguments: [String]
        do {
            arguments = try ArgumentTemplate.expand(edge.arguments, values: values, options: step.options)
        } catch TemplateError.unresolved(let key) {
            if edge.producesFolder { try? fileManager.removeItem(at: folder) }
            throw ConversionError.converterFault(engine: id, message: "unresolved placeholder {\(key)}")
        }

        // A manifest's own timeout replaces the runner's default for conversions (not for the version probe).
        let conversionRunner = manifest.timeoutSeconds.map { ProcessRunner(timeout: .seconds($0)) } ?? runner
        do {
            _ = try await conversionRunner.run(executable: executable, arguments: arguments)
            if edge.producesFolder { try checkFolder(folder, in: step.stagingDirectory) }
            guard Self.hasContent(produced, folder: edge.producesFolder) else {
                throw ConversionError.converterFault(engine: id, message: "produced no output")
            }
        } catch {
            if edge.producesFolder { StagedFolder.openFolders(under: folder) }
            try? fileManager.removeItem(at: produced)
            throw map(error)
        }
        return produced
    }

    /// P62: the same walk as an extracted archive's (unar's `{outputFolder}` is one).
    private func checkFolder(_ folder: URL, in staging: URL) throws {
        StagedFolder.openFolders(under: folder)
        switch StagedFolder.containment(of: folder, in: staging) {
        case .inside: return
        case .outside:
            throw ConversionError.converterFault(engine: id, message: "an item it made is outside its staging folder")
        case .unreadable(let path):
            throw ConversionError.engineFailed(engine: id, message: "cannot read the produced \(path)")
        }
    }

    private static func hasContent(_ url: URL, folder: Bool) -> Bool {
        guard folder else { return FileManager.default.fileExists(atPath: url.path) }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }

    private var installHint: String {
        if let formula = manifest.install.homebrew { return "brew install \(formula)" }
        if let website = manifest.install.website { return website }
        return "Install \(manifest.displayName)"
    }

    private func map(_ error: any Error) -> any Error {
        guard let error = error as? ProcessRunnerError else { return error }
        switch error {
        case .nonZeroExit(let code, let stderrTail):
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversionError.engineFailed(
                engine: id, message: tail.isEmpty ? "exited with code \(code)" : "exited with code \(code): \(tail)"
            )
        case .timedOut:
            return ConversionError.converterTimedOut(engine: id)
        case .launchFailed(let code):
            return ConversionError.converterUnavailable(
                engine: id, message: "could not launch: \(String(cString: strerror(code)))"
            )
        }
    }
}
