// Finder's "Convert with Pomelo" Quick Action (P101). The extension is sandboxed and does no work: it hands the
// selected files to the app that contains it, which opens the click-mode wheel on them at the pointer.
import AppKit
import os

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "quick-action")

    func beginRequest(with context: NSExtensionContext) {
        let request = Request(context: context)
        Task { await request.hand() }
    }

    /// The context crosses into the task once and is touched only there.
    private struct Request: @unchecked Sendable {
        let context: NSExtensionContext

        func hand() async {
            let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
            let files = await QuickActionHandoff.fileURLs(from: items)
            guard !files.isEmpty else {
                ActionRequestHandler.log.error("the Quick Action received no file URLs")
                context.cancelRequest(withError: CocoaError(.fileReadNoSuchFile))
                return
            }
            guard let app = QuickActionHandoff.containingApp(ofExtensionAt: Bundle.main.bundleURL) else {
                ActionRequestHandler.log.error(
                    "the Quick Action is not inside an app: \(Bundle.main.bundleURL.path, privacy: .public)")
                context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            do {
                _ = try await NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration)
                context.completeRequest(returningItems: nil)
            } catch {
                // If the sandbox refuses this open, the way out is a uniquely named NSPasteboard holding the URLs
                // and opening the app with that name; never a URL scheme carrying paths.
                ActionRequestHandler.log.error(
                    "the Quick Action couldn't hand \(files.count, privacy: .public) files to \(app.path, privacy: .public): \(String(describing: error), privacy: .public)")
                context.cancelRequest(withError: error)
            }
        }
    }
}
