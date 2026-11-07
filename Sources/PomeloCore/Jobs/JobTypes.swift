import Foundation

/// A batch of files to convert to one target with one set of options.
public struct ConversionRequest: Sendable {
    public var inputs: [URL]
    /// nil means "same format as each source" (same-format tools such as "Half size").
    public var target: FormatID?
    public var options: PresetOptions
    /// Used in the output name of same-format tools (`photo-half.jpg`).
    public var nameSuffix: String?
    /// An explicit output folder; nil puts each output next to its source.
    public var outputFolder: URL?
    /// A tool's name; the runner then plans one operation edge instead of a conversion route.
    public var operation: String?
    /// A result that is not smaller than its source fails with "Already compressed" (folders are exempt).
    public var onlyIfSmaller = false
    public var outputNaming: OutputNaming = .fromSource
    /// Opt-in: a result of the same kind next to its source takes the source's place (its name, with the result's
    /// extension), the source going to the Trash (P273).
    public var replaceOriginal = false
    /// All inputs become one output (a merge) through one `CombiningEngine`; it never replaces a source and is
    /// never refused for its size.
    public var combinesInputs = false

    public init(
        inputs: [URL],
        target: FormatID?,
        options: PresetOptions = .init(),
        nameSuffix: String? = nil,
        outputFolder: URL? = nil,
        operation: String? = nil
    ) {
        self.inputs = inputs
        self.target = target
        self.options = options
        self.nameSuffix = nameSuffix
        self.outputFolder = outputFolder
        self.operation = operation
    }

    public static func from(_ preset: Preset, inputs: [URL]) -> ConversionRequest {
        var request = ConversionRequest(
            inputs: inputs, target: preset.target, options: preset.options, nameSuffix: preset.nameSuffix,
            operation: preset.operation
        )
        request.onlyIfSmaller = preset.onlyIfSmaller
        request.outputNaming = preset.outputNaming
        request.combinesInputs = preset.combinesInputs
        return request
    }
}

/// Where a result's name comes from.
public enum OutputNaming: String, Codable, Sendable {
    /// `<source stem>-<suffix>.<ext>`.
    case fromSource
    /// The produced item's own name (an extracted folder).
    case fromOutput
}

public enum ResultNote: Sendable, Equatable {
    /// The source's folder was not writable, so the output went to the Downloads folder.
    case fellBackToDownloads
    /// The source went to the Trash. The result has the source's name, or keeps its own when that name was taken
    /// again in the meantime.
    case replacedOriginal
}

public enum ConversionError: Error, Sendable, Equatable {
    case sourceMissing
    case isDirectory
    /// A FIFO, socket or device: opening one can block forever, so it never reaches an engine.
    case notARegularFile
    case unknownFormat(ext: String)
    case noRoute(from: FormatID, to: FormatID)
    /// The engine could not do the work on this file: most likely the file itself is damaged or unsupported.
    case engineFailed(engine: EngineID, message: String)
    /// The engine or its executable is not there, or could not be launched.
    case converterUnavailable(engine: EngineID, message: String)
    /// The engine can't do this work, for a reason it words for the person and the app shows as written: the route
    /// needs an engine this Mac can't run ("Needs macOS 26.") or the file is one it refuses ("It's password-protected").
    case engineUnsupported(engine: EngineID, reason: String)
    case converterTimedOut(engine: EngineID)
    /// The converter misbehaved whatever the file: no matching manifest edge, an unresolved placeholder, no output,
    /// or an item returned outside its staging folder.
    case converterFault(engine: EngineID, message: String)
    /// The work does not apply to this file, as a sentence written for the person ("No code found").
    case notApplicable(reason: String)
    case publishFailed(message: String)
}

extension ConversionError: CustomStringConvertible {
    /// A short human-readable message, shared by the CLI and the app.
    public var description: String {
        switch self {
        case .sourceMissing: "file not found"
        case .isDirectory: "is a folder"
        case .notARegularFile: "not a regular file"
        case .unknownFormat(let ext): "unknown format .\(ext)"
        case .noRoute(let from, let to): "can't convert \(from) to \(to)"
        case .engineFailed(let engine, let message): "\(engine): \(message)"
        case .converterUnavailable(let engine, let message): "\(engine): \(message)"
        // As written, as the app shows it: the sentence already says why ("Needs macOS 26.").
        case .engineUnsupported(_, let reason): reason
        case .converterTimedOut(let engine): "\(engine): timed out"
        case .converterFault(let engine, let message): "\(engine): \(message)"
        // As written: a reason may start with a name ("Apple Intelligence…", "Pomelo…").
        case .notApplicable(let reason): reason
        case .publishFailed(let message): "couldn't save: \(message)"
        }
    }
}

public enum FileResult: Sendable, Equatable {
    case succeeded(source: URL, outputs: [URL], note: ResultNote?)
    case failed(source: URL, error: ConversionError)
    case cancelled(source: URL)

    public var source: URL {
        switch self {
        case .succeeded(let source, _, _), .failed(let source, _), .cancelled(let source): source
        }
    }
}

public enum JobEvent: Sendable {
    /// The file's work began: its first step got a slot of its engine (`maxConcurrentJobs`), so the app can time
    /// how long it really runs. A file that fails, or is cancelled before or while it waits for that slot, only reports
    /// `.fileFinished`.
    case fileStarted(index: Int)
    /// `fraction` is 0...1 for the whole file, across all of its steps.
    case progress(index: Int, fraction: Double)
    case fileFinished(index: Int, result: FileResult)
}
