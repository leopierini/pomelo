import Foundation

/// Turns a batch of files into published outputs.
///
/// Every file is planned, converted step by step inside its own staging directory (on the destination's volume),
/// and published under a fresh name that never replaces anything; with replace-original, the source then goes to the
/// Trash and the result is renamed onto its name (RENAME_EXCL). Files run concurrently; each engine's
/// `maxConcurrentJobs` is enforced with a semaphore. One file failing never affects the others. Engine work runs
/// off the actor; publishing is serialized on it, so names reserved within a batch never collide (the app runs each
/// file as its own job, where the exclusive rename alone still guarantees that nothing is replaced). A cancelled
/// file publishes nothing: cancellation is checked last on the actor, right before the rename. A combining request
/// is the exception: its files become one output and succeed or fail together.
public actor JobRunner {
    private let registry: EngineRegistry
    private let formats: FormatRegistry
    private let destinations: DestinationResolver
    private let trashItem: @Sendable (URL) throws -> Void
    private var semaphores: [EngineID: AsyncSemaphore] = [:]
    /// Lowercased file names claimed by each running job: its sources, then every name it has published.
    private var reservedNames: [UUID: Set<String>] = [:]

    /// `trashItem` moves a replaced source to the Trash; tests inject their own (P16).
    public init(
        registry: EngineRegistry, formats: FormatRegistry = .builtIn, destinations: DestinationResolver,
        trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.registry = registry
        self.formats = formats
        self.destinations = destinations
        self.trashItem = trashItem
    }

    /// Converts every input and returns one result per input, in input order. Never throws: when the surrounding
    /// task is cancelled, unfinished files report `.cancelled`.
    public func run(_ request: ConversionRequest) async -> [FileResult] {
        await run(request, emit: { _ in })
    }

    /// Like `run(_:)`, reporting each file's events through `emit` (from any thread). Cancelling
    /// the calling task cancels the job, and this returns only once every engine has stopped and its staging is
    /// gone, after emitting each file's true `.fileFinished`.
    public func run(_ request: ConversionRequest, emit: @escaping @Sendable (JobEvent) -> Void) async -> [FileResult] {
        let job = UUID()
        // Sources are reserved so an output can never take a source's name.
        reservedNames[job] = Set(request.inputs.map { $0.lastPathComponent.lowercased() })
        defer { reservedNames[job] = nil }

        // A cached "still getting ready" must not fail a job the engine could run now.
        await registry.recheckVolatileEngines()
        let available = await registry.planner()
        let unsupported = await registry.unsupportedReasons()
        var all: RoutePlanner?
        if !unsupported.isEmpty { all = await registry.planner(includingMissing: true) }
        let planners = Planners(available: available, all: all, unsupported: unsupported)
        if request.combinesInputs {
            let results = await combine(request, planners: planners, job: job, emit: emit)
            for (index, result) in results.enumerated() { emit(.fileFinished(index: index, result: result)) }
            return results
        }
        var results = [FileResult?](repeating: nil, count: request.inputs.count)
        await withTaskGroup(of: (Int, FileResult).self) { group in
            for (index, source) in request.inputs.enumerated() {
                group.addTask {
                    let result = await self.convert(
                        source, index: index, request: request, planners: planners, job: job, emit: emit
                    )
                    emit(.fileFinished(index: index, result: result))
                    return (index, result)
                }
            }
            for await (index, result) in group {
                results[index] = result
            }
        }
        return zip(request.inputs, results).map { source, result in result ?? .cancelled(source: source) }
    }

    // MARK: - One file

    private struct PlannedStep {
        let edge: ConversionEdge
        let from: FileFormat
        let to: FileFormat
    }

    private struct Plan {
        let sourceFormat: FormatID
        let steps: [PlannedStep]
        let folder: URL
        let note: ResultNote?
    }

    /// The installed engines' planner, and the full one that tells a route through an engine this Mac can't run
    /// (a CLI request, a stale wheel) from no route at all.
    private struct Planners {
        let available: RoutePlanner
        /// Nil when every engine is supported.
        let all: RoutePlanner?
        let unsupported: [EngineID: String]

        func route(from source: FormatID, for request: ConversionRequest, over planner: RoutePlanner) -> Route? {
            planner.route(from: source, operation: request.operation, target: request.target)
        }

        /// Why no installed route exists, when the full route runs through an unsupported engine.
        func unsupportedFailure(from source: FormatID, for request: ConversionRequest) -> ConversionError? {
            guard let all, let route = route(from: source, for: request, over: all),
                  let (engine, reason) = route.edges.lazy.compactMap({ edge in
                      unsupported[edge.engineID].map { (edge.engineID, $0) }
                  }).first else { return nil }
            return .engineUnsupported(engine: engine, reason: reason)
        }
    }

    private nonisolated func plan(
        for source: URL, request: ConversionRequest, planners: Planners
    ) -> Result<Plan, ConversionError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return .failure(.sourceMissing)
        }
        // A folder is refused, except a package (such as `.rtfd`) of a known format, which is a single document.
        if isDirectory.boolValue && !isKnownPackage(source) { return .failure(.isDirectory) }
        // A FIFO (or socket, or device) would block the engine that opens it forever.
        let type = (try? FileManager.default.attributesOfItem(atPath: source.resolvingSymlinksInPath().path))?[.type]
        if !isDirectory.boolValue, type as? FileAttributeType != .typeRegular { return .failure(.notARegularFile) }
        guard let sourceFormat = formats.format(for: source) else {
            return .failure(.unknownFormat(ext: source.pathExtension.lowercased()))
        }
        let target = request.target ?? sourceFormat.id
        guard let route = planners.route(from: sourceFormat.id, for: request, over: planners.available) else {
            return .failure(
                planners.unsupportedFailure(from: sourceFormat.id, for: request)
                    ?? .noRoute(from: sourceFormat.id, to: target)
            )
        }
        var steps: [PlannedStep] = []
        for edge in route.edges {
            guard let from = formats.format(id: edge.from) else { return .failure(.unknownFormat(ext: edge.from.rawValue)) }
            guard let to = formats.format(id: edge.to) else { return .failure(.unknownFormat(ext: edge.to.rawValue)) }
            steps.append(PlannedStep(edge: edge, from: from, to: to))
        }
        let destination = destinations.destination(for: source, override: request.outputFolder)
        return .success(Plan(
            sourceFormat: sourceFormat.id, steps: steps, folder: destination.folder,
            note: destination.fellBack ? .fellBackToDownloads : nil
        ))
    }

    private nonisolated func isKnownPackage(_ url: URL) -> Bool {
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return isPackage && formats.format(forExtension: url.pathExtension) != nil
    }

    private nonisolated func convert(
        _ source: URL, index: Int, request: ConversionRequest, planners: Planners, job: UUID,
        emit: @escaping @Sendable (JobEvent) -> Void
    ) async -> FileResult {
        if Task.isCancelled { return .cancelled(source: source) }
        let plan: Plan
        switch self.plan(for: source, request: request, planners: planners) {
        case .success(let planned): plan = planned
        case .failure(let error): return .failed(source: source, error: error)
        }

        // Staging on the destination's volume, so the final renamex_np never crosses volumes (EXDEV).
        let staging: URL
        do {
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: plan.folder, create: true
            )
        } catch {
            return .failed(source: source, error: .publishFailed(message: (error as NSError).localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        var current = source
        for (stepIndex, step) in plan.steps.enumerated() {
            let engineID = step.edge.engineID
            // Each step gets its own folder, so an intermediate can never clash with the next step's output.
            let stepDirectory = staging.appending(path: "step-\(stepIndex)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: stepDirectory, withIntermediateDirectories: false)
            } catch {
                return .failed(source: source, error: .publishFailed(message: (error as NSError).localizedDescription))
            }
            guard let engine = await registry.engine(id: engineID) else {
                return .failed(
                    source: source, error: .converterUnavailable(engine: engineID, message: "engine not found")
                )
            }

            let conversionStep = ConversionStep(
                input: current, stagingDirectory: stepDirectory, from: step.from, to: step.to, options: request.options,
                operation: request.operation
            )
            let stepCount = Double(plan.steps.count)
            let progress: @Sendable (Double) -> Void = { fraction in
                let clamped = min(max(fraction, 0), 1)
                emit(.progress(index: index, fraction: (Double(stepIndex) + clamped) / stepCount))
            }

            let outcome = await withSlot(
                of: engine, started: { if stepIndex == 0 { emit(.fileStarted(index: index)) } },
                { try await engine.convert(conversionStep, progress: progress) }
            )
            switch outcome {
            case .failure(let error):
                if error is CancellationError || Task.isCancelled { return .cancelled(source: source) }
                return .failed(source: source, error: Self.conversionError(error, engine: engineID))
            case .success(let produced):
                if Task.isCancelled { return .cancelled(source: source) }
                // Publishing moves the item, so it must be something the engine created, never the source.
                guard Self.isInside(produced, stepDirectory) else {
                    return .failed(source: source, error: .converterFault(
                        engine: engineID, message: "returned \(produced.path), outside its staging directory"
                    ))
                }
                current = produced
            }
        }

        // A cancelled file reports `.cancelled`, never a size refusal.
        if Task.isCancelled { return .cancelled(source: source) }
        if Self.isSharedFile(current) {
            return .failed(source: source, error: .converterFault(
                engine: plan.steps.last?.edge.engineID ?? "", message: Self.sharedFileMessage
            ))
        }
        let isRegularFile = (try? current.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        if request.onlyIfSmaller, isRegularFile, !Self.isSmaller(current, than: source) {
            return .failed(source: source, error: .notApplicable(reason: "Already compressed"))
        }

        let ext = current.pathExtension
        let (stem, suffix) = switch request.outputNaming {
        case .fromSource: (OutputNamer.stem(of: source), request.nameSuffix)
        case .fromOutput: (OutputNamer.stem(of: current), String?.none)
        }
        // Only a version of the source published next to it may take its place (§3.4 rule 8, P273: the same kind of
        // file, so HEIC → JPG replaces and a video's audio never does). Trashing a symlink would leave its target in
        // place (P47); a produced name is not a version of the source (P48).
        let isSymlink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let outputFormat = formats.format(forExtension: ext)
        let sourceCategory = formats.format(id: plan.sourceFormat)?.category
        let replaces = request.replaceOriginal && plan.note == nil && isRegularFile && !isSymlink
            && request.outputNaming == .fromSource
            && outputFormat != nil && sourceCategory != .other && outputFormat?.category == sourceCategory
            && Self.isSameFolder(plan.folder, source.deletingLastPathComponent())
        // A same-format result takes the source's exact name; another format keeps the source's name with its own
        // extension (Lake.heic → Lake.jpg).
        let replacementName = outputFormat?.id == plan.sourceFormat
            ? source
            : plan.folder.appending(path: "\(source.deletingPathExtension().lastPathComponent).\(ext)",
                                    directoryHint: .notDirectory)

        // Marked while still in staging, so the output is never visible without its quarantine (P58).
        if let mark = Quarantine.mark(of: source) { Quarantine.apply(mark, to: current) }
        do {
            let published = try await publish(
                current, to: plan.folder, stem: stem, ext: ext, suffix: suffix,
                replacing: replaces ? (original: source, name: replacementName) : nil, job: job
            )
            return .succeeded(
                source: source, outputs: [published.output], note: published.replaced ? .replacedOriginal : plan.note
            )
        } catch is CancellationError {
            return .cancelled(source: source)
        } catch {
            return .failed(source: source, error: .publishFailed(message: (error as NSError).localizedDescription))
        }
    }

    // MARK: - Many files into one

    /// One output for all the inputs, named after the first (§3.4 rule 3) and listed by every input's result. It is
    /// no version of one source, so it never replaces one and `onlyIfSmaller` doesn't apply. It succeeds or fails as
    /// a whole: a failure fails the input it names (else the first) and cancels the others.
    private nonisolated func combine(
        _ request: ConversionRequest, planners: Planners, job: UUID, emit: @escaping @Sendable (JobEvent) -> Void
    ) async -> [FileResult] {
        let inputs = request.inputs
        guard !inputs.isEmpty else { return [] }
        let allCancelled = inputs.map { FileResult.cancelled(source: $0) }
        func failing(_ index: Int, _ error: ConversionError) -> [FileResult] {
            inputs.enumerated().map { offset, source in
                offset == index ? .failed(source: source, error: error) : .cancelled(source: source)
            }
        }
        if Task.isCancelled { return allCancelled }

        var plans: [Plan] = []
        for (index, source) in inputs.enumerated() {
            switch plan(for: source, request: request, planners: planners) {
            case .success(let planned): plans.append(planned)
            case .failure(.noRoute): return noRoutes(for: request)
            case .failure(let error): return failing(index, error)
            }
        }
        // One engine must take every input: each route is a single operation edge of that engine, to one format.
        let edge = plans[0].steps[0].edge
        let target = plans[0].steps[0].to
        let sharesOneEdge = plans.allSatisfy { plan in
            plan.steps.count == 1 && plan.steps[0].edge.engineID == edge.engineID && plan.steps[0].to.id == target.id
        }
        guard let operation = request.operation, sharesOneEdge else { return noRoutes(for: request) }
        guard let found = await registry.engine(id: edge.engineID) else {
            return failing(0, .converterUnavailable(engine: edge.engineID, message: "engine not found"))
        }
        guard let engine = found as? any CombiningEngine else { return noRoutes(for: request) }

        let folder = plans[0].folder
        let staging: URL
        do {
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true
            )
        } catch {
            return failing(0, .publishFailed(message: (error as NSError).localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let step = CombineStep(
            inputs: inputs, formats: plans.map(\.steps[0].from), stagingDirectory: staging, to: target,
            operation: operation
        )
        let progress: @Sendable (Double) -> Void = { fraction in
            let clamped = min(max(fraction, 0), 1)
            for index in inputs.indices { emit(.progress(index: index, fraction: clamped)) }
        }

        let outcome = await withSlot(
            of: engine, started: { for index in inputs.indices { emit(.fileStarted(index: index)) } },
            { try await engine.combine(step, progress: progress) }
        )
        let produced: URL
        switch outcome {
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { return allCancelled }
            if let named = error as? CombineInputError {
                let path = named.input.standardizedFileURL.path
                let index = inputs.firstIndex { $0.standardizedFileURL.path == path } ?? 0
                return failing(index, Self.conversionError(named.underlying, engine: engine.id))
            }
            return failing(0, Self.conversionError(error, engine: engine.id))
        case .success(let url):
            produced = url
        }
        if Task.isCancelled { return allCancelled }
        guard Self.isInside(produced, staging) else {
            return failing(0, .converterFault(
                engine: engine.id, message: "returned \(produced.path), outside its staging directory"
            ))
        }

        if Self.isSharedFile(produced) { return failing(0, .converterFault(engine: engine.id, message: Self.sharedFileMessage)) }

        if let mark = inputs.lazy.compactMap(Quarantine.mark(of:)).first { Quarantine.apply(mark, to: produced) }
        do {
            let published = try await publish(
                produced, to: folder, stem: OutputNamer.stem(of: inputs[0]), ext: produced.pathExtension,
                suffix: request.nameSuffix, replacing: nil, job: job
            )
            return inputs.map { .succeeded(source: $0, outputs: [published.output], note: plans[0].note) }
        } catch is CancellationError {
            return allCancelled
        } catch {
            return failing(0, .publishFailed(message: (error as NSError).localizedDescription))
        }
    }

    /// Runs `work` once `engine` has a free slot; `started` fires only then (P24). A job cancelled while it queued
    /// never starts, and its file reports only `.fileFinished`.
    private nonisolated func withSlot(
        of engine: any ConversionEngine, started: () -> Void, _ work: () async throws -> URL
    ) async -> Result<URL, any Error> {
        let semaphore = await semaphore(for: engine)
        await semaphore.wait()
        let outcome: Result<URL, any Error>
        if Task.isCancelled {
            outcome = .failure(CancellationError())
        } else {
            started()
            do {
                outcome = .success(try await work())
            } catch {
                outcome = .failure(error)
            }
        }
        await semaphore.signal()
        return outcome
    }

    private nonisolated func noRoutes(for request: ConversionRequest) -> [FileResult] {
        request.inputs.map { source in
            let from = formats.format(for: source)?.id ?? FormatID(source.pathExtension.lowercased())
            return .failed(source: source, error: .noRoute(from: from, to: request.target ?? from))
        }
    }

    /// An engine that already reports a ConversionError (such as CommandEngine) keeps it, unwrapped.
    private static func conversionError(_ error: any Error, engine: EngineID) -> ConversionError {
        error as? ConversionError ?? .engineFailed(engine: engine, message: String(describing: error))
    }

    // MARK: - Actor-isolated state

    private func semaphore(for engine: any ConversionEngine) -> AsyncSemaphore {
        if let existing = semaphores[engine.id] { return existing }
        let created = AsyncSemaphore(value: max(1, engine.maxConcurrentJobs))
        semaphores[engine.id] = created
        return created
    }

    /// Serialized on the actor: the cancellation check, the name check, the exclusive rename and the reservation
    /// happen as one unit, so a cancel that lands after the check is too late by definition (the file succeeded).
    /// With `replacing`, replace-original follows with no cancellation check, since the file already counts as
    /// converted: the original goes to the Trash and the result moves to `name`.
    private func publish(
        _ staged: URL, to folder: URL, stem: String, ext: String, suffix: String?,
        replacing: (original: URL, name: URL)?, job: UUID
    ) throws -> (output: URL, replaced: Bool) {
        try Task.checkCancellation()
        let published = try OutputPublisher.publish(
            staged: staged, to: folder, stem: stem, ext: ext, suffix: suffix,
            avoiding: reservedNames[job] ?? [], namer: OutputNamer()
        )
        reservedNames[job, default: []].insert(published.lastPathComponent.lowercased())
        guard let (original, name) = replacing else { return (published, false) }

        // The source is trashed only once its replacement is published: if the Trash refuses, both stay.
        do { try trashItem(original) } catch { return (published, false) }
        if published.path == name.path { return (published, true) }
        // RENAME_EXCL: an item that took the name since the trash keeps it; the result keeps its own name.
        if renamex_np(published.path, name.path, UInt32(RENAME_EXCL)) == 0 {
            reservedNames[job, default: []].insert(name.lastPathComponent.lowercased())
            return (name, true)
        }
        return (published, true)
    }

    /// A size that can't be read never refuses the result. `fileSize` doesn't follow a symlink (it gives the link's
    /// own size), so a symlinked source is measured at its target.
    private static func isSmaller(_ result: URL, than source: URL) -> Bool {
        guard let resultSize = (try? result.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let sourceSize = (try? source.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return true }
        return resultSize < sourceSize
    }

    private static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A regular file with more than one link shares its inode with another file, maybe a source (`ln {input}
    /// {output}`): the marks and the publish would reach that file too, so it is never published.
    private static func isSharedFile(_ item: URL) -> Bool {
        var info = stat()
        return lstat(item.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink > 1
    }

    private static let sharedFileMessage = "returned a hard link to another file"

    private static func isInside(_ item: URL, _ directory: URL) -> Bool {
        let itemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return itemPath.hasPrefix(directoryPath + "/")
    }
}
