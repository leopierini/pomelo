import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct VisionAndDefaultsTests {
    private let registry = FormatRegistry.builtIn

    private func ocr(_ image: URL, in dir: URL) async throws -> (output: URL, text: String, progress: [Double]) {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: image, stagingDirectory: staging,
            from: try #require(registry.format(for: image)), to: try #require(registry.format(id: "txt")),
            options: PresetOptions()
        )
        let recorder = ProgressRecorder()
        let output = try await VisionEngine().convert(step) { recorder.record($0) }
        return (output, try String(contentsOf: output, encoding: .utf8), recorder.values)
    }

    @Test func ocrReadsRenderedText() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try Fixtures.textImage("HELLO POMELO", in: dir)

        let result = try await ocr(image, in: dir)

        #expect(result.text.uppercased().contains("HELLO POMELO"))
        #expect(result.output.pathExtension == "txt")
        #expect(result.output.deletingLastPathComponent().lastPathComponent.hasPrefix("staging-"))
        #expect(result.progress.first == 0 && result.progress.last == 1)
    }

    @Test func imageWithoutTextYieldsAnEmptyFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = try Fixtures.textImage("", in: dir)

        let result = try await ocr(image, in: dir)

        #expect(result.text.isEmpty)
        #expect(FileManager.default.fileExists(atPath: result.output.path))
    }

    @Test func visionEdgesAreDirectOnlyImageToText() {
        let edges = VisionEngine().edges().filter { $0.operation == nil }
        #expect(Set(edges.map(\.from)) == ["png", "jpg", "heic", "tiff"])
        #expect(edges.allSatisfy { $0.to == "txt" && $0.engineID == "vision" && $0.cost == 10 && $0.flags == [.directOnly] })
    }

    @Test func visionToolEdgesAreOperationEdges() {
        let edges = VisionEngine().edges().filter { $0.operation != nil }
        let images: Set<FormatID> = ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp"]
        let background = edges.filter { $0.operation == "remove-background" }
        let codes = edges.filter { $0.operation == "read-codes" }
        let straighten = edges.filter { $0.operation == "straighten" }
        let duplicates = edges.filter { $0.operation == "find-duplicates" }
        #expect(Set(background.map(\.from)) == images && background.allSatisfy { $0.to == "png" })
        #expect(Set(codes.map(\.from)) == images.union(["pdf"]) && codes.allSatisfy { $0.to == "txt" })
        #expect(Set(duplicates.map(\.from)) == images && duplicates.allSatisfy { $0.to == "txt" && $0.flags.isEmpty })
        #expect(duplicates.count == images.count)
        #expect(edges.count == background.count + codes.count + straighten.count + duplicates.count)
        #expect(edges.allSatisfy { $0.engineID == "vision" && $0.cost == 10 })
    }

    @Test func registryRoutesTheVisionTools() async {
        let planner = await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner()
        #expect(planner.route(from: "jpg", operation: "remove-background", to: "png")?.edges.map(\.engineID) == ["vision"])
        #expect(planner.route(from: "pdf", operation: "read-codes", to: "txt")?.edges.map(\.engineID) == ["vision"])
        #expect(planner.route(from: "jpg", operation: "straighten", to: "jpg")?.edges.map(\.engineID) == ["vision"])
        #expect(planner.route(from: "heic", operation: "find-duplicates", to: "txt")?.edges.map(\.engineID) == ["vision"])
    }

    // MARK: Tools

    private func tool(
        _ operation: String, _ input: URL, to target: FormatID, in dir: URL
    ) async throws -> URL {
        let staging = dir.appending(path: "staging-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let step = ConversionStep(
            input: input, stagingDirectory: staging,
            from: try #require(registry.format(for: input)), to: try #require(registry.format(id: target)),
            options: PresetOptions(), operation: operation
        )
        let output = try await VisionEngine().convert(step) { _ in }
        #expect(output.deletingLastPathComponent() == staging)
        return output
    }

    private func notApplicable(
        _ operation: String, _ input: URL, to target: FormatID, in dir: URL
    ) async -> String? {
        do {
            _ = try await tool(operation, input, to: target, in: dir)
            return nil
        } catch ConversionError.notApplicable(let reason) {
            return reason
        } catch {
            return "unexpected \(error)"
        }
    }

    private func codes(_ input: URL, in dir: URL) async throws -> String {
        let output = try await tool("read-codes", input, to: "txt", in: dir)
        #expect(output.pathExtension == "txt")
        return try String(contentsOf: output, encoding: .utf8)
    }

    @Test func readsAQRCode() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let qr = try Fixtures.qrCode("https://pomelo.example", in: dir)

        #expect(try await codes(qr, in: dir) == "https://pomelo.example\n")
    }

    @Test func readsCodesInAPDF() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try imagesAsPDF([try Fixtures.qrCode("page one", in: dir), try Fixtures.qrCode("page two", in: dir)], in: dir)

        #expect(try await codes(pdf, in: dir) == "page one\n\npage two\n")
    }

    @Test func aQRCodeConvertedToPDFIsStillRead() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let qr = try Fixtures.qrCode("https://pomelo.example/pdf", in: dir)
        let staging = dir.appending(path: "pdf-staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let toPDF = ConversionStep(
            input: qr, stagingDirectory: staging, from: try #require(registry.format(id: "png")),
            to: try #require(registry.format(id: "pdf")), options: PresetOptions()
        )
        let pdf = try await PDFKitEngine().convert(toPDF) { _ in }

        #expect(try await codes(pdf, in: dir) == "https://pomelo.example/pdf\n")
    }

    @Test func aRepeatedCodeIsListedOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let again = try Fixtures.qrCode("same", in: dir)
        let pdf = try imagesAsPDF([again, again, try Fixtures.qrCode("other", in: dir)], in: dir)

        #expect(try await codes(pdf, in: dir) == "same\n\nother\n")
    }

    @Test func codesOnOnePageComeInReadingOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try Fixtures.qrCode("first", in: dir)
        let second = try Fixtures.qrCode("second", in: dir)
        let third = try Fixtures.qrCode("third", in: dir)
        let fourth = try Fixtures.qrCode("fourth", in: dir)
        // Drawn out of order: the rows are 1000 px apart and the right-hand codes sit 24 px higher than the left-hand ones.
        let sheet = try composite(
            in: dir, width: 1300, height: 1300,
            [(fourth, CGPoint(x: 700, y: 44)), (second, CGPoint(x: 700, y: 724)), (third, CGPoint(x: 20, y: 20)), (first, CGPoint(x: 20, y: 700))]
        )

        #expect(try await codes(sheet, in: dir) == "first\n\nsecond\n\nthird\n\nfourth\n")
    }

    @Test func noCodeIsNotApplicable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try Fixtures.textImage("NO CODES HERE", in: dir)

        #expect(await notApplicable("read-codes", plain, to: "txt", in: dir) == "No code found")
    }

    @Test func aFlatImageHasNoSubject() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flat = try Fixtures.png(width: 512, height: 512, in: dir)
        let blank = try Fixtures.png(width: 512, height: 512, alpha: true, in: dir)

        #expect(await notApplicable("remove-background", flat, to: "png", in: dir) == "No subject found")
        #expect(await notApplicable("remove-background", blank, to: "png", in: dir) == "No subject found")
    }

    @Test func removesTheBackground() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.subjectPhoto(in: dir)

        let cutout = try await tool("remove-background", photo, to: "png", in: dir)

        #expect(cutout.pathExtension == "png")
        #expect(Fixtures.imageSize(cutout) == Fixtures.imageSize(photo))
        let corner = try #require(rgba(of: cutout, x: 8, y: 8))
        let centre = try #require(rgba(of: cutout, x: 256, y: 256))
        #expect(corner.a == 0)
        #expect(centre.a == 255)
    }

    @Test func removingTheBackgroundLeavesTheSourceAlone() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.subjectPhoto(in: dir)
        let before = try Data(contentsOf: photo)

        _ = try await tool("remove-background", photo, to: "png", in: dir)

        #expect(try Data(contentsOf: photo) == before)
    }

    @Test func aToolRefusesAnOperationItDoesNotHave() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = try Fixtures.subjectPhoto(in: dir)

        await #expect(throws: VisionEngine.Failure.self) { _ = try await tool("sharpen", photo, to: "png", in: dir) }
    }

    // MARK: Test helpers

    private func rgba(of url: URL, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            x < image.width, y < image.height
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let row = data.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        return (row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3])
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// One white page per image, each as large as the image, so a code keeps its size.
    private func imagesAsPDF(_ images: [URL], in dir: URL) throws -> URL {
        let url = dir.appending(path: "codes-\(UUID().uuidString.prefix(8)).pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 600)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for image in images {
            context.beginPDFPage(nil)
            context.draw(try decode(image), in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A white `width` x `height` PNG with each image drawn at its origin (a lower-left origin, as CoreGraphics has).
    private func composite(in dir: URL, width: Int, height: Int, _ placements: [(URL, CGPoint)]) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (url, origin) in placements {
            let image = try decode(url)
            context.draw(image, in: CGRect(x: origin.x, y: origin.y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        let output = try #require(context.makeImage())
        let url = dir.appending(path: "sheet-\(UUID().uuidString.prefix(8)).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, output, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func bundledManifestsLoadAndValidate() throws {
        let (ms, failures) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        #expect(failures.isEmpty)
        #expect(Set(ms.map(\.id)) == ["ffmpeg", "cwebp", "pngquant", "libreoffice", "pandoc", "unar"])
        for m in ms {
            try m.validate()
            #expect(m.conversionEdges().allSatisfy { $0.from != $0.to || $0.operation != nil })
        }
    }

    @Test func pandocHtmlEdgeWritesAStandaloneDocument() throws {
        let (ms, _) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        let pandoc = try #require(ms.first { $0.id == "pandoc" })
        let edge = try #require(pandoc.edge(from: "md", to: "html", operation: nil))
        #expect(edge.arguments == ["-s", "{input}", "-o", "{output}"])
        // Only the html edge is standalone.
        let others = pandoc.edges.filter { !$0.to.contains("html") }
        #expect(others.allSatisfy { !$0.arguments.contains("-s") })
    }

    @Test func loadPluginsReturnsManifestsAndReportsInvalidFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let valid = PluginManifest(
            id: "extra", displayName: "Extra",
            executable: .init(names: ["/bin/sh"], searchPaths: [], versionArguments: nil),
            install: .init(), edges: [.init(from: ["docx"], to: ["pdf"], arguments: ["{input}", "{output}"])]
        )
        try JSONEncoder().encode(valid).write(to: dir.appending(path: "extra.pomelo-plugin.json"))
        try Data("{ not json".utf8).write(to: dir.appending(path: "broken.pomelo-plugin.json"))

        let (manifests, failures) = DefaultEngines.loadPlugins(userPluginsFolder: dir)

        #expect(manifests.map(\.id).first == "extra")
        #expect(Set(manifests.map(\.id)) == ["extra", "ffmpeg", "cwebp", "pngquant", "libreoffice", "pandoc", "unar"])
        #expect(failures.map(\.lastPathComponent) == ["broken.pomelo-plugin.json"])
    }

    @Test func loadPluginsWithoutUserFolderLoadsBundledOnly() {
        let (manifests, failures) = DefaultEngines.loadPlugins(userPluginsFolder: nil)
        #expect(Set(manifests.map(\.id)) == ["ffmpeg", "cwebp", "pngquant", "libreoffice", "pandoc", "unar"])
        #expect(failures.isEmpty)
    }

    @Test func pluginsLoadFromTheUserFolderByDefault() {
        let explicit = DefaultEngines.loadPlugins(userPluginsFolder: DefaultEngines.userPluginsFolder)
        let byDefault = DefaultEngines.loadPlugins()
        #expect(byDefault.manifests == explicit.manifests)
        #expect(byDefault.failures == explicit.failures)
    }

    @Test func userPluginsFolderIsInsideAppSupport() {
        #expect(DefaultEngines.appSupportFolder.path.hasSuffix("Application Support/Pomelo"))
        #expect(DefaultEngines.legacyAppSupportFolder.path.hasSuffix("Application Support/Kumquat"))
        // Which of the two depends on this Mac's folders (P96), so only that it is one of them.
        let folders = [DefaultEngines.appSupportFolder, DefaultEngines.legacyAppSupportFolder]
        #expect(DefaultEngines.userPluginsFolder.lastPathComponent == "Plugins")
        #expect(folders.contains(DefaultEngines.userPluginsFolder.deletingLastPathComponent()))
        #expect(DefaultEngines.enginesFolder.lastPathComponent == "Engines")
        #expect(folders.contains(DefaultEngines.enginesFolder.deletingLastPathComponent()))
    }

    /// P96: the pre-rename folder serves only while the new one doesn't exist; nothing is created, copied or moved.
    @Test func thePreRenameFolderIsUsedOnlyUntilTheNewOneExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = dir.appending(path: "Pomelo/Plugins", directoryHint: .isDirectory)
        let old = dir.appending(path: "Kumquat/Plugins", directoryHint: .isDirectory)

        #expect(DefaultEngines.preferredFolder(new, legacy: old) == new)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        #expect(DefaultEngines.preferredFolder(new, legacy: old) == old)
        #expect(!FileManager.default.fileExists(atPath: new.path))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        #expect(DefaultEngines.preferredFolder(new, legacy: old) == new)
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func aFileWhereTheNewFolderShouldBeDoesNotHideTheOldFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = dir.appending(path: "Pomelo"), old = dir.appending(path: "Kumquat", directoryHint: .isDirectory)
        try Data().write(to: new)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        #expect(DefaultEngines.preferredFolder(new, legacy: old) == old)
    }

    @Test func theUserFolderStillLoadsPreRenameManifests() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = PluginManifest(
            id: "oldplugin", displayName: "Old Plugin",
            executable: .init(names: ["/bin/sh"], searchPaths: [], versionArguments: nil),
            install: .init(), edges: [.init(from: ["docx"], to: ["pdf"], arguments: ["{input}", "{output}"])]
        )
        try JSONEncoder().encode(old).write(to: dir.appending(path: "oldplugin.kumquat-plugin.json"))

        let (manifests, failures) = DefaultEngines.loadPlugins(userPluginsFolder: dir)
        #expect(manifests.map(\.id).first == "oldplugin")
        #expect(failures.isEmpty)
    }

    @Test func libreOfficeIsPreferredForDocxToPDFWhenAvailable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = PluginManifest(
            id: "libreoffice", displayName: "LibreOffice",
            executable: .init(names: ["/bin/sh"], searchPaths: [], versionArguments: nil),
            install: .init(), defaultCost: 60,
            edges: [.init(from: ["docx"], to: ["pdf"], arguments: ["{input}", "{output}"])]
        )
        try JSONEncoder().encode(manifest).write(to: dir.appending(path: "libreoffice.pomelo-plugin.json"))

        let registry = DefaultEngines.makeRegistry(userPluginsFolder: dir)
        let route = await registry.planner().route(from: "docx", to: "pdf")

        #expect(route?.edges.first?.engineID == "libreoffice")
    }

    @Test func registryPlansHeicToJpgNatively() async {
        #expect(await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner().route(from: "heic", to: "jpg")?.edges.map(\.engineID) == ["imageio"])
    }

    @Test func registryPlansImageToTextWithVision() async {
        #expect(await DefaultEngines.makeRegistry(userPluginsFolder: nil).planner().route(from: "png", to: "txt")?.edges.map(\.engineID) == ["vision"])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
