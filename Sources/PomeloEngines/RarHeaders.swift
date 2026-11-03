import Foundation

/// What a RAR's block headers say about it, read without decoding any data (RAR 4 and RAR 5 layouts). The system
/// bsdtar can't be asked: it reads no encrypted RAR and words that failure differently by version, and it lists a
/// truncated archive's whole blocks without complaint.
struct RarHeaders: Equatable {
    /// Some entry's data, or the headers themselves, are encrypted.
    private(set) var isEncrypted = false
    /// The archive ends where RAR says it ends and is not a volume that continues in another file.
    private(set) var isWhole = false

    private static let rar4Signature = 7
    private static let rar5Signature = 8
    private static let maxHeaderSize = 1 << 21
    private static let maxBlocks = 1 << 20
    private static let cancellationInterval = 4096

    /// Throws only a cancellation: a hostile archive of tiny blocks takes a while to walk.
    init(of url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return }
        defer { try? handle.close() }
        let head = Self.bytes(handle, at: 0, count: Self.rar5Signature, exactly: false) ?? []
        if head.count == Self.rar5Signature, head[6] == 1 {
            try scanRar5(handle, size: size)
        } else if head.count >= Self.rar4Signature {
            try scanRar4(handle, size: size)
        }
    }

    /// The sum of file-supplied sizes, nil when it overflows.
    private static func sum(_ values: UInt64...) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            if overflow { return nil }
            total = next
        }
        return total
    }

    /// `count` bytes at `offset`; with `exactly` false, as many as the file has (a short or missing read is nil/empty).
    private static func bytes(_ handle: FileHandle, at offset: UInt64, count: Int, exactly: Bool = true) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
              !exactly || data.count == count else { return nil }
        return [UInt8](data)
    }

    // MARK: RAR 4

    private mutating func scanRar4(_ handle: FileHandle, size: UInt64) throws {
        var position = UInt64(Self.rar4Signature)
        for block in 0..<Self.maxBlocks {
            if block % Self.cancellationInterval == 0 { try Task.checkCancellation() }
            // RAR 4 may omit its end block, but a file that is only the signature is not an archive.
            if position == size { isWhole = position > UInt64(Self.rar4Signature); return }
            guard let head = Self.bytes(handle, at: position, count: 7) else { return }
            let flags = Int(head[3]) | Int(head[4]) << 8
            let headerSize = UInt64(head[5]) | UInt64(head[6]) << 8
            guard headerSize >= 7, headerSize <= UInt64(Self.maxHeaderSize),
                  let next = rar4BlockEnd(handle, at: position, type: head[2], flags: flags, headerSize: headerSize),
                  next > position, next <= size else { return }
            position = next
        }
    }

    /// Where the block after this one starts, or nil when the walk stops here (its answer recorded).
    private mutating func rar4BlockEnd(
        _ handle: FileHandle, at position: UInt64, type: UInt8, flags: Int, headerSize: UInt64
    ) -> UInt64? {
        let next = position + headerSize
        switch type {
        case 0x73:
            // A volume's main header, or encrypted headers: nothing after it can be read as it stands.
            if flags & 0x0080 != 0 { isEncrypted = true }
            return flags & 0x0081 != 0 ? nil : next
        case 0x74, 0x7A:
            if type == 0x74, flags & 0x0004 != 0 { isEncrypted = true; return nil }
            return Self.rar4FileDataEnd(handle, at: position, flags: flags, headerSize: headerSize)
        case 0x7B:
            isWhole = flags & 0x0001 == 0
            return nil
        default:
            guard flags & 0x8000 != 0 else { return next }
            guard headerSize >= 11, let add = Self.bytes(handle, at: position + 7, count: 4) else { return nil }
            return Self.sum(next, UInt64(add[0]) | UInt64(add[1]) << 8 | UInt64(add[2]) << 16 | UInt64(add[3]) << 24)
        }
    }

    /// A file or service block's end: its header, then its packed data (32 bits, or 64 with the large-file flag).
    private static func rar4FileDataEnd(_ handle: FileHandle, at position: UInt64, flags: Int, headerSize: UInt64) -> UInt64? {
        guard flags & 0x8000 != 0, headerSize >= 11,
              let block = bytes(handle, at: position, count: Int(headerSize)) else { return nil }
        var data = UInt64(block[7]) | UInt64(block[8]) << 8 | UInt64(block[9]) << 16 | UInt64(block[10]) << 24
        if flags & 0x0100 != 0 {
            guard block.count >= 36 else { return nil }
            data |= (UInt64(block[32]) | UInt64(block[33]) << 8 | UInt64(block[34]) << 16 | UInt64(block[35]) << 24) << 32
        }
        // Sizes come from the file: adding them unchecked would trap on a hostile one.
        return sum(position + headerSize, data)
    }

    // MARK: RAR 5

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        /// A variable-length integer: seven bits per byte, low group first, high bit set while more follow.
        mutating func vint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 70, by: 7) {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]
                offset += 1
                if shift < 64 { value |= UInt64(byte & 0x7F) << UInt64(shift) }
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
    }

    private mutating func scanRar5(_ handle: FileHandle, size: UInt64) throws {
        var position = UInt64(Self.rar5Signature)
        for block in 0..<Self.maxBlocks {
            if block % Self.cancellationInterval == 0 { try Task.checkCancellation() }
            // CRC32, then the header size as a vint of at most 4 bytes under the size limit.
            guard let prefix = Self.bytes(handle, at: position, count: 4 + 4, exactly: false), prefix.count > 4 else { return }
            var sizeReader = Reader(bytes: prefix, offset: 4)
            guard let headerSize = sizeReader.vint(), headerSize > 0, headerSize <= UInt64(Self.maxHeaderSize) else { return }
            let headerStart = position + UInt64(sizeReader.offset)
            guard let header = Self.bytes(handle, at: headerStart, count: Int(headerSize)),
                  let dataSize = rar5BlockData(header),
                  let next = Self.sum(headerStart, headerSize, dataSize), next <= size else { return }
            position = next
        }
    }

    /// The size of the data after this header, or nil when the walk stops here (its answer recorded).
    private mutating func rar5BlockData(_ header: [UInt8]) -> UInt64? {
        var reader = Reader(bytes: header)
        guard let type = reader.vint(), let flags = reader.vint() else { return nil }
        let extraSize = flags & 0x1 != 0 ? reader.vint() : 0
        let dataSize = flags & 0x2 != 0 ? reader.vint() : 0
        guard let extraSize, let dataSize else { return nil }
        switch type {
        case 4:
            isEncrypted = true
            return nil
        case 1:
            guard let archiveFlags = reader.vint(), archiveFlags & 0x1 == 0 else { return nil }
        case 2:
            if Self.hasEncryptionRecord(in: header, extraSize: extraSize) { isEncrypted = true; return nil }
        case 5:
            guard let endFlags = reader.vint() else { return nil }
            isWhole = endFlags & 0x1 == 0
            return nil
        default:
            break
        }
        return dataSize
    }

    /// The extra area is the last `extraSize` bytes of a header: records of size, type, data; type 1 is encryption.
    private static func hasEncryptionRecord(in header: [UInt8], extraSize: UInt64) -> Bool {
        guard extraSize <= UInt64(header.count) else { return false }
        var reader = Reader(bytes: header, offset: header.count - Int(extraSize))
        while reader.offset < header.count, let recordSize = reader.vint(), recordSize > 0 {
            let end = reader.offset + Int(min(recordSize, UInt64(header.count)))
            guard end <= header.count, let type = reader.vint() else { return false }
            if type == 1 { return true }
            reader.offset = end
        }
        return false
    }
}
