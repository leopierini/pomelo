import Foundation
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct ArchiveEngineTests {
    private func runner(registry: EngineRegistry = EngineRegistry(engines: [ArchiveEngine()], priority: ["archive"])) -> JobRunner {
        JobRunner(registry: registry, destinations: DestinationResolver(
            downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
        ))
    }

    private func extract(_ source: URL, registry: EngineRegistry? = nil) async throws -> FileResult {
        let preset = try #require(Preset.builtIns.first { $0.id == "extract-archive" })
        let results = await (registry.map { runner(registry: $0) } ?? runner()).run(ConversionRequest.from(preset, inputs: [source]))
        return try #require(results.first)
    }

    private func convert(_ source: URL, to target: FormatID) async throws -> URL {
        let results = await runner().run(ConversionRequest(inputs: [source], target: target))
        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            throw Fixtures.Failure("\(results)")
        }
        return output
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A folder `name` in a fresh temporary folder, holding one small text file per name in `files`.
    private func folder(_ name: String, files: [String]) throws -> URL {
        let folder = try makeTempDir().appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in files { try Data("contents of \(file)".utf8).write(to: folder.appending(path: file)) }
        return folder
    }

    /// The entry names `bsdtar -t` lists.
    private func entries(of archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bsdtar")
        process.arguments = ["-t", "-f", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Fixtures.Failure("bsdtar -t failed on \(archive.path)") }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func outputs(of result: FileResult) throws -> [URL] {
        guard case .succeeded(_, let outputs, _) = result else { throw Fixtures.Failure("\(result)") }
        return outputs
    }

    // MARK: Extract

    @Test func extractingAZipOfOneFolderGivesThatFolder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let holiday = try folder("Holiday", files: ["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        // An extended attribute makes ditto add `__MACOSX/` entries, as Finder's Compress does for most files.
        let tag = Array("kept".utf8)
        #expect(setxattr(holiday.appending(path: "a.txt").path, "com.pomelo.test", tag, tag.count, 0, 0) == 0)
        let zip = try Fixtures.zip(holiday, named: "Holiday.zip", in: dir)

        let outputs = try outputs(of: try await extract(zip))

        #expect(outputs == [dir.appending(path: "Holiday")])
        #expect(getxattr(dir.appending(path: "Holiday/a.txt").path, "com.pomelo.test", nil, 0, 0, 0) == tag.count)
        #expect(try names(in: dir.appending(path: "Holiday")) == ["a.txt", "b.txt"])
        #expect(try String(contentsOf: dir.appending(path: "Holiday/a.txt"), encoding: .utf8) == "contents of a.txt")
        #expect(try names(in: dir) == ["Holiday", "Holiday.zip"])
    }

    @Test func extractingSeveralItemsWrapsThemInTheArchivesName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let content = try folder("content", files: ["a.jpg", "b.jpg"])
        defer { try? FileManager.default.removeItem(at: content.deletingLastPathComponent()) }
        let zip = try Fixtures.zip(content, keepParent: false, named: "photos.zip", in: dir)

        let outputs = try outputs(of: try await extract(zip))

        #expect(outputs == [dir.appending(path: "photos")])
        #expect(try names(in: dir.appending(path: "photos")) == ["a.jpg", "b.jpg"])
    }

    @Test func extractingATarGzStripsBothExtensions() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try Fixtures.tar(entries: [.file("a.txt", Data("a".utf8)), .file("b.txt", Data("b".utf8))],
                                   named: "x.tar", in: dir)
        let tarGz = try Fixtures.gzip(tar)
        try FileManager.default.removeItem(at: tar)
        #expect(FormatRegistry.builtIn.format(for: tarGz)?.id == "gz")

        let outputs = try outputs(of: try await extract(tarGz))

        #expect(outputs == [dir.appending(path: "x")])
        #expect(try names(in: dir.appending(path: "x")) == ["a.txt", "b.txt"])
    }

    @Test func extractingAGzippedFileGivesTheFile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(pages: 2, in: dir)
        let report = dir.appending(path: "report.pdf")
        try FileManager.default.moveItem(at: pdf, to: report)
        let gz = try Fixtures.gzip(report)
        let original = try Data(contentsOf: report)
        try FileManager.default.removeItem(at: report)

        let outputs = try outputs(of: try await extract(gz))

        #expect(outputs == [report])
        #expect(try Data(contentsOf: report) == original)
        #expect(try names(in: dir) == ["report.pdf", "report.pdf.gz"])
    }

    @Test func extractingAnItemWhoseNameIsTakenNumbersIt() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let holiday = try folder("Holiday", files: ["a.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        let zip = try Fixtures.zip(holiday, named: "Holiday.zip", in: dir)
        try FileManager.default.createDirectory(at: dir.appending(path: "Holiday"), withIntermediateDirectories: false)

        #expect(try outputs(of: try await extract(zip)) == [dir.appending(path: "Holiday 2")])
    }

    /// No entry may write outside the step's staging. bsdtar runs without `-P`, so it refuses `..`,
    /// strips a leading `/` and never writes through a symlink or links to a file outside.
    @Test func extractingNeverWritesOutsideStaging() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        let absolute = "/tmp/pomelo-evil-\(id).txt"
        let viaDots = String(repeating: "../", count: 24) + "tmp/pomelo-evil-\(id)-dots.txt"
        let evilPaths = [absolute, "/private/tmp/pomelo-evil-\(id).txt", "/private/tmp/pomelo-evil-\(id)-dots.txt"]
        // A writable folder and a file outside staging that a link entry aims at; ustar link names hold 100 bytes,
        // so they live in /tmp under the same unique name.
        let outside = URL(filePath: "/tmp/pomelo-evil-\(id)-dir", directoryHint: .isDirectory)
        let victim = URL(filePath: "/tmp/pomelo-evil-\(id)-victim.txt")
        defer { for path in evilPaths + [outside.path, victim.path] { try? FileManager.default.removeItem(atPath: path) } }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("precious".utf8).write(to: victim)
        let evil = Data("evil".utf8)
        let source = try Fixtures.tar(entries: [
            .file("ok.txt", Data("fine".utf8)),
            .file("../evil.txt", evil),
            .file(viaDots, evil),
            .file(absolute, evil),
            .symlink("link", target: outside.path),
            .file("link/x.txt", evil),
            .hardLink("hard", target: victim.path),
        ], named: "evil.tar", in: dir)
        let sourceBytes = try Data(contentsOf: source)

        let result = try await extract(source)

        for path in evilPaths { #expect(!FileManager.default.fileExists(atPath: path), "\(path)") }
        #expect(try names(in: outside).isEmpty)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "precious")
        #expect(try FileManager.default.attributesOfItem(atPath: victim.path)[.referenceCount] as? Int == 1)
        #expect(try Data(contentsOf: source) == sourceBytes)
        switch result {
        case .failed:
            #expect(try names(in: dir) == ["evil.tar"])
        case .succeeded(_, let outputs, _):
            for output in outputs {
                #expect(output.deletingLastPathComponent() == dir)
                let found = FileManager.default.enumerator(atPath: output.path)?.allObjects as? [String] ?? []
                #expect(!found.contains { $0.hasSuffix("evil.txt") || $0.hasSuffix("x.txt") || $0.hasSuffix("-dots.txt") })
            }
        case .cancelled:
            Issue.record("\(result)")
        }
    }

    @Test func anEmptyArchiveIsNotApplicable() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try Fixtures.tar(entries: [], named: "empty.tar", in: dir)
        let zip = dir.appending(path: "empty.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)

        for archive in [tar, zip] {
            let result = try await extract(archive)
            #expect(result == .failed(source: archive, error: .notApplicable(reason: "The archive is empty")))
        }
        #expect(try names(in: dir) == ["empty.tar", "empty.zip"])
    }

    @Test func aSingleTopLevelSymlinkIsWrappedRatherThanReturned() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.tar(entries: [.symlink("shortcut", target: "/etc")], named: "links.tar", in: dir)

        let outputs = try outputs(of: try await extract(source))

        #expect(outputs == [dir.appending(path: "links")])
        let link = dir.appending(path: "links/shortcut").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/etc")
    }

    /// bsdtar extracts a real archive in well under a second, so a cancel could land after it finished; a stand-in
    /// that never finishes makes the cancel land mid-extraction every time.
    @Test func cancellingAnExtractionStopsItsProcess() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let work = try makeTempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let standIn = work.appending(path: "slow-bsdtar")
        let sleep = "/bin/sleep 600.\(Int.random(in: 100_000...999_999))"
        try Data("#!/bin/sh\n\(sleep)\n".utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
        let large = try folder("Large", files: ["a.txt"])
        defer { try? FileManager.default.removeItem(at: large.deletingLastPathComponent()) }
        let source = try Fixtures.zip(large, named: "large.zip", in: dir)
        let registry = EngineRegistry(engines: [ArchiveEngine(bsdtar: standIn)], priority: ["archive"])

        let job = Task { try await extract(source, registry: registry) }
        let started = await eventually { isRunning(matching: source.path) }
        #expect(started)
        job.cancel()
        let result = try await job.value

        #expect(result == .cancelled(source: source))
        #expect(!isRunning(matching: source.path))
        // The runner stops the tool's whole process group, so what the tool started goes too.
        #expect(await eventually(seconds: 5) { !isRunning(matching: sleep) })
        #expect(try names(in: dir) == ["large.zip"])
    }

    // MARK: Convert

    @Test func zipBecomesTgzAndBack() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let holiday = try folder("Holiday", files: ["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        let zip = try Fixtures.zip(holiday, named: "Holiday.zip", in: dir)
        let original = try entries(of: zip)

        let tgz = try await convert(zip, to: "tgz")
        let back = try await convert(tgz, to: "zip")
        let tar = try await convert(zip, to: "tar")

        #expect(original.sorted() == ["Holiday/", "Holiday/a.txt", "Holiday/b.txt"])
        #expect(tgz.lastPathComponent == "Holiday.tgz")
        #expect(back.lastPathComponent == "Holiday 2.zip")
        #expect(try entries(of: tgz) == original)
        #expect(try entries(of: back) == original)
        #expect(try entries(of: tar) == original)
        #expect(try Data(contentsOf: tgz).prefix(2) == Data([0x1F, 0x8B]))
        #expect(try Data(contentsOf: back).prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(try Data(contentsOf: tar).subdata(in: 257..<262) == Data("ustar".utf8))
    }

    /// ustar fails on a path over 255 bytes; pax stores it and still carries the ustar magic P59 checks.
    @Test func aPathOver255BytesConvertsAndExtractsBack() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let top = try folder("Deep", files: [])
        defer { try? FileManager.default.removeItem(at: top.deletingLastPathComponent()) }
        let nested = top.appending(path: String(repeating: "a", count: 120)).appending(path: String(repeating: "b", count: 120))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: nested.appending(path: String(repeating: "c", count: 60) + ".txt"))
        let zip = try Fixtures.zip(top, named: "Deep.zip", in: dir)
        let deepest = try #require(try entries(of: zip).max { $0.utf8.count < $1.utf8.count })
        try #require(deepest.utf8.count > 300)

        for target: FormatID in ["tar", "tgz"] {
            let converted = try await convert(zip, to: target)
            #expect(try entries(of: converted).contains(deepest), "\(target)")
            let extracted = try outputs(of: try await extract(converted))
            let file = try #require(extracted.first).deletingLastPathComponent().appending(path: deepest)
            #expect(try String(contentsOf: file, encoding: .utf8) == "deep", "\(target)")
            for item in extracted { try FileManager.default.removeItem(at: item) }
        }
    }

    @Test func edgesCoverExtractAndTheSixConversions() {
        let edges = ArchiveEngine().edges()
        let extracts = edges.filter { $0.operation == "extract" }
        #expect(Set(extracts.map(\.from)) == ["zip", "tar", "tgz", "gz"])
        #expect(extracts.allSatisfy { $0.from == $0.to })
        let conversions = edges.filter { $0.operation == nil && $0.from != "rar" }
        #expect(Set(conversions.map { "\($0.from)>\($0.to)" })
                == ["zip>tar", "zip>tgz", "tar>zip", "tar>tgz", "tgz>zip", "tgz>tar"])
        #expect(edges.allSatisfy { $0.cost == 10 && $0.flags == [] && $0.engineID == "archive" })
    }

    @Test func theArchiveStemDropsEveryArchiveExtension() {
        let stem = { (name: String) in ArchiveEngine.archiveStem(of: URL(filePath: "/x/\(name)")) }
        #expect(stem("photos.zip") == "photos")
        #expect(stem("x.tar.gz") == "x")
        #expect(stem("x.TGZ") == "x")
        #expect(stem("backup.tar") == "backup")
        #expect(stem("report.pdf.gz") == "report.pdf")
        #expect(stem("v1.2.zip") == "v1.2")
    }

    @Test func theContainmentCheckRejectsARootOutsideStaging() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        let outside = dir.appending(path: "outside", directoryHint: .isDirectory)
        for folder in [staging, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let inside = staging.appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: inside.appending(path: "link").path, withDestinationPath: outside.path)
        let swapped = staging.appending(path: "y")
        try FileManager.default.createSymbolicLink(atPath: swapped.path, withDestinationPath: outside.path)

        #expect(StagedFolder.containment(of: inside, in: staging) == .inside)
        #expect(StagedFolder.containment(of: swapped, in: staging) == .outside)
    }

    // MARK: Containers (P59)

    /// mtree text (`contents=` names any file bsdtar may read) under an archive's name must never get the named
    /// file's bytes into an output, by extract or by conversion.
    @Test func mtreeTextIsNeverReadAsAnArchive() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let elsewhere = try makeTempDir(); defer { try? FileManager.default.removeItem(at: elsewhere) }
        let secretText = "TOPSECRET-\(UUID().uuidString)"
        let secret = elsewhere.appending(path: "secret.txt")
        try Data(secretText.utf8).write(to: secret)
        let mtree = Data("#mtree\n./stolen.txt type=file size=\(secretText.utf8.count) contents=\(secret.path)\n".utf8)
        let tar = dir.appending(path: "notes.tar")
        try mtree.write(to: tar)
        let plain = elsewhere.appending(path: "backup")
        try mtree.write(to: plain)
        let tgz = dir.appending(path: "backup.tgz")
        try FileManager.default.moveItem(at: try Fixtures.gzip(plain), to: tgz)

        guard case .failed(_, .engineFailed) = try await extract(tar) else { Issue.record("notes.tar extracted"); return }
        for (source, targets) in [(tar, ["zip", "tgz"]), (tgz, ["zip", "tar"])] as [(URL, [FormatID])] {
            for target in targets {
                let results = await runner().run(ConversionRequest(inputs: [source], target: target))
                guard case .failed(_, .engineFailed) = results.first else {
                    Issue.record("\(source.lastPathComponent) to \(target): \(results)"); continue
                }
            }
        }
        // Not a tarball, so the tgz is one gzipped file: its own text, at most.
        _ = try await extract(tgz)

        let produced = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for file in produced {
            let bytes = (try? Data(contentsOf: file)) ?? Data()
            #expect(bytes.firstRange(of: Data(secretText.utf8)) == nil, "\(file.lastPathComponent)")
        }
        #expect(try names(in: dir).allSatisfy { ["notes.tar", "backup.tgz", "backup"].contains($0) })
    }

    @Test func aGzippedFileThatIsNoTarballComesOutAsItIs() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appending(path: "disk.img")
        try Data(count: 8192).write(to: image)
        let holiday = try folder("Holiday", files: ["a.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        let inner = try Fixtures.zip(holiday, named: "inner.zip", in: dir)

        for file in [image, inner] {
            let original = try Data(contentsOf: file)
            let gz = try Fixtures.gzip(file)
            try FileManager.default.removeItem(at: file)
            #expect(try outputs(of: try await extract(gz)) == [file])
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aTarHeaderNeedsItsMagicAndChecksum() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let tar = try Fixtures.tar(entries: [.file("a.txt", Data("a".utf8))], in: dir)
        var block = [UInt8](try Data(contentsOf: tar).prefix(512))
        #expect(ArchiveEngine.isTarHeader(block))
        block[0] ^= 0xFF
        #expect(!ArchiveEngine.isTarHeader(block))
        #expect(!ArchiveEngine.isTarHeader([UInt8](Data("#mtree\n".utf8)) + [UInt8](repeating: 0, count: 600)))
    }

    // MARK: Folder modes

    @Test func foldersWithoutOwnerAccessAreOpenedAndPublished() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.tar(entries: [
            .directory("top/", mode: 0o555),
            .directory("top/locked/", mode: 0),
            .file("top/locked/a.txt", Data("a".utf8)),
        ], named: "modes.tar", in: dir)

        let outputs = try outputs(of: try await extract(source))

        #expect(outputs == [dir.appending(path: "top")])
        #expect(try String(contentsOf: dir.appending(path: "top/locked/a.txt"), encoding: .utf8) == "a")
        for path in ["top", "top/locked"] {
            let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: path).path)[.posixPermissions] as? Int
            #expect((mode ?? 0) & 0o700 == 0o700, "\(path)")
        }
    }

    @Test func aFailedExtractionWithALockedFolderLeavesARemovableStaging() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let source = try Fixtures.tar(entries: [
            .directory("locked/", mode: 0),
            .file("locked/a.txt", Data("a".utf8)),
            .file("../evil.txt", Data("evil".utf8)),
        ], named: "bad.tar", in: dir)
        let tar = try #require(FormatRegistry.builtIn.format(id: "tar"))
        let step = ConversionStep(input: source, stagingDirectory: staging, from: tar, to: tar, options: .init(),
                                  operation: "extract")

        await #expect(throws: ConversionError.self) { try await ArchiveEngine().convert(step, progress: { _ in }) }

        #expect(throws: Never.self) { try FileManager.default.removeItem(at: staging) }
    }

    // MARK: Read-back

    /// Apple's bsdtar writes a truncated tar from a zip with inline `._` entries and still exits 0.
    @Test func aConversionThatDoesNotReadBackFails() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let content = try folder("content", files: ["x.txt"])
        defer { try? FileManager.default.removeItem(at: content.deletingLastPathComponent()) }
        let tag = Array("value".utf8)
        #expect(setxattr(content.appending(path: "x.txt").path, "com.pomelo.test", tag, tag.count, 0, 0) == 0)
        let zip = try Fixtures.zip(content, keepParent: false, sequesterResources: false, named: "inline.zip", in: dir)
        #expect(try entries(of: zip).contains("._x.txt"))

        let results = await runner().run(ConversionRequest(inputs: [zip], target: "tgz"))

        guard case .failed(_, .engineFailed(_, let message)) = results.first else { Issue.record("\(results)"); return }
        #expect(message.hasPrefix("the new archive does not read back"))
        #expect(try names(in: dir) == ["inline.zip"])
    }

    // MARK: Quarantine (P58)

    @Test func whatComesOutOfAQuarantinedArchiveIsQuarantined() async throws {
        let mark = Data("0081;65f00000;Safari;F1A2B3C4-0000-4000-8000-000000000000".utf8)
        func quarantine(_ url: URL) {
            #expect(mark.withUnsafeBytes { setxattr(url.path, "com.apple.quarantine", $0.baseAddress, mark.count, 0, 0) } == 0)
        }
        func markOf(_ url: URL) -> Data? {
            let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            return getxattr(url.path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW) == size ? Data(bytes) : nil
        }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let holiday = try folder("Holiday", files: ["a.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        let zip = try Fixtures.zip(holiday, named: "dl.zip", in: dir)
        let script = dir.appending(path: "run.command")
        try Data("echo hi\n".utf8).write(to: script)
        let gz = try Fixtures.gzip(script)
        try FileManager.default.removeItem(at: script)
        quarantine(zip)
        quarantine(gz)

        let tgz = try await convert(zip, to: "tgz")
        let extracted = try outputs(of: try await extract(zip))
        let unzipped = try outputs(of: try await extract(gz))

        #expect(markOf(tgz) == mark)
        #expect(extracted.map(markOf) == [mark])
        // bsdtar marks what it extracts itself (same event, its own time stamp); P58 keeps an inner item's own mark.
        #expect(markOf(dir.appending(path: "Holiday/a.txt")) != nil)
        #expect(unzipped == [script])
        #expect(markOf(script) == mark)
    }

    // MARK: RAR

    @Test(.enabled(if: Installed.has("unar") && Installed.has("rar"))) func extractsARar() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let content = try folder("content", files: ["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: content.deletingLastPathComponent()) }
        let rar = dir.appending(path: "x.rar")
        guard let rarTool = Installed.path(of: "rar") else { throw Fixtures.Failure("rar is not installed") }
        let process = Process()
        process.executableURL = rarTool
        process.arguments = ["a", "-idq", rar.path, "a.txt", "b.txt"]
        process.currentDirectoryURL = content
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let outputs = try outputs(of: try await extract(rar, registry: DefaultEngines.makeRegistry(userPluginsFolder: nil)))

        #expect(outputs == [dir.appending(path: "x")])
        #expect(try names(in: dir.appending(path: "x")) == ["a.txt", "b.txt"])
    }

    // MARK: RAR to zip, tgz and tar (P200)

    private func rarFixture(_ name: String, in directory: URL, as copyName: String? = nil) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Resources/archives"))
        let copy = directory.appending(path: copyName ?? "\(name).rar")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// Runs the engine on `input` as a rar into a fresh staging folder; returns the engine's error and the staging folder.
    private func rarStep(_ input: URL, to target: FormatID, in directory: URL) throws -> (ConversionStep, URL) {
        let staging = directory.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let step = ConversionStep(
            input: input, stagingDirectory: staging, from: try #require(FormatRegistry.builtIn.format(id: "rar")),
            to: try #require(FormatRegistry.builtIn.format(id: target)), options: .init()
        )
        return (step, staging)
    }

    /// The engine's sentence, which the app shows as written only from `engineUnsupported` (check 2).
    private func rarFailure(_ input: URL, in directory: URL) async throws -> (message: String, staging: [String]) {
        let (step, staging) = try rarStep(input, to: "zip", in: directory)
        do {
            _ = try await ArchiveEngine().convert(step, progress: { _ in })
        } catch ConversionError.engineUnsupported(let engine, let reason) {
            #expect(engine == "archive")
            return (reason, try names(in: staging))
        }
        throw Fixtures.Failure("the conversion of \(input.lastPathComponent) succeeded")
    }

    @Test func rarSignaturesAreRecognized() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["rar4", "rar5"] {
            let rar = try rarFixture(name, in: dir)
            #expect(try ArchiveEngine.container(of: rar, as: "rar") == .rar, "\(name)")
        }
        let holiday = try folder("Holiday", files: ["a.txt"])
        defer { try? FileManager.default.removeItem(at: holiday.deletingLastPathComponent()) }
        let zip = try Fixtures.zip(holiday, named: "Holiday.zip", in: dir)
        let renamedZip = dir.appending(path: "zip.rar")
        try FileManager.default.moveItem(at: zip, to: renamedZip)
        let mtree = dir.appending(path: "mtree.rar")
        try Data("#mtree\n./stolen.txt type=file size=1 contents=/etc/hosts\n".utf8).write(to: mtree)
        for impostor in [renamedZip, mtree] {
            #expect(throws: ConversionError.self) { try ArchiveEngine.container(of: impostor, as: "rar") }
        }
    }

    @Test func rar4AndRar5ConvertToEveryTarget() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["rar4", "rar5"] {
            let rar = try rarFixture(name, in: dir)
            let expected = try entries(of: rar).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.sorted()
            #expect(expected.count >= 4, "\(name)")
            for target: FormatID in ["zip", "tgz", "tar"] {
                let output = try await convert(rar, to: target)
                let listed = try entries(of: output).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.sorted()
                #expect(listed == expected, "\(name) to \(target)")
                #expect(output.lastPathComponent == "\(name).\(target)", "\(name) to \(target)")
                try FileManager.default.removeItem(at: output)
            }
        }
        #expect(try names(in: dir) == ["rar4.rar", "rar5.rar"])
    }

    @Test func encryptedRarIsPasswordProtected() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rar = try rarFixture("rar5-encrypted", in: dir)

        let failure = try await rarFailure(rar, in: dir)

        #expect(failure.message == "It's password-protected")
        #expect(failure.staging.isEmpty)
    }

    /// The RAR 4 file header's "encrypted" flag, set on the RAR 4 fixture: bsdtar reports garbage, not "encrypted".
    @Test func aRar4WithEncryptedFilesIsPasswordProtected() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rar = try rarFixture("rar4", in: dir)
        var bytes = try Data(contentsOf: rar)
        try #require(bytes[22] == 0x74)
        bytes[23] |= 0x04
        try bytes.write(to: rar)

        let failure = try await rarFailure(rar, in: dir)

        #expect(failure.message == "It's password-protected")
        #expect(failure.staging.isEmpty)
    }

    @Test func truncatedRarCannotBeRead() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rar = try rarFixture("rar5", in: dir)
        let bytes = try Data(contentsOf: rar)
        try bytes.prefix(bytes.count / 2).write(to: rar)

        let failure = try await rarFailure(rar, in: dir)

        #expect(failure.message == "Pomelo can't read this RAR")
        #expect(failure.staging.isEmpty)
    }

    /// A volume that continues in the next file would publish part of the contents.
    @Test func aMultiVolumeRarCannotBeRead() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rar = try rarFixture("rar4", in: dir, as: "x.part1.rar")
        var bytes = try Data(contentsOf: rar)
        try #require(bytes[9] == 0x73)
        bytes[10] |= 0x01
        try bytes.write(to: rar)

        let failure = try await rarFailure(rar, in: dir)

        #expect(failure.message == "Pomelo can't read this RAR")
        #expect(failure.staging.isEmpty)
    }

    @Test func rarHeadersTellEncryptionAndCompleteness() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["rar4", "rar5"] {
            let headers = try RarHeaders(of: rarFixture(name, in: dir))
            #expect(!headers.isEncrypted && headers.isWhole, "\(name)")
        }
        let encrypted = try RarHeaders(of: rarFixture("rar5-encrypted", in: dir))
        #expect(encrypted.isEncrypted && !encrypted.isWhole)
        #expect(try !RarHeaders(of: dir.appending(path: "missing.rar")).isWhole)
    }

    /// Sizes in a RAR come from the file: none of these may trap, and none is a whole archive.
    @Test func hostileRarHeadersAreRejectedWithoutCrashing() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rar4 = Array("Rar!".utf8) + [0x1A, 0x07, 0x00]
        let rar5 = Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00]
        func vint(_ value: UInt64) -> [UInt8] {
            var bytes: [UInt8] = [], rest = value
            repeat {
                bytes.append(UInt8(rest & 0x7F) | (rest > 0x7F ? 0x80 : 0))
                rest >>= 7
            } while rest > 0
            return bytes
        }
        func rar5Block(type: UInt64, flags: UInt64, fields: [UInt8]) -> [UInt8] {
            let header = vint(type) + vint(flags) + fields
            return [0, 0, 0, 0] + vint(UInt64(header.count)) + header
        }
        func rar4Block(type: UInt8, flags: UInt16, size: Int, fill: [Int: UInt8] = [:]) -> [UInt8] {
            var block = [UInt8](repeating: 0, count: size)
            block[2] = type
            block[3] = UInt8(flags & 0xFF)
            block[4] = UInt8(flags >> 8)
            block[5] = UInt8(size & 0xFF)
            block[6] = UInt8(size >> 8)
            for (index, byte) in fill { block[index] = byte }
            return block
        }
        let largeFile: [Int: UInt8] = Dictionary(uniqueKeysWithValues: ([7, 8, 9, 10, 32, 33, 34, 35]).map { ($0, 0xFF) })
        let cases: [(String, [UInt8])] = [
            ("rar5 data size 2^64-1", rar5 + rar5Block(type: 2, flags: 2, fields: vint(UInt64.max))),
            ("rar5 data size 2^64-20", rar5 + rar5Block(type: 2, flags: 2, fields: vint(UInt64.max - 19))),
            ("rar4 large pack size", rar4 + rar4Block(type: 0x73, flags: 0, size: 13)
                + rar4Block(type: 0x74, flags: 0x8100, size: 36, fill: largeFile)),
            ("rar5 header size vint overflow", rar5 + [0, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 10) + [0x01]),
            ("rar5 flags vint overflow", rar5 + [0, 0, 0, 0, 12, 2] + [UInt8](repeating: 0xFF, count: 11)),
            ("rar5 zero-size block", rar5 + [0, 0, 0, 0, 0]),
            ("rar4 zero-size block", rar4 + [UInt8](repeating: 0, count: 7)),
            ("rar5 signature only", rar5),
            ("rar4 signature only", rar4),
        ]
        for (name, bytes) in cases {
            let file = dir.appending(path: "hostile.rar")
            try Data(bytes).write(to: file)
            let headers = try RarHeaders(of: file)
            #expect(!headers.isWhole && !headers.isEncrypted, "\(name)")
            let failure = try await rarFailure(file, in: dir)
            #expect(failure.message == "Pomelo can't read this RAR", "\(name)")
        }
    }

    @Test func theEvalsRarIsTheTestResource() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let embedded = try Fixtures.rar5Archive(in: dir)
        let resource = try rarFixture("rar5", in: makeTempDir())
        defer { try? FileManager.default.removeItem(at: resource.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: embedded) == Data(contentsOf: resource))
    }

    @Test func rarIsNeverATarget() {
        #expect(!ArchiveEngine().edges().contains { $0.to == "rar" })
        let fromRar = ArchiveEngine().edges().filter { $0.from == "rar" }
        #expect(Set(fromRar.map(\.to)) == ["zip", "tgz", "tar"])
        #expect(fromRar.allSatisfy { $0.cost == 10 && $0.flags == [] && $0.operation == nil && $0.engineID == "archive" })
    }

    // MARK: Helpers

    /// Polls `condition` until it holds or `seconds` pass.
    private func eventually(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// True when a process whose arguments contain `text` is running (`pgrep -f`).
    private func isRunning(matching text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", "--", text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
