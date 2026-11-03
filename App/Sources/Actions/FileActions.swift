// The wheel's file tools (P31): copy paths or files, reveal in Finder, zip, open Terminal. Nothing here modifies
// the files it is given; the zip is staged and published with `OutputPublisher` like any conversion output.
import AppKit
import Foundation
import PomeloCore
import PomeloUIModel

/// What can go wrong in a file action, with a short message (logged; never a raw error dump).
enum FileActionError: Error, LocalizedError, Equatable {
    case terminalNotFound
    case zipFailed(String)
    /// A dragged item is gone: its URL on the clipboard would paste nothing.
    case missing(name: String)

    var errorDescription: String? {
        switch self {
        case .terminalNotFound: "Terminal.app wasn't found"
        case .zipFailed(let message): "Couldn't make the zip: \(message)"
        case .missing(let name): "\(ResultSummary.shortened(name, to: ResultSummary.maxTitleNameLength)) was moved or deleted"
        }
    }
}

@MainActor
enum FileActions {
    /// Runs `kind` on `files`. Returns the files it created: the zip for `makeZip`, empty otherwise.
    /// `pasteboard` is a parameter so tests never touch the user's clipboard.
    static func run(
        _ kind: FileActionKind, on files: [URL], pasteboard: NSPasteboard = .general,
        destinations: DestinationResolver = .nextToSource
    ) async throws -> [URL] {
        switch kind {
        case .copyPaths:
            pasteboard.clearContents()
            pasteboard.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            return []
        case .copyFiles:
            if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw FileActionError.missing(name: missing.lastPathComponent)
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(files as [NSURL])
            return []
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(files)
            return []
        case .makeZip:
            return [try await makeZip(of: files, destinations: destinations)]
        case .openTerminal:
            try await openTerminal(in: terminalFolder(for: files))
            return []
        case .shelf:
            // The Shelf takes the files straight from the wheel (S31); no job ever reaches here.
            return []
        }
    }

    /// The folder Terminal opens in: the first item if it is a folder, otherwise its parent.
    static func terminalFolder(for files: [URL]) -> URL {
        guard let first = files.first else { return FileManager.default.homeDirectoryForCurrentUser }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return first
        }
        return first.deletingLastPathComponent()
    }

    // MARK: - Private

    private static func openTerminal(in folder: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw FileActionError.terminalNotFound
        }
        _ = try await NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: .init())
    }

    /// Zips `files` off the main actor: gathering copies a whole selection (a real data copy off APFS or across
    /// volumes) and `ditto` can run for minutes, and neither may stall the wheel, the menu bar or the drag monitor.
    /// A detached task doesn't inherit cancellation, so it is passed on: a cancel (from Finder, P24) stops `ditto`.
    private static func makeZip(of files: [URL], destinations: DestinationResolver) async throws -> URL {
        let zip = Task.detached { try await ZipBuilder.makeZip(of: files, destinations: destinations) }
        return try await withTaskCancellationHandler { try await zip.value } onCancel: { zip.cancel() }
    }
}

/// Builds the zip. Not main-actor: everything here is file and process work.
enum ZipBuilder {
    /// `ditto -c -k` is silent while it works, so ProcessRunner's inactivity timeout is raised far above its
    /// default (10 minutes) to let a very large archive finish.
    static let dittoTimeout: Duration = .seconds(6 * 60 * 60)

    /// `<stem>.zip` for one file, `<full name>.zip` for one folder (`v1.2` → `v1.2.zip`), `Archive.zip` for
    /// several, next to the first item (in Downloads when that folder is read-only). Built by `ditto` inside a
    /// staging folder on the destination's volume, then published without replacing anything.
    static func makeZip(of files: [URL], destinations: DestinationResolver = .nextToSource) async throws -> URL {
        guard let first = files.first else { throw FileActionError.zipFailed("no files") }
        let folder = destinations.destination(for: first, override: nil).folder
        let stem = files.count == 1 ? zipStem(of: first) : "Archive"

        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appending(path: "\(stem).zip", directoryHint: .notDirectory)
        // `ditto -c -k` archives exactly one source, so several items are first gathered into an `Archive` folder
        // (copies, which are clones on APFS), like Finder's Compress does.
        let source: URL
        if files.count == 1 {
            source = first
        } else {
            source = staging.appending(path: stem, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            var taken: Set<String> = []
            for file in files {
                try Task.checkCancellation()
                let target = OutputNamer().uniqueURL(
                    stem: OutputNamer.stem(of: file), ext: file.pathExtension, suffix: nil, in: source, avoiding: taken
                )
                taken.insert(target.lastPathComponent.lowercased())
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
        do {
            _ = try await ProcessRunner(timeout: dittoTimeout).run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, staged.path]
            )
        } catch let error as ProcessRunnerError {
            throw FileActionError.zipFailed(message(for: error))
        }
        // A zip cancelled as `ditto` ended is still never published.
        try Task.checkCancellation()
        // The sources' names are claimed, so a source called `Archive.zip` is never taken as the zip's name.
        return try OutputPublisher.publish(
            staged: staged, to: folder, stem: stem, ext: "zip", suffix: nil,
            avoiding: Set(files.map { $0.lastPathComponent.lowercased() }), namer: OutputNamer()
        )
    }

    /// The name a single item's zip takes: a folder's full name (its dots are part of the name, not an
    /// extension), a file's stem.
    static func zipStem(of item: URL) -> String {
        let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isFolder ? item.lastPathComponent : OutputNamer.stem(of: item)
    }

    /// A human message for every way the process can fail, never the raw error dump.
    static func message(for error: ProcessRunnerError) -> String {
        switch error {
        case .launchFailed(let code):
            return "ditto couldn't start (\(String(cString: strerror(code))))"
        case .timedOut:
            return "ditto stopped responding"
        case .nonZeroExit(let code, let stderrTail):
            let text = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "ditto failed (exit code \(code))" : text
        }
    }
}
