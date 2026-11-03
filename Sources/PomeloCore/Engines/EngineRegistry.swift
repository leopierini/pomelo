import Foundation

/// Holds the installed engines, caches their availability, and builds the route planner from the available ones.
public actor EngineRegistry {
    private let engines: [any ConversionEngine]
    private let priority: [EngineID]
    private var cachedAvailability: [EngineID: EngineAvailability]?
    /// Each engine's probe, started once per refresh and shared by every caller; done ones hold their answer.
    private var versionProbes: [EngineID: Task<String?, Never>] = [:]
    /// Told when `recheckVolatileEngines()` finds an answer changed, so the app plans its wheel again.
    private var changeHandler: (@Sendable () -> Void)?

    public init(engines: [any ConversionEngine], priority: [EngineID]) {
        self.engines = engines
        self.priority = priority
    }

    /// Every engine that has an install of its own (not a composite on a `hostEngineID`), in the order given, with
    /// its cached availability and, for an available one, its version.
    /// Only this asks for versions, so planning never pays for an engine's version command (P143). The probes run
    /// at once, each stopped after 5 s without output, so the slowest engine sets the wait, not their sum.
    public func statuses() async -> [EngineStatus] {
        let availability = await currentAvailability()
        var probes: [EngineID: Task<String?, Never>] = [:]
        let listed = engines.filter { $0.hostEngineID == nil }
        for engine in listed {
            guard case .available = availability[engine.id] else { continue }
            probes[engine.id] = probe(engine)
        }
        var statuses: [EngineStatus] = []
        for engine in listed {
            var state = availability[engine.id] ?? .missing(installHint: "")
            if case .available = state, let probe = probes[engine.id] { state = .available(version: await probe.value) }
            statuses.append(EngineStatus(id: engine.id, displayName: engine.displayName, availability: state))
        }
        return statuses
    }

    /// Re-queries the availability of every engine; versions are probed again on the next `statuses()`. A composite
    /// takes its host's answer (asked once); only one with no host in this registry is asked itself.
    public func refresh() async {
        let ids = Set(engines.map(\.id))
        var fresh: [EngineID: EngineAvailability] = [:]
        for engine in engines where engine.hostEngineID.map(ids.contains) != true {
            fresh[engine.id] = await engine.availability()
        }
        for engine in engines {
            if let host = engine.hostEngineID, let answer = fresh[host] { fresh[engine.id] = answer }
        }
        cachedAvailability = fresh
        // A probe still running answers its own callers; the next `statuses()` starts a new one.
        versionProbes = [:]
    }

    /// Asks the engines whose availability can change at run time again (`availabilityIsVolatile`), and tells the
    /// change handler when an answer differs. Nothing to do before the first answers: they are fresh anyway.
    public func recheckVolatileEngines() async {
        guard cachedAvailability != nil else { return }
        var changed = false
        for engine in engines where engine.availabilityIsVolatile {
            let fresh = await engine.availability()
            // Written key by key: a `refresh()` may have run during the await.
            if cachedAvailability?[engine.id] != fresh {
                cachedAvailability?[engine.id] = fresh
                changed = true
            }
        }
        if changed { changeHandler?() }
    }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        changeHandler = handler
    }

    /// A planner over the edges of the available engines, in engine order. With `includingMissing` the edges of
    /// engines that are not installed or not supported are planned too, so a UI can show them disabled with an
    /// install hint or the reason.
    public func planner(includingMissing: Bool = false) async -> RoutePlanner {
        let availability = await currentAvailability()
        let edges = engines.flatMap { engine -> [ConversionEdge] in
            if includingMissing { return engine.edges() }
            if case .available = availability[engine.id] { return engine.edges() }
            return []
        }
        return RoutePlanner(edges: edges, enginePriority: priority)
    }

    /// For every engine that is not installed, `"<displayName>|<installHint>"`. The UI splits the value on `|`.
    public func installHints() async -> [EngineID: String] {
        let availability = await currentAvailability()
        var hints: [EngineID: String] = [:]
        for engine in engines {
            if case .missing(let installHint) = availability[engine.id] {
                hints[engine.id] = "\(shownName(of: engine))|\(installHint)"
            }
        }
        return hints
    }

    /// For every engine this Mac can't run, its reason, a sentence shown as is.
    public func unsupportedReasons() async -> [EngineID: String] {
        let availability = await currentAvailability()
        var reasons: [EngineID: String] = [:]
        for engine in engines {
            if case .unsupported(let reason) = availability[engine.id] { reasons[engine.id] = reason }
        }
        return reasons
    }

    public func engine(id: EngineID) -> (any ConversionEngine)? {
        engines.first { $0.id == id }
    }

    /// What the person is told to install: a composite's host, by the host's name.
    private func shownName(of engine: any ConversionEngine) -> String {
        engine.hostEngineID.flatMap { host in engines.first { $0.id == host } }?.displayName ?? engine.displayName
    }

    /// Off the actor, so planning and other callers never wait behind a version command.
    private func probe(_ engine: any ConversionEngine) -> Task<String?, Never> {
        if let running = versionProbes[engine.id] { return running }
        let probe = Task.detached(priority: .utility) { await engine.version() }
        versionProbes[engine.id] = probe
        return probe
    }

    private func currentAvailability() async -> [EngineID: EngineAvailability] {
        if cachedAvailability == nil { await refresh() }
        return cachedAvailability ?? [:]
    }
}
