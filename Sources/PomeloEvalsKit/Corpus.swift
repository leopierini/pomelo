import AVFoundation
import Foundation
import PomeloTestSupport

/// The files the evals convert, generated through `Fixtures` so nothing binary is committed.
public enum Corpus {
    public static let photoWidth = 4032
    public static let photoHeight = 3024

    struct Recipe: Sendable {
        var name: String
        /// An executable, or an `engine:<id>`, the recipe needs; without it the file is left out of the corpus.
        var requires: String?
        /// The corpus file this one is made from, written earlier in `recipes`; rewriting it rewrites this one too.
        var source: String?
        /// Makes the file in its first argument, a scratch folder; the second is the corpus folder.
        var make: @Sendable (URL, URL) async throws -> URL

        init(_ name: String, requires: String? = nil, _ make: @escaping @Sendable (URL) async throws -> URL) {
            self.name = name
            self.requires = requires
            self.make = { scratch, _ in try await make(scratch) }
        }

        /// A file made from the corpus's `source`: `derive` gets that file and a scratch folder.
        init(_ name: String, from source: String, _ derive: @escaping @Sendable (URL, URL) async throws -> URL) {
            self.name = name
            self.source = source
            self.make = { scratch, corpus in
                try await derive(corpus.appending(path: source, directoryHint: .notDirectory), scratch)
            }
        }

        var isAvailable: Bool { requires.map { Installed.has($0) } ?? true }
    }

