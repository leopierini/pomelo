import CryptoKit
import Foundation
import Testing
import PomeloCore
import PomeloEngines
import PomeloTestSupport

@Suite struct PinnedDownloadsTests {
    @Test func everyPinIsHTTPSWithAHexHashAndACap() {
        #expect(!PinnedDownloads.all.isEmpty)
        for pin in PinnedDownloads.all {
            #expect(pin.url.scheme == "https", "\(pin.url)")
            #expect(pin.url.host() != nil, "\(pin.url)")
            #expect(pin.sha256.count == 64 && pin.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(pin.url)")
            #expect(pin.maxBytes > 0 && pin.maxBytes <= 100_000_000, "\(pin.url)")
            #expect(!pin.archs.isEmpty, "\(pin.url)")
            // bsdtar reads the member as a pattern: a literal relative path keeps it matching exactly one entry.
            #expect(!pin.member.isEmpty && !pin.member.hasPrefix("/") && !pin.member.hasSuffix("/"), "\(pin.member)")
            #expect(!pin.member.split(separator: "/").contains(".."), "\(pin.member)")
            #expect(pin.member.allSatisfy { !"*?[]\\".contains($0) }, "\(pin.member)")
            #expect(pin.member.split(separator: "/").last.map(String.init) == pin.executableName, "\(pin.member)")
            #expect(!pin.publisher.isEmpty && !pin.version.isEmpty)
        }
        #expect(Set(PinnedDownloads.all.map(\.sha256)).count == PinnedDownloads.all.count)
    }

    @Test func theCapsAreTheBriefs() {
        let caps = Dictionary(PinnedDownloads.all.map { ($0.engineID, $0.maxBytes) }, uniquingKeysWith: max)
        #expect(caps == ["ffmpeg": 100_000_000, "pandoc": 60_000_000, "cwebp": 10_000_000, "pngquant": 5_000_000])
    }

    @Test func everyPinnedEngineHasABundledManifestWithTheSameExecutable() throws {
        let (manifests, _) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        #expect(!PinnedDownloads.all.isEmpty)
        for pin in PinnedDownloads.all {
            let manifest = try #require(manifests.first { $0.id == pin.engineID.rawValue }, "\(pin.engineID)")
            #expect(manifest.executable.names.first == pin.executableName, "\(pin.engineID)")
            #expect(manifest.executable.versionArguments == pin.versionArguments, "\(pin.engineID)")
            #expect(pin.versionArguments != nil, "\(pin.engineID)")
        }
    }

    @Test func everyInstallableEngineCoversBothArchitectures() {
        let arm = PinnedDownloads.installable(on: .arm64)
        let intel = PinnedDownloads.installable(on: .x86_64)
        #expect(arm == ["ffmpeg", "cwebp", "pandoc", "pngquant"])
        #expect(arm == intel)
        for engine in arm {
            for machine in MachineArch.allCases {
                let pin = PinnedDownloads.download(for: engine, on: machine)
                #expect(pin?.engineID == engine && pin?.archs.contains(machine) == true, "\(engine) \(machine)")
            }
        }
        #expect(PinnedDownloads.download(for: "unar", on: .arm64) == nil)
        #expect(PinnedDownloads.download(for: "libreoffice", on: .x86_64) == nil)
    }

    @Test func theArchitecturesGetTheirOwnBuilds() {
        #expect(PinnedDownloads.download(for: "ffmpeg", on: .arm64)?.url.path().contains("/arm64/") == true)
        #expect(PinnedDownloads.download(for: "ffmpeg", on: .x86_64)?.url.path().contains("/amd64/") == true)
        #expect(PinnedDownloads.download(for: "pandoc", on: .x86_64)?.member == "pandoc-3.13-x86_64/bin/pandoc")
        #expect(PinnedDownloads.download(for: "cwebp", on: .arm64)?.member == "libwebp-1.6.0-mac-arm64/bin/cwebp")
    }

    /// Hits the network: `POMELO_NETWORK_TESTS=1 swift test --filter everyPinStillMatchesItsDownload`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POMELO_NETWORK_TESTS"] == "1"))
    func everyPinStillMatchesItsDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = URLSessionDownloader()
        for (index, pin) in PinnedDownloads.all.enumerated() {
            let file = dir.appending(path: "download-\(index)")
            try await downloader.download(pin.url, to: file, maxBytes: pin.maxBytes) { _, _ in }
            let digest = SHA256.hash(data: try Data(contentsOf: file, options: .alwaysMapped))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            #expect(hex == pin.sha256, "\(pin.url)")
            try FileManager.default.removeItem(at: file)
        }
    }
}
