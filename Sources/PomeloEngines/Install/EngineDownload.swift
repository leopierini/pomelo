import Darwin
import Foundation
import PomeloCore

/// The two architectures an engine can be installed for.
public enum MachineArch: String, Sendable, Hashable, CaseIterable {
    case arm64, x86_64

    /// The Mac's own architecture. Asks `hw.optional.arm64` rather than the running binary, so a Pomelo running
    /// under Rosetta still installs arm64 engines.
    public static var current: MachineArch {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? .arm64 : .x86_64
    }
}

/// One pinned engine build: where to get it, the SHA-256 it must have, and which file inside it is the program.
public struct EngineDownload: Sendable, Equatable {
    public var engineID: EngineID
    public var version: String
    public var archs: Set<MachineArch>
    public var url: URL
    /// 64 lowercase hex digits.
    public var sha256: String
    public var maxBytes: Int64
    /// The program's path inside the archive, exactly as `bsdtar -t` lists it.
    public var member: String
    public var executableName: String
    public var versionArguments: [String]?
    public var publisher: String

    public init(
        engineID: EngineID, version: String, archs: Set<MachineArch>, url: URL, sha256: String, maxBytes: Int64,
        member: String, executableName: String, versionArguments: [String]?, publisher: String
    ) {
        self.engineID = engineID
        self.version = version
        self.archs = archs
        self.url = url
        self.sha256 = sha256
        self.maxBytes = maxBytes
        self.member = member
        self.executableName = executableName
        self.versionArguments = versionArguments
        self.publisher = publisher
    }
}
