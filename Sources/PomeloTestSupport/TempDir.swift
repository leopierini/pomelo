import Foundation

/// Creates a fresh, unique directory under the system temporary directory and returns it with symlinks resolved
/// (`/var` becomes `/private/var`), so path comparisons are stable. The caller removes it with `defer`.
public func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "pomelo-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}
