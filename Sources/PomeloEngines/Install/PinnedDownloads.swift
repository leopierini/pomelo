import Foundation
import PomeloCore

/// The publishers' builds Pomelo can install, each pinned to the SHA-256 of its archive (checked 2026-10-27/28).
///
/// Updating a pin means downloading the new archive once, checking it against the publisher's checksum (or
/// signature), listing its member, and changing the version, URL and hash together in one commit. A publisher that
/// replaces a file behind the same URL (pngquant's has no version) fails the check until then: the safe failure.
/// Not installable: unar (its only build is a 2016 Intel binary) and LibreOffice (a whole app).
public enum PinnedDownloads {
    private static let mb: Int64 = 1_000_000

    public static let all: [EngineDownload] = [
        // Martin Riedl's builds: ffmpeg.org publishes no macOS binaries and the build it links is Intel only. These
        // are signed, notarized, for both architectures, with every encoder the ffmpeg manifest uses.
        EngineDownload(
            engineID: "ffmpeg", version: "9.0.2", archs: [.arm64],
            url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip")!,
            sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924", maxBytes: 100 * mb,
            member: "ffmpeg", executableName: "ffmpeg", versionArguments: ["-version"], publisher: "Martin Riedl"
        ),
        EngineDownload(
            engineID: "ffmpeg", version: "9.0.2", archs: [.x86_64],
            url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/amd64/1789931006_9.0.2/ffmpeg.zip")!,
            sha256: "7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4", maxBytes: 100 * mb,
            member: "ffmpeg", executableName: "ffmpeg", versionArguments: ["-version"], publisher: "Martin Riedl"
        ),
        EngineDownload(
            engineID: "cwebp", version: "1.6.0", archs: [.arm64],
            url: URL(string: "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-mac-arm64.tar.gz")!,
            sha256: "bc6bf84cc70f3f8574fba797d1e4a7dea4feebe9fa4be919f202413ea2b3b8f2", maxBytes: 10 * mb,
            member: "libwebp-1.6.0-mac-arm64/bin/cwebp", executableName: "cwebp", versionArguments: ["-version"],
            publisher: "The WebM Project"
        ),
        EngineDownload(
            engineID: "cwebp", version: "1.6.0", archs: [.x86_64],
            url: URL(string: "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-mac-x86-64.tar.gz")!,
            sha256: "f112dd83b420ab2a4b27d46610d9827ddf4200216023281de378647ecca31c2a", maxBytes: 10 * mb,
            member: "libwebp-1.6.0-mac-x86-64/bin/cwebp", executableName: "cwebp", versionArguments: ["-version"],
            publisher: "The WebM Project"
        ),
        EngineDownload(
            engineID: "pandoc", version: "3.13", archs: [.arm64],
            url: URL(string: "https://github.com/jgm/pandoc/releases/download/3.13/pandoc-3.13-arm64-macOS.zip")!,
            sha256: "f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3", maxBytes: 60 * mb,
            member: "pandoc-3.13-arm64/bin/pandoc", executableName: "pandoc", versionArguments: ["--version"],
            publisher: "John MacFarlane"
        ),
        EngineDownload(
            engineID: "pandoc", version: "3.13", archs: [.x86_64],
            url: URL(string: "https://github.com/jgm/pandoc/releases/download/3.13/pandoc-3.13-x86_64-macOS.zip")!,
            sha256: "1823278715aa405aaf21b59cde5dc789346aa8d4fc307467f9a9ee84162bedc5", maxBytes: 60 * mb,
            member: "pandoc-3.13-x86_64/bin/pandoc", executableName: "pandoc", versionArguments: ["--version"],
            publisher: "John MacFarlane"
        ),
        // One universal binary; the publisher posts no checksum, so this hash is the download's own.
        EngineDownload(
            engineID: "pngquant", version: "3.0.3", archs: [.arm64, .x86_64],
            url: URL(string: "https://pngquant.org/pngquant.tar.bz2")!,
            sha256: "68c32e4988d3f99f79f0642a94900756b7a2a463166067c5862826ced1e0ce1e", maxBytes: 5 * mb,
            member: "pngquant", executableName: "pngquant", versionArguments: ["--version"], publisher: "Kornel Lesiński"
        ),
    ]

    public static func download(for engine: EngineID, on machine: MachineArch, in table: [EngineDownload] = all) -> EngineDownload? {
        table.first { $0.engineID == engine && $0.archs.contains(machine) }
    }

    public static func installable(on machine: MachineArch) -> Set<EngineID> {
        Set(all.filter { $0.archs.contains(machine) }.map(\.engineID))
    }
}
