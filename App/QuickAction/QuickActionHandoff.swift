// What the Quick Action hands the app (P101): the selected file URLs, opened with the app that contains the
// extension. Foundation only, so the app tests compile it in (P33).
import Foundation

enum QuickActionHandoff {
    static let fileURLType = "public.file-url"

    /// The app holding the extension at `bundleURL` (`X.app/Contents/PlugIns/Y.appex`), else nil. Found by place,
    /// never by name: the evals build is called PomeloEvals (P45).
    static func containingApp(ofExtensionAt bundleURL: URL) -> URL? {
        let plugIns = bundleURL.standardizedFileURL.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard plugIns.lastPathComponent == "PlugIns", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }

    /// Every attachment's file URL, in order, file URLs only, each once. An attachment that fails to load is skipped.
    static func fileURLs(from items: [NSExtensionItem]) async -> [URL] {
        let providers = items.flatMap { $0.attachments ?? [] }
            .filter { $0.canLoadObject(ofClass: NSURL.self) || $0.hasItemConformingToTypeIdentifier(fileURLType) }
        var urls: [URL] = []
        var seen: Set<String> = []
        for provider in providers {
            guard let url = await fileURL(from: provider), seen.insert(url.standardizedFileURL.path).inserted
            else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Loaded as an `NSURL` first: that keeps the sandbox extension Finder attaches to the URL. The item's data
    /// representation is the fallback; an `NSURL` item, should a host send one, is taken as is.
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        var url = await object(from: provider)
        if url == nil, provider.hasItemConformingToTypeIdentifier(fileURLType) {
            url = switch try? await provider.loadItem(forTypeIdentifier: fileURLType) {
            case let item as URL: item
            case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
            default: nil
            }
        }
        guard let url, url.isFileURL else { return nil }
        return url
    }

    private static func object(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }
}
