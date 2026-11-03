import Foundation

/// A JSON description of an external converter (ffmpeg, pandoc, ...): where to find it and which argument list
/// performs each conversion. See `ArgumentTemplate` for the placeholder grammar.
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Executable: Codable, Sendable, Equatable {
        /// File names to look for, in order. An absolute path is used as is.
        public var names: [String]
        public var searchPaths: [String]
        /// Arguments that make the tool print its version; nil skips the version probe.
        public var versionArguments: [String]?

        public init(names: [String], searchPaths: [String], versionArguments: [String]?) {
            self.names = names
            self.searchPaths = searchPaths
            self.versionArguments = versionArguments
        }
    }

    public struct Install: Codable, Sendable, Equatable {
        public var homebrew: String?
        public var website: String?

        public init(homebrew: String? = nil, website: String? = nil) {
            self.homebrew = homebrew
            self.website = website
        }
    }

    public struct Edge: Codable, Sendable, Equatable {
        public var from: [String]
        public var to: [String]
        /// Any of `lossy`, `layoutRisk`, `directOnly`.
        public var flags: [String]?
        public var cost: Int?
        public var arguments: [String]
        /// The tool this edge performs; nil for a plain conversion.
        public var operation: String?
        /// `"file"` (the default) or `"folder"`: what the tool produces.
        public var output: String?

        public init(
            from: [String], to: [String], flags: [String]? = nil, cost: Int? = nil, operation: String? = nil,
            output: String? = nil, arguments: [String]
        ) {
            self.from = from
            self.to = to
            self.flags = flags
            self.cost = cost
            self.operation = operation
            self.output = output
            self.arguments = arguments
        }

        var producesFolder: Bool { output == "folder" }
    }

    public static let fallbackCost = 30
    static let outputKinds: Set<String> = ["file", "folder"]
    static let knownFlags: [String: EdgeFlags] = [
        "lossy": .lossy, "layoutRisk": .layoutRisk, "directOnly": .directOnly,
    ]

    public var id: String
    public var displayName: String
    public var executable: Executable
    public var install: Install
    public var maxConcurrentJobs: Int?
    public var defaultCost: Int?
    /// Seconds a conversion may go without printing anything before it is stopped; nil means
    /// `ProcessRunner`'s default. Must be positive.
    public var timeoutSeconds: Int?
    public var edges: [Edge]

    public init(
        id: String,
        displayName: String,
        executable: Executable,
        install: Install,
        maxConcurrentJobs: Int? = nil,
        defaultCost: Int? = nil,
        timeoutSeconds: Int? = nil,
        edges: [Edge]
    ) {
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.install = install
        self.maxConcurrentJobs = maxConcurrentJobs
        self.defaultCost = defaultCost
        self.timeoutSeconds = timeoutSeconds
        self.edges = edges
    }

    public static func load(from url: URL) throws -> PluginManifest {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }

    /// Every edge needs `{input}`, then `{output}` or `{outputDir}` (a file edge) or `{outputFolder}` (a folder
    /// edge) among its arguments, and a `timeoutSeconds`, when given, must be positive.
    public func validate() throws(PluginManifestError) {
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyID }
        if executable.names.isEmpty { throw .noExecutableNames }
        if let timeoutSeconds, timeoutSeconds <= 0 { throw .invalidTimeout(timeoutSeconds) }
        for (index, edge) in edges.enumerated() {
            let keys = Set(edge.arguments.flatMap(ArgumentTemplate.placeholderKeys(in:)))
            if !keys.contains("input") { throw .missingInput(edgeIndex: index) }
            if let kind = edge.output, !Self.outputKinds.contains(kind) { throw .unknownOutputKind(kind) }
            if edge.producesFolder {
                if !keys.contains("outputFolder") { throw .folderOutputNeedsOutputFolder(edgeIndex: index) }
            } else if !keys.contains("output") && !keys.contains("outputDir") {
                throw .missingOutput(edgeIndex: index)
            }
            for flag in edge.flags ?? [] where Self.knownFlags[flag] == nil { throw .unknownFlag(flag) }
        }
    }

    /// The format a manifest names: a format the registry knows (by id or extension alias, any case) maps to its
    /// canonical id (`jpeg` becomes `jpg`); an unknown name stays as written, since plugins may add formats.
    public static func canonicalFormat(_ name: String, registry: FormatRegistry = .builtIn) -> FormatID {
        registry.format(id: FormatID(name))?.id ?? registry.format(forExtension: name)?.id ?? FormatID(name)
    }

    /// The manifest edge that converts `from` to `to` (canonical ids), found with the same canonicalisation as
    /// `conversionEdges()`. A nil `operation` matches only edges without one.
    public func edge(from: FormatID, to: FormatID, operation: String?, registry: FormatRegistry = .builtIn) -> Edge? {
        edges.first { edge in
            edge.operation == operation
                && edge.from.contains { Self.canonicalFormat($0, registry: registry) == from }
                && edge.to.contains { Self.canonicalFormat($0, registry: registry) == to }
        }
    }

    /// One `ConversionEdge` per `from x to` pair of every manifest edge, with canonical format ids.
    public func conversionEdges(registry: FormatRegistry = .builtIn) -> [ConversionEdge] {
        let engineID = EngineID(id)
        return edges.flatMap { edge in
            let flags = (edge.flags ?? []).reduce(into: EdgeFlags()) { result, name in
                if let flag = Self.knownFlags[name] { result.insert(flag) }
            }
            let cost = edge.cost ?? defaultCost ?? Self.fallbackCost
            let sources = Self.unique(edge.from.map { Self.canonicalFormat($0, registry: registry) })
            let targets = Self.unique(edge.to.map { Self.canonicalFormat($0, registry: registry) })
            return sources.flatMap { from in
                targets.map { to in
                    ConversionEdge(
                        from: from, to: to, engineID: engineID, cost: cost, flags: flags, operation: edge.operation
                    )
                }
            }
        }
    }

    private static func unique(_ formats: [FormatID]) -> [FormatID] {
        var seen: Set<FormatID> = []
        return formats.filter { seen.insert($0).inserted }
    }
}

