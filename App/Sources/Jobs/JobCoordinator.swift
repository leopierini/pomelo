// Runs the slice the user chose: conversions and tools go through the Phase 1 `JobRunner`, file actions through
// `FileActions`. Jobs never wait for each other. Outputs appear next to their sources (P23); every finished job
// plays its sound when sounds are on, and failures are logged. Each job is listed in `jobs`, the progress pill's
// model (P25): while the wheel holds a job its hub shows the outcome, and whatever outcome the hub did not show
// (a failure or a note) becomes a pill. A long job's progress also shows on its sources in Finder, whose cancel
// button stops that file's work (P24); quitting stops every job's work. An unattended job (an intent, a watch folder)
// has Finder's indicators alone: no pill, no sound (P106).
import AppKit
import Combine
import Foundation
import PomeloCore
import PomeloUIModel
import os

/// How a job ended.
enum JobOutcome: Equatable, Sendable {
    /// Nothing failed (this includes "nothing to convert" and cancelled files).
    case succeeded
    /// Nothing failed, but the user should know something: codes were copied, or outputs went to Downloads.
    case noted(ResultSummary)
    /// At least one file failed; the summary says which and why, in a few words.
    case failed(ResultSummary)

    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

/// A job just started: its id in `JobCoordinator.jobs`, and its outcome for whoever waits for it (the wheel).
struct JobHandle {
    let id: UUID
    let outcome: Task<JobOutcome, Never>
}

private extension JobEvent {
    /// The input the event is about.
    var fileIndex: Int {
        switch self {
        case .fileStarted(let index), .progress(let index, _), .fileFinished(let index, _): index
        }
    }
}

@MainActor
final class JobCoordinator: ObservableObject {
    /// Every job not yet settled, oldest first: running, held, or a failure or note the pill shows.
    @Published private(set) var jobs: [PillJob] = []

    /// The wheel's content, used to skip files already in a convert slice's target format (P14).
    var contentBuilder: WheelContentBuilder?

    private let settings: SettingsStore
    private let runner: JobRunner
    /// Where a zip goes, as the runner decides for conversions.
    private let destinations: DestinationResolver
    /// Where the copy actions and read codes write; a parameter so tests never touch the user's clipboard.
    private let pasteboard: NSPasteboard
    /// Plays a system sound by name; a parameter so tests can record sounds instead of playing them.
    private let soundPlayer: @MainActor (NSSound.Name) -> Void
    /// Publishes the files' progresses to Finder; a parameter so tests never publish real ones (P16).
    private let progressPublisher: any FileProgressPublishing
    private let progressDelay: Duration
    private let noteStay: Duration
    /// Jobs' start times, the note's stay and the Finder progress delay run on it; the pill reads its time from it too.
    let clock: TimerClock
    /// Every indicator not yet retired, so none is left behind when the app quits.
    private var indicators: [ObjectIdentifier: FileProgressIndicator] = [:]
    /// How to cancel each job still running, unattended ones included, so quitting can stop them. A job leaves it as
    /// it ends, so a job in `jobs` but not here has ended.
    private var active: [UUID: @MainActor () -> Void] = [:]
    /// How to cancel each file of a running job, by index; a combine's or a zip's cancel the whole job.
    private var fileCancels: [UUID: [@MainActor () -> Void]] = [:]
    /// Set once quitting has begun: the jobs it cancels make no sound, and no new job starts (M1). Cleared when the
    /// quit is called off (M2).
    private var isQuitting = false

    private nonisolated static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "jobs")

    /// How long quitting waits for the cancelled jobs to stop: ProcessRunner's 2 s grace before SIGKILL, plus a
    /// margin.
    static let quitWait: Duration = .seconds(3)

