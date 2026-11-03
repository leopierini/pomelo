import CryptoKit
import Darwin
import Foundation
import PomeloCore

public enum InstallStage: Sendable, Equatable {
    case downloading(fraction: Double?), verifying, unpacking, checking
}

public enum InstallError: Error, Equatable {
    case notAvailableForThisMac, downloadFailed, tooLarge, checksumMismatch, memberMissing, notAnExecutable,
        wrongArchitecture, doesNotRun, cancelled

    /// A short sentence for the UI (P32); nil when the person cancelled, which needs no explanation.
    public var reason: String? {
        switch self {
        case .notAvailableForThisMac: "No download for this Mac"
        case .downloadFailed: "The download failed"
        case .tooLarge: "The download is larger than expected"
        case .checksumMismatch: "The download didn't match its checksum"
        case .memberMissing, .notAnExecutable: "The download didn't hold the program"
        case .wrongArchitecture: "The program doesn't run on this Mac"
        case .doesNotRun: "The program didn't start"
        case .cancelled: nil
        }
    }
}

/// Installs a pinned engine build into `<enginesFolder>/<id>/bin/`, where `ExecutableLocator` looks first.
///
/// Safety: no byte of the download is parsed before its SHA-256 equals the pin, so bsdtar only ever reads the
/// pinned archive; only the one expected member is unpacked, and only a regular Mach-O file for this Mac leaves
/// the work folder (bsdtar gives it the archive's mode in there, before it is checked). Every failure removes the
/// work folder; one before the rename leaves the engines folder as it was, and an old program goes to the Trash only
/// once nothing but the rename is left (P113). The one exception is the version probe after the rename: a program
/// that fails it, or is cancelled then, goes to the Trash too, so a reinstall leaves the engine missing (P132).
/// Installs of one engine never overlap: a second caller gets the first's result.
public actor EngineInstaller {
    private static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    private static let probeTimeout: Duration = .seconds(10)

    private let enginesFolder: URL
    private let downloader: any Downloader
    private let table: [EngineDownload]
    private let machine: MachineArch
    private let trashItem: @Sendable (URL) throws -> Void
    private let volume: @Sendable (URL) -> dev_t?

    public init(
        enginesFolder: URL, downloader: any Downloader, table: [EngineDownload] = PinnedDownloads.all,
        machine: MachineArch = .current, trashItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.init(
            enginesFolder: enginesFolder, downloader: downloader, table: table, machine: machine, trashItem: trashItem,
            volume: Self.volume(of:)
        )
    }

    /// Tests pass `volume` to put the work folder and the engines folder on different volumes.
    init(
        enginesFolder: URL, downloader: any Downloader, table: [EngineDownload], machine: MachineArch,
        trashItem: @escaping @Sendable (URL) throws -> Void, volume: @escaping @Sendable (URL) -> dev_t?
    ) {
        self.enginesFolder = enginesFolder
        self.downloader = downloader
        self.table = table
        self.machine = machine
        self.trashItem = trashItem
        self.volume = volume
    }

    /// The device `url` (followed through symlinks) lives on.
    static func volume(of url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    private var inFlight: [EngineID: Task<URL, any Error>] = [:]
    private var waiting: [EngineID: Int] = [:]

    /// How many callers are waiting for an install of `engine` already under way, for tests.
    func waitingCallers(for engine: EngineID) -> Int { waiting[engine, default: 0] }

    /// Returns the installed executable. Throws `InstallError` only; cancelling the task throws `.cancelled`.
    /// While an install of `engine` is under way, another call waits for it and returns (or throws) what it did,
    /// without stages; cancelling that waiting call doesn't stop the first.
    public func install(_ engine: EngineID, stage: @escaping @Sendable (InstallStage) -> Void) async throws -> URL {
        if let running = inFlight[engine] {
            waiting[engine, default: 0] += 1
            defer { waiting[engine, default: 1] -= 1 }
            return try await running.value
        }
        let task = Task { try await self.mapped(engine, stage: stage) }
        inFlight[engine] = task
        defer { inFlight[engine] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func mapped(_ engine: EngineID, stage: @escaping @Sendable (InstallStage) -> Void) async throws -> URL {
        do {
            return try await run(engine, stage: stage)
        } catch let error as InstallError {
            throw Task.isCancelled ? .cancelled : error
        } catch {
            throw error is CancellationError || Task.isCancelled ? InstallError.cancelled : InstallError.downloadFailed
        }
    }

    private func run(_ engine: EngineID, stage: @escaping @Sendable (InstallStage) -> Void) async throws -> URL {
        guard let entry = PinnedDownloads.download(for: engine, on: machine, in: table) else {
            throw InstallError.notAvailableForThisMac
        }
        let manager = FileManager.default
        try manager.createDirectory(at: enginesFolder, withIntermediateDirectories: true)
        // Asked for the resolved folder: for a link to another disk, the unresolved path gives a work folder on the
        // boot volume and the final rename fails (EXDEV). Everything else uses the caller's path.
        guard let resolved = realpath(enginesFolder.path, nil) else { throw InstallError.downloadFailed }
        let target = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        let work = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
        )
        defer { try? manager.removeItem(at: work) }

        let download = work.appending(path: "download")
        stage(.downloading(fraction: nil))
        try await downloader.download(entry.url, to: download, maxBytes: entry.maxBytes) { received, expected in
            stage(.downloading(fraction: expected.map { $0 > 0 ? min(1, Double(received) / Double($0)) : 0 }))
        }
        try Task.checkCancellation()
        // lstat first: chmod follows symlinks.
        guard let size = regularFileSize(download), chmod(download.path, 0o600) == 0 else {
            throw InstallError.downloadFailed
        }
        guard size <= entry.maxBytes else { throw InstallError.tooLarge }

        stage(.verifying)
        guard try Self.sha256(of: download) == entry.sha256 else { throw InstallError.checksumMismatch }

        stage(.unpacking)
        let unpacked = try await unpack(entry.member, from: download, into: work.appending(path: "x"))

        stage(.checking)
        let archs: Set<MachineArch>
        do { archs = try MachO.architectures(of: unpacked) } catch { throw InstallError.notAnExecutable }
        guard archs.contains(machine) else { throw InstallError.wrongArchitecture }
        guard chmod(unpacked.path, 0o755) == 0 else { throw InstallError.downloadFailed }
        if removexattr(unpacked.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw InstallError.downloadFailed
        }
        try Task.checkCancellation()

        let placed = try place(unpacked, as: entry, work: work)
        do {
            try await probe(placed.executable, arguments: entry.versionArguments)
        } catch {
            try? trashItem(placed.executable)
            placed.removeCreatedFolders()
            throw error is CancellationError || Task.isCancelled ? InstallError.cancelled : InstallError.doesNotRun
        }
        return placed.executable
    }

    /// Lists the archive, requires `member` as an exact entry (so an absolute or `..` member can't match what bsdtar
    /// extracts, which strips a leading `/` and refuses `..`), then extracts that entry alone, without the archive's
    /// ACLs, extended attributes or file flags (macOS bsdtar restores them by default; a `deny delete` ACL would
    /// block the rename). The archive is the pinned one, so its mtree trap (P59) can't apply. The result must be a
    /// regular file (lstat: never a symlink) of more than 0 bytes.
    private func unpack(_ member: String, from archive: URL, into folder: URL) async throws -> URL {
        let runner = ProcessRunner(timeout: .seconds(120))
        let listing: ProcessResult
        do {
            listing = try await runner.run(executable: Self.bsdtar, arguments: ["-t", "-f", archive.path])
        } catch is ProcessRunnerError {
            throw InstallError.memberMissing
        }
        guard listing.stdout.split(separator: "\n", omittingEmptySubsequences: true).contains(Substring(member)) else {
            throw InstallError.memberMissing
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            _ = try await runner.run(
                executable: Self.bsdtar,
                arguments: [
                    "-x", "-f", archive.path, "-C", folder.path, "--no-same-owner", "--no-mac-metadata", "--no-acls",
                    "--no-xattrs", "--no-fflags", member,
                ]
            )
        } catch is ProcessRunnerError {
            throw InstallError.memberMissing
        }
        let unpacked = folder.appending(path: member)
        var info = stat()
        guard lstat(unpacked.path, &info) == 0 else { throw InstallError.memberMissing }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw InstallError.notAnExecutable }
        return unpacked
    }

    private struct Placed {
        let executable: URL
        /// The folders `place` made, deepest first.
        let createdFolders: [URL]

        func removeCreatedFolders() { EngineInstaller.removeEmpty(createdFolders) }
    }

    /// rmdir only removes an empty folder, so nothing else that is there can go with it.
    private static func removeEmpty(_ folders: [URL]) {
        for folder in folders { rmdir(folder.path) }
    }

    /// Moves the verified file to `<engines>/<id>/bin/<executableName>`; what was there goes to the Trash first, once
    /// only the rename is left. `<id>` and `bin` must be real folders: following a symlink there would write and
    /// trash outside the engines folder (someone may link `ffmpeg/bin` to /opt/homebrew/bin).
    private func place(_ unpacked: URL, as entry: EngineDownload, work: URL) throws -> Placed {
        let engineFolder = enginesFolder.appending(path: entry.engineID.rawValue, directoryHint: .isDirectory)
        let bin = engineFolder.appending(path: "bin", directoryHint: .isDirectory)
        var created: [URL] = []
        for folder in [engineFolder, bin] {
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    Self.removeEmpty(created.reversed())
                    throw InstallError.downloadFailed
                }
                continue
            }
            guard mkdir(folder.path, 0o755) == 0 else {
                Self.removeEmpty(created.reversed())
                throw InstallError.downloadFailed
            }
            created.append(folder)
        }
        let placed = Placed(executable: bin.appending(path: entry.executableName), createdFolders: created.reversed())
        guard let workVolume = volume(work), workVolume == volume(bin) else {
            placed.removeCreatedFolders()
            throw InstallError.downloadFailed
        }
        var existing = stat()
        if lstat(placed.executable.path, &existing) == 0 {
            do { try trashItem(placed.executable) } catch { throw InstallError.downloadFailed }
        }
        guard renamex_np(unpacked.path, placed.executable.path, UInt32(RENAME_EXCL)) == 0 else {
            placed.removeCreatedFolders()
            throw InstallError.downloadFailed
        }
        return placed
    }

    /// Runs the version command; it must exit 0 within `probeTimeout` overall, not just between lines of output.
    private func probe(_ executable: URL, arguments: [String]?) async throws {
        guard let arguments else { return }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try await ProcessRunner(timeout: Self.probeTimeout).run(executable: executable, arguments: arguments)
                return true
            }
            group.addTask {
                try await Task.sleep(for: Self.probeTimeout)
                return false
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else { throw ProcessRunnerError.timedOut }
        }
    }

    private func regularFileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    /// Streamed in 1 MB chunks, so a 100 MB download never sits in memory whole.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
