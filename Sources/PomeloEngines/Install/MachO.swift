import Foundation

/// Reads which architectures a Mach-O executable holds, from its header only.
public enum MachO {
    public struct NotMachO: Error {}

    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    /// More slices than any real fat file has; `0xCAFEBABE` also starts Java class files, whose "count" is large.
    private static let maxSlices: UInt32 = 32

    /// Thin 64-bit and 32-bit Mach-O and fat files with 32- or 64-bit tables. `arm64e` is an arm64 subtype, so it
    /// counts as arm64; slices of other cpus are left out. Throws for anything else, a truncated header or a fat
    /// slice that runs past the end of the file.
    public static func architectures(of file: URL) throws -> Set<MachineArch> {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = [UInt8](try handle.read(upToCount: 8 + Int(maxSlices) * 32) ?? Data())
        guard header.count >= 8 else { throw NotMachO() }

        switch bigEndian(header, 0) {
        case 0xCFFA_EDFE, 0xCEFA_EDFE:  // MH_MAGIC_64 and MH_MAGIC, stored little-endian
            let headerSize = bigEndian(header, 0) == 0xCFFA_EDFE ? 32 : 28
            guard header.count >= headerSize else { throw NotMachO() }
            return arch(littleEndian(header, 4)).map { [$0] } ?? []
        case 0xCAFE_BABE, 0xCAFE_BABF:  // FAT_MAGIC and FAT_MAGIC_64, stored big-endian
            let is64 = bigEndian(header, 0) == 0xCAFE_BABF
            let count = bigEndian(header, 4)
            guard count > 0, count <= maxSlices else { throw NotMachO() }
            let entrySize = is64 ? 32 : 20
            guard header.count >= 8 + Int(count) * entrySize else { throw NotMachO() }
            var archs: Set<MachineArch> = []
            for index in 0..<Int(count) {
                let entry = 8 + index * entrySize
                let offset = is64 ? bigEndian64(header, entry + 8) : UInt64(bigEndian(header, entry + 8))
                let length = is64 ? bigEndian64(header, entry + 16) : UInt64(bigEndian(header, entry + 12))
                guard length > 0, offset <= size, length <= size - offset else { throw NotMachO() }
                if let arch = arch(bigEndian(header, entry)) { archs.insert(arch) }
            }
            return archs
        default:
            throw NotMachO()
        }
    }

    private static func arch(_ cpuType: UInt32) -> MachineArch? {
        switch cpuType {
        case cpuTypeARM64: .arm64
        case cpuTypeX86_64: .x86_64
        default: nil
        }
    }

    private static func bigEndian(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func bigEndian64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func littleEndian(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