    /// The clipboard, the sound player, the progress publisher and the Trash have no defaults: a test that forgot
    /// one would touch the user's real clipboard or Trash, play sounds or show progress in the real Finder (P16).
    init(
        registry: EngineRegistry, settings: SettingsStore,
        destinations: DestinationResolver = .nextToSource,
        pasteboard: NSPasteboard,
        playSound: @escaping @MainActor (NSSound.Name) -> Void,
        progressPublisher: any FileProgressPublishing,
        trashItem: @escaping @Sendable (URL) throws -> Void,
        progressDelay: Duration = FileProgressIndicator.standardDelay,
        noteStay: Duration = PillTiming.noteStay,
        clock: TimerClock = .live
    ) {
        self.settings = settings
        self.runner = JobRunner(registry: registry, destinations: destinations, trashItem: trashItem)
        self.destinations = destinations
        self.pasteboard = pasteboard
        self.soundPlayer = playSound
        self.progressPublisher = progressPublisher
        self.progressDelay = progressDelay
        self.noteStay = noteStay
        self.clock = clock
    }

    // MARK: - Performing a slice

    /// Runs `slice` on `files` and returns at once; the job runs to the end whether or not anyone waits for its
    /// outcome. `anchor` is where its pill appears. A job `isHeld` (by the wheel or an editor) stays out of sight,
    /// whatever its outcome, until the holder calls `release`. `onResult` hears each file's result as it finishes
    /// (S37): every source of a combine or a zip with the one output; never codes for the clipboard, nor the other
    /// file tools, which make no file.
    @discardableResult
    func perform(
        _ slice: WheelSlice, on files: [URL], anchor: CGPoint, isHeld: Bool,
        onResult: (@MainActor (FileResult) -> Void)? = nil
    ) -> JobHandle {
        // A job started now could publish after the quit's bounded wait, or outlive the app (M1).
        guard !isQuitting else {
            Self.log.info("refused: quitting")
            return Self.nothingToDo
        }
        let place = Placement(anchor: anchor, isHeld: isHeld)
        switch slice.kind {
        case .convert(let target):
            let inputs = filesToConvert(files, to: target)
            let verb = contentBuilder?.conversionVerb(for: inputs, to: target) ?? "Converting"
            return start(ConversionRequest(inputs: inputs, target: target), verb: verb, finderVerb: "Converting",
                         symbol: slice.symbol, place, onResult: onResult)
        case .preset(let id):
            guard let preset = contentBuilder?.tool(id: id) else {
                return unknownTool(slice, on: files, place)
            }
            return run(preset, on: files, symbol: ToolCatalog.info(id)?.symbol ?? slice.symbol, place,
                       onResult: onResult)
        case .editor(let id):
            // An editor's panel runs its job through `perform(preset:)` once the person has chosen; the wheel never
            // sends the slice itself.
            Self.log.fault("an editor slice reached the coordinator: \(id, privacy: .public)")
            return Self.nothingToDo
        case .action(let kind):
            return perform(kind, on: files, place, onResult: kind == .makeZip ? onResult : nil)
        }
    }

    /// Runs `preset` on `files` as the tool it names, with the options it carries (an editor's `edit` or
    /// `targetBytes`). Same hold, anchor and result rules as `perform(_:on:anchor:isHeld:onResult:)`.
    @discardableResult
    func perform(
        preset: Preset, on files: [URL], anchor: CGPoint, isHeld: Bool,
        onResult: (@MainActor (FileResult) -> Void)? = nil
    ) -> JobHandle {
        guard !isQuitting else {
            Self.log.info("refused: quitting")
            return Self.nothingToDo
        }
        return run(preset, on: files, symbol: ToolCatalog.symbol(ofPreset: preset.id),
                   Placement(anchor: anchor, isHeld: isHeld), onResult: onResult)
    }

    private func run(
        _ preset: Preset, on files: [URL], symbol: String, _ place: Placement,
        onResult: (@MainActor (FileResult) -> Void)?
    ) -> JobHandle {
        let info = ToolCatalog.info(preset.id)
        return start(toolRequest(for: preset, on: files), verb: info?.verb ?? preset.name,
                     finderVerb: info?.verb ?? preset.name, symbol: symbol, tool: info?.name ?? preset.name,
                     delivery: preset.delivery, place, onResult: onResult)
    }

    /// Where a job's pill goes, and whether it is held.
    private struct Placement {
        var anchor: CGPoint
        var isHeld: Bool
    }

    /// A job that never starts: no pill, no sound.
    private static var nothingToDo: JobHandle { JobHandle(id: UUID(), outcome: Task { .succeeded }) }

