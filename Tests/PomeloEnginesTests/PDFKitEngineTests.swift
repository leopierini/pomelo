import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct PDFKitEngineTests {
    private let registry = FormatRegistry.builtIn

    private func step(
        _ input: URL, to target: FormatID, in staging: URL, options: PresetOptions = PresetOptions()
    ) throws -> ConversionStep {
        let from = try #require(registry.format(for: input))
        let to = try #require(registry.format(id: target))
        return ConversionStep(input: input, stagingDirectory: staging, from: from, to: to, options: options)
    }

    private func makeStaging(in dir: URL) throws -> URL {
        let staging = dir.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    @Test func edgesMatchTheBrief() throws {
        let engine = PDFKitEngine()
        let edges = engine.edges()
        func edge(_ from: FormatID, _ to: FormatID) -> ConversionEdge? {
            edges.first { $0.from == from && $0.to == to }
        }
        #expect(edges.count == 19)
        #expect(edges.allSatisfy { $0.engineID == "pdfkit" && $0.cost == 10 })
        #expect(edge("pdf", "png")?.flags == [.directOnly])
        #expect(edge("pdf", "jpg")?.flags == [.lossy, .directOnly])
        #expect(edge("pdf", "txt")?.flags == [.directOnly])
        for source: FormatID in ["png", "jpg", "heic", "tiff"] {
            #expect(edge(source, "pdf")?.flags == [.directOnly])
        }
        let tools = edges.filter { $0.operation != nil }
        #expect(tools.count == 12)
        #expect(tools.allSatisfy { $0.from == "pdf" || $0.to == "pdf" })
        for operation in ["compress", "split", "combine", "organize"] {
            let edge = tools.first { $0.operation == operation && $0.from == "pdf" && $0.to == "pdf" }
            #expect(edge?.flags == [])
        }
        let imagesToPDF = Set(tools.filter { $0.operation == "combine" && $0.from != "pdf" }.map(\.from))
        #expect(imagesToPDF == ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp"])
        #expect(engine.id == "pdfkit")
        #expect(engine.displayName == "PDFKit")
        #expect(engine.maxConcurrentJobs == 2)
    }

    @Test func singlePagePDFToPNGIsAFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try step(input, to: "png", in: staging)
        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(output.pathExtension == "png")
        #expect(!isDirectory(output))
        #expect(Fixtures.imageUTType(output) == "public.png")
    }

    @Test func multiPagePDFToPNGIsAFolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 3, in: dir)
        let staging = try makeStaging(in: dir)
        let stem = OutputNamer.stem(of: input)

        let output = try await PDFKitEngine().convert(try step(input, to: "png", in: staging)) { _ in }

        #expect(isDirectory(output))
        #expect(output.lastPathComponent == stem)
        #expect(output.deletingLastPathComponent() == staging)
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names == ["\(stem)-1.png", "\(stem)-2.png", "\(stem)-3.png"])
        for name in names {
            #expect(Fixtures.imageUTType(output.appending(path: name)) == "public.png")
        }
    }

    @Test func renderDPI() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(
            try step(input, to: "png", in: staging, options: PresetOptions(pdfRenderDPI: 144))
        ) { _ in }

        #expect(Fixtures.imageSize(output) == CGSize(width: 1224, height: 1584))
    }

    @Test func imageToPDF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.png(width: 400, height: 200, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try step(input, to: "pdf", in: staging)
        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 1)
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(bounds.size == CGSize(width: 400, height: 200))
    }

    @Test func pdfToText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)

        let conversion = try step(input, to: "txt", in: staging)
        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Page 1"))
    }

    /// A 612x792 pt PDF that is white except for a red 100 pt square in the media box's lower-left corner.
    private func markedPDF(in directory: URL) throws -> URL {
        let url = directory.appending(path: "marked.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// The RGB value of the pixel at (`x`, `y`), counted from the image's top-left corner.
    private func pixel(of url: URL, x: Int, y: Int) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        let offset = (y * image.width + x) * 4  // memory row 0 is the top of the image
        return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
    }

    private func isRed(_ rgb: [Int]) -> Bool { rgb[0] > 200 && rgb[1] < 60 && rgb[2] < 60 }
    private func isWhite(_ rgb: [Int]) -> Bool { rgb.allSatisfy { $0 > 240 } }

    @Test func unrotatedPageKeepsTheLowerLeftMarkerAtBottomLeft() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try markedPDF(in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(try step(input, to: "png", in: staging)) { _ in }

        // 612 x 792 pt at 150 dpi; the 100 pt marker is about 208 px square.
        let size = try #require(Fixtures.imageSize(output))
        let (width, height) = (Int(size.width), Int(size.height))
        #expect(size == CGSize(width: 1275, height: 1650))
        #expect(isRed(try pixel(of: output, x: 50, y: height - 50)))
        #expect(isRed(try pixel(of: output, x: 200, y: height - 200)))  // the marker fills 208 px, so the page is scaled
        #expect(isWhite(try pixel(of: output, x: 220, y: height - 220)))
        #expect(isWhite(try pixel(of: output, x: 50, y: 50)))
        #expect(isWhite(try pixel(of: output, x: width - 50, y: 50)))
        #expect(isWhite(try pixel(of: output, x: width - 50, y: height - 50)))
    }

    @Test func rotatedPageRendersUpright() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = try #require(PDFDocument(url: try markedPDF(in: dir)))
        try #require(document.page(at: 0)).rotation = 90
        let input = dir.appending(path: "rotated.pdf")
        try #require(document.write(to: input))
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(try step(input, to: "png", in: staging)) { _ in }

        // Rotated clockwise by 90 degrees the page is 792 x 612 pt (1650 x 1275 px at 150 dpi) and its
        // lower-left corner, where the marker is, ends up at the top-left.
        let size = try #require(Fixtures.imageSize(output))
        let (width, height) = (Int(size.width), Int(size.height))
        #expect(size == CGSize(width: 1650, height: 1275))
        #expect(isRed(try pixel(of: output, x: 50, y: 50)))
        #expect(isWhite(try pixel(of: output, x: width - 50, y: 50)))
        #expect(isWhite(try pixel(of: output, x: 50, y: height - 50)))
        #expect(isWhite(try pixel(of: output, x: width - 50, y: height - 50)))
    }

    @Test func lockedAndBrokenPDFsFailDescriptively() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)

        let broken = dir.appending(path: "broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        await #expect(throws: PDFKitEngine.Failure.self) {
            _ = try await PDFKitEngine().convert(try step(broken, to: "png", in: staging)) { _ in }
        }

        let locked = dir.appending(path: "locked.pdf")
        let source = try #require(PDFDocument(url: try Fixtures.pdf(pages: 1, in: dir)))
        try #require(source.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "secret"]))
        await #expect(throws: PDFKitEngine.Failure.self) {
            _ = try await PDFKitEngine().convert(try step(locked, to: "txt", in: staging)) { _ in }
        }
    }

    // MARK: PDF tools

    private func tool(_ operation: String, _ input: URL, in staging: URL) throws -> ConversionStep {
        let pdf = try #require(registry.format(id: "pdf"))
        return ConversionStep(
            input: input, stagingDirectory: staging, from: pdf, to: pdf, options: PresetOptions(), operation: operation
        )
    }

    private func combineStep(_ inputs: [URL], to target: FormatID = "pdf", in staging: URL) throws -> CombineStep {
        CombineStep(
            inputs: inputs, formats: try inputs.map { try #require(registry.format(for: $0)) }, stagingDirectory: staging,
            to: try #require(registry.format(id: target)), operation: "combine"
        )
    }

    private func size(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    @Test func compressShrinksAPDFWithPhotos() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdfWithPhoto(pages: 2, in: dir)
        let staging = try makeStaging(in: dir)
        let conversion = try tool("compress", input, in: staging)

        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        #expect(try size(output) < size(input) / 2)
        #expect(try #require(PDFDocument(url: output)).pageCount == 2)
    }

    @Test func compressKeepsTheText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(texts: ["Alpha", "Beta"], in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(try tool("compress", input, in: staging)) { _ in }

        let document = try #require(PDFDocument(url: output))
        #expect(document.page(at: 1)?.string?.contains("Beta") == true)
    }

    @Test func splitMakesOneFilePerPage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 3, in: dir)
        let staging = try makeStaging(in: dir)
        let stem = OutputNamer.stem(of: input)
        let conversion = try tool("split", input, in: staging)

        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedFolder)
        #expect(isDirectory(output))
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(names == ["\(stem)-1.pdf", "\(stem)-2.pdf", "\(stem)-3.pdf"])
        for (index, name) in names.enumerated() {
            let page = try #require(PDFDocument(url: output.appending(path: name)))
            #expect(page.pageCount == 1)
            #expect(page.string?.contains("Page \(index + 1)") == true)
        }
    }

    @Test func splittingOnePageIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.notApplicable(reason: "It has only one page")) {
            _ = try await PDFKitEngine().convert(try tool("split", input, in: staging)) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func splittingALockedPDFFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let locked = try Fixtures.lockedPDF(in: dir)

        do {
            _ = try await PDFKitEngine().convert(try tool("split", locked, in: staging)) { _ in }
            Issue.record("the split should have failed")
        } catch let failure as PDFKitEngine.Failure {
            #expect(failure.description == "\(locked.lastPathComponent) is password protected")
        }
    }

    @Test func mergeKeepsTheInputOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.pdf(texts: ["A1", "A2"], in: dir)
        let b = try Fixtures.pdf(texts: ["B1"], in: dir)
        let staging = try makeStaging(in: dir)
        let step = try combineStep([a, b], in: staging)

        let output = try await PDFKitEngine().combine(step) { _ in }

        #expect(output == step.suggestedOutput)
        let merged = try #require(PDFDocument(url: output))
        #expect(merged.pageCount == 3)
        #expect(merged.page(at: 0)?.string?.contains("A1") == true)
        #expect(merged.page(at: 1)?.string?.contains("A2") == true)
        #expect(merged.page(at: 2)?.string?.contains("B1") == true)
        #expect(try #require(PDFDocument(url: a)).pageCount == 2)
    }

    @Test func mergingAReversedOrderReversesThePages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.pdf(texts: ["A1"], in: dir)
        let b = try Fixtures.pdf(texts: ["B1"], in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().combine(try combineStep([b, a], in: staging)) { _ in }

        let merged = try #require(PDFDocument(url: output))
        #expect(merged.page(at: 0)?.string?.contains("B1") == true)
        #expect(merged.page(at: 1)?.string?.contains("A1") == true)
    }

    @Test func mergingALockedPDFFailsNamingIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try Fixtures.pdf(pages: 1, in: dir)
        let locked = try Fixtures.lockedPDF(in: dir)
        let staging = try makeStaging(in: dir)

        do {
            _ = try await PDFKitEngine().combine(try combineStep([plain, locked], in: staging)) { _ in }
            Issue.record("the merge should have failed")
        } catch let named as CombineInputError {
            #expect(named.input == locked)
            #expect(String(describing: named.underlying).contains("is password protected"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func mergingADamagedPDFFailsNamingIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try Fixtures.pdf(pages: 1, in: dir)
        let broken = dir.appending(path: "broken.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        let staging = try makeStaging(in: dir)

        do {
            _ = try await PDFKitEngine().combine(try combineStep([broken, plain], in: staging)) { _ in }
            Issue.record("the merge should have failed")
        } catch let named as CombineInputError {
            #expect(named.input == broken)
        }
    }

    @Test func imagesBecomeOnePDF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Fixtures.png(width: 400, height: 200, in: dir)
        let second = try Fixtures.png(width: 100, height: 300, in: dir)
        let third = try Fixtures.jpgWithOrientation(6, width: 300, height: 200, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try combineStep([first, second, third], in: staging)

        let output = try await PDFKitEngine().combine(step) { _ in }

        #expect(output == step.suggestedOutput)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        let sizes = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
        // The third image is rotated by its orientation tag, so its page is upright: 200 x 300.
        #expect(sizes == [CGSize(width: 400, height: 200), CGSize(width: 100, height: 300), CGSize(width: 200, height: 300)])
    }

    @Test func anUnreadableImageIsNamedInTheCombine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try Fixtures.png(width: 40, height: 40, in: dir)
        let bad = dir.appending(path: "bad.png")
        try Data("not an image".utf8).write(to: bad)
        let staging = try makeStaging(in: dir)

        do {
            _ = try await PDFKitEngine().combine(try combineStep([good, bad], in: staging)) { _ in }
            Issue.record("the combine should have failed")
        } catch let named as CombineInputError {
            #expect(named.input == bad)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func aCancelledCombineThrowsCancellationNotAnInputError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.pdf(pages: 1, in: dir)
        let b = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)
        let step = try combineStep([a, b], in: staging)

        let task = Task { () -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFKitEngine().combine(step) { _ in }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCombineToAnythingButPDFIsRefused() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixtures.pdf(pages: 1, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: PDFKitEngine.Failure.self) {
            _ = try await PDFKitEngine().combine(try combineStep([a], to: "png", in: staging)) { _ in }
        }
    }

    // MARK: Organize

    private func organizeStep(_ input: URL, _ pages: [PageEdit]?, in staging: URL) throws -> ConversionStep {
        let pdf = try #require(registry.format(id: "pdf"))
        let options = PresetOptions(edit: pages.map(EditSpec.organize))
        return ConversionStep(
            input: input, stagingDirectory: staging, from: pdf, to: pdf, options: options, operation: "organize"
        )
    }

    private func pageTexts(_ url: URL) throws -> [String] {
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func organizeReordersRotatesAndDrops() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pageTexts: ["1", "2", "3"], in: dir)
        let staging = try makeStaging(in: dir)
        let conversion = try organizeStep(input, [PageEdit(page: 2, rotation: 0), PageEdit(page: 0, rotation: 90)], in: staging)

        let output = try await PDFKitEngine().convert(conversion) { _ in }

        #expect(output == conversion.suggestedOutput)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(try pageTexts(output) == ["3", "1"])
        #expect(document.page(at: 0)?.rotation == 0)
        #expect(document.page(at: 1)?.rotation == 90)
    }

    @Test func organizeAddsToAnExistingRotation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pageTexts: ["a", "b", "c"], rotations: [90, 270, 0], in: dir)
        let staging = try makeStaging(in: dir)
        let pages = [PageEdit(page: 0, rotation: 90), PageEdit(page: 1, rotation: 180), PageEdit(page: 2, rotation: 270)]

        let output = try await PDFKitEngine().convert(try organizeStep(input, pages, in: staging)) { _ in }

        let document = try #require(PDFDocument(url: output))
        #expect((0..<3).map { document.page(at: $0)?.rotation } == [180, 90, 270])
    }

    @Test func organizeKeepsTheDocumentAttributes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pageTexts: ["a", "b"], title: "Quarterly report", in: dir)
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(
            try organizeStep(input, [PageEdit(page: 1, rotation: 0), PageEdit(page: 0, rotation: 0)], in: staging)
        ) { _ in }

        let attributes = try #require(PDFDocument(url: output)?.documentAttributes)
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly report")
    }

    @Test func organizeKeepsLinksOnKeptPages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try Fixtures.pdf(pageTexts: ["a", "b", "c"], in: dir)
        let source = try #require(PDFDocument(url: plain))
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 120, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://pomelo.example/kept")
        try #require(source.page(at: 2)).addAnnotation(link)
        let input = dir.appending(path: "linked.pdf")
        try #require(source.write(to: input))
        let staging = try makeStaging(in: dir)

        let output = try await PDFKitEngine().convert(
            try organizeStep(input, [PageEdit(page: 2, rotation: 0), PageEdit(page: 0, rotation: 0)], in: staging)
        ) { _ in }

        let document = try #require(PDFDocument(url: output))
        let links = try #require(document.page(at: 0)).annotations.compactMap(\.url)
        #expect(links == [URL(string: "https://pomelo.example/kept")])
        #expect(try #require(document.page(at: 1)).annotations.compactMap(\.url).isEmpty)
    }

    @Test func organizeNeverTouchesTheSource() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pageTexts: ["a", "b"], in: dir)
        let before = try Data(contentsOf: input)
        let staging = try makeStaging(in: dir)

        _ = try await PDFKitEngine().convert(
            try organizeStep(input, [PageEdit(page: 1, rotation: 90)], in: staging)
        ) { _ in }

        #expect(try Data(contentsOf: input) == before)
    }

    @Test func aDuplicatedPageIsKeptTwice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pageTexts: ["a", "b"], in: dir)
        let staging = try makeStaging(in: dir)
        let pages = [PageEdit(page: 0, rotation: 0), PageEdit(page: 0, rotation: 90)]

        let output = try await PDFKitEngine().convert(try organizeStep(input, pages, in: staging)) { _ in }

        let document = try #require(PDFDocument(url: output))
        #expect(try pageTexts(output) == ["a", "a"])
        #expect(document.page(at: 0)?.rotation == 0 && document.page(at: 1)?.rotation == 90)
    }

    @Test func anOutOfRangePageIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 3, in: dir)
        let staging = try makeStaging(in: dir)
        let changed = ConversionError.notApplicable(reason: "The pages changed since the editor opened")

        for pages in [[PageEdit(page: 3, rotation: 0)], [PageEdit(page: -1, rotation: 0)],
                      [PageEdit(page: 0, rotation: 45)], [PageEdit(page: 0, rotation: 0), PageEdit(page: 7, rotation: 90)]] {
            await #expect(throws: changed) {
                _ = try await PDFKitEngine().convert(try organizeStep(input, pages, in: staging)) { _ in }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test func noPagesOrNoEditIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.pdf(pages: 2, in: dir)
        let staging = try makeStaging(in: dir)

        await #expect(throws: ConversionError.notApplicable(reason: "Keep at least one page")) {
            _ = try await PDFKitEngine().convert(try organizeStep(input, [], in: staging)) { _ in }
        }
        await #expect(throws: ConversionError.notApplicable(reason: "The pages changed since the editor opened")) {
            _ = try await PDFKitEngine().convert(try organizeStep(input, nil, in: staging)) { _ in }
        }
    }

    @Test func organizingALockedPDFFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staging = try makeStaging(in: dir)
        let locked = try Fixtures.lockedPDF(in: dir)

        do {
            _ = try await PDFKitEngine().convert(
                try organizeStep(locked, [PageEdit(page: 0, rotation: 90)], in: staging)
            ) { _ in }
            Issue.record("the organizer should have failed")
        } catch let failure as PDFKitEngine.Failure {
            #expect(failure.description == "\(locked.lastPathComponent) is password protected")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }
}
