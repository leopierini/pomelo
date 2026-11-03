// DEBUG only: `Pomelo --snapshot-wheel <file> <out.png> [page] [hoverIndex] [light|dark] [state=<state>]
// [settings=<settings.json>]` renders the wheel for <file> with ImageRenderer at scale 2, writes a PNG and exits. It
// lets the wheel be checked without a Finder drag. The page is a built-in kind or an index (a customized wheel's
// pages have no kind); without one, the page the wheel opens on. The file goes through the readability check, so a
// damaged one shows the red hub; `state=failure` shows a failed job's red hub, `state=note` a job's note in the accent
// colour and `state=automation` click mode's Automation prompt. `settings=` loads a blob's customized wheels
// (`EvalHooks.inMemoryDefaults`).
#if DEBUG
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

/// The parsed `--snapshot-wheel` arguments.
struct WheelSnapshotRequest: Equatable {
    static let flag = "--snapshot-wheel"
    static let usage = """
        usage: Pomelo --snapshot-wheel <file> <out.png> [convert|tools|ai|<page index>] [hoverIndex] [light|dark] \
        [state=failure|note|automation] [settings=<settings.json>]
        """

    enum Page: Equatable {
        case kind(WheelPageKind)
        case index(Int)
    }

    /// A wheel state the snapshot can show besides choosing.
    enum State: String {
        /// A dropped job failed: the red hub with a fixed summary, slices live (P191).
        case failure
        /// A dropped job succeeded with a note (P25): the accent hub, slices dimmed.
        case note
        /// Click mode's Automation prompt: no slices (the file is only needed by the parser).
        case automation
    }

    var file: URL
    var output: URL
    /// Nil for the page the wheel opens on.
    var page: Page?
    /// The 0-based slice to show hovered; nil for none.
    var hoverIndex: Int?
    var dark = false
    var state: State?

    struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    /// nil when `arguments` has no `--snapshot-wheel`; throws when the flag's arguments are malformed.
    static func parse(_ arguments: [String]) throws -> WheelSnapshotRequest? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        var rest = Array(arguments[(flagIndex + 1)...])
        var state: State?
        if let index = rest.firstIndex(where: { $0.hasPrefix("state=") }) {
            guard let parsed = State(rawValue: String(rest[index].dropFirst("state=".count))) else {
                throw UsageError(description: "unknown \(rest[index])\n\(usage)")
            }
            state = parsed
            rest.remove(at: index)
        }
        // Checked here for the usage error; the file itself is loaded with the launch's defaults.
        _ = try EvalHooks.settingsFile(in: arguments)
        rest.removeAll { $0.hasPrefix(EvalHooks.settingsPrefix) }
        guard rest.count >= 2, rest.count <= 5 else { throw UsageError(description: usage) }
        var request = WheelSnapshotRequest(file: URL(fileURLWithPath: rest[0]), output: URL(fileURLWithPath: rest[1]))
        request.state = state
        if rest.count > 2 {
            if let kind = WheelPageKind(rawValue: rest[2]) {
                request.page = .kind(kind)
            } else if let index = Int(rest[2]), index >= 0 {
                request.page = .index(index)
            } else {
                throw UsageError(description: "unknown page \(rest[2])\n\(usage)")
            }
        }
        if rest.count > 3 {
            guard let index = Int(rest[3]), index >= 0 else {
                throw UsageError(description: "hoverIndex must be a slice index from 0\n\(usage)")
            }
            request.hoverIndex = index
        }
        if rest.count > 4 {
            guard ["light", "dark"].contains(rest[4]) else { throw UsageError(description: usage) }
            request.dark = rest[4] == "dark"
        }
        return request
    }
}

enum WheelSnapshot {
    /// When the process was launched with `--snapshot-wheel`, schedules the render (which exits the process) and
    /// returns true; otherwise returns false and the app launches normally.
    @MainActor
    static func runIfRequested(arguments: [String], environment: AppEnvironment) -> Bool {
        let request: WheelSnapshotRequest
        do {
            guard let parsed = try WheelSnapshotRequest.parse(arguments) else { return false }
            request = parsed
        } catch {
            DebugOutput.fail("\(error)", 64)
        }
        Task {
            do {
                try await render(request, environment: environment)
                print(request.output.path)
                exit(0)
            } catch {
                DebugOutput.fail("snapshot failed: \(error)")
            }
        }
        return true
    }

    @MainActor
    private static func pageIndex(for page: WheelSnapshotRequest.Page?, in model: WheelModel) -> Int? {
        switch page {
        case nil: model.pageIndex
        case .kind(let kind): model.pages.firstIndex { $0.kind == kind }
        case .index(let index): model.pages.indices.contains(index) ? index : nil
        }
    }

    @MainActor
    private static func render(_ request: WheelSnapshotRequest, environment: AppEnvironment) async throws {
        typealias Failure = WheelSnapshotRequest.UsageError
        guard FileManager.default.fileExists(atPath: request.file.path) else {
            throw Failure(description: "no file at \(request.file.path)")
        }
        guard request.output.standardizedFileURL != request.file.standardizedFileURL else {
            throw Failure(description: "the output would overwrite the input")
        }
        await environment.rebuildWheelContent()
        guard let builder = environment.contentBuilder else { throw Failure(description: "no wheel content") }

        let model = WheelModel()
        let settings = environment.settingsStore.settings
        model.trigger = settings.trigger
        model.load(pages: builder.pages(for: [request.file]), files: [request.file], builder: builder,
                   firstPage: settings.firstPage)
        // The live wheel applies the check after it opens (up to 2 s per video); the snapshot waits for it.
        model.apply(await FileReadability.check([request.file]))
        guard let pageIndex = pageIndex(for: request.page, in: model) else {
            let pages = model.pages.map(\.id).joined(separator: ", ")
            throw Failure(description: "no such page for this file (pages: \(pages))")
        }
        model.setPage(pageIndex)
        if let hoverIndex = request.hoverIndex {
            guard model.slices.indices.contains(hoverIndex) else {
                throw Failure(description: "hoverIndex \(hoverIndex) is outside 0..<\(model.slices.count)")
            }
            model.setHovered(hoverIndex)
        }
        model.thumbnail = await WheelThumbnail.load(for: request.file, scale: 2)
            ?? WheelThumbnail.placeholder(for: request.file)
        if request.state == .failure {
            model.beginWaiting()
            let summary = ResultSummary.make(results: [
                .succeeded(source: request.file, outputs: [], note: nil),
                .failed(source: URL(fileURLWithPath: "/tmp/bad.png"),
                        error: .engineFailed(engine: "imageio", message: "cannot open bad.png as an image")),
                .succeeded(source: request.file, outputs: [], note: nil),
            ])
            guard case .showFailure(let alert) = DropFollowUp.decision(for: .failed(summary)) else { return }
            model.showFailure(alert)
        }
        if request.state == .note {
            model.beginWaiting()
            let note = ResultSummary(title: "Saved to Downloads", detail: "The folder is read-only")
            guard case .showNote(let alert) = DropFollowUp.decision(for: .noted(note)) else { return }
            model.showNote(alert)
        }
        if request.state == .automation {
            model.clickMode = true
            model.load(prompt: .allowAutomation)
        }

        try DebugOutput.render(WheelView(model: model), dark: request.dark, to: request.output)
    }
}
#endif