    private func unknownTool(_ slice: WheelSlice, on files: [URL], _ place: Placement) -> JobHandle {
        let summary = ResultSummary(title: "Couldn't run \(slice.title)", detail: "Unknown tool", isFailure: true)
        let id = begin(verb: slice.title, symbol: slice.symbol, files: files, isCombined: false, place)
        setAllFiles(of: id, to: .failed(reason: "Unknown tool"))
        let outcome = JobOutcome.failed(summary)
        end(id, outcome)
        finish(outcome)
        return JobHandle(id: id, outcome: Task { outcome })
    }

    // MARK: - Conversions

    /// P14: files already in the target format are skipped.
    private func filesToConvert(_ files: [URL], to target: FormatID) -> [URL] {
        contentBuilder?.filesToConvert(files, to: target)
            ?? files.filter { FormatRegistry.builtIn.format(for: $0)?.id != target }
    }

    /// A combine takes its inputs by name, as Finder sorts them, whatever order they were dragged in. Replace-original
    /// is the user's setting, and only for the tools that keep the file's format.
    private func toolRequest(for preset: Preset, on files: [URL]) -> ConversionRequest {
        let inputs = preset.combinesInputs
            ? files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            : files
        var request = ConversionRequest.from(preset, inputs: inputs)
        request.replaceOriginal = settings.settings.replaceOriginal && ToolCatalog.info(preset.id)?.canReplaceOriginal == true
        return request
    }

    /// `finderVerb` labels the sources' Finder indicators (P51): every conversion is "Converting" there, whatever the
    /// pill says. `tool` names a tool's job in its summary; nil for a conversion.
    private func start(
        _ request: ConversionRequest, verb: String, finderVerb: String, symbol: String, tool: String? = nil,
        delivery: PresetDelivery = .file, _ place: Placement, onResult: (@MainActor (FileResult) -> Void)?
    ) -> JobHandle {
        // Nothing to convert is not a failure, and makes no sound.
        guard !request.inputs.isEmpty else { return Self.nothingToDo }
        var request = request
        // Codes for the clipboard are written into a folder of Pomelo's own, read, then removed (§3.4 rule 5): its
        // files are no outputs of the user's.
        let codesFolder = delivery == .clipboard ? Self.makeCodesFolder() : nil
        if let codesFolder { request.outputFolder = codesFolder }
        let onResult = codesFolder == nil ? onResult : nil
        let id = begin(verb: verb, symbol: symbol, files: request.inputs, isCombined: request.combinesInputs, place)
        let (events, feeds) = Self.fileEvents(for: request, runner: runner)

        let task = Task { [request] in
            let final = await follow(request, events: events, feeds: feeds, finderVerb: finderVerb) { index, event in
                switch event {
                case .fileStarted: setFile(index, of: id, to: .running(fraction: nil))
                case .progress(_, let fraction): advance(index, of: id, to: fraction)
                case .fileFinished(_, let result):
                    setFile(index, of: id, to: Self.state(of: result))
                    onResult?(result)
                }
            }
            // A file that never finished was cancelled; the others already show their state.
            for (index, result) in final.enumerated() { setFile(index, of: id, to: Self.state(of: result)) }
            Self.logFailures(in: final)
            let outcome: JobOutcome
            if let codesFolder {
                outcome = deliverCodes(from: final, in: codesFolder)
            } else {
                outcome = Self.outcome(of: final, summary: ResultSummary.make(results: final, of: request, tool: tool))
            }
            end(id, outcome)
            // A job the user cancelled entirely makes no sound.
            if !final.allSatisfy(Self.isCancelled) { finish(outcome) }
            return outcome
        }
        active[id] = { feeds.forEach { $0.cancel() } }
        fileCancels[id] = feeds.map { feed in { feed.cancel() } }
        return JobHandle(id: id, outcome: task)
    }

