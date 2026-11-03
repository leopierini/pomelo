import Compression
import Foundation
import PomeloCore

/// Archives through the system's `bsdtar` (libarchive): extracts zip, tar, tgz and gz, converts between zip, tar and
/// tgz, and converts rar to zip, tar and tgz (P200). Extracting a RAR comes from the `unar` plugin.
public struct ArchiveEngine: ConversionEngine {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static let bsdtar = URL(filePath: "/usr/bin/bsdtar")
    static let gzip = URL(filePath: "/usr/bin/gzip")
    private static let edgeCost = 10
    private static let extract = "extract"
    private static let extractable: [FormatID] = ["zip", "tar", "tgz", "gz"]
    private static let convertible: [FormatID] = ["zip", "tar", "tgz"]
    private static let convertibleSources: [FormatID] = convertible + ["rar"]
    /// Longest first, so `x.tar.gz` loses both extensions.
    private static let archiveExtensions = [".tar.gz", ".tgz", ".tar", ".zip", ".gz"]

    private let runner: ProcessRunner
    private let bsdtarExecutable: URL

    /// bsdtar writes nothing while it works, and ProcessRunner's timeout measures silence, so the default must
    /// cover the slowest single archive.
    public init(runner: ProcessRunner = ProcessRunner(timeout: .seconds(3600))) {
        self.init(runner: runner, bsdtar: Self.bsdtar)
    }

    /// Tests run a stand-in that never finishes, so a cancel always lands mid-extraction.
    init(runner: ProcessRunner = ProcessRunner(timeout: .seconds(3600)), bsdtar: URL) {
        self.runner = runner
        bsdtarExecutable = bsdtar
    }

    public var id: EngineID { "archive" }
    public var displayName: String { "Archive tools" }
    public var maxConcurrentJobs: Int { 2 }

    public func availability() async -> EngineAvailability { .available(version: nil) }

    public func edges() -> [ConversionEdge] {
        let extracts = Self.extractable.map {
            ConversionEdge(from: $0, to: $0, engineID: id, cost: Self.edgeCost, flags: [], operation: Self.extract)
        }
        let conversions = Self.convertibleSources.flatMap { from in
            Self.convertible.filter { $0 != from }.map {
                ConversionEdge(from: from, to: $0, engineID: id, cost: Self.edgeCost, flags: [])
            }
        }
        return extracts + conversions
    }

    public func convert(_ step: ConversionStep, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        progress(0)
        let output: URL
        switch step.operation {
        case nil: output = try await recompress(step)
        case Self.extract: output = try await extract(step)
        default: throw Failure("Archive tools have no \(step.operation ?? "") tool")
        }
        try Task.checkCancellation()
        progress(1)
        return output
    }

    /// The archive's name without its archive extensions: `x.tar.gz` and `x.tgz` give `x`, `report.pdf.gz` gives
    /// `report.pdf`.
    static func archiveStem(of url: URL) -> String {
        let name = url.lastPathComponent
        let lowercased = name.lowercased()
        for ext in archiveExtensions where lowercased.hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return OutputNamer.stem(of: url)
    }

    // MARK: Convert

