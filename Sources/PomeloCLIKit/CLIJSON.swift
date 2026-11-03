import Foundation

// The stable `--json` schema of the CLI, documented in docs/cli-json.md. Optional fields are always present and
// encode as an explicit `null`, so a script never has to test whether a key exists.

public struct CLIConvertJSON: Codable, Sendable, Equatable {
    public var results: [CLIFileResultJSON]

    public init(results: [CLIFileResultJSON]) {
        self.results = results
    }
}

public struct CLIFileResultJSON: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case succeeded, failed, cancelled
    }

    public var source: String
    public var status: Status
    public var outputs: [String]
    /// `"fellBackToDownloads"`, `"replacedOriginal"` (never from the CLI, which doesn't replace originals) or null.
    public var note: String?
    /// `ConversionError.description`; docs/cli-json.md lists the texts.
    public var error: String?

    public init(source: String, status: Status, outputs: [String], note: String?, error: String?) {
        self.source = source
        self.status = status
        self.outputs = outputs
        self.note = note
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case source, status, outputs, note, error
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(status, forKey: .status)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeOrNil(note, forKey: .note)
        try container.encodeOrNil(error, forKey: .error)
    }
}

public struct CLITargetsJSON: Codable, Sendable, Equatable {
    public var source: String
    public var targets: [CLITargetJSON]

    public init(source: String, targets: [CLITargetJSON]) {
        self.source = source
        self.targets = targets
    }
}

public struct CLITargetJSON: Codable, Sendable, Equatable {
    public var format: String
    public var category: String
    public var hops: Int
    public var engines: [String]
    /// Any of `"lossy"`, `"layoutRisk"`, `"directOnly"`, in that order.
    public var flags: [String]

    public init(format: String, category: String, hops: Int, engines: [String], flags: [String]) {
        self.format = format
        self.category = category
        self.hops = hops
        self.engines = engines
        self.flags = flags
    }
}

public struct CLIEnginesJSON: Codable, Sendable, Equatable {
    public var engines: [CLIEngineJSON]
    /// Absolute paths of plugin manifests that could not be loaded.
    public var pluginErrors: [String]

    public init(engines: [CLIEngineJSON], pluginErrors: [String]) {
        self.engines = engines
        self.pluginErrors = pluginErrors
    }
}

public struct CLIEngineJSON: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case available, missing, unsupported
    }

    public var id: String
    public var name: String
    public var status: Status
    /// Set only for an available engine that reports a version.
    public var version: String?
    /// Set only for a missing engine.
    public var install: String?
    /// Set only for an unsupported engine: why this Mac can't run it.
    public var reason: String?

    public init(id: String, name: String, status: Status, version: String?, install: String?, reason: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.version = version
        self.install = install
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, version, install, reason
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeOrNil(version, forKey: .version)
        try container.encodeOrNil(install, forKey: .install)
        try container.encodeOrNil(reason, forKey: .reason)
    }
}

public struct CLIRoutesJSON: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    /// The planner's score, or null when there is no route (then `steps` is empty).
    public var cost: Int?
    public var steps: [CLIRouteStepJSON]

    public init(from: String, to: String, cost: Int?, steps: [CLIRouteStepJSON]) {
        self.from = from
        self.to = to
        self.cost = cost
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, cost, steps
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encodeOrNil(cost, forKey: .cost)
        try container.encode(steps, forKey: .steps)
    }
}

public struct CLIRouteStepJSON: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public var engine: String

    public init(from: String, to: String, engine: String) {
        self.from = from
        self.to = to
        self.engine = engine
    }
}

/// What every command prints in `--json` mode for a usage error (exit code 2).
public struct CLIErrorJSON: Codable, Sendable, Equatable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

enum CLIJSON {
    /// Pretty-printed, keys sorted, slashes unescaped.
    static func string(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding these plain value types cannot fail.
        let data = (try? encoder.encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension KeyedEncodingContainer {
    /// Encodes the value, or an explicit `null` when it is nil (never omits the key).
    fileprivate mutating func encodeOrNil<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
