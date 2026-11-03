import CryptoKit
import Darwin
import Foundation
import Testing
import os
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

/// Serves fixed bytes whatever `maxBytes` says (the installer must check the size itself) and records the file it
/// was asked to write, whose folder is the installer's work folder.
private final class FakeDownloader: Downloader, @unchecked Sendable {
    enum Behavior {
        case serves
        /// Writes half, then sleeps until the task is cancelled.
        case waitsUntilCancelled
        /// Writes half, then waits until `release()`.
        case waitsForRelease
        /// Marks the download quarantined, as a browser would; bsdtar passes that on to what it extracts.
        case quarantines
        /// Puts a symlink to this file where the download belongs.
        case symlink(to: URL)
    }

    let bytes: Data
    let behavior: Behavior
    private let state = OSAllocatedUnfairLock(initialState: [URL]())
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation

    init(bytes: Data, _ behavior: Behavior = .serves) {
        self.bytes = bytes
        self.behavior = behavior
        (started, startedContinuation) = AsyncStream.makeStream()
        (released, releasedContinuation) = AsyncStream.makeStream()
    }

    var files: [URL] { state.withLock { $0 } }

    /// Ends `started`, so a test waiting on it can't hang when the download never begins.
    func finishStarted() { startedContinuation.finish() }

    /// Lets every waiting (and later) `.waitsForRelease` download finish.
    func release() { releasedContinuation.finish() }

    func download(
        _ url: URL, to file: URL, maxBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        state.withLock { $0.append(file) }
        if case .symlink(let target) = behavior {
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            return
        }
        let half = bytes.count / 2
        try bytes.prefix(half).write(to: file, options: .withoutOverwriting)
        progress(Int64(half), Int64(bytes.count))
        switch behavior {
        case .waitsUntilCancelled:
            startedContinuation.yield()
            try await Task.sleep(for: .seconds(30))
        case .waitsForRelease:
            startedContinuation.yield()
            for await _ in released {}
        default:
            break
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes.dropFirst(half))
        try handle.close()
        if case .quarantines = behavior {
            let value = "0081;00000000;Tests;"
            guard setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW) == 0 else {
                throw POSIXError(.EPERM)
            }
        }
        progress(Int64(bytes.count), Int64(bytes.count))
    }
}

/// A temp folder with an archive holding `pkg/bin/fake`, an engines folder, and an injected Trash that moves what
/// it is given into `root/Trash` and records it. The program is compiled per fixture: a copy of a system binary
/// such as /bin/echo is killed when run from elsewhere.
private struct Fixture {
    let root: URL
    let engines: URL
    let trashFolder: URL
    /// A native program that exits 0 only when its one argument is `1.0` (the entry's `versionArguments`).
    let program: URL
    let archive: Data
    let trashed = OSAllocatedUnfairLock(initialState: [URL]())
    let stages = OSAllocatedUnfairLock(initialState: [InstallStage]())

    static let member = "pkg/bin/fake"

    /// `writeMember` creates the member at its first URL, given `program` as the second. `macMetadata` keeps
    /// bsdtar's extended attributes in the archive.
    init(
        enginesExists: Bool = true, macMetadata: Bool = false,
        writeMember: (_ member: URL, _ program: URL) async throws -> Void = Fixture.copyProgram
    ) async throws {
        root = try makeTempDir()
        engines = root.appending(path: "Support/Engines", directoryHint: .isDirectory)
        trashFolder = root.appending(path: "Trash", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        if enginesExists { try manager.createDirectory(at: engines, withIntermediateDirectories: true) }
        program = root.appending(path: "tools/ok")
        try await Self.compile(
            "#include <string.h>\nint main(int c, char **v) { return c == 2 && strcmp(v[1], \"1.0\") == 0 ? 0 : 1; }",
            to: program
        )

        let source = root.appending(path: "src", directoryHint: .isDirectory)
        try manager.createDirectory(at: source.appending(path: "pkg/bin"), withIntermediateDirectories: true)
        try await writeMember(source.appending(path: Self.member), program)
        try "readme".write(to: source.appending(path: "pkg/README"), atomically: false, encoding: .utf8)
        let archiveURL = root.appending(path: "archive.tar")
        var environment = ProcessInfo.processInfo.environment
        if !macMetadata { environment["COPYFILE_DISABLE"] = "1" }
        _ = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/bsdtar"),
            arguments: ["-c", "-f", archiveURL.path, "-C", source.path, "pkg"], environment: environment
        )
        archive = try Data(contentsOf: archiveURL)
    }

