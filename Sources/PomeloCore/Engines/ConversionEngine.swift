import Foundation

/// One hop of a route, handed to an engine. The engine writes only inside `stagingDirectory`.
public struct ConversionStep: Sendable {
    public let input: URL
    public let stagingDirectory: URL
    public let from: FileFormat
    public let to: FileFormat
    public let options: PresetOptions
    /// The tool this step performs, or nil for a conversion.
    public let operation: String?

    public init(
        input: URL, stagingDirectory: URL, from: FileFormat, to: FileFormat, options: PresetOptions,
        operation: String? = nil
    ) {
        self.input = input
        self.stagingDirectory = stagingDirectory
        self.from = from
        self.to = to
        self.options = options
        self.operation = operation
    }

    /// `stagingDirectory/<stem>.<canonical extension of the target>`.
    public var suggestedOutput: URL {
        stagingDirectory.appending(path: "\(OutputNamer.stem(of: input)).\(to.extensions[0])", directoryHint: .notDirectory)
    }
    /// `stagingDirectory/<stem>`, for a tool that produces a folder.
    public var suggestedFolder: URL {
        stagingDirectory.appending(path: OutputNamer.stem(of: input), directoryHint: .isDirectory)
    }
}

public enum EngineAvailability: Sendable, Equatable {
    case available(version: String?)
    case missing(installHint: String)
    /// This Mac can't run the engine, and no install would change that (an older macOS, no Apple Intelligence).
    /// `reason` is a full sentence for the person, ending with a period: "Needs macOS 26."
    case unsupported(reason: String)
}

public protocol ConversionEngine: Sendable {
    var id: EngineID { get }
    var displayName: String { get }
    var maxConcurrentJobs: Int { get }
    func availability() async -> EngineAvailability
    /// True when the answer of `availability()` can change while the app runs and costs no more than a property
    /// read (Apple Intelligence getting ready or turned on): the registry asks again before each job.
    var availabilityIsVolatile: Bool { get }
    func version() async -> String?
    /// The engine this one runs on, for a composite that has no install of its own (R5): the registry answers its
    /// availability and install hint with that engine's and lists it nowhere, so only the host is ever shown.
    var hostEngineID: EngineID? { get }
    func edges() -> [ConversionEdge]
    /// Performs the step and returns the file or folder it created inside `step.stagingDirectory`.
    func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension ConversionEngine {
    public var availabilityIsVolatile: Bool { false }
    public var hostEngineID: EngineID? { nil }
    public func version() async -> String? { nil }
}

/// Many inputs that become one output (a merge), handed to a `CombiningEngine`. The engine writes only inside
/// `stagingDirectory`.
public struct CombineStep: Sendable {
    /// In the order of the request.
    public let inputs: [URL]
    /// The format of each input, index for index.
    public let formats: [FileFormat]
    public let stagingDirectory: URL
    public let to: FileFormat
    public let operation: String

    public init(inputs: [URL], formats: [FileFormat], stagingDirectory: URL, to: FileFormat, operation: String) {
        self.inputs = inputs
        self.formats = formats
        self.stagingDirectory = stagingDirectory
        self.to = to
        self.operation = operation
    }

    /// `stagingDirectory/<first input's stem>.<canonical extension of the target>`.
    public var suggestedOutput: URL {
        let stem = inputs.first.map(OutputNamer.stem(of:)) ?? "combined"
        return stagingDirectory.appending(path: "\(stem).\(to.extensions[0])", directoryHint: .notDirectory)
    }
}

/// An engine that can also turn many inputs into one output. The runner hands it a combine only when every
/// input's operation edge is on this engine.
public protocol CombiningEngine: ConversionEngine {
    /// Performs the step and returns the file it created inside `step.stagingDirectory`. To blame one input (a
    /// damaged or locked file), throw `CombineInputError`; any other error is blamed on the first input.
    func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Thrown by a combining engine when one input is the cause: the runner fails that input and cancels the others.
public struct CombineInputError: Error {
    public let input: URL
    public let underlying: any Error

    public init(input: URL, underlying: any Error) {
        self.input = input
        self.underlying = underlying
    }
}

public struct EngineStatus: Sendable, Equatable {
    public let id: EngineID
    public let displayName: String
    public let availability: EngineAvailability

    public init(id: EngineID, displayName: String, availability: EngineAvailability) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
    }
}
