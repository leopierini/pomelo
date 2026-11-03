import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

/// Routes the default registry plans once the bundled plugins are "installed": each stub is a copy of the bundled
/// manifest whose executable is /bin/sh, placed in a temporary user plugins folder. Nothing is ever run.
@Suite struct DefaultRoutesTests {
    private let formats = FormatRegistry.builtIn
    private static let documentFormats: Set<FormatID> = ["doc", "docx", "html", "odt", "rtf", "rtfd"]

    private func planner(installing pluginIDs: [String]) async throws -> RoutePlanner {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder]).manifests
        for id in pluginIDs {
            var manifest = try #require(bundled.first { $0.id == id })
            manifest.executable = .init(names: ["/bin/sh"], searchPaths: [], versionArguments: nil)
            try JSONEncoder().encode(manifest).write(to: dir.appending(path: "\(id).pomelo-plugin.json"))
        }
        return await DefaultEngines.makeRegistry(userPluginsFolder: dir).planner()
    }

    @Test func videoOffersNoImageDocumentOrTextChains() async throws {
        let targets = try await planner(installing: ["ffmpeg"]).reachableTargets(from: "mp4")

        let images = targets.keys.filter { formats.format(id: $0)?.category == .image }
        // The only image target is the animated GIF itself, made directly by ffmpeg.
        #expect(images == ["gif"])
        #expect(targets["gif"]?.edges.map(\.engineID) == ["ffmpeg"])
        #expect(targets["pdf"] == nil)
        #expect(targets["txt"] == nil)
    }

    @Test func pdfOffersNoDocumentsViaExtractedText() async throws {
        let targets = try await planner(installing: []).reachableTargets(from: "pdf")
        // Word is the one document a PDF becomes, in one step through Vision (P196).
        #expect(Set(targets.keys).isDisjoint(with: Self.documentFormats.subtracting(["docx"])))
        #expect(targets["docx"]?.edges.map(\.engineID) == ["documentscan"])
        #expect(targets["docx"]?.flags.contains(.layoutRisk) == true)
        #expect(targets["txt"]?.edges.map(\.engineID) == ["pdfkit"])
    }

    @Test func noChainThroughPdf() async throws {
        let planner = try await planner(installing: ["libreoffice"])

        // Presentations reach images in the one `slides` hop; a docx still can't chain through the PDF (R22).
        for target in ["png", "jpg"] as [FormatID] {
            let route = try #require(planner.route(from: "pptx", to: target))
            #expect(route.edges.map(\.engineID) == ["slides"])
        }
        #expect(planner.route(from: "odp", to: "png")?.edges.map(\.engineID) == ["slides"])
        #expect(planner.route(from: "ppt", to: "jpg")?.edges.map(\.engineID) == ["slides"])
        #expect(planner.route(from: "docx", to: "png") == nil)
        #expect(planner.route(from: "xlsx", to: "jpg") == nil)
        #expect(planner.route(from: "pptx", to: "pdf")?.edges.map(\.engineID) == ["libreoffice"])
    }

    @Test func slidesNeedLibreOffice() async throws {
        let planner = try await planner(installing: [])
        #expect(planner.route(from: "pptx", to: "png") == nil)
    }

    @Test func imagesOfferNoDocumentsViaOCR() async throws {
        let targets = try await planner(installing: []).reachableTargets(from: "png")
        #expect(Set(targets.keys).isDisjoint(with: Self.documentFormats))
        #expect(targets["txt"]?.edges.map(\.engineID) == ["vision"])
    }

    @Test func audioFromVideoIsExtractedInOneStep() async throws {
        let planner = try await planner(installing: ["ffmpeg"])

        let m4a = try #require(planner.route(from: "mkv", to: "m4a"))
        #expect(m4a.edges.map(\.engineID) == ["ffmpeg"])
        #expect(m4a.edges.count == 1)
        // AVFoundation still wins where it can read the source.
        #expect(planner.route(from: "mp4", to: "m4a")?.edges.map(\.engineID) == ["avfoundation"])

        let wav = try #require(planner.route(from: "mkv", to: "wav"))
        #expect(!wav.flags.contains(.lossy))
    }

    @Test func webpFromJPEGGoesThroughPNG() async throws {
        let route = try #require(try await planner(installing: ["cwebp"]).route(from: "jpg", to: "webp"))
        #expect(route.edges.map(\.engineID) == ["imageio", "cwebp"])
        #expect(route.edges.map(\.to) == ["png", "webp"])
    }

    @Test func pdfToolsRouteOnlyThroughPDFKit() async throws {
        let planner = try await planner(installing: [])
        for operation in ["compress", "split", "combine"] {
            let route = try #require(planner.route(from: "pdf", operation: operation, to: "pdf"))
            #expect(route.edges.map(\.engineID) == ["pdfkit"])
        }
        for image: FormatID in ["png", "jpg", "heic", "tiff", "avif", "gif", "bmp"] {
            let route = try #require(planner.route(from: image, operation: "combine", to: "pdf"))
            #expect(route.edges.map(\.engineID) == ["pdfkit"])
        }
        #expect(planner.route(from: "pdf", operation: "combine", to: "png") == nil)
    }

    @Test func audioAndVideoToolsRouteThroughAVFoundation() async throws {
        let planner = try await planner(installing: ["ffmpeg"])
        let tools: [(String, FormatID, FormatID?)] = [
            ("compress", "mov", nil), ("remove-audio", "mp4", nil), ("snapshot", "m4v", "png"), ("speed", "mov", nil),
            ("speed", "m4a", nil), ("mono", "wav", nil), ("strip-metadata", "m4a", nil), ("trim", "mp4", nil),
            ("trim", "m4a", nil), ("trim", "caf", nil), ("split", "m4v", nil),
        ]
        for (operation, source, target) in tools {
            let route = try #require(
                planner.route(from: source, operation: operation, to: target), "\(operation) \(source)"
            )
            #expect(route.edges.map(\.engineID) == ["avfoundation"], "\(operation) \(source)")
            #expect(route.edges.last?.to == target ?? source)
        }
    }

    @Test func avfoundationWinsWhereBothCan() async throws {
        let planner = try await planner(installing: ["ffmpeg"])
        let cases: [(String, FormatID, String)] = [
            ("speed", "mov", "avfoundation"), ("speed", "mkv", "ffmpeg"), ("speed", "avi", "ffmpeg"),
            ("remove-audio", "mp4", "avfoundation"), ("remove-audio", "webm", "ffmpeg"),
            ("compress", "mkv", "ffmpeg"), ("normalize-volume", "wav", "ffmpeg"), ("normalize-volume", "mp4", "ffmpeg"),
            ("mono", "wav", "avfoundation"), ("mono", "mp3", "ffmpeg"), ("mono", "ogg", "ffmpeg"),
            ("strip-metadata", "m4a", "avfoundation"), ("strip-metadata", "mp3", "ffmpeg"),
            ("trim", "mov", "avfoundation"), ("trim", "wav", "avfoundation"), ("trim", "mp3", "ffmpeg"),
            ("trim", "flac", "ffmpeg"),
        ]
        for (operation, source, engine) in cases {
            let route = try #require(planner.route(from: source, operation: operation, to: nil), "\(operation) \(source)")
            #expect(route.edges.map(\.engineID) == [EngineID(engine)], "\(operation) \(source)")
        }
        #expect(planner.route(from: "mkv", operation: "snapshot", to: "png")?.edges.map(\.engineID) == ["ffmpeg"])
    }

    @Test func windowsFormatsConvertThroughFFmpeg() async throws {
        let planner = try await planner(installing: ["ffmpeg"])
        for (from, to) in [("mov", "wmv"), ("mov", "avi"), ("wav", "wma"), ("wmv", "mp4"), ("wma", "mp3"), ("avi", "wmv")] {
            let route = try #require(planner.route(from: FormatID(from), to: FormatID(to)), "\(from) to \(to)")
            #expect(route.edges.map(\.engineID) == ["ffmpeg"], "\(from) to \(to)")
        }
    }
}
