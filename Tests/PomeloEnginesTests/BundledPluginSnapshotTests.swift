import Foundation
import Testing
import PomeloCore
import PomeloEngines

/// The snapshot is the bundled manifests, their edges and what they register, as of Phase 6's debloat. A plugin
/// field or edge dropped by mistake changes a line here; change a manifest on purpose, regenerate the snapshot.
@Suite struct BundledPluginSnapshotTests {
    static func render() -> String {
        let (manifests, failures) = PluginLoader.load(folders: [DefaultEngines.bundledPluginsFolder])
        var lines = ["failures \(failures.count)"]
        for manifest in manifests.sorted(by: { $0.id < $1.id }) {
            let e = manifest.executable, i = manifest.install
            lines.append("plugin \(manifest.id) | \(manifest.displayName) | names \(e.names) | paths \(e.searchPaths) | version \(e.versionArguments ?? [])")
            lines.append("  install \(i.homebrew ?? "-") \(i.website ?? "-") | jobs \(manifest.maxConcurrentJobs.map(String.init) ?? "-") | cost \(manifest.defaultCost.map(String.init) ?? "-") | timeout \(manifest.timeoutSeconds.map(String.init) ?? "-")")
            for edge in manifest.edges {
                lines.append("  edge \(edge.from) > \(edge.to) | op \(edge.operation ?? "-") | flags \(edge.flags ?? []) | cost \(edge.cost.map(String.init) ?? "-") | out \(edge.output ?? "-") | \(edge.arguments)")
            }
            for edge in manifest.conversionEdges() {
                lines.append("  registers \(edge.from.rawValue) > \(edge.to.rawValue) | \(edge.engineID.rawValue) | op \(edge.operation ?? "-") | cost \(edge.cost) | flags \(edge.flags.rawValue)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func everyBundledPluginManifestStillLoads() throws {
        let url = try #require(Bundle.module.url(forResource: "bundled-plugins", withExtension: "snapshot", subdirectory: "Resources"))
        let expected = try String(contentsOf: url, encoding: .utf8)
        let actual = Self.render()
        #expect(actual == expected)
        #expect(actual.contains("failures 0"))
    }
}
