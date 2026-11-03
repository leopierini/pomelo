import Foundation
import PomeloCore

extension XLSXReader {
    /// The zip: what it holds is read from `bsdtar -tv` before extraction, and only the named parts are extracted,
    /// with bsdtar's default safe behaviour (never `-P`, so no `..`, no writes through links; P59's reasoning).
    struct Package {
        let url: URL
        let workDirectory: URL
        let runner: ProcessRunner
        /// Every entry's name and the size its header declares.
        let entries: [String: Int]

        private static let bsdtar = XLSXWriter.bsdtar
        private static let zipLocalHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        private static let oleHeader: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0]
        private static let endRecordSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        private static let maxCentralDirectoryBytes: UInt64 = 16_000_000
        private static let endRecordSize = 22
        private static let maxCommentBytes = 65_535

        func file(_ name: String) -> URL {
            workDirectory.appending(path: name, directoryHint: .notDirectory)
        }

        // MARK: Header

        /// A zip starts with a local header; an OLE container (an encrypted workbook is one) with its own magic.
        static func checkHeader(of url: URL) throws {
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.damaged }
            defer { try? handle.close() }
            let head = [UInt8]((try? handle.read(upToCount: 4)) ?? Data())
            if head == oleHeader { throw Failure.passwordProtected }
            guard head == zipLocalHeader else { throw Failure.damaged }
            try checkCentralDirectory(handle)
        }

        /// The end record claims how many entries there are and how big their directory is. `bsdtar -tv` prints a
        /// line for each and the runner keeps all its output, so a bomb of tiny entries is refused before the listing.
        private static func checkCentralDirectory(_ handle: FileHandle) throws {
            let length = try handle.seekToEnd()
            let window = min(length, UInt64(endRecordSize + maxCommentBytes + 20))
            try handle.seek(toOffset: length - window)
            let tail = [UInt8]((try handle.read(upToCount: Int(window))) ?? Data())
            guard tail.count >= endRecordSize,
                  let start = (0...(tail.count - endRecordSize)).reversed().first(where: {
                      tail[$0..<($0 + 4)].elementsEqual(endRecordSignature)
                  }) else { throw Failure.damaged }
            var entries = UInt64(littleEndian(tail, start + 10, 2))
            var directoryBytes = UInt64(littleEndian(tail, start + 12, 4))
            if entries == 0xFFFF || directoryBytes == 0xFFFF_FFFF {
                (entries, directoryBytes) = try zip64Totals(handle, tail: tail, endRecord: start)
            }
            guard entries <= UInt64(maxEntries), directoryBytes <= maxCentralDirectoryBytes else { throw Failure.tooLarge }
        }

        private static func zip64Totals(_ handle: FileHandle, tail: [UInt8], endRecord: Int) throws -> (UInt64, UInt64) {
            let locator = endRecord - 20
            guard locator >= 0, tail[locator..<(locator + 4)].elementsEqual([0x50, 0x4B, 0x06, 0x07]) else {
                throw Failure.damaged
            }
            try handle.seek(toOffset: littleEndian(tail, locator + 8, 8))
            let record = [UInt8]((try handle.read(upToCount: 56)) ?? Data())
            guard record.count == 56, record[0..<4].elementsEqual([0x50, 0x4B, 0x06, 0x06]) else { throw Failure.damaged }
            return (littleEndian(record, 32, 8), littleEndian(record, 40, 8))
        }

        private static func littleEndian(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
        }

        // MARK: Listing

        static func list(_ url: URL, runner: ProcessRunner) async throws -> [String: Int] {
            let listing: ProcessResult
            do {
                listing = try await runner.run(executable: Self.bsdtar, arguments: ["-t", "-v", "-f", url.path])
            } catch ProcessRunnerError.nonZeroExit {
                throw Failure.damaged
            }
            return try parse(listing: listing.stdout)
        }

        /// `drwxr-xr-x  0 501    20          0 Oct 30 22:53 xl/`: type and mode, links, owner, group, size, three
        /// words of date, then the name, which may hold spaces.
        static func parse(listing: String) throws -> [String: Int] {
            var sizes: [String: Int] = [:]
            var total = 0
            var lines = 0
            for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
                lines += 1
                guard lines <= maxEntries else { throw Failure.tooLarge }
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9, let kind = fields[0].first, kind == "-" || kind == "d" else {
                    throw Failure.damaged
                }
                let name = String(fields[8])
                try check(name)
                let size = try declaredSize(fields[4])
                total += size
                guard total <= maxUncompressedBytes else { throw Failure.tooLarge }
                guard sizes.updateValue(size, forKey: name) == nil else { throw Failure.damaged }
            }
            return sizes
        }

        /// A name that leaves the folder it is extracted into, or that could not come back out of a one-line listing.
        private static func check(_ name: String) throws {
            let unsafe = name.hasPrefix("/") || name.isEmpty
                || name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
                || name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            if unsafe { throw Failure.damaged }
        }

        private static func declaredSize(_ field: Substring) throws -> Int {
            if let size = Int(field), size >= 0 { return size }
            // A number too big for an Int is a size claim like any other.
            guard !field.isEmpty, field.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { throw Failure.damaged }
            throw Failure.tooLarge
        }

        // MARK: Extraction

        func extract(_ names: [String]) async throws {
            for name in names {
                guard let size = entries[name] else { throw Failure.damaged }
                guard size <= maxPartBytes else { throw Failure.tooLarge }
            }
            try Task.checkCancellation()
            let patterns = names.map(Self.globEscaped)
            do {
                _ = try await runner.run(
                    executable: Self.bsdtar,
                    arguments: ["-x", "-f", url.path, "-C", workDirectory.path, "--no-same-owner"] + patterns)
            } catch ProcessRunnerError.nonZeroExit {
                throw Failure.damaged
            }
            StagedFolder.openFolders(under: workDirectory)
            for name in names { try verify(file(name)) }
        }

        /// What came out must be a plain file of the size the listing promised: a header can lie about it.
        private func verify(_ file: URL) throws {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.damaged }
            guard info.st_size <= maxPartBytes else { throw Failure.tooLarge }
            chmod(file.path, 0o600)
        }

        /// bsdtar reads its member arguments as patterns.
        private static func globEscaped(_ name: String) -> String {
            var escaped = ""
            for character in name {
                if "\\[]*?".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return escaped
        }
    }

}