    /// The per-file loop `start` and `runUnattended` share. Each source gets Finder's indicator once its file starts
    /// (P24); Finder's cancel ends it at once and cancels that file's runner job (a combine's one job), which still
    /// reports how the file really ended (cancelled, or succeeded when its publish came first). `observe` sees each
    /// event after the indicator. Returns one result per input, in input order, once the events end.
    private func follow(
        _ request: ConversionRequest, events: AsyncStream<(Int, JobEvent)>, feeds: [Task<Void, Never>],
        finderVerb: String, observe: (Int, JobEvent) -> Void = { _, _ in }
    ) async -> [FileResult] {
        var results = [FileResult?](repeating: nil, count: request.inputs.count)
        var fileIndicators: [Int: FileProgressIndicator] = [:]
        for await (index, event) in events {
            switch event {
            case .fileStarted:
                fileIndicators[index] = showProgress(on: request.inputs[index], verb: finderVerb) {
                    feeds[index].cancel()
                }
            case .progress(_, let fraction):
                fileIndicators[index]?.update(fraction: fraction)
            case .fileFinished(_, let result):
                results[index] = result
                if let indicator = fileIndicators.removeValue(forKey: index) { retire(indicator) }
            }
            observe(index, event)
        }
        fileIndicators.values.forEach(retire)
        return zip(request.inputs, results).map { source, result in result ?? .cancelled(source: source) }
    }

    // MARK: - Unattended jobs (intents, watch folders)

    /// Runs `request` for a caller nobody watches (P106): no pill, never held, no sound, only Finder's per-file
    /// indicator labelled `verb`. It never replaces an original, whatever Settings says. Returns one result per input,
    /// in input order; while quitting nothing starts and every input is `.cancelled`. Cancelling the calling task
    /// cancels every file, and this returns once their engines have stopped and their staging is gone.
    func runUnattended(_ request: ConversionRequest, verb: String) async -> [FileResult] {
        guard !isQuitting else {
            Self.log.info("refused: quitting")
            return request.inputs.map { .cancelled(source: $0) }
        }
        guard !request.inputs.isEmpty else { return [] }
        var request = request
        request.replaceOriginal = false
        let id = UUID()
        let (events, feeds) = Self.fileEvents(for: request, runner: runner)
        // Counted as running work, so quitting cancels it and waits for it.
        active[id] = { feeds.forEach { $0.cancel() } }
        defer { active[id] = nil }
        // Followed in a task of its own: the caller's cancel would end its event loop at once, before the files have
        // stopped. It reaches the files through their feeds instead, so each result is what is on disk.
        let followed = Task { [request] in await follow(request, events: events, feeds: feeds, finderVerb: verb) }
        let results = await withTaskCancellationHandler {
            await followed.value
        } onCancel: {
            feeds.forEach { $0.cancel() }
        }
        Self.logFailures(in: results)
        return results
    }

    /// Failures win over notes; outputs that went to Downloads are worth a note, as the user looks next to the source.
    private static func outcome(of results: [FileResult], summary: ResultSummary) -> JobOutcome {
        if summary.isFailure { return .failed(summary) }
        let fellBack = results.contains { result in
            if case .succeeded(_, _, .fellBackToDownloads) = result { true } else { false }
        }
        return fellBack ? .noted(savedToDownloads) : .succeeded
    }

    static let savedToDownloads = ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")

    /// Runs each file as its own runner job, so a cancel from one file's indicator stops that file alone (a combine
    /// is the exception: one runner job for all its files, which a cancel on any source stops); the runner still
    /// enforces each engine's limit across jobs, and publishing never replaces anything. The events
    /// come back merged, tagged with the file's index in `request`. Cancelling a feed cancels its runner job
    /// through its task: the feed ends once the engine has stopped and its staging is removed, after the file's
    /// true `.fileFinished`, so the job's outcome always matches what is on disk.
    private nonisolated static func fileEvents(for request: ConversionRequest, runner: JobRunner)
        -> (events: AsyncStream<(Int, JobEvent)>, feeds: [Task<Void, Never>]) {
        let (events, continuation) = AsyncStream.makeStream(of: (Int, JobEvent).self)
        let feeds: [Task<Void, Never>]
        if request.combinesInputs {
            // A combine is one runner job: its files succeed or fail together, so Finder's cancel on any of them
            // cancels all.
            let combine = Task {
                _ = await runner.run(request, emit: { continuation.yield(($0.fileIndex, $0)) })
            }
            feeds = Array(repeating: combine, count: request.inputs.count)
        } else {
            feeds = request.inputs.indices.map { index in
                var single = request
                single.inputs = [request.inputs[index]]
                return Task { [single] in
                    _ = await runner.run(single, emit: { continuation.yield((index, $0)) })
                }
            }
        }
        Task {
            for feed in feeds { await feed.value }
            continuation.finish()
        }
        return (events, feeds)
    }

