import Foundation
import Testing

/// `QuickActionHandoff` is compiled into this bundle from `App/QuickAction` (the appex is not importable).
@Suite struct QuickActionHandoffTests {
    private func fileProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: "public.file-url")
    }

    /// A provider with a load handler rather than a stored item, answering with the URL's data representation.
    private func dataProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = url.dataRepresentation
        provider.registerItem(forTypeIdentifier: "public.file-url") { completion, _, _ in
            completion?(data as NSData, nil)
        }
        return provider
    }

    private func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }

    @Test func theContainingAppIsThreeLevelsUp() {
        let appex = URL(fileURLWithPath: "/A/Pomelo.app/Contents/PlugIns/Q.appex", isDirectory: true)
        #expect(QuickActionHandoff.containingApp(ofExtensionAt: appex)?.path == "/A/Pomelo.app")
        // Never the bundle's name: the evals build is called PomeloEvals (P45).
        let evals = URL(fileURLWithPath: "/B/PomeloEvals.app/Contents/PlugIns/PomeloQuickAction.appex")
        #expect(QuickActionHandoff.containingApp(ofExtensionAt: evals)?.path == "/B/PomeloEvals.app")
    }

    @Test func anExtensionOutsideAnAppHasNoContainer() {
        for path in ["/tmp/Q.appex", "/A/Folder/Contents/PlugIns/Q.appex", "/A/Pomelo.app/Contents/Q.appex",
                     "/A/Pomelo.app/Contents/Resources/Q.appex"] {
            #expect(QuickActionHandoff.containingApp(ofExtensionAt: URL(fileURLWithPath: path)) == nil, "\(path)")
        }
    }

    @Test func fileURLsComeFromEveryAttachmentInOrder() async {
        let a = URL(fileURLWithPath: "/tmp/pomelo-qa/a photo.heic")
        let b = URL(fileURLWithPath: "/tmp/pomelo-qa/b.png")
        let c = URL(fileURLWithPath: "/tmp/pomelo-qa/Folder", isDirectory: true)
        let items = [item([fileProvider(a), fileProvider(b)]), item([dataProvider(c), fileProvider(a)])]
        let urls = await QuickActionHandoff.fileURLs(from: items)
        #expect(urls.map(\.path) == [a.path, b.path, c.path])
        #expect(urls.allSatisfy { $0.isFileURL })
    }

    /// A provider that offers the URL as an object only (no `public.file-url` item): loading it as an `NSURL` comes
    /// first, which keeps the sandbox extension Finder attaches to it.
    @Test func aURLOfferedAsAnObjectIsTaken() async {
        let url = URL(fileURLWithPath: "/tmp/pomelo-qa/e.png")
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            completion(url as NSURL, nil)
            return nil
        }
        let urls = await QuickActionHandoff.fileURLs(from: [item([provider])])
        #expect(urls.map(\.path) == [url.path])
    }

    @Test func nonFileAttachmentsAreIgnored() async throws {
        let web = try #require(URL(string: "https://example.com/a.png"))
        let file = URL(fileURLWithPath: "/tmp/pomelo-qa/c.jpg")
        let providers = [
            NSItemProvider(item: web as NSURL, typeIdentifier: "public.url"),
            // A host that labels a web address a file URL is not trusted either.
            NSItemProvider(item: web as NSURL, typeIdentifier: "public.file-url"),
            NSItemProvider(item: "/tmp/pomelo-qa/d.png" as NSString, typeIdentifier: "public.utf8-plain-text"),
            fileProvider(file),
        ]
        let urls = await QuickActionHandoff.fileURLs(from: [item(providers), NSExtensionItem()])
        #expect(urls.map(\.path) == [file.path])
    }
}
