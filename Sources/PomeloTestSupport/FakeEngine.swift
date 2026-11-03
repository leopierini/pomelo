import Foundation
import PomeloCore

/// A scriptable engine for tests: "converts" by copying the input and appending `"\n->\(to.id)"` (plus
/// ` [operation]` for a tool), then the JSON of `options.edit` and `targetBytes` when set. `outputBytes` writes that
/// many bytes instead; `folderItems` produces a folder of files. `unsupportedReason` makes it report
/// `.unsupported(reason:)`, which wins over `available`.
public struct FakeEngine: ConversionEngine {
    public struct Failure: Error, Equatable {
        public init() {}
    }

    public let id: EngineID
    public let maxConcurrentJobs: Int
    private let fakeEdges: [ConversionEdge]
    private let isAvailable: Bool
    private let unsupportedReason: String?
    private let failOnStem: String?
    private let delay: Duration
    private let outputBytes: Int?
    private let folderItems: [String]?

    public init(
        id: EngineID,
        edges: [ConversionEdge],
        available: Bool = true,
        unsupportedReason: String? = nil,
        failOnStem: String? = nil,
        delay: Duration = .zero,
        maxConcurrentJobs: Int = 4,
        outputBytes: Int? = nil,
        folderItems: [String]? = nil
    ) {
        self.id = id
        self.fakeEdges = edges
        self.isAvailable = available
        self.unsupportedReason = unsupportedReason
        self.failOnStem = failOnStem
        self.delay = delay
        self.maxConcurrentJobs = maxConcurrentJobs
        self.outputBytes = outputBytes
        self.folderItems = folderItems
    }

    public var displayName: String { id.rawValue }

    public func availability() async -> EngineAvailability {
        if let unsupportedReason { return .unsupported(reason: unsupportedReason) }
        return isAvailable ? .available(version: nil) : .missing(installHint: "fake")
    }

    public func edges() -> [ConversionEdge] { fakeEdges }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failOnStem, OutputNamer.stem(of: step.input) == failOnStem { throw Failure() }
        if let folderItems {
            let folder = step.suggestedFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in folderItems {
                try Data(name.utf8).write(to: folder.appending(path: name, directoryHint: .notDirectory))
            }
            progress(1.0)
            return folder
        }
        let output = step.suggestedOutput
        if let outputBytes {
            try Data(repeating: 0x2A, count: outputBytes).write(to: output)
            progress(1.0)
            return output
        }
        var data = try Data(contentsOf: step.input)
        data.append(Data("\n->\(step.to.id)\(step.operation.map { " [\($0)]" } ?? "")".utf8))
        if let edit = step.options.edit {
            data.append(Data("\nedit: \(Self.json(edit))".utf8))
        }
        if let targetBytes = step.options.targetBytes {
            data.append(Data("\ntargetBytes: \(targetBytes)".utf8))
        }
        try data.write(to: output)
        progress(1.0)
        return output
    }

    private static func json(_ edit: EditSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(edit)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
}

/// A scriptable combining engine for tests: its output is its inputs' bytes, concatenated in order. An input whose
/// stem is `failOnStem` fails the combine, named in a `CombineInputError`.
public struct FakeCombiningEngine: CombiningEngine {
    public let id: EngineID
    public let maxConcurrentJobs = 1
    private let fakeEdges: [ConversionEdge]
    private let failOnStem: String?
    private let delay: Duration

    public init(id: EngineID, edges: [ConversionEdge], failOnStem: String? = nil, delay: Duration = .zero) {
        self.id = id
        self.fakeEdges = edges
        self.failOnStem = failOnStem
        self.delay = delay
    }

    public var displayName: String { id.rawValue }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] { fakeEdges }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await combine(
            CombineStep(
                inputs: [step.input], formats: [step.from], stagingDirectory: step.stagingDirectory, to: step.to,
                operation: step.operation ?? "combine"
            ),
            progress: progress
        )
    }

    public func combine(_ step: CombineStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if delay != .zero { try await Task.sleep(for: delay) }
        var data = Data()
        for (index, input) in step.inputs.enumerated() {
            if let failOnStem, OutputNamer.stem(of: input) == failOnStem {
                throw CombineInputError(input: input, underlying: FakeEngine.Failure())
            }
            data.append(try Data(contentsOf: input))
            progress(Double(index + 1) / Double(step.inputs.count))
        }
        try data.write(to: step.suggestedOutput)
        return step.suggestedOutput
    }
}
