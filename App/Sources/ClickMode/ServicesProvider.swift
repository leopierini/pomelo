// The "Convert with Pomelo…" service (Info.plist `NSServices`, message `convertFiles`): Finder's Services menu sends
// the selected files on a pasteboard, and the wheel opens in click mode at the cursor. No permission is involved.
import AppKit

/// `NSApp.servicesProvider`, set at launch.
@MainActor
final class ServicesProvider: NSObject {
    private let onFiles: ([URL]) -> Void

    /// `onFiles` receives the files of each service request (never empty).
    init(onFiles: @escaping ([URL]) -> Void) {
        self.onFiles = onFiles
    }

    // periphery:ignore:parameters userData - the selector's signature is fixed by the Services machinery
    /// The `convertFiles` service message (`convertFiles:userData:error:`). `userData` is nil: the service declares
    /// no `NSUserData`.
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(on: pboard)
        guard !urls.isEmpty else {
            error.pointee = "Pomelo didn't receive any files." as NSString
            return
        }
        onFiles(urls)
    }

    /// The file URLs on `pboard`, in order.
    static func fileURLs(on pboard: NSPasteboard) -> [URL] {
        pboard.fileURLs
    }
}