    /// Archived as 0644, as a zip that lost its modes would hold it: the installer must make it executable.
    static func copyProgram(_ member: URL, _ program: URL) throws {
        try FileManager.default.copyItem(at: program, to: member)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: member.path)
    }

    /// Builds a C program with the system compiler; the linker signs it ad hoc, so it runs on Apple silicon.
    static func compile(_ source: String, to executable: URL) async throws {
        let folder = executable.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(executable.lastPathComponent).c")
        try source.write(to: file, atomically: false, encoding: .utf8)
        _ = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/cc"), arguments: ["-o", executable.path, file.path]
        )
    }

    var sha256: String { SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined() }

    var installed: URL { engines.appending(path: "fake/bin/fake") }

    func entry(
        member: String = Fixture.member, sha256: String? = nil, maxBytes: Int64? = nil,
        archs: Set<MachineArch> = [.arm64, .x86_64]
    ) -> EngineDownload {
        EngineDownload(
            engineID: "fake", version: "1.0", archs: archs, url: URL(string: "https://example.invalid/fake.tar")!,
            sha256: sha256 ?? self.sha256, maxBytes: maxBytes ?? Int64(archive.count) + 100, member: member,
            executableName: "fake", versionArguments: ["1.0"], publisher: "Tests"
        )
    }

    func installer(
        _ downloader: FakeDownloader, entry: EngineDownload? = nil, machine: MachineArch = .current,
        enginesFolder: URL? = nil, volume: @escaping @Sendable (URL) -> dev_t? = EngineInstaller.volume(of:)
    ) -> EngineInstaller {
        let trashFolder = trashFolder
        let trashed = trashed
        return EngineInstaller(
            enginesFolder: enginesFolder ?? engines, downloader: downloader, table: [entry ?? self.entry()],
            machine: machine,
            trashItem: { url in
                trashed.withLock { $0.append(url) }
                try FileManager.default.moveItem(
                    at: url, to: trashFolder.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
                )
            },
            volume: volume
        )
    }

    func install(_ installer: EngineInstaller, _ engine: EngineID = "fake") async throws -> URL {
        let stages = stages
        return try await installer.install(engine) { stage in stages.withLock { $0.append(stage) } }
    }

    /// The stages seen, each run of `downloading` folded into one.
    var stageKinds: [String] {
        stages.withLock { stages in
            stages.map { stage -> String in
                switch stage {
                case .downloading: "downloading"
                case .verifying: "verifying"
                case .unpacking: "unpacking"
                case .checking: "checking"
                }
            }.reduce(into: [String]()) { kinds, kind in if kinds.last != kind { kinds.append(kind) } }
        }
    }

    /// Every path under the engines folder, relative to it (nil when it doesn't exist).
    var enginesContents: [String]? {
        guard FileManager.default.fileExists(atPath: engines.path) else { return nil }
        return (FileManager.default.subpaths(atPath: engines.path) ?? []).sorted()
    }

    func workFolderIsGone(_ downloader: FakeDownloader) -> Bool {
        guard let file = downloader.files.first else { return false }
        return !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path)
    }

    /// A folder outside the engines folder holding the person's own file ("mine") at `path`.
    func makeOutsideFolder(holding path: String) throws -> URL {
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        let file = outside.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: file, atomically: false, encoding: .utf8)
        return outside
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func mode(_ url: URL) throws -> mode_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
    return info.st_mode & 0o7777
}

/// Strips every ACL under `url`, so a `deny delete` entry can't keep the test's files from being removed.
private func clearACLs(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["-R", "-N", url.path]
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

private func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

private func expectFailure(
    _ expected: InstallError, _ body: () async throws -> URL, sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        let url = try await body()
        Issue.record("installed \(url.path) instead of failing with \(expected)", sourceLocation: sourceLocation)
    } catch {
        #expect(error as? InstallError == expected, sourceLocation: sourceLocation)
    }
}

@Suite struct EngineInstallerTests {
    @Test func aVerifiedDownloadInstallsTheExecutable() async throws {
        let fixture = try await Fixture(enginesExists: false)
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)

        let installed = try await fixture.install(fixture.installer(downloader))

