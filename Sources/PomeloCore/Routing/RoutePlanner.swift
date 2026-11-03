import Foundation

/// Picks the cheapest chain of engine conversions between two formats.
///
/// The search is an exhaustive depth-first walk over simple paths of 1...`maxHops` edges. The graph is small, and
/// exhaustive search keeps tie-breaking deterministic, whatever order the edges come in. The best route has the
/// lowest score, then the fewest hops, then the fewest `lossy` edges, then the best engine-priority order of its
/// edges (compared lexicographically; engines missing from the priority list sort last), and finally the
/// lexicographically smallest sequence of the formats it passes through (each edge's `to`).
public struct RoutePlanner: Sendable {
    public static let hopPenalty = 5
    public static let layoutRiskPenalty = 100
    public static let maxHops = 3

    private let edgesBySource: [FormatID: [ConversionEdge]]
    private let operationEdges: [String: [FormatID: [ConversionEdge]]]
    private let priorityIndex: [EngineID: Int]

    public init(edges: [ConversionEdge], enginePriority: [EngineID]) {
        self.edgesBySource = Dictionary(grouping: edges.filter { $0.operation == nil }, by: \.from)
        var byOperation: [String: [FormatID: [ConversionEdge]]] = [:]
        for edge in edges {
            guard let operation = edge.operation else { continue }
            byOperation[operation, default: [:]][edge.from, default: []].append(edge)
        }
        self.operationEdges = byOperation
        var index: [EngineID: Int] = [:]
        for (position, engine) in enginePriority.enumerated() where index[engine] == nil {
            index[engine] = position
        }
        self.priorityIndex = index
    }

    /// The best route from `from` to `to`, or nil. When both are the same format, only a single self-edge counts.
    public func route(from: FormatID, to: FormatID) -> Route? {
        bestRoutes(from: from)[to]
    }

    /// The best single edge of `operation` from `from` to `to` (to `from` itself when `to` is nil), or nil. It is
    /// the lowest score, then the best engine priority, then the smallest target format.
    public func route(from: FormatID, operation: String, to: FormatID?) -> Route? {
        let target = to ?? from
        let candidates = (operationEdges[operation]?[from] ?? []).filter { $0.to == target }
        let best = candidates.min { a, b in
            let (scoreA, scoreB) = (Self.score(of: a), Self.score(of: b))
            if scoreA != scoreB { return scoreA < scoreB }
            let (priorityA, priorityB) = (priorityIndex[a.engineID] ?? Int.max, priorityIndex[b.engineID] ?? Int.max)
            if priorityA != priorityB { return priorityA < priorityB }
            return a.to.rawValue < b.to.rawValue
        }
        return best.map { Route(edges: [$0]) }
    }

    /// The route a tool or a request runs from `from`: its `operation`'s edge when it has one, else a conversion to
    /// `target`, or to `from` itself when there is none.
    public func route(from: FormatID, operation: String?, target: FormatID?) -> Route? {
        if let operation { return route(from: from, operation: operation, to: target) }
        return route(from: from, to: target ?? from)
    }

    /// Every format some edge of `operation` produces, from any source.
    public func targets(ofOperation operation: String) -> Set<FormatID> {
        Set((operationEdges[operation] ?? [:]).values.joined().map(\.to))
    }

    /// The best route to every format reachable from `from`, the source itself included when a self-edge reaches it:
    /// `reachableTargets` and `route(from:to:)` in one search.
    public func routes(from: FormatID) -> [FormatID: Route] {
        bestRoutes(from: from)
    }

    /// The best route to every reachable format other than the source itself.
    public func reachableTargets(from: FormatID) -> [FormatID: Route] {
        var routes = bestRoutes(from: from)
        routes[from] = nil
        return routes
    }

    static func score(of edge: ConversionEdge) -> Int {
        edge.cost + hopPenalty + (edge.flags.contains(.layoutRisk) ? layoutRiskPenalty : 0)
    }

    // MARK: - Search

    private struct Candidate {
        let edges: [ConversionEdge]
        let score: Int
        let lossyCount: Int
        let priorities: [Int]
        let formats: [String]
    }

    /// Best route to every format reachable in 1...maxHops edges, including `source` itself via a self-edge.
    private func bestRoutes(from source: FormatID) -> [FormatID: Route] {
        var best: [FormatID: Candidate] = [:]
        var path: [ConversionEdge] = []
        var visited: Set<FormatID> = [source]

        func visit(_ current: FormatID) {
            for edge in edgesBySource[current] ?? [] {
                let isFirst = path.isEmpty
                // directOnly edges only ever form a complete one-edge route.
                if edge.flags.contains(.directOnly) && !isFirst { continue }
                let isSelfEdge = edge.to == source
                // Simple paths only. The one exception is a lone self-edge on the source.
                if visited.contains(edge.to) && !(isFirst && isSelfEdge) { continue }

                path.append(edge)
                let candidate = Candidate(
                    edges: path,
                    score: path.reduce(0) { $0 + Self.score(of: $1) },
                    lossyCount: path.count { $0.flags.contains(.lossy) },
                    priorities: path.map { priorityIndex[$0.engineID] ?? Int.max },
                    formats: path.map(\.to.rawValue)
                )
                if best[edge.to].map({ isBetter(candidate, than: $0) }) ?? true {
                    best[edge.to] = candidate
                }

                let canExtend = path.count < Self.maxHops && !edge.flags.contains(.directOnly) && !isSelfEdge
                if canExtend {
                    visited.insert(edge.to)
                    visit(edge.to)
                    visited.remove(edge.to)
                }
                path.removeLast()
            }
        }
        visit(source)

        return best.mapValues { Route(edges: $0.edges) }
    }

    private func isBetter(_ a: Candidate, than b: Candidate) -> Bool {
        if a.score != b.score { return a.score < b.score }
        if a.edges.count != b.edges.count { return a.edges.count < b.edges.count }
        if a.lossyCount != b.lossyCount { return a.lossyCount < b.lossyCount }
        if a.priorities != b.priorities { return a.priorities.lexicographicallyPrecedes(b.priorities) }
        return a.formats.lexicographicallyPrecedes(b.formats)
    }
}