    private nonisolated static func isCancelled(_ result: FileResult) -> Bool {
        if case .cancelled = result { true } else { false }
    }

    private nonisolated static func state(of result: FileResult) -> PillFileState {
        switch result {
        case .succeeded: .done
        case .failed(_, let error): .failed(reason: ResultSummary.reason(for: error))
        case .cancelled: .cancelled
        }
    }

    // MARK: - Codes for the clipboard

    private static func makeCodesFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Pomelo Codes", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        // A folder that can't be made fails every file at staging, which the outcome reports.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Puts every code the job read on the clipboard, each once, in the order the files were read. A payload may
    /// span lines (a vCard, a Wi-Fi network), so payloads are separated by a blank line, in the outputs and on the
    /// clipboard (P53).
    private func deliverCodes(from results: [FileResult], in folder: URL) -> JobOutcome {
        defer { try? FileManager.default.removeItem(at: folder) }
        var codes: [String] = []
        var seen: Set<String> = []
        for case .succeeded(_, let outputs, _) in results {
            for output in outputs {
                let text = ((try? String(contentsOf: output, encoding: .utf8)) ?? "")
                    .replacingOccurrences(of: "\r\n", with: "\n")
                for payload in text.components(separatedBy: "\n\n") {
                    let code = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty, seen.insert(code).inserted { codes.append(code) }
                }
            }
        }
        if !codes.isEmpty {
            pasteboard.clearContents()
            pasteboard.setString(codes.joined(separator: "\n\n"), forType: .string)
        }
        if results.allSatisfy(Self.isCancelled) { return .succeeded }
        if codes.isEmpty {
            let detail = results.count == 1
                ? ResultSummary.shortened(results[0].source.lastPathComponent, to: ResultSummary.maxDetailLength)
                : "In \(results.count) files"
            return .failed(ResultSummary(title: "No code found", detail: detail, isFailure: true))
        }
        let summary = ResultSummary.make(results: results)
        // A successful read says nothing, like any success (no "Copied" note): the clipboard
        // holds the codes.
        return summary.isFailure ? .failed(summary) : .succeeded
    }

    /// `text` cut at the end to the hub's detail length, ellipsis included.
    private static func clipped(_ text: String) -> String {
        let limit = ResultSummary.maxDetailLength
        return text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }

    // MARK: - File actions

    /// `onResult` hears every source with the zip once Make Zip succeeds.
    private func perform(
        _ kind: FileActionKind, on files: [URL], _ place: Placement, onResult: (@MainActor (FileResult) -> Void)?
    ) -> JobHandle {
        let info = ToolCatalog.info(for: kind)
        let id = begin(verb: info.verb, symbol: info.symbol, files: files, isCombined: true, place)
        setAllFiles(of: id, to: .running(fraction: nil))
        // Asked as ZipBuilder asks it (P52): comparing the zip's folder with the source's misreads symlinked paths.
        let zipFellBack = kind == .makeZip && files.first.map { destinations.destination(for: $0, override: nil).fellBack }
            == true
        let work = Task { [pasteboard, destinations] in
            try await FileActions.run(kind, on: files, pasteboard: pasteboard, destinations: destinations)
        }
        // A zip of a large selection can run for minutes. Its sources show an indeterminate indicator (`ditto`
        // reports no progress), and Finder's cancel on any of them cancels the whole zip, whose indicators then
        // all go at once rather than when `ditto` has exited.
        let zipIndicators = kind == .makeZip
            ? files.map { showProgress(on: $0, verb: info.verb) { [weak self] in self?.cancel(job: id) } }
            : []
        let task = Task {
            let outcome: JobOutcome
            var cancelled = false
            do {
                let outputs = try await work.value
                outcome = zipFellBack ? .noted(Self.savedToDownloads) : .succeeded
                setAllFiles(of: id, to: .done)
                if let onResult, !outputs.isEmpty {
                    let note: ResultNote? = zipFellBack ? .fellBackToDownloads : nil
                    for file in files { onResult(.succeeded(source: file, outputs: outputs, note: note)) }
                }
            } catch {
                cancelled = work.isCancelled
                if cancelled {
                    outcome = .succeeded
                    setAllFiles(of: id, to: .cancelled)
                } else {
                    Self.log.error("\(Self.verb(of: kind), privacy: .public) failed: \(String(describing: error), privacy: .private)")
                    let reason = Self.reason(for: error)
                    outcome = .failed(ResultSummary(title: "Couldn't \(Self.verb(of: kind))", detail: reason,
                                                    isFailure: true))
                    setAllFiles(of: id, to: .failed(reason: reason))
                }
            }
            zipIndicators.forEach(retire)
            end(id, outcome)
            // Copying, revealing and opening Terminal are their own feedback; only the zip and failures sound, and
            // a zip the user cancelled makes no sound.
            if !cancelled && (kind == .makeZip || outcome.isFailure) { finish(outcome) }
            return outcome
        }
        active[id] = { [weak self] in
            work.cancel()
            zipIndicators.forEach { self?.retire($0) }
        }
        fileCancels[id] = files.map { _ in { [weak self] in self?.cancel(job: id) } }
        return JobHandle(id: id, outcome: task)
    }

