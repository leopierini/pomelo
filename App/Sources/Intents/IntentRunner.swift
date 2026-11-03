// Runs what Shortcuts asks for through the unattended job path (P106): no pill, no sound, Finder's progress only,
// never replacing an original. A failure on any file throws one sentence; the outputs already published stay
// next to their sources (P104). A file the work doesn't apply to is handed back unchanged (P120).
import AppIntents
import Foundation
import PomeloCore
import PomeloUIModel

enum IntentRunError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noFiles
    /// The format's name, as the person would read it.
    case unknownFormat(String)
    /// The tool's name, or the id Shortcuts sent when Pomelo knows no such tool.
    case unknownTool(String)
    /// `IntentCatalog.failureMessage` of the job's summary.
    case failed(String)
    /// The DEBUG PomeloTrace copy records drags and nothing else (S34.1).
    case recorderCopy

    var message: String {
        switch self {
        case .noFiles: "Choose at least one file."
        case .unknownFormat(let name): "Pomelo can't make \(name) files."
        case .unknownTool(let name): "Pomelo has no tool called \(name)."
        case .failed(let message): message
        case .recorderCopy: "PomeloTrace only records drags."
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
final class IntentRunner {
    private let registry: EngineRegistry
    private let settings: SettingsStore
    private let runJob: @MainActor (ConversionRequest, String) async -> [FileResult]
    /// Where files that reach an intent as data alone are written, so they have a folder for their outputs.
    let workFolder: URL
    private let refusesWork: Bool

    /// `run` is `JobCoordinator.runUnattended` in the app.
    init(
        registry: EngineRegistry, settings: SettingsStore,
        run: @escaping @MainActor (ConversionRequest, String) async -> [FileResult], workFolder: URL,
        refusesWork: Bool = false
    ) {
        self.refusesWork = refusesWork
        self.registry = registry
        self.settings = settings
        self.runJob = run
        self.workFolder = workFolder
    }

    /// The formats the installed engines can make now: asked of the registry, never of the wheel's content, so an
    /// intent arriving while the app is still starting gets the answer.
    func targetFormats() async -> [FileFormat] {
        IntentCatalog.targetFormats(formats: .builtIn, planner: await registry.planner())
    }

    func tools() -> [Preset] {
        IntentCatalog.tools(settings: settings.settings)
    }

    /// Converts `files` to `target`. P105 (P14): a file already in `target` is passed on as it is, not copied.
    func convert(_ files: [URL], to target: FormatID) async throws -> [URL] {
        guard !files.isEmpty else { throw IntentRunError.noFiles }
        let formats = FormatRegistry.builtIn
        guard formats.format(id: target) != nil else {
            throw IntentRunError.unknownFormat(target.rawValue.uppercased())
        }
        let toConvert = files.filter { formats.format(for: $0)?.id != target }
        guard !toConvert.isEmpty else { return files }
        let request = ConversionRequest(inputs: toConvert, target: target)
        let results = Self.passingThrough(await runJob(request, "Converting"))
        try Self.throwIfFailed(results, summary: ResultSummary.make(results: results))
        // The results are in the order of `toConvert`.
        var converted = results.makeIterator()
        return files.flatMap { file in
            formats.format(for: file)?.id == target ? [file] : converted.next().map(Self.outputs) ?? []
        }
    }

    /// Runs the tool `toolID` on `files`. A combine takes them in the order given: Shortcuts' order is the person's.
    func run(toolID: String, on files: [URL]) async throws -> [URL] {
        guard !files.isEmpty else { throw IntentRunError.noFiles }
        guard let preset = tools().first(where: { $0.id == toolID }) else {
            throw IntentRunError.unknownTool(Self.toolName(toolID))
        }
        var request = ConversionRequest.from(preset, inputs: files)
        request.replaceOriginal = false
        let verb = ToolCatalog.info(preset.id)?.verb ?? preset.name
        let results = Self.passingThrough(await runJob(request, verb))
        let summary = ResultSummary.make(
            results: results, of: request, tool: ToolCatalog.info(preset.id)?.name ?? preset.name
        )
        try Self.throwIfFailed(results, summary: summary)
        // Every file of a combine reports the one output (or, passed through, its own source).
        return Self.unique(results.flatMap(Self.outputs))
    }

    /// Runs `work` on an intent's files and hands its outputs back to Shortcuts. A URL Shortcuts passes may be
    /// security-scoped: it is opened for the job and closed after.
    func perform(on files: [IntentFile], _ work: ([URL]) async throws -> [URL]) async throws -> [IntentFile] {
        if refusesWork { throw IntentRunError.recorderCopy }
        let scoped = files.compactMap(\.fileURL).filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        // Off the main actor: a file handed over as data can be a large video, and a drag starting meanwhile must
        // open the wheel within 50 ms.
        let folder = workFolder
        let inputs = try await Task.detached(priority: .userInitiated) {
            try Self.inputs(from: files, workFolder: folder)
        }.value
        let outputs = try await work(inputs)
        return outputs.map { url in
            IntentFile(fileURL: url, filename: url.lastPathComponent,
                       type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        }
    }

    /// The files an intent received, as URLs a job can take. A file Shortcuts passes as data alone (from another
    /// app, or made by an earlier action) is written into a fresh folder of Pomelo's own, so its outputs land there;
    /// a name without an extension takes its type's, since jobs find a file's format by its extension.
    nonisolated static func inputs(from files: [IntentFile], workFolder: URL) throws -> [URL] {
        try files.map { file in
            if let url = file.fileURL { return url }
            let folder = workFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var name = safeName(file.filename)
            if (name as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension {
                name += "." + ext
            }
            let url = folder.appending(path: name, directoryHint: .notDirectory)
            try file.data.write(to: url, options: .withoutOverwriting)
            return url
        }
    }

    // MARK: - Private

    /// The name's last component only, so a name such as `../x.png` stays in its folder.
    private nonisolated static func safeName(_ filename: String) -> String {
        let name = (filename as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." || name == "/" ? "File" : name
    }

    /// P120: work that doesn't apply to a file ("Already compressed") is no failure: the file is handed back as it
    /// is, at its place, as P105 passes on a file already in the target. Matched on the case, never the text (M5).
    private static func passingThrough(_ results: [FileResult]) -> [FileResult] {
        results.map { result in
            guard case .failed(let source, .notApplicable) = result else { return result }
            return .succeeded(source: source, outputs: [source], note: nil)
        }
    }

    private static func throwIfFailed(_ results: [FileResult], summary: ResultSummary) throws {
        guard results.contains(where: { if case .failed = $0 { true } else { false } }) else { return }
        throw IntentRunError.failed(IntentCatalog.failureMessage(summary))
    }

    /// A cancelled file has no outputs, and is no failure either.
    private static func outputs(of result: FileResult) -> [URL] {
        if case .succeeded(_, let outputs, _) = result { outputs } else { [] }
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    /// An editor's name without its ellipsis ("Trim", not "Trim…"), else the id itself.
    private static func toolName(_ id: String) -> String {
        guard let name = ToolCatalog.info(id)?.name else { return id }
        return name.hasSuffix("\u{2026}") ? String(name.dropLast()) : name
    }
}
