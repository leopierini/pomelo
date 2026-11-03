import Foundation
import Testing

@Suite struct FixturesWiringTests {
    @Test func theSharedFixturesAreCompiledIntoTheAppTests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-app-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = try Fixtures.png(width: 12, height: 8, in: directory)
        #expect(Fixtures.imageSize(png) == CGSize(width: 12, height: 8))
    }
}