    /// A file tool's failure in a few words for the hub or pill; the raw error (a `ditto` stderr tail, a Cocoa
    /// error) is only logged.
    static func reason(for error: any Error) -> String {
        let reason = switch error as? FileActionError {
        case .terminalNotFound: "Terminal wasn't found"
        case .zipFailed: "The zip couldn't be made"
        case .missing(let name): "\(ResultSummary.shortened(name, to: ResultSummary.maxTitleNameLength)) was moved or deleted"
        case nil: "Something went wrong"
        }
        return clipped(reason)
    }

    private static func verb(of kind: FileActionKind) -> String {
        switch kind {
        case .copyPaths: "copy the paths"
        case .copyFiles: "copy the files"
        case .revealInFinder: "show in Finder"
        case .makeZip: "make the zip"
        case .openTerminal: "open Terminal"
        case .shelf: "add to the Shelf"
        }
    }

    // MARK: - Progress in Finder (P24)

    /// Starts `file`'s indicator, which appears in Finder once the work has run for `progressDelay`.
    private func showProgress(
        on file: URL, verb: String, onCancel: @escaping @MainActor () -> Void
    ) -> FileProgressIndicator {
        // The verb alone (P51): Finder draws the indicator on the file, so naming it again says nothing.
        let indicator = FileProgressIndicator(
            file: file, description: "\(verb)\u{2026}",
            publisher: progressPublisher, delay: progressDelay, sleep: clock.sleep, onCancel: onCancel
        )
        indicators[ObjectIdentifier(indicator)] = indicator
        return indicator
    }

    private func retire(_ indicator: FileProgressIndicator) {
        indicator.end()
        indicators[ObjectIdentifier(indicator)] = nil
    }

    /// Removes every indicator still up; called when the app quits.
    func endAllProgress() {
        indicators.values.forEach(retire)
    }

    // MARK: - Quitting

    /// True while any job runs: quitting then waits for `cancelAll`.
    var hasRunningWork: Bool { !active.isEmpty }

    /// Cancels every running job and waits, at most `limit`, for them to stop: their engines and processes are
    /// stopped (ffmpeg, `ditto`), their staging is removed, and nothing more is published. Called when the app
    /// quits; the cancelled jobs make no sound.
    func cancelAll(waitingAtMost limit: Duration = JobCoordinator.quitWait) async {
        isQuitting = true
        endAllProgress()
        for cancel in active.values { cancel() }
        let deadline = ContinuousClock.now + limit
        // Each job leaves `active` as it ends. Polled: awaiting a job's task can't be bounded by a deadline.
        while !active.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !active.isEmpty { Self.log.error("quitting with \(self.active.count, privacy: .public) jobs still stopping") }
    }

    /// The app will not quit after all (M2): new jobs start and sound again.
    func quitWasCancelled() {
        isQuitting = false
    }

    // MARK: - The pill's jobs (P25)

    /// Cancels every file of a running job.
    func cancel(job id: UUID) {
        active[id]?()
    }

    /// Cancels one file of a running job; a combine or a zip stops as a whole.
    func cancel(job id: UUID, file index: Int) {
        guard let cancels = fileCancels[id], cancels.indices.contains(index) else { return }
        cancels[index]()
    }

