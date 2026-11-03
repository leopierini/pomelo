import Foundation
import Testing
import PomeloTestSupport
@testable import PomeloCore

@Test func plainName() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    #expect(OutputNamer().uniqueURL(stem: "photo", ext: "png", suffix: nil, in: d, avoiding: []).lastPathComponent == "photo.png")
}
@Test func collisionNumbering() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    FileManager.default.createFile(atPath: d.appending(path: "photo.png").path, contents: Data())
    FileManager.default.createFile(atPath: d.appending(path: "photo 2.png").path, contents: Data())
    #expect(OutputNamer().uniqueURL(stem: "photo", ext: "png", suffix: nil, in: d, avoiding: []).lastPathComponent == "photo 3.png")
}
@Test func avoidsSourceCaseInsensitively() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    #expect(OutputNamer().uniqueURL(stem: "Photo", ext: "png", suffix: nil, in: d, avoiding: ["photo.png"]).lastPathComponent == "Photo 2.png")
}
@Test func suffixName() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    #expect(OutputNamer().uniqueURL(stem: "clip", ext: "mp4", suffix: "compressed", in: d, avoiding: []).lastPathComponent == "clip-compressed.mp4")
}
@Test func multiDotUppercase() { #expect(OutputNamer.stem(of: URL(fileURLWithPath: "/x/IMG.Final.HEIC")) == "IMG.Final") }
@Test func folderOutputHasNoDot() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    #expect(OutputNamer().uniqueURL(stem: "deck", ext: "", suffix: nil, in: d, avoiding: []).lastPathComponent == "deck")
}
@Test func publishNeverOverwritesRacingFile() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let staged = d.appending(path: "staged.png"); try Data("new".utf8).write(to: staged)
    try Data("old".utf8).write(to: d.appending(path: "photo.png"))
    let blindNamer = OutputNamer(fileExists: { _ in false })   // simulates a file appearing after naming
    let out = try OutputPublisher.publish(staged: staged, to: d, stem: "photo", ext: "png", suffix: nil, avoiding: [], namer: blindNamer)
    #expect(out.lastPathComponent == "photo 2.png")
    #expect(try String(contentsOf: d.appending(path: "photo.png"), encoding: .utf8) == "old")
    #expect(FileManager.default.fileExists(atPath: staged.path) == false)
}
@Test func destinationFallsBack() {
    let r = DestinationResolver(downloadsFolder: URL(fileURLWithPath: "/dl"), isWritable: { $0.path != "/ro" })
    #expect(r.destination(for: URL(fileURLWithPath: "/ro/a.png"), override: nil) == (URL(fileURLWithPath: "/dl"), true))
    #expect(r.destination(for: URL(fileURLWithPath: "/rw/a.png"), override: nil).fellBack == false)
}

// MARK: - The output mark (§3.4 rule 10)

private func setMark(_ value: String, on url: URL) {
    let bytes = Array(value.utf8)
    precondition(setxattr(url.path, OutputMark.attributeName, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0)
}

@Test func aPlainFileIsNotMarked() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let png = try Fixtures.png(width: 4, height: 4, in: d)
    #expect(!OutputMark.isMarked(png))
    setMark("1", on: png)
    #expect(OutputMark.isMarked(png))
}

@Test func aPublishedItemIsMarkedButNotWhatIsInsideIt() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let staged = d.appending(path: "staged", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
    let inner = staged.appending(path: "1.txt")
    try Data("x".utf8).write(to: inner)
    let out = try OutputPublisher.publish(staged: staged, to: d, stem: "pages", ext: "", suffix: nil, avoiding: [], namer: OutputNamer())
    #expect(OutputMark.isMarked(out))
    #expect(!OutputMark.isMarked(out.appending(path: "1.txt")))
}

/// Read without following links: a link to a marked file is not itself Pomelo's output.
@Test func aLinkToAMarkedFileIsNotMarked() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let target = d.appending(path: "target.txt")
    try Data("x".utf8).write(to: target)
    setMark("1", on: target)
    let link = d.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(OutputMark.isMarked(target))
    #expect(!OutputMark.isMarked(link))
}

@Test func markingReportsWhetherTheAttributeWasSet() throws {
    let d = try makeTempDir(); defer { try? FileManager.default.removeItem(at: d) }
    let file = d.appending(path: "out.png")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    #expect(OutputMark.apply(to: file))
    #expect(OutputMark.isMarked(file))
    #expect(!OutputMark.apply(to: d.appending(path: "missing.png")))
}