    static let recipes: [Recipe] = [
        Recipe("photo.png", { try Fixtures.photo(width: photoWidth, height: photoHeight, type: "public.png", ext: "png", in: $0) }),
        Recipe("photo.jpg", { try Fixtures.photo(width: photoWidth, height: photoHeight, type: "public.jpeg", ext: "jpg", in: $0) }),
        Recipe("photo.heic", { try Fixtures.photo(width: photoWidth, height: photoHeight, type: "public.heic", ext: "heic", in: $0) }),
        Recipe("screenshot.png", { try Fixtures.screenshot(width: 2880, height: 1800, in: $0) }),
        Recipe("animated.gif", {
            try Fixtures.animatedGIF(width: 480, height: 320, delays: Array(repeating: 0.1, count: 8), loopCount: 0, in: $0)
        }),
        Recipe("doc.pdf", { try Fixtures.pdf(pages: 5, in: $0) }),
        Recipe("photos.pdf", { try Fixtures.pdfWithPhoto(pages: 2, in: $0) }),
        Recipe("scan.pdf", { try Fixtures.pdfWithPhoto(pages: 4, in: $0) }),
        Recipe("doc.rtf", { try Fixtures.rtf("Pomelo evals document.\nA second line of plain text.", in: $0) }),
        Recipe("qr.png", { try Fixtures.qrCode("https://pomelo.example/evals", in: $0) }),
        Recipe("subject.png", { try Fixtures.subjectPhoto(in: $0) }),
        Recipe("subject-scene.png", { try Fixtures.subjectScene(width: 1600, height: 1200, in: $0) }),
        Recipe("page-photo.jpg", { try Fixtures.pagePhoto(side: 3000, in: $0) }),
        // Find duplicates' set (P268): dup-b is a byte copy of dup-a, dup-c and dup-d are made from dup-a's pixels.
        // Copied, not drawn twice: two renders of one scene need not give the same bytes.
        Recipe("dup-a.jpg", { try Fixtures.scene(seed: 1, width: 2000, height: 1500, in: $0) }),
        Recipe("dup-b.jpg", from: "dup-a.jpg", { original, directory in
            let copy = directory.appending(path: "dup-b.jpg", directoryHint: .notDirectory)
            try FileManager.default.copyItem(at: original, to: copy)
            return copy
        }),
        Recipe("dup-c.jpg", from: "dup-a.jpg", { original, directory in
            try Fixtures.copy(of: original, scale: 0.5, quality: 0.9, type: "public.jpeg", ext: "jpg", in: directory)
        }),
        Recipe("dup-d.jpg", from: "dup-a.jpg", { original, directory in
            try Fixtures.copy(of: original, quality: 0.5, type: "public.jpeg", ext: "jpg", in: directory)
        }),
        Recipe("dup-e.jpg", { try Fixtures.scene(seed: 2, width: 2000, height: 1500, in: $0) }),
        Recipe("text.png", { try Fixtures.textImage("Hello Pomelo", in: $0) }),
        // Prose the on-device model can summarize; a two-line document gets an invented summary (Task 7).
        Recipe("article.txt", { directory in
            try Fixtures.textFile("""
                The town council met on Monday evening to discuss the new library. After a long debate, the members \
                approved a budget of two million euros for the building, which will open in the spring of 2028.

                The council also agreed to extend the opening hours of the public swimming pool during the summer, \
                and to plant two hundred trees along the river before the end of the year.
                """, ext: "txt", in: directory)
        }),
        Recipe("table.png", { try Fixtures.tableImage(in: $0) }),
        Recipe("receipt.png", { try Fixtures.receipt(in: $0) }),
        Recipe("speech.m4a", { try Fixtures.speech(in: $0) }),
        Recipe("clip.mov", { try await Fixtures.movie(seconds: 10, withAudio: true, width: 1920, height: 1080, in: $0) }),
        // Top quality and every frame a key frame spend bits the way a camera does, so Compress has something to
        // gain; clip.mov is already tiny.
        Recipe("phone.mov", {
            try await Fixtures.movie(
                seconds: 10, withAudio: true, width: 1920, height: 1080,
                compression: [AVVideoQualityKey: 1.0, AVVideoMaxKeyFrameIntervalKey: 1], in: $0
            )
        }),
        Recipe("clip.mkv", requires: "ffmpeg", {
            try await Fixtures.matroskaMovie(
                seconds: 10, width: 1920, height: 1080,
                compression: [AVVideoQualityKey: 1.0, AVVideoMaxKeyFrameIntervalKey: 1], in: $0
            )
        }),
        // Stored landscape with an iPhone portrait's transform, so a crop must turn it upright first.
        Recipe("quadrants.mov", {
            try await Fixtures.quadrantMovie(width: 1280, height: 720, seconds: 4, rotated90: true, in: $0)
        }),
        Recipe("tone.wav", { try Fixtures.wav(seconds: 10, channels: 2, in: $0) }),
        // AVFoundation can't pass mp3 through and can't write flac, so these trims run through ffmpeg.
        Recipe("tone.mp3", requires: "ffmpeg", { try Fixtures.ffmpegAudio(seconds: 10, channels: 2, ext: "mp3", in: $0) }),
        Recipe("tone.flac", requires: "ffmpeg", { try Fixtures.ffmpegAudio(seconds: 10, channels: 2, ext: "flac", in: $0) }),
        // Three items at the top, so Extract wraps them in a folder named after the archive.
        Recipe("archive.zip", { directory in
            let content = directory.appending(path: "content", directoryHint: .isDirectory)
            let docs = content.appending(path: "docs", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            try Data("Pomelo evals archive".utf8).write(to: content.appending(path: "notes.txt"))
            try Data("A document inside a folder".utf8).write(to: docs.appending(path: "readme.txt"))
            try FileManager.default.moveItem(
                at: try Fixtures.png(width: 64, height: 64, in: directory), to: content.appending(path: "image.png")
            )
            return try Fixtures.zip(content, keepParent: false, named: "archive.zip", in: directory)
        }),
        Recipe("archive.rar", { try Fixtures.rar5Archive(in: $0) }),
        Recipe("logo.svg", { try Fixtures.svg(in: $0) }),
        Recipe("subs.srt", { try Fixtures.srt(in: $0) }),
        Recipe("subs.vtt", { try Fixtures.vtt(in: $0) }),
        Recipe("table.csv", { try Fixtures.textFile("città;prezzo;quantità\nRoma;1,5;12\nNapoli;2,25;7\nTorino;3;007\n", ext: "csv", in: $0) }),
        Recipe("sheet.xlsx", { try Fixtures.dateWorkbook(in: $0) }),
        Recipe("deck.pptx", { try Fixtures.presentation(slides: 3, in: $0) }),
        Recipe("tone.m4a", { try Fixtures.m4a(seconds: 10, in: $0) }),
        Recipe("codes.pdf", { try Fixtures.qrCodePDF("https://pomelo.example/evals-pdf", in: $0) }),
        Recipe("notes.txt.gz", { directory in
            try Fixtures.gzip(try Fixtures.textFile("Pomelo evals gzipped notes", ext: "txt", in: directory))
        }),
    ]

    public static var fileNames: [String] { recipes.filter(\.isAvailable).map(\.name) }

    /// The recipes' version, kept in the corpus folder's `.version`. Bump it whenever a recipe changes (its content,
    /// a fixture it calls, its name), or an existing corpus keeps the old files and the edges check stale content.
    public static let version = 12
    static let versionFileName = ".version"

    /// Writes every file of the corpus that is not already in `directory`, or every file when the folder's
    /// `.version` is not `version`; returns the names it wrote.
    @discardableResult
    public static func write(to directory: URL) async throws -> [String] {
        try await write(to: directory, recipes: recipes)
    }

    /// `recipes` is a seam for the tests, which check the version logic on a few cheap files.
    static func write(to directory: URL, recipes: [Recipe]) async throws -> [String] {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let versionFile = directory.appending(path: versionFileName, directoryHint: .notDirectory)
        let stored = (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrent = stored == String(version)
        var written: [String] = []
        for recipe in recipes where recipe.isAvailable {
            let destination = directory.appending(path: recipe.name, directoryHint: .notDirectory)
            let exists = manager.fileExists(atPath: destination.path)
            let sourceRewritten = recipe.source.map(written.contains) ?? false
            if exists && isCurrent && !sourceRewritten { continue }
            let scratch = manager.temporaryDirectory
                .appending(path: "pomelo-corpus-\(UUID().uuidString)", directoryHint: .isDirectory)
            try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: scratch) }
            let made = try await recipe.make(scratch, directory)
            if exists {
                _ = try manager.replaceItemAt(destination, withItemAt: made)
            } else {
                try manager.moveItem(at: made, to: destination)
            }
            written.append(recipe.name)
        }
        // Last, so an interrupted regeneration starts over next time.
        if !isCurrent { try Data("\(version)\n".utf8).write(to: versionFile) }
        return written
    }
}
