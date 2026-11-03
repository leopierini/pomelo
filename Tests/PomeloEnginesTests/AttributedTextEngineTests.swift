import AppKit
import Foundation
import os
import PDFKit
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct AttributedTextEngineTests {
    private let registry = FormatRegistry.builtIn

    private func step(_ input: URL, to target: FormatID, in staging: URL) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target))
        return ConversionStep(input: input, stagingDirectory: staging, from: from, to: to, options: PresetOptions())
    }

    private func makeStaging(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Converts `input` to `target` in a fresh staging folder and returns the output.
    private func convert(_ input: URL, to target: FormatID, in dir: URL) async throws -> URL {
        let output = try await AttributedTextEngine().convert(step(input, to: target, in: makeStaging(in: dir))) { _ in }
        return output
    }

    @Test func rtfToDocxToTxtRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rtf = try Fixtures.rtf("Hello Pomelo", in: dir)

        let docx = try await convert(rtf, to: "docx", in: dir)
        #expect(docx.pathExtension == "docx")
        let txt = try await convert(docx, to: "txt", in: dir)

        #expect(try String(contentsOf: txt, encoding: .utf8).contains("Hello Pomelo"))
        #expect(txt.pathExtension == "txt")
    }

    @Test func htmlToTxtDropsTags() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appending(path: "page.html", directoryHint: .notDirectory)
        try Data("<p><b>Hi</b> there</p>".utf8).write(to: html)

        let txt = try await convert(html, to: "txt", in: dir)

        let text = try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "Hi there")
    }

    @Test func longTextPaginates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let txt = dir.appending(path: "long.txt", directoryHint: .notDirectory)
        try Data(lines.utf8).write(to: txt)

        let pdf = try await convert(txt, to: "pdf", in: dir)

        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount > 1)
        #expect(document.page(at: 0)?.string?.contains("line 1") == true)
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("line 400") == true)
    }

    @Test func docxEdgesCarryLayoutRisk() {
        #expect(AttributedTextEngine().edges().filter { $0.from == "docx" }.allSatisfy { $0.flags.contains(.layoutRisk) })
    }

    @Test func edgesMatchTheBrief() {
        let engine = AttributedTextEngine()
        let edges = engine.edges()
        let formats: [FormatID] = ["docx", "doc", "odt", "rtf", "rtfd", "html", "txt"]
        let layoutRiskSources: Set<FormatID> = ["docx", "doc", "odt"]

        #expect(edges.count == 7 * 6 + 7)
        #expect(Set(edges.map { "\($0.from.rawValue)>\($0.to.rawValue)" }).count == edges.count)
        #expect(edges.allSatisfy { $0.engineID == "attributedtext" && $0.cost == 10 })
        #expect(edges.allSatisfy { $0.from != $0.to })
        for from in formats {
            for to in formats where to != from {
                let edge = edges.first { $0.from == from && $0.to == to }
                #expect(edge?.flags == (layoutRiskSources.contains(from) ? [.layoutRisk] : []), "\(from) to \(to)")
            }
            #expect(edges.first { $0.from == from && $0.to == "pdf" }?.flags == [.layoutRisk], "\(from) to pdf")
        }
        #expect(!edges.contains { $0.from == "pdf" })
        #expect(engine.edges() == edges)
        #expect(engine.id == "attributedtext")
        #expect(engine.displayName == "Text")
        #expect(engine.maxConcurrentJobs == 1)
    }

    @Test func rtfToRTFDToTxtRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rtf = try Fixtures.rtf("Hello Pomelo", in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try step(rtf, to: "rtfd", in: staging)
        let package = try await AttributedTextEngine().convert(conversion) { _ in }

        #expect(package == conversion.suggestedOutput)
        #expect(package.pathExtension == "rtfd")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: package.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try package.resourceValues(forKeys: [.isPackageKey]).isPackage == true)

        let txt = try await convert(package, to: "txt", in: dir)
        #expect(try String(contentsOf: txt, encoding: .utf8).contains("Hello Pomelo"))
    }

    @Test func emptyDocumentProducesOneBlankPage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appending(path: "empty.txt", directoryHint: .notDirectory)
        try Data().write(to: txt)

        let pdf = try await convert(txt, to: "pdf", in: dir)

        #expect(try #require(PDFDocument(url: pdf)).pageCount == 1)
    }

    @Test @MainActor func paginatorWritesBlankPageForEmptyText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.pdf", directoryHint: .notDirectory)

        try TextPaginator.writePDF(NSAttributedString(string: ""), to: url, pageSize: CGSize(width: 612, height: 792))

        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    }

    @Test @MainActor func textThatNeverFitsTerminatesWithABlankPage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.pdf", directoryHint: .notDirectory)

        // A 6 x 6 pt text area cannot hold a single line of the default 12 pt font.
        try TextPaginator.writePDF(
            NSAttributedString(string: "never fits\nanywhere"), to: url, pageSize: CGSize(width: 150, height: 150)
        )

        #expect(try #require(PDFDocument(url: url)).pageCount == 1)
    }

    @Test @MainActor func oversizedAttachmentTerminates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "out.pdf", directoryHint: .notDirectory)
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: 0, width: 100, height: 5_000)
        let text = NSMutableAttributedString(string: "before ")
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: " after"))

        try TextPaginator.writePDF(text, to: url, pageSize: CGSize(width: 595, height: 842))

        #expect(try #require(PDFDocument(url: url)).pageCount >= 1)
    }

    @Test func utf8HTMLWithoutCharsetKeepsItsCharacters() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appending(path: "u.html", directoryHint: .notDirectory)
        try Data("<p>caf\u{E9} \u{4E16}\u{754C}</p>".utf8).write(to: html)

        let txt = try await convert(html, to: "txt", in: dir)

        #expect(try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "caf\u{E9} \u{4E16}\u{754C}")
    }

    @Test func textWithoutAColourDrawsBlack() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appending(path: "black.txt", directoryHint: .notDirectory)
        try Data("MMMMMMMM MMMMMMMM MMMMMMMM".utf8).write(to: txt)

        let pdf = try await convert(txt, to: "pdf", in: dir)

        let page = try #require(PDFDocument(url: pdf)?.page(at: 0))
        let image = page.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var darkest = 1.0
        var coloured = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                darkest = min(darkest, Double(pixel.brightnessComponent))
                if pixel.saturationComponent > 0.1 { coloured = true }
            }
        }
        #expect(darkest < 0.2, "the text should be near black, darkest brightness was \(darkest)")
        #expect(!coloured)
    }

    /// Conversions that never need WebKit: reading docx/rtf/txt, writing every non-PDF format (html included) and
    /// paginating into a PDF.
    @Test(arguments: [
        ("rtf", "pdf"), ("rtf", "docx"), ("rtf", "html"), ("rtf", "rtfd"), ("rtf", "odt"), ("docx", "txt"), ("txt", "pdf"),
    ] as [(FormatID, FormatID)])
    @MainActor func nonHTMLConversionCompletesWhileTheMainActorIsBusy(from: FormatID, to: FormatID) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var input = try Fixtures.rtf("Hello Pomelo", in: dir)
        if from != "rtf" { input = try await convert(input, to: from, in: dir) }
        let conversion = try step(input, to: to, in: makeStaging(in: dir))

        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task.detached {
            let output = try await AttributedTextEngine().convert(conversion) { _ in }
            finished.withLock { $0 = true }
            return output
        }
        // Hold the main actor without ever suspending until the conversion finishes, or give up after 10 s.
        let deadline = ContinuousClock.now + .seconds(10)
        while !finished.withLock({ $0 }) && ContinuousClock.now < deadline { usleep(1_000) }

        #expect(finished.withLock { $0 }, "\(from) to \(to) waited for the main actor")
        let output = try await task.value
        #expect(output == conversion.suggestedOutput)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func htmlToPDFKeepsItsText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appending(path: "page.html", directoryHint: .notDirectory)
        try Data("<h1>Title</h1><ul><li>one</li></ul><table><tr><td>cell</td></tr></table>".utf8).write(to: html)

        let pdf = try await convert(html, to: "pdf", in: dir)

        let text = try #require(PDFDocument(url: pdf)?.string)
        #expect(text.contains("Title") && text.contains("one") && text.contains("cell"))
    }

    @Test func missingInputFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appending(path: "missing.docx", directoryHint: .notDirectory)
        let staging = try makeStaging(in: dir)

        await #expect(throws: AttributedTextEngine.Failure.self) {
            _ = try await AttributedTextEngine().convert(self.step(missing, to: "txt", in: staging)) { _ in }
        }
    }
}
