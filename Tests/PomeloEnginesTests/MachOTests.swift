import Foundation
import Testing
import PomeloEngines
import PomeloTestSupport

/// Synthetic Mach-O headers, written byte by byte (thin headers little-endian, fat headers big-endian, as on disk).
@Suite struct MachOTests {
    private static let arm64: UInt32 = 0x0100_000C
    private static let x86_64: UInt32 = 0x0100_0007
    private static let i386: UInt32 = 7

    private func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    private func be32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private func be64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    private func thin64(cpu: UInt32, subtype: UInt32 = 0) -> [UInt8] {
        [0xFEED_FACF, cpu, subtype, 2, 0, 0, 0, 0].flatMap(le)
    }

    /// A fat file with one slice per cpu, each slice a thin header at a 4096-aligned offset.
    private func fat(_ cpus: [UInt32], sixtyFour: Bool = false) -> [UInt8] {
        var bytes = be32(sixtyFour ? 0xCAFE_BABF : 0xCAFE_BABE) + be32(UInt32(cpus.count))
        for (index, cpu) in cpus.enumerated() {
            let offset = UInt32(4096 * (index + 1))
            bytes += be32(cpu) + be32(0)
            if sixtyFour {
                bytes += be64(UInt64(offset)) + be64(32)
                bytes += be32(12) + be32(0)
            } else {
                bytes += [offset, 32, 12].flatMap(be32)
            }
        }
        for (index, cpu) in cpus.enumerated() {
            bytes += [UInt8](repeating: 0, count: 4096 * (index + 1) - bytes.count)
            bytes += thin64(cpu: cpu)
        }
        return bytes
    }

    private func architectures(_ bytes: [UInt8]) throws -> Set<MachineArch> {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "binary")
        try Data(bytes).write(to: file)
        return try MachO.architectures(of: file)
    }

    @Test func thinArm64() throws {
        #expect(try architectures(thin64(cpu: Self.arm64)) == [.arm64])
    }

    @Test func thinX86_64() throws {
        #expect(try architectures(thin64(cpu: Self.x86_64)) == [.x86_64])
    }

    @Test func arm64eCountsAsArm64() throws {
        #expect(try architectures(thin64(cpu: Self.arm64, subtype: 0x8000_0002)) == [.arm64])
    }

    @Test func fat32() throws {
        #expect(try architectures(fat([Self.x86_64, Self.arm64])) == [.x86_64, .arm64])
    }

    @Test func fat64() throws {
        #expect(try architectures(fat([Self.arm64], sixtyFour: true)) == [.arm64])
    }

    @Test func aSliceOfAnotherArchitectureIsLeftOut() throws {
        #expect(try architectures(fat([Self.i386, Self.x86_64])) == [.x86_64])
    }

    @Test func aSystemBinaryHasItsSlices() throws {
        #expect(try MachO.architectures(of: URL(fileURLWithPath: "/bin/echo")).contains(MachineArch.current))
    }

    @Test func aTextFileThrows() {
        #expect(throws: (any Error).self) { try architectures(Array("#!/bin/sh\necho hi\n".utf8)) }
    }

    @Test func aTruncatedThinHeaderThrows() {
        #expect(throws: (any Error).self) { try architectures(Array(thin64(cpu: Self.arm64).prefix(12))) }
    }

    @Test func aTruncatedFatTableThrows() {
        let bytes = [0xCAFE_BABE, 2, Self.arm64, 0].flatMap(be32)
        #expect(throws: (any Error).self) { try architectures(bytes) }
    }

    @Test func aFatSliceBeyondTheEndThrows() {
        #expect(throws: (any Error).self) { try architectures(Array(fat([Self.arm64]).prefix(4096 + 8))) }
    }

    @Test func anEmptyFileThrows() {
        #expect(throws: (any Error).self) { try architectures([]) }
    }
}
