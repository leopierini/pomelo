// A finished job in a few words: a title, an optional detail line, and whether the run counts as a failure. The
// wheel's red hub shows a failure that arrives while it is still up, and the pill one the hub did not show (P25), so
// the text must fit both and read as a person would say it. The raw error (engine IDs, a tool's stderr) is only logged.
// Only Foundation and PomeloCore: no AppKit.
import Foundation
import PomeloCore

public struct ResultSummary: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// True when at least one file failed.
    public var isFailure: Bool

    public init(title: String, detail: String? = nil, isFailure: Bool = false) {
        self.title = title
        self.detail = detail
        self.isFailure = isFailure
    }

    /// The longest detail, ellipsis included: about two caption lines of the 108 pt hub.
    public static let maxDetailLength = 45
    /// The longest file name in a title, ellipsis included, so the title fits the hub's three headline lines.
    public static let maxTitleNameLength = 24

    /// Summarises a finished job.
    ///
    /// - Title: `Converted <name>` / `Converted <n> files` when everything succeeded; `<ok> of <n> converted` when
    ///   some files failed or were cancelled (cancelled files count in `n`); `Couldn't convert <name|n files>` when
    ///   none succeeded and some failed; `Cancelled` when every file was cancelled. For `tool` (a tool's name, an
    ///   editor's without its "…"): `Finished <name|n files>`, `<ok> of <n> finished`, `Couldn't run <tool>` (the
    ///   hub's thumbnail names a lone file, and the title must fit its three lines) or `Couldn't run <tool> on <n>
    ///   files`: a tool doesn't convert.
    /// - Detail: the first failure's reason in a few words (`reason(for:)`), never the raw error. A one-file job's
    ///   title already names the file (`The file may be damaged`); in a job of several files the reason names it
    ///   and counts further failures (`bad.png may be damaged (and 2 more)`). At most `maxDetailLength`
    ///   characters: a long name is shortened in the middle. Nil when nothing failed.
    public static func make(results: [FileResult], tool: String? = nil) -> ResultSummary {
        var succeeded = 0
        var failures: [(source: URL, error: ConversionError)] = []
        for result in results {
            switch result {
            case .succeeded: succeeded += 1
            case .failed(let source, let error): failures.append((source, error))
            case .cancelled: break
            }
        }

        let tool = tool.map { $0.hasSuffix("\u{2026}") ? String($0.dropLast()) : $0 }
        let title: String
        if results.isEmpty {
            title = "Nothing to convert"
        } else if succeeded == 0 {
            title = failureTitle(failures, tool: tool)
        } else if succeeded == results.count {
            let done = tool == nil ? "Converted" : "Finished"
            title = succeeded == 1
                ? "\(done) \(shortened(results[0].source.lastPathComponent, to: maxTitleNameLength))"
                : "\(done) \(succeeded) files"
        } else {
            title = "\(succeeded) of \(results.count) \(tool == nil ? "converted" : "finished")"
        }

        var detail: String?
        if let first = failures.first {
            if results.count == 1 {
                detail = reason(for: first.error)
            } else {
                let more = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
                detail = fitted(name: first.source.lastPathComponent) { reason(for: first.error, naming: $0) + more }
            }
        }
        return ResultSummary(title: title, detail: detail, isFailure: !failures.isEmpty)
    }

    /// The title when no file succeeded: none failed either, so the job was cancelled, or one or more failed.
    private static func failureTitle(_ failures: [(source: URL, error: ConversionError)], tool: String?) -> String {
        if failures.isEmpty { return "Cancelled" }
        if let tool {
            return failures.count == 1 ? "Couldn't run \(tool)" : "Couldn't run \(tool) on \(failures.count) files"
        }
        return failures.count == 1
            ? "Couldn't convert \(shortened(failures[0].source.lastPathComponent, to: maxTitleNameLength))"
            : "Couldn't convert \(failures.count) files"
    }

    /// Summarises a finished job of `request`: a combine's summary (`makeCombined`) or each file's (`make`). A combine
    /// into one PDF (the `combine` operation: Combine into PDF, Merge PDFs) combines; any other is `tool`'s run.
    public static func make(results: [FileResult], of request: ConversionRequest, tool: String?) -> ResultSummary {
        guard request.combinesInputs else { return make(results: results, tool: tool) }
        return makeCombined(results: results, tool: request.operation == "combine" ? nil : tool)
    }

    /// Summarises a combining job, whose files succeed or fail together: `Combined <n> files`, `Couldn't combine
    /// <n> files` with the failed file's reason naming it (`b.pdf may be damaged`), or `Cancelled`. For `tool` (a
    /// combine that makes no document, such as Find duplicates): `Finished <n> files` and `Couldn't run <tool>`. A
    /// reason it doesn't apply is shown bare: in a combine it concerns the whole set, not the input it was put on.
    public static func makeCombined(results: [FileResult], tool: String? = nil) -> ResultSummary {
        if results.isEmpty { return ResultSummary(title: "Nothing to combine") }
        let files = results.count == 1 ? "1 file" : "\(results.count) files"
        let failure = results.lazy.compactMap { result -> (source: URL, error: ConversionError)? in
            if case .failed(let source, let error) = result { (source, error) } else { nil }
        }.first
        if let failure {
            let detail = if case .notApplicable(let reason) = failure.error {
                reason
            } else {
                fitted(name: failure.source.lastPathComponent) { reason(for: failure.error, naming: $0) }
            }
            return ResultSummary(
                title: tool.map { "Couldn't run \($0)" } ?? "Couldn't combine \(files)", detail: detail, isFailure: true
            )
        }
        if results.allSatisfy({ if case .succeeded = $0 { true } else { false } }) {
            return ResultSummary(title: tool == nil ? "Combined \(files)" : "Finished \(files)")
        }
        return ResultSummary(title: "Cancelled")
    }

    /// Why a file failed, as a short sentence about "the file". An engine's failure is the file's (damaged or
    /// unsupported); the converter's own trouble has its own case (M5), so no message is ever matched as text.
    public static func reason(for error: ConversionError) -> String {
        switch error {
        case .sourceMissing: "The file was moved or deleted"
        case .isDirectory: "It's a folder"
        case .notARegularFile: "It's not a regular file"
        case .unknownFormat: "Pomelo doesn't know this format"
        case .noRoute(_, let target): "Can't become \(displayName(of: target))"
        case .engineFailed: "The file may be damaged"
        case .converterUnavailable: "The converter isn't available"
        case .engineUnsupported(_, let reason): reason
        case .converterTimedOut: "The converter stopped responding"
        case .converterFault: "The converter failed"
        case .notApplicable(let reason): reason
        case .publishFailed: "Couldn't save the result"
        }
    }

    /// Why `file` failed, naming it.
    static func reason(for error: ConversionError, naming file: String) -> String {
        switch error {
        case .sourceMissing: "\(file) was moved or deleted"
        case .isDirectory: "\(file) is a folder"
        case .notARegularFile: "\(file) isn't a regular file"
        case .unknownFormat: "\(file) has an unknown format"
        case .noRoute(_, let target): "\(file) can't become \(displayName(of: target))"
        case .engineFailed: "\(file) may be damaged"
        case .converterUnavailable: "\(file): the converter isn't available"
        // Kept as written, as every engine's reason: it may start with a name ("Apple Intelligence…").
        case .engineUnsupported(_, let reason): "\(file): \(reason)"
        case .converterTimedOut: "\(file): the converter stopped responding"
        case .converterFault: "\(file): the converter failed"
        case .notApplicable(let reason): "\(file): \(reason)"
        case .publishFailed: "\(file): couldn't save the result"
        }
    }

    private static func displayName(of format: FormatID) -> String {
        FormatRegistry.builtIn.format(id: format)?.displayName ?? format.rawValue.uppercased()
    }

    /// `make(name)`, with `name` shortened in the middle as far as needed to keep the whole within
    /// `maxDetailLength`; the end is cut when even a short name does not fit.
    static func fitted(name: String, _ make: (String) -> String) -> String {
        let whole = make(name)
        guard whole.count > maxDetailLength else { return whole }
        let room = maxDetailLength - (whole.count - name.count)
        if room >= 8 { return make(shortened(name, to: room)) }
        return String(whole.prefix(maxDetailLength - 1)) + "\u{2026}"
    }

    /// `name` cut to `length` characters in the middle, keeping its extension when it can: `a-very-l…name.png`.
    public static func shortened(_ name: String, to length: Int) -> String {
        guard name.count > length, length > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let tailCount = ext.isEmpty || ext.count + 4 > length / 2 ? (length - 1) / 2 : ext.count + 4
        let headCount = length - 1 - tailCount
        return String(name.prefix(headCount)) + "\u{2026}" + String(name.suffix(tailCount))
    }
}
