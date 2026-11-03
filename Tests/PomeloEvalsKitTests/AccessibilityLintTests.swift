import Foundation
import Testing
@testable import PomeloEvalsKit

/// The static half of the accessibility audit (P146): SwiftUI patterns VoiceOver reads badly, found in the source.
@Suite struct AccessibilityLintTests {
    private func rules(_ source: String) -> [AccessibilityLint.Rule] {
        AccessibilityLint.findings(in: source, file: "A.swift").map(\.rule)
    }

    // MARK: Icon-only controls

    @Test func anIconOnlyButtonWithoutALabelIsAFinding() {
        let source = """
            Button { close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            """
        let found = AccessibilityLint.findings(in: source, file: "A.swift")
        #expect(found.map(\.rule) == [AccessibilityLint.Rule.iconOnlyControl], "\(found)")
        #expect(found.first?.line == 1)
        #expect(found.first?.file == "A.swift")
    }

    @Test func anIconOnlyButtonWithALabelInItsChainIsNot() {
        #expect(rules("""
            Button { close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            """).isEmpty)
    }

    @Test func theActionInitializerTakesItsTrailingClosureAsTheLabel() {
        #expect(rules("""
            Button(action: model.cancel) { Image(systemName: "xmark.circle.fill") }
            """) == [AccessibilityLint.Rule.iconOnlyControl])
        #expect(rules("""
            Button(action: model.cancel) { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel")
            """).isEmpty)
    }

    @Test func aTitledButtonIsNot() {
        #expect(rules(#"Button("Install") { install() }"#).isEmpty)
        #expect(rules("Button(title) { install() }").isEmpty)
        #expect(rules("""
            Button { install() } label: {
                Label("Install", systemImage: "arrow.down")
            }
            """).isEmpty)
        #expect(rules("""
            Button { install() } label: {
                HStack { Image(systemName: "arrow.down"); Text("Install") }
            }
            """).isEmpty)
    }

    @Test func iconOnlyTogglesMenusAndLinksAreFindings() {
        #expect(rules("Toggle(isOn: $on) { Image(systemName: \"bolt\") }") == [AccessibilityLint.Rule.iconOnlyControl])
        #expect(rules("""
            Menu { Button("A") {} } label: { Image(systemName: "ellipsis") }
            """) == [AccessibilityLint.Rule.iconOnlyControl])
        #expect(rules("Link(destination: url) { Image(systemName: \"globe\") }") == [AccessibilityLint.Rule.iconOnlyControl])
    }

    @Test func aLabelPassedInsideTheParenthesesIsRead() {
        #expect(rules("""
            Button(action: close, label: { Image(systemName: "xmark") })
            """) == [AccessibilityLint.Rule.iconOnlyControl])
        #expect(rules("""
            Link(destination: url, label: { Image(systemName: "globe") }).accessibilityLabel("Website")
            """).isEmpty)
    }

    @Test func aModuleQualifiedViewIsStillJudged() {
        #expect(rules("SwiftUI.Image(systemName: \"photo\")") == [AccessibilityLint.Rule.unlabeledImage])
    }

    // MARK: Images

    @Test func anUnlabeledSymbolImageIsAFinding() {
        let found = AccessibilityLint.findings(in: """
            HStack {
                Image(systemName: "photo")
                Text("Photos")
            }
            """, file: "A.swift")
        #expect(found.map(\.rule) == [AccessibilityLint.Rule.unlabeledImage], "\(found)")
        #expect(found.first?.line == 2)
    }

    @Test func anNSImageIsJudgedToo() {
        #expect(rules("Image(nsImage: icon)") == [AccessibilityLint.Rule.unlabeledImage])
    }

    @Test func hiddenOrLabeledImagesAreNot() {
        #expect(rules("""
            Image(systemName: "photo")
                .font(.title)
                .accessibilityHidden(true)
            """).isEmpty)
        #expect(rules(#"Image(nsImage: icon).accessibilityLabel("App icon")"#).isEmpty)
    }

    @Test func spacesInsideTheModifierDoNotMatter() {
        #expect(rules("Image(systemName: \"photo\").accessibilityHidden( true )").isEmpty)
        #expect(rules("""
            HStack { Image(systemName: "photo") }
                .accessibilityElement( children: .ignore )
                .accessibilityLabel("Photos")
            """).isEmpty)
    }

    @Test func anImageInsideTextIsReadWithTheText() {
        #expect(rules(#"Text("\(Image(systemName: "star")) Favorites")"#).isEmpty)
        #expect(rules("Text(Image(systemName: \"star\")) + Text(\" Favorites\")").isEmpty)
    }

    @Test func anImageInsideALabelOrALabeledContainerIsNot() {
        #expect(rules("""
            Label { Text("Photos") } icon: { Image(systemName: "photo") }
            """).isEmpty)
        #expect(rules("""
            HStack {
                Image(systemName: "photo")
                Text("Photos")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photos")
            """).isEmpty)
        #expect(rules("""
            VStack {
                Image(systemName: "photo")
            }
            .accessibilityHidden(true)
            """).isEmpty)
    }

    @Test func theIconOfAControlIsJudgedWithTheControl() {
        #expect(rules("""
            Button { close() } label: { Image(systemName: "xmark") }
            """) == [AccessibilityLint.Rule.iconOnlyControl])
    }

    // MARK: What the scan reads

    @Test func stringsAndCommentsAreNotCode() {
        #expect(rules(#"""
            let a = "Image(systemName: \"x\")"
            // Image(systemName: "photo")
            /* Button { } label: { Image(systemName: "x") } */
            let b = NSImage(systemSymbolName: "x", accessibilityDescription: nil)
            let c = """
                Image(systemName: "x")
                """
            """#).isEmpty)
    }

    @Test func aMemberNamedLikeAViewIsNotIt() {
        #expect(rules("DisplayRepresentation(title: name, image: DisplayRepresentation.Image(systemName: symbol))").isEmpty)
    }

    @Test func anInlineReasonSuppressesAFinding() {
        #expect(rules("""
            Image(systemName: "photo") // a11y: the row's label names it
            """).isEmpty)
        #expect(rules("""
            // a11y: the caller hides this view
            Image(systemName: "photo")
            """).isEmpty)
        #expect(rules("""
            // a11y:
            Image(systemName: "photo")
            """) == [AccessibilityLint.Rule.unlabeledImage], "a reason is required")
    }

    @Test func theFindingsMetricAllowsNone() {
        let metric = MetricDefaults.metric(named: "a11y.findings", value: 0)
        #expect(metric.unit == "findings")
        #expect(metric.better == .lower)
        #expect(!metric.regressed(by: 0))
        #expect(metric.regressed(by: 1))
    }

    @Test func theFolderScanReportsPathsFromTheRepository() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pomelo-a11y-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "App/Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Image(systemName: \"x\")\n".write(to: folder.appending(path: "App/Sources/V.swift"), atomically: true,
                                               encoding: .utf8)
        try "Image(systemName: \"x\")\n".write(to: folder.appending(path: "App/Sources/notes.txt"), atomically: true,
                                               encoding: .utf8)
        let found = try AccessibilityLint.run(sources: [folder.appending(path: "App/Sources")])
        #expect(found.map(\.file) == ["App/Sources/V.swift"], "\(found)")
    }
}
