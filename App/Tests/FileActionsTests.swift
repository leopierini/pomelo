import AppKit
import Foundation
import PomeloCore
import PomeloUIModel
import Testing
@testable import Pomelo

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// The names `/usr/bin/unzip -l` lists, one per entry.
private func zipListing(_ zip: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-l", zip.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@MainActor
@Suite struct FileActionsTests {
    @Test func makeZipOfTwoFilesProducesOneArchiveWithBoth() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt")
        let b = dir.appending(path: "b.txt")
        try Data("alpha".utf8).write(to: a)
        try Data("beta".utf8).write(to: b)

        let created = try await FileActions.run(.makeZip, on: [a, b])

        #expect(created == [dir.appending(path: "Archive.zip")])
        let listing = try zipListing(created[0])
        #expect(listing.contains("a.txt"))
        #expect(listing.contains("b.txt"))
        // The sources are untouched and nothing else was left in the folder.
        #expect(try String(contentsOf: a, encoding: .utf8) == "alpha")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["Archive.zip", "a.txt", "b.txt"])
    }

    @Test func makeZipOfOneItemIsNamedAfterIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "one.txt"))

        let created = try await FileActions.run(.makeZip, on: [folder])

        #expect(created == [dir.appending(path: "Photos.zip")])
        #expect(try zipListing(created[0]).contains("Photos/one.txt"))
    }

    /// P22: a folder zips under its full name, dots included, like Finder's Compress; a file keeps `<stem>.zip`.
    @Test func makeZipOfAFolderKeepsItsFullName() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "v1.2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "notes.txt"))
        let file = dir.appending(path: "report.v2.txt")
        try Data("y".utf8).write(to: file)

        // A drag can hand over a folder URL without its trailing slash.
        let created = try await FileActions.run(.makeZip, on: [URL(fileURLWithPath: folder.path, isDirectory: false)])
        let zippedFile = try await FileActions.run(.makeZip, on: [file])

        #expect(created == [dir.appending(path: "v1.2.zip")])
        #expect(try zipListing(created[0]).contains("v1.2/notes.txt"))
        #expect(zippedFile == [dir.appending(path: "report.v2.zip")])
    }

    @Test func makeZipNeverReplacesAnExistingArchive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt")
        try Data("alpha".utf8).write(to: a)
        let existing = dir.appending(path: "a.zip")
        try Data("not a zip".utf8).write(to: existing)

        let created = try await FileActions.run(.makeZip, on: [a])

        #expect(created == [dir.appending(path: "a 2.zip")])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "not a zip")
    }

    /// §3.4 rule 10 (P116): the zip is an output like any other, so a watch folder never takes it.
    @Test func makeZipMarksTheZipAndNotItsSources() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.txt")
        let b = dir.appending(path: "b.txt")
        try Data("alpha".utf8).write(to: a)
        try Data("beta".utf8).write(to: b)

        let created = try await FileActions.run(.makeZip, on: [a, b])

        #expect(created.count == 1)
        #expect(created.allSatisfy(OutputMark.isMarked))
        #expect(!OutputMark.isMarked(a) && !OutputMark.isMarked(b))
    }

    @Test func copyPathsPutsNewlineJoinedPathsOnThePasteboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/c.txt")]

        let created = try await FileActions.run(.copyPaths, on: files, pasteboard: pasteboard)

        #expect(created.isEmpty)
        #expect(pasteboard.string(forType: .string) == "/tmp/a b.txt\n/tmp/c.txt")
    }

    @Test func copyFilesWritesFileURLs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a.txt", "b.txt"].map { name in
            let file = dir.appending(path: name)
            try Data("x".utf8).write(to: file)
            return file
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        _ = try await FileActions.run(.copyFiles, on: files, pasteboard: pasteboard)

        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(read == files)
    }

    /// A gone item's URL would paste nothing, so the copy fails and says which, leaving the clipboard as it was.
    @Test func copyFilesFailsForAMissingFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let present = dir.appending(path: "a.txt")
        try Data("x".utf8).write(to: present)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        await #expect(throws: FileActionError.missing(name: "gone.txt")) {
            try await FileActions.run(.copyFiles, on: [present, dir.appending(path: "gone.txt")], pasteboard: pasteboard)
        }
        #expect(pasteboard.string(forType: .string) == "before")
        #expect(FileActionError.missing(name: "gone.txt").localizedDescription == "gone.txt was moved or deleted")
    }

    @Test func terminalFolderIsTheItemItselfForADirectoryElseItsParent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "a.txt")
        try Data("x".utf8).write(to: file)
        #expect(FileActions.terminalFolder(for: [file]) == dir)
        #expect(FileActions.terminalFolder(for: [dir]) == dir)
    }

    @Test func everyProcessFailureHasAHumanMessage() {
        #expect(ZipBuilder.message(for: .timedOut) == "ditto stopped responding")
        #expect(ZipBuilder.message(for: .launchFailed(errno: ENOENT)).hasPrefix("ditto couldn't start"))
        #expect(ZipBuilder.message(for: .nonZeroExit(code: 1, stderrTail: "\n  ditto: no space left\n")) == "ditto: no space left")
        #expect(ZipBuilder.message(for: .nonZeroExit(code: 3, stderrTail: "")) == "ditto failed (exit code 3)")
        #expect(FileActionError.zipFailed("x").localizedDescription == "Couldn't make the zip: x")
    }
}
