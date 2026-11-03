import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

/// Pins the argument lists of the bundled manifests that carry hard-won fixes.
@Suite struct BundledManifestTests {
    private func bundled(_ id: String) throws -> PluginManifest {
        let (manifests, _) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        return try #require(manifests.first { $0.id == id })
    }

    @Test func ffmpegMP4EdgeIsWidelyPlayable() throws {
        let edge = try #require(try bundled("ffmpeg").edge(from: "mkv", to: "mp4", operation: nil))
        #expect(edge.arguments == [
            "-hide_banner", "-nostdin", "-y", "-i", "{input}", "-c:v", "libx264", "-crf", "23",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "{output}",
        ])
    }

    @Test func ffmpegMKVEdgeUses420WithoutMovflags() throws {
        let edge = try #require(try bundled("ffmpeg").edge(from: "mov", to: "mkv", operation: nil))
        #expect(edge.arguments == [
            "-hide_banner", "-nostdin", "-y", "-i", "{input}", "-c:v", "libx264", "-crf", "23",
            "-pix_fmt", "yuv420p", "{output}",
        ])
    }

    /// Every libx264 edge outputs 4:2:0 (players reject 4:4:4 H.264); only MP4/MOV targets get `+faststart`. The
    /// tools are left out: the mp4/mov/m4v normalize edges copy the picture with `-c copy` and no `-movflags`.
    @Test func ffmpegVideoFlagsFollowTheTarget() throws {
        let ffmpeg = try bundled("ffmpeg")
        for edge in ffmpeg.edges where edge.operation == nil {
            let args = edge.arguments
            let output = try #require(args.firstIndex(of: "{output}"))
            if args.contains("libx264") {
                let pixFmt = try #require(args.firstIndex(of: "-pix_fmt"), "\(edge.to)")
                #expect(args[pixFmt + 1] == "yuv420p" && pixFmt < output, "\(edge.to)")
            }
            let isMP4OrMOV = !Set(edge.to).isDisjoint(with: ["mp4", "mov", "m4v"])
            #expect(args.contains("-movflags") == isMP4OrMOV, "\(edge.to)")
            if let movflags = args.firstIndex(of: "-movflags") {
                #expect(args[movflags + 1] == "+faststart" && movflags < output, "\(edge.to)")
            }
        }
    }

    @Test func libreOfficeProfileIsAFileURL() throws {
        let edge = try #require(try bundled("libreoffice").edge(from: "docx", to: "pdf", operation: nil))
        #expect(edge.arguments.first == "-env:UserInstallation={tempDirURL}profile")
        #expect(!edge.arguments.contains { $0.contains("file://") })
    }

    @Test func pngquantManifestIsValidAndCompresses() throws {
        let manifest = try bundled("pngquant")
        let edge = try #require(manifest.edge(from: "png", to: "png", operation: "compress"))
        #expect(edge.arguments == [
            "--quality=0-{quality:70}", "--speed", "3", "--force", "--output", "{output}", "--", "{input}",
        ])
        #expect(edge.flags == ["lossy"])
        #expect(manifest.edge(from: "png", to: "png", operation: nil) == nil)
        #expect(manifest.install.homebrew == "pngquant")
    }

    @Test func pngquantRanksAfterCwebp() throws {
        let priority = DefaultEngines.priority
        let cwebp = try #require(priority.firstIndex(of: "cwebp"))
        #expect(priority.firstIndex(of: "pngquant") == cwebp + 1)
    }

    @Test func unarManifestIsValid() throws {
        let manifest = try bundled("unar")
        try manifest.validate()
        #expect(manifest.displayName == "The Unarchiver (unar)")
        #expect(manifest.executable.names == ["unar"])
        #expect(manifest.executable.versionArguments == ["-v"])
        #expect(manifest.install == PluginManifest.Install(homebrew: "unar", website: "https://theunarchiver.com/command-line"))
        let edge = try #require(manifest.edge(from: "rar", to: "rar", operation: "extract"))
        #expect(edge.output == "folder")
        #expect(edge.arguments == ["-q", "-D", "-o", "{outputFolder}", "{input}"])
        #expect(manifest.edges.count == 1)
    }

    @Test func archiveRanksAfterVisionAndUnarAfterPandoc() throws {
        let priority = DefaultEngines.priority
        #expect(priority.firstIndex(of: "archive") == (try #require(priority.firstIndex(of: "vision"))) + 1)
        #expect(priority.firstIndex(of: "unar") == (try #require(priority.firstIndex(of: "pandoc"))) + 1)
    }

    @Test func withoutUnarARarCanOnlyBeExtractedOnceItIsInstalled() async throws {
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        let route = try #require(await registry.planner(includingMissing: true).route(from: "rar", operation: "extract", to: nil))
        #expect(route.edges.map(\.engineID) == ["unar"])
        if !Installed.has("unar") {
            #expect(await registry.planner().route(from: "rar", operation: "extract", to: nil) == nil)
            #expect(await registry.installHints()["unar"] == "The Unarchiver (unar)|brew install unar")
        }
    }

    @Test(.enabled(if: Installed.has("pngquant"))) func pngquantShrinksAScreenshot() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try Fixtures.screenshot(width: 1440, height: 900, in: dir)
        let runner = JobRunner(
            registry: DefaultEngines.makeRegistry(userPluginsFolder: nil), destinations: DestinationResolver(
                downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }
            )
        )
        let preset = try #require(Preset.builtIns.first { $0.id == "compress" })

        let results = await runner.run(ConversionRequest.from(preset, inputs: [input]))

        guard case .succeeded(_, let outputs, _) = results.first, let output = outputs.first else {
            Issue.record("\(results)"); return
        }
        let size = { (url: URL) in try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue) }
        #expect(try size(output) < size(input))
        #expect(output.pathExtension == "png")
    }
}
