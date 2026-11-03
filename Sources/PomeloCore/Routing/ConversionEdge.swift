import Foundation

/// Identifier of a conversion engine, e.g. `imageio`, `ffmpeg`.
public struct EngineID: StringIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct EdgeFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The conversion loses information (e.g. PNG to JPG).
    public static let lossy = EdgeFlags(rawValue: 1 << 0)
    /// The output layout may differ from the input (e.g. a word processor document to PDF).
    public static let layoutRisk = EdgeFlags(rawValue: 1 << 1)
    /// The edge may only be used as a whole route, never as one step of a chain.
    public static let directOnly = EdgeFlags(rawValue: 1 << 2)
}

/// One conversion an engine can perform.
public struct ConversionEdge: Hashable, Sendable {
    public let from: FormatID
    public let to: FormatID
    public let engineID: EngineID
    public let cost: Int
    public let flags: EdgeFlags
    /// A tool's name ("remove-audio"). An operation edge is one hop and never part of a conversion route.
    public let operation: String?

    public init(
        from: FormatID, to: FormatID, engineID: EngineID, cost: Int, flags: EdgeFlags, operation: String? = nil
    ) {
        self.from = from
        self.to = to
        self.engineID = engineID
        self.cost = cost
        self.flags = flags
        self.operation = operation
    }
}

/// A chain of one or more edges.
public struct Route: Hashable, Sendable {
    public let edges: [ConversionEdge]

    public init(edges: [ConversionEdge]) {
        precondition(!edges.isEmpty, "A route needs at least one edge")
        self.edges = edges
    }

    public var flags: EdgeFlags { edges.reduce(into: []) { $0.formUnion($1.flags) } }

    /// The planner's score: each edge's cost plus the hop and layout-risk penalties.
    public var totalCost: Int {
        edges.reduce(0) { $0 + RoutePlanner.score(of: $1) }
    }
}