public enum PluginManifestError: Error, Equatable {
    case emptyID
    case missingInput(edgeIndex: Int)
    case missingOutput(edgeIndex: Int)
    case unknownFlag(String)
    case noExecutableNames
    case invalidTimeout(Int)
    case unknownOutputKind(String)
    case folderOutputNeedsOutputFolder(edgeIndex: Int)
}

public enum TemplateError: Error, Equatable {
    case unresolved(String)
}

/// Expands `{key}` and `{key:default}` placeholders inside single argv elements. It never splits or joins
/// elements and never involves a shell. A key is `[A-Za-z][A-Za-z0-9]*`; a `{` or `}` that does not form a
/// placeholder stays as it is.
///
/// A key is looked up in `values` (the built-ins `input`, `output`, `outputDir`, `outputFolder`, `tempDir`, `tempDirURL`, `inputStem`),
/// then in `options.templateValue(for:)`, then its default. With none of these, expansion throws. `tempDirURL` is
/// `tempDir` as a percent-encoded `file://` URL with a trailing slash.
public enum ArgumentTemplate {
    enum Piece: Equatable {
        case literal(String)
        case placeholder(key: String, defaultValue: String?)
    }

    public static func expand(_ args: [String], values: [String: String], options: PresetOptions) throws -> [String] {
        try args.map { arg in
            var result = ""
            for piece in parse(arg) {
                switch piece {
                case .literal(let text):
                    result += text
                case .placeholder(let key, let defaultValue):
                    guard let value = values[key] ?? options.templateValue(for: key) ?? defaultValue else {
                        throw TemplateError.unresolved(key)
                    }
                    result += value
                }
            }
            return result
        }
    }

    /// The keys of the placeholders in `arg`, in order of appearance.
    static func placeholderKeys(in arg: String) -> [String] {
        parse(arg).compactMap { piece in
            if case .placeholder(let key, _) = piece { key } else { nil }
        }
    }

    static func parse(_ arg: String) -> [Piece] {
        let scalars = Array(arg.unicodeScalars)
        var pieces: [Piece] = []
        var literal = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "{", let (piece, next) = placeholder(in: scalars, at: i) {
                if !literal.isEmpty {
                    pieces.append(.literal(String(literal)))
                    literal = String.UnicodeScalarView()
                }
                pieces.append(piece)
                i = next
            } else {
                literal.append(scalars[i])
                i += 1
            }
        }
        if !literal.isEmpty { pieces.append(.literal(String(literal))) }
        return pieces
    }

    /// Parses a placeholder starting at the `{` at `start`; returns it and the index after its `}`.
    private static func placeholder(in scalars: [Unicode.Scalar], at start: Int) -> (Piece, Int)? {
        var i = start + 1
        guard i < scalars.count, isLetter(scalars[i]) else { return nil }
        let keyStart = i
        while i < scalars.count, isLetter(scalars[i]) || isDigit(scalars[i]) { i += 1 }
        guard i < scalars.count else { return nil }
        var key = String.UnicodeScalarView()
        key.append(contentsOf: scalars[keyStart..<i])
        if scalars[i] == "}" {
            return (.placeholder(key: String(key), defaultValue: nil), i + 1)
        }
        guard scalars[i] == ":" else { return nil }
        let defaultStart = i + 1
        guard let close = scalars[defaultStart...].firstIndex(of: "}") else { return nil }
        var defaultValue = String.UnicodeScalarView()
        defaultValue.append(contentsOf: scalars[defaultStart..<close])
        return (.placeholder(key: String(key), defaultValue: String(defaultValue)), close + 1)
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(s) || ("a"..."z").contains(s)
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(s)
    }
}