    /// Closes the pill of a job that has ended; a running job is cancelled with `cancel(job:)` instead.
    func dismiss(job id: UUID) {
        guard active[id] == nil else { return }
        jobs.removeAll { $0.id == id }
    }

    /// Whoever held a job (the wheel, an editor) lets go of it (P23, P25). When its hub showed the outcome the job
    /// leaves at once; otherwise it carries on in the pill, where a failure the hub never showed turns red (Review
    /// Focus 4).
    func release(_ id: UUID, outcomeShown: Bool) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let hasEnded = active[id] == nil
        if outcomeShown && hasEnded {
            jobs.remove(at: index)
            return
        }
        jobs[index].isHeld = false
        if hasEnded { settle(at: index) }
    }

    private func begin(verb: String, symbol: String, files: [URL], isCombined: Bool, _ place: Placement) -> UUID {
        let id = UUID()
        let pillFiles = files.enumerated().map { PillFile(id: $0.offset, name: $0.element.lastPathComponent,
                                                          state: .waiting) }
        jobs.append(PillJob(id: id, verb: verb, symbol: symbol, files: pillFiles, isCombined: isCombined,
                            anchor: place.anchor, startedAt: clock.now(), isHeld: place.isHeld))
        return id
    }

    private func setFile(_ file: Int, of id: UUID, to state: PillFileState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].files.indices.contains(file),
              jobs[index].files[file].state != state else { return }
        jobs[index].files[file].state = state
    }

    /// A running file's fraction never goes backwards, and stays indeterminate at zero.
    private func advance(_ file: Int, of id: UUID, to fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].files.indices.contains(file) else {
            return
        }
        let previous: Double
        switch jobs[index].files[file].state {
        case .waiting: previous = 0
        case .running(let current): previous = current ?? 0
        case .done, .failed, .cancelled: return
        }
        let next = max(previous, min(max(fraction, 0), 1))
        setFile(file, of: id, to: .running(fraction: next > 0 ? next : nil))
    }

    private func setAllFiles(of id: UUID, to state: PillFileState) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[index]
        for file in job.files.indices { job.files[file].state = state }
        if job != jobs[index] { jobs[index] = job }
    }

    /// The job's work is over. A held job keeps its final phase out of sight until `release`.
    private func end(_ id: UUID, _ outcome: JobOutcome) {
        active[id] = nil
        fileCancels[id] = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .succeeded: break
        case .failed(let summary): jobs[index].phase = .failed(summary)
        case .noted(let summary): jobs[index].phase = .noted(summary)
        }
        if !jobs[index].isHeld { settle(at: index) }
    }

    /// An ended job nothing holds: a success leaves, a failure stays until closed, a note leaves after `noteStay`.
    private func settle(at index: Int) {
        let id = jobs[index].id
        switch jobs[index].phase {
        case .running:
            jobs.remove(at: index)
        case .failed:
            break
        case .noted:
            Task { [weak self, noteStay, clock] in
                try? await clock.sleep(noteStay)
                self?.dismiss(job: id)
            }
        }
    }

    // MARK: - Outcomes

    /// The raw error of every failed file, which the hub's short reason leaves out. File names and tools' output
    /// are private: they stay out of sysdiagnoses.
    private nonisolated static func logFailures(in results: [FileResult]) {
        for case .failed(let source, let error) in results {
            log.error("\(source.lastPathComponent, privacy: .private) failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Every finished job plays its sound, whether or not anything shows its outcome; failures are logged.
    private func finish(_ outcome: JobOutcome) {
        if case .failed(let summary) = outcome {
            Self.log.error("job failed: \(summary.title, privacy: .private): \(summary.detail ?? "", privacy: .private)")
        }
        guard settings.settings.soundsEnabled, !isQuitting else { return }
        soundPlayer(outcome.isFailure ? "Basso" : "Glass")
    }
}

extension DestinationResolver {
    /// Outputs go next to their source, or to Downloads when that folder is read-only.
    static let nextToSource = DestinationResolver(
        downloadsFolder: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        isWritable: { FileManager.default.isWritableFile(atPath: $0.path) }
    )
}