        #expect(installed == fixture.installed)
        #expect(try mode(installed) == 0o755)
        #expect(FileManager.default.contentsEqual(atPath: installed.path, andPath: fixture.program.path))
        #expect(fixture.stageKinds == ["downloading", "verifying", "unpacking", "checking"])
        #expect(fixture.stages.withLock { $0.contains(.downloading(fraction: 0.5)) })
        #expect(fixture.enginesContents == ["fake", "fake/bin", "fake/bin/fake"])
        #expect(fixture.trashed.withLock { $0.isEmpty })
        #expect(downloader.files.first?.lastPathComponent == "download")
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func theInstalledEngineIsFoundByTheLocator() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let installed = try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive)))

        let located = ExecutableLocator(enginesFolder: fixture.engines).locate(
            PluginManifest.Executable(names: ["fake"], searchPaths: [], versionArguments: ["1.0"]), pluginID: "fake"
        )
        #expect(located == installed)
    }

    @Test func aMismatchedHashLeavesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)
        let installer = fixture.installer(downloader, entry: fixture.entry(sha256: String(repeating: "0", count: 64)))

        await expectFailure(.checksumMismatch) { try await fixture.install(installer) }
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func theArchiveIsNeverOpenedBeforeTheHashMatches() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer(
            FakeDownloader(bytes: fixture.archive), entry: fixture.entry(sha256: String(repeating: "a", count: 64))
        )

        await expectFailure(.checksumMismatch) { try await fixture.install(installer) }
        #expect(fixture.stageKinds == ["downloading", "verifying"])
    }

    @Test func aTruncatedDownloadFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive.prefix(fixture.archive.count / 2))

        await expectFailure(.checksumMismatch) { try await fixture.install(fixture.installer(downloader)) }
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func aTooLargeDownloadIsStopped() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)
        let installer = fixture.installer(downloader, entry: fixture.entry(maxBytes: Int64(fixture.archive.count) - 1))

        await expectFailure(.tooLarge) { try await fixture.install(installer) }
        #expect(fixture.stageKinds == ["downloading"])
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func aMissingMemberFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)
        let installer = fixture.installer(downloader, entry: fixture.entry(member: "pkg/bin/other"))

        await expectFailure(.memberMissing) { try await fixture.install(installer) }
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    /// A pattern that bsdtar would match as a prefix (`pkg` extracts everything under it) is not the member.
    @Test func aFolderIsNotTheMember() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let installer = fixture.installer(FakeDownloader(bytes: fixture.archive), entry: fixture.entry(member: "pkg/bin"))

        await expectFailure(.memberMissing) { try await fixture.install(installer) }
        #expect(fixture.enginesContents == [])
    }

    @Test func aSymlinkMemberIsRefused() async throws {
        let fixture = try await Fixture { url, program in
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: program.path)
        }
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)

        await expectFailure(.notAnExecutable) { try await fixture.install(fixture.installer(downloader)) }
        #expect(fixture.stageKinds == ["downloading", "verifying", "unpacking"])
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    /// Refused while unpacking, before the Mach-O check (which would refuse it too).
    @Test func anEmptyMemberIsRefused() async throws {
        let fixture = try await Fixture { url, _ in try Data().write(to: url) }
        defer { fixture.remove() }

        await expectFailure(.notAnExecutable) {
            try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive)))
        }
        #expect(fixture.stageKinds == ["downloading", "verifying", "unpacking"])
        #expect(fixture.enginesContents == [])
    }

    @Test func aScriptIsRefused() async throws {
        let fixture = try await Fixture { url, _ in
            try "#!/bin/sh\nexit 0\n".write(to: url, atomically: false, encoding: .utf8)
        }
        defer { fixture.remove() }

        await expectFailure(.notAnExecutable) {
            try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive)))
        }
        #expect(fixture.enginesContents == [])
    }

    @Test func aWrongArchitectureIsRefused() async throws {
        let fixture = try await Fixture { url, _ in
            func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
            let header: [UInt32] = [0xFEED_FACF, 0x0100_0007, 3, 2, 0, 0, 0, 0]
            try Data(header.flatMap(le)).write(to: url)
        }
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)

        await expectFailure(.wrongArchitecture) {
            try await fixture.install(fixture.installer(downloader, machine: .arm64))
        }
        #expect(fixture.stageKinds == ["downloading", "verifying", "unpacking", "checking"])
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func anExistingExecutableGoesToTheTrash() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let bin = fixture.engines.appending(path: "fake/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "old".write(to: fixture.installed, atomically: false, encoding: .utf8)

        let installed = try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive)))

        #expect(fixture.trashed.withLock { $0 } == [fixture.installed])
        let inTrash = try FileManager.default.contentsOfDirectory(at: fixture.trashFolder, includingPropertiesForKeys: nil)
        #expect(try inTrash.map { try String(contentsOf: $0, encoding: .utf8) } == ["old"])
        #expect(FileManager.default.contentsEqual(atPath: installed.path, andPath: fixture.program.path))
    }

    @Test func aFailedInstallLeavesTheExistingExecutable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let bin = fixture.engines.appending(path: "fake/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "old".write(to: fixture.installed, atomically: false, encoding: .utf8)
        let installer = fixture.installer(
            FakeDownloader(bytes: fixture.archive), entry: fixture.entry(sha256: String(repeating: "b", count: 64))
        )

        await expectFailure(.checksumMismatch) { try await fixture.install(installer) }
        #expect(try String(contentsOf: fixture.installed, encoding: .utf8) == "old")
        #expect(fixture.trashed.withLock { $0.isEmpty })
    }

    /// bsdtar passes a quarantined archive's quarantine on to what it extracts, even with --no-xattrs.
    @Test func quarantineIsRemovedFromTheVerifiedExecutable() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let installed = try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive, .quarantines)))

        #expect(!hasQuarantine(installed))
    }

    /// macOS bsdtar restores an archive's ACLs, extended attributes and flags by default; a `deny delete` ACL would
    /// make the final rename (and removing the work folder) fail.
    @Test func theArchivesACLsAndAttributesAreNotRestored() async throws {
        let fixture = try await Fixture(macMetadata: true) { url, program in
            try Fixture.copyProgram(url, program)
            _ = try await ProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/chmod"), arguments: ["+a", "everyone deny delete", url.path]
            )
            #expect(setxattr(url.path, "org.pomelo.test", "x", 1, 0, XATTR_NOFOLLOW) == 0)
        }
        let downloader = FakeDownloader(bytes: fixture.archive)
        defer {
            clearACLs(fixture.root)
            if let work = downloader.files.first?.deletingLastPathComponent() {
                clearACLs(work)
                try? FileManager.default.removeItem(at: work)
            }
            fixture.remove()
        }

        let installed = try await fixture.install(fixture.installer(downloader))

        #expect(acl_get_file(installed.path, ACL_TYPE_EXTENDED) == nil)
        #expect(getxattr(installed.path, "org.pomelo.test", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        #expect(fixture.workFolderIsGone(downloader))
    }

    /// Someone may point `<engines>/ffmpeg/bin` at /opt/homebrew/bin: nothing outside the engines folder is touched.
    @Test func aSymlinkedBinFolderIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let outside = try fixture.makeOutsideFolder(holding: "fake")
        let engineFolder = fixture.engines.appending(path: "fake", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: engineFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: engineFolder.appending(path: "bin"), withDestinationURL: outside)
        let downloader = FakeDownloader(bytes: fixture.archive)

        await expectFailure(.downloadFailed) { try await fixture.install(fixture.installer(downloader)) }
        #expect(try String(contentsOf: outside.appending(path: "fake"), encoding: .utf8) == "mine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["fake"])
        #expect(fixture.trashed.withLock { $0.isEmpty })
        #expect(fixture.enginesContents == ["fake", "fake/bin"])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func aSymlinkedEngineFolderIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let outside = try fixture.makeOutsideFolder(holding: "bin/fake")
        try FileManager.default.createSymbolicLink(at: fixture.engines.appending(path: "fake"), withDestinationURL: outside)

        await expectFailure(.downloadFailed) {
            try await fixture.install(fixture.installer(FakeDownloader(bytes: fixture.archive)))
        }
        #expect(try String(contentsOf: outside.appending(path: "bin/fake"), encoding: .utf8) == "mine")
        #expect(fixture.trashed.withLock { $0.isEmpty })
        #expect(fixture.enginesContents == ["fake"])
    }

    /// The engines folder itself may be a symlink: the install lands in the folder it points to, at the path given.
    @Test func aSymlinkedEnginesFolderStillInstalls() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let link = fixture.root.appending(path: "EnginesLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.engines)

        let installed = try await fixture.install(
            fixture.installer(FakeDownloader(bytes: fixture.archive), enginesFolder: link)
        )

        #expect(installed == link.appending(path: "fake/bin/fake"))
        #expect(fixture.enginesContents == ["fake", "fake/bin", "fake/bin/fake"])
    }

    /// The rename can't cross volumes: when the work folder and `bin` are on different ones (an engines folder
    /// linked to another disk), the install fails before the old program is touched.
    @Test func anotherVolumeLeavesTheOldProgramWhereItWas() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.engines.appending(path: "fake/bin"), withIntermediateDirectories: true
        )
        try "old".write(to: fixture.installed, atomically: false, encoding: .utf8)
        let engines = fixture.engines.path
        let downloader = FakeDownloader(bytes: fixture.archive)
        let installer = fixture.installer(downloader) { url in
            url.path.hasPrefix(engines) ? 1 : 2
        }

        await expectFailure(.downloadFailed) { try await fixture.install(installer) }
        #expect(try String(contentsOf: fixture.installed, encoding: .utf8) == "old")
        #expect(fixture.trashed.withLock { $0.isEmpty })
        #expect(fixture.workFolderIsGone(downloader))
    }

    /// chmod follows symlinks: the download is lstat'ed first, so a link can't change another file's mode.
    @Test func aDownloadThatIsASymlinkIsNotFollowed() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let target = fixture.root.appending(path: "someone-elses-file")
        try fixture.archive.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let downloader = FakeDownloader(bytes: fixture.archive, .symlink(to: target))

        await expectFailure(.downloadFailed) { try await fixture.install(fixture.installer(downloader)) }
        #expect(try mode(target) == 0o644)
        #expect(fixture.workFolderIsGone(downloader))
    }

    /// A second install of the same engine waits for the first and gets its result: two at once would trash each
    /// other's program.
    @Test func aSecondInstallOfTheSameEngineWaitsForTheFirst() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive, .waitsForRelease)
        let installer = fixture.installer(downloader)

        let first = Task { try await fixture.install(installer) }
        Task { _ = try? await first.value; downloader.finishStarted() }
        var started = downloader.started.makeAsyncIterator()
        _ = await started.next()
        let second = Task { try await installer.install("fake") { _ in } }
        let deadline = ContinuousClock.now + .seconds(5)
        while await installer.waitingCallers(for: "fake") == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        downloader.release()

        let (a, b) = try await (first.value, second.value)
        #expect(a == fixture.installed && b == fixture.installed)
        #expect(downloader.files.count == 1)
        #expect(fixture.trashed.withLock { $0.isEmpty })
        #expect(FileManager.default.contentsEqual(atPath: fixture.installed.path, andPath: fixture.program.path))
    }

    @Test func aProgramThatDoesntStartGoesToTheTrash() async throws {
        let fixture = try await Fixture { url, _ in try await Fixture.compile("int main(void) { return 1; }", to: url) }
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)

        await expectFailure(.doesNotRun) { try await fixture.install(fixture.installer(downloader)) }
        #expect(fixture.trashed.withLock { $0 } == [fixture.installed])
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
    }

    @Test func cancellingRemovesTheWorkFolder() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive, .waitsUntilCancelled)
        let installer = fixture.installer(downloader)

        let task = Task { try await fixture.install(installer) }
        Task { _ = try? await task.value; downloader.finishStarted() }
        var started = downloader.started.makeAsyncIterator()
        _ = await started.next()
        #expect(downloader.files.count == 1 && !fixture.workFolderIsGone(downloader))
        task.cancel()

        await expectFailure(.cancelled) { try await task.value }
        #expect(fixture.enginesContents == [])
        #expect(fixture.workFolderIsGone(downloader))
        #expect(InstallError.cancelled.reason == nil)
    }

    @Test func noDownloadForThisMac() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let downloader = FakeDownloader(bytes: fixture.archive)
        let installer = fixture.installer(downloader, entry: fixture.entry(archs: [.x86_64]), machine: .arm64)

        await expectFailure(.notAvailableForThisMac) { try await fixture.install(installer) }
        await expectFailure(.notAvailableForThisMac) { try await fixture.install(installer, "unar") }
        #expect(downloader.files.isEmpty)
        #expect(fixture.stageKinds.isEmpty)
        #expect(fixture.enginesContents == [])
    }

    @Test func everyFailureHasAShortReason() {
        let reasons: [InstallError: String] = [
            .notAvailableForThisMac: "No download for this Mac",
            .downloadFailed: "The download failed",
            .tooLarge: "The download is larger than expected",
            .checksumMismatch: "The download didn't match its checksum",
            .memberMissing: "The download didn't hold the program",
            .notAnExecutable: "The download didn't hold the program",
            .wrongArchitecture: "The program doesn't run on this Mac",
            .doesNotRun: "The program didn't start",
        ]
        for (error, reason) in reasons {
            #expect(error.reason == reason)
            #expect(reason.count <= 45)
        }
    }
}