    private func recompress(_ step: ConversionStep) async throws -> URL {
        guard Self.convertibleSources.contains(step.from.id), Self.convertible.contains(step.to.id) else {
            throw Failure("Archive tools can't turn \(step.from.displayName) into \(step.to.displayName)")
        }
        let expected: Container = switch step.from.id {
        case "zip": .zip
        case "tgz": .gzippedTar
        case "rar": .rar
        default: .tar
        }
        guard try Self.container(of: step.input, as: step.from.id) == expected else { throw notAn(step.from) }
        // pax, not ustar, which drops paths over 255 bytes; pax headers still carry the ustar magic (P59).
        let format: [String] = switch step.to.id {
        case "zip": ["--format", "zip"]
        case "tgz": ["-z", "--format", "pax"]
        default: ["--format", "pax"]
        }
        let isRar = expected == .rar
        let sourceEntries = isRar ? try await rarEntryCount(of: step.input) : nil as Int?
        let output = step.suggestedOutput
        do {
            // `@archive` copies the entries straight from the input: nothing is written to disk but the output.
            do {
                try await run(bsdtarExecutable, ["-c", "-f", output.path] + format + ["@\(step.input.path)"])
            } catch ConversionError.engineFailed(_, let message) where isRar {
                throw rarFailure(stderr: message)
            }
            // Apple's bsdtar can write a truncated archive and still exit 0 (a zip with inline `._` entries).
            let listing: String
            do {
                listing = try await runner.run(executable: bsdtarExecutable, arguments: ["-t", "-f", output.path]).stdout
            } catch ProcessRunnerError.nonZeroExit(_, let stderrTail) {
                let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ConversionError.engineFailed(engine: id, message: "the new archive does not read back: \(tail)")
            } catch let error as ProcessRunnerError {
                throw map(error)
            }
            if let sourceEntries, Self.entryCount(of: listing) != sourceEntries { throw Self.cannotReadRar(id) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: RAR (P200)

    /// The entries `bsdtar -t` lists in a RAR that can be converted whole. Encryption and a missing end are read from
    /// the headers (`RarHeaders`): bsdtar words an encrypted RAR differently by version and lists the whole blocks
    /// of a truncated one without complaint.
    private func rarEntryCount(of input: URL) async throws -> Int {
        let headers = try RarHeaders(of: input)
        if headers.isEncrypted { throw Self.passwordProtected(id) }
        guard headers.isWhole else { throw Self.cannotReadRar(id) }
        do {
            return Self.entryCount(of: try await runner.run(executable: bsdtarExecutable, arguments: ["-t", "-f", input.path]).stdout)
        } catch ProcessRunnerError.nonZeroExit(_, let stderrTail) {
            throw rarFailure(stderr: stderrTail)
        } catch let error as ProcessRunnerError {
            throw map(error)
        }
    }

    private func rarFailure(stderr: String) -> ConversionError {
        let text = stderr.lowercased()
        return text.contains("encrypt") || text.contains("passphrase") ? Self.passwordProtected(id) : Self.cannotReadRar(id)
    }

    /// `engineUnsupported`, the failure the app shows as written: an `engineFailed` reads "may be damaged" (§3.11).
    private static func passwordProtected(_ engine: EngineID) -> ConversionError {
        .engineUnsupported(engine: engine, reason: "It's password-protected")
    }

    private static func cannotReadRar(_ engine: EngineID) -> ConversionError {
        .engineUnsupported(engine: engine, reason: "Pomelo can't read this RAR")
    }

    private static func entryCount(of listing: String) -> Int {
        listing.split(separator: "\n").count
    }

    // MARK: Extract

    private func extract(_ step: ConversionStep) async throws -> URL {
        if try Self.container(of: step.input, as: step.from.id) == .gzippedFile { return try await gunzip(step) }
        let staging = step.stagingDirectory
        let root = staging.appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        // Never `-P`: without it bsdtar refuses `..` and writing through a symlink, strips a leading `/`, and
        // refuses hard links to files outside. Symlinks are kept as links, wherever they point.
        do {
            try await run(bsdtarExecutable, ["-x", "-f", step.input.path, "-C", root.path, "--no-same-owner"])
        } catch {
            StagedFolder.openFolders(under: root)
            throw error
        }
        // bsdtar applies an archive's folder modes (000, 0555) last.
        StagedFolder.openFolders(under: root)
        try Task.checkCancellation()
        switch StagedFolder.containment(of: root, in: staging) {
        case .inside: break
        case .outside:
            throw ConversionError.converterFault(engine: id, message: "an extracted item is outside its staging folder")
        case .unreadable(let path):
            throw ConversionError.engineFailed(engine: id, message: "cannot read the extracted \(path)")
        }

        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard !items.isEmpty else { throw ConversionError.notApplicable(reason: "The archive is empty") }
        // A symlink is published only inside a folder: the runner resolves what an engine returns, and a link
        // to somewhere else would count as an item outside staging.
        if items.count == 1, !Self.isSymlink(items[0]) { return items[0] }
        let folder = staging.appending(path: Self.archiveStem(of: step.input), directoryHint: .isDirectory)
        // rename(2), not moveItem: an archive called `X.zip` only changes the case of `x`, which moveItem refuses.
        if folder.lastPathComponent != root.lastPathComponent, rename(root.path, folder.path) != 0 {
            throw Failure("cannot name the folder \(folder.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return folder
    }

    /// One gzipped file: `gzip -d` on a clone in staging, since gzip replaces the file it decompresses.
    private func gunzip(_ step: ConversionStep) async throws -> URL {
        let stem = Self.archiveStem(of: step.input)
        let work = step.stagingDirectory.appending(path: "g", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        // gzip refuses a name without `.gz`, and a symlink: copyItem would copy the link itself.
        let clone = work.appending(path: "\(stem).gz", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: step.input.resolvingSymlinksInPath(), to: clone)
        try await run(Self.gzip, ["-d", clone.path])
        let output = work.appending(path: stem, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.converterFault(engine: id, message: "gzip produced no output")
        }
        return output
    }

    private func notAn(_ format: FileFormat) -> ConversionError {
        .engineFailed(engine: id, message: "it is not a \(format.displayName)")
    }

    // MARK: Containers (P59)

    /// What the bytes of an input are, whatever its name says.
    enum Container: Equatable {
        case zip, tar, gzippedTar, gzippedFile, rar
    }

    private static let zipLocalHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let zipEndRecord: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    private static let gzipHeader: [UInt8] = [0x1F, 0x8B]
    private static let rar4Signature = Array("Rar!".utf8) + [0x1A, 0x07, 0x00]
    private static let rar5Signature = Array("Rar!".utf8) + [0x1A, 0x07, 0x01, 0x00]
    private static let tarHeaderSize = 512

    /// P59: bsdtar picks the format from the content and also reads mtree text, whose `contents=` makes it copy any
    /// file the user can read into the output. So the input must be the container its format names before bsdtar
    /// sees it; anything else is damaged. A gz is a tarball when its first 512 decompressed bytes are a tar header.
    static func container(of input: URL, as format: FormatID) throws -> Container {
        let damaged = ConversionError.engineFailed(engine: "archive", message: "it is not a valid \(format) archive")
        guard let handle = try? FileHandle(forReadingFrom: input) else { throw damaged }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: tarHeaderSize)) ?? Data())
        switch format {
        case "zip":
            guard head.starts(with: zipLocalHeader) || head.starts(with: zipEndRecord) else { throw damaged }
            return .zip
        case "tar":
            // An empty tar is only its end blocks of zeros, which no other format bsdtar reads looks like.
            let isEmptyTar = head.count == tarHeaderSize && head.allSatisfy { $0 == 0 }
            guard isTarHeader(head) || isEmptyTar else { throw damaged }
            return .tar
        case "rar":
            guard head.starts(with: rar4Signature) || head.starts(with: rar5Signature) else { throw damaged }
            return .rar
        case "tgz", "gz":
            guard head.starts(with: gzipHeader) else { throw damaged }
            try handle.seek(toOffset: 0)
            return isTarHeader(gunzippedHead(of: handle)) ? .gzippedTar : .gzippedFile
        default:
            throw damaged
        }
    }

    /// `ustar` at offset 257 and a header checksum that adds up, the way libarchive's tar reader recognises one.
    static func isTarHeader(_ block: [UInt8]) -> Bool {
        guard block.count >= tarHeaderSize, block[257..<262].elementsEqual("ustar".utf8) else { return false }
        let field = block[148..<156].drop { $0 == 0x20 }.prefix { (0x30...0x37).contains($0) }
        guard !field.isEmpty, let stored = Int(String(decoding: field, as: UTF8.self), radix: 8) else { return false }
        let header = block.prefix(tarHeaderSize).enumerated().map { 148..<156 ~= $0.offset ? 0x20 : $0.element }
        let unsigned = header.reduce(0) { $0 + Int($1) }
        let signed = header.reduce(0) { $0 + Int(Int8(bitPattern: $1)) }
        return stored == unsigned || stored == signed
    }

    /// Up to the first 512 decompressed bytes of a gzip stream; fewer (or none) when it is short or damaged.
    private static func gunzippedHead(of handle: FileHandle) -> [UInt8] {
        // A member header with a long name or comment still fits: the head is read in one bounded piece.
        guard let data = try? handle.read(upToCount: 1 << 20), let start = deflateStart(in: [UInt8](data)) else {
            return []
        }
        let source = [UInt8](data)[start...]
        var output = [UInt8](repeating: 0, count: tarHeaderSize)
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return []
        }
        defer { compression_stream_destroy(&stream) }
        let produced: Int = source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                stream.src_ptr = input.baseAddress!
                stream.src_size = input.count
                stream.dst_ptr = buffer.baseAddress!
                stream.dst_size = buffer.count
                while stream.dst_size > 0, stream.src_size > 0 {
                    let before = (stream.src_size, stream.dst_size)
                    guard compression_stream_process(&stream, 0) == COMPRESSION_STATUS_OK,
                          (stream.src_size, stream.dst_size) != before else { break }
                }
                return buffer.count - stream.dst_size
            }
        }
        return Array(output.prefix(produced))
    }

    /// Where the deflate data of a gzip member starts, past its header (RFC 1952), or nil when it doesn't fit.
    private static func deflateStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count > 10, bytes.starts(with: gzipHeader), bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        return offset < bytes.count ? offset : nil
    }

    // MARK: Extracted items

    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    // MARK: Processes

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        do {
            _ = try await runner.run(executable: executable, arguments: arguments)
        } catch let error as ProcessRunnerError {
            throw map(error)
        }
    }

    private func map(_ error: ProcessRunnerError) -> ConversionError {
        switch error {
        case .nonZeroExit(let code, let stderrTail):
            let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .engineFailed(engine: id, message: tail.isEmpty ? "exited with code \(code)" : tail)
        case .timedOut:
            return .converterTimedOut(engine: id)
        case .launchFailed(let code):
            return .converterUnavailable(engine: id, message: "could not launch: \(String(cString: strerror(code)))")
        }
    }
}
