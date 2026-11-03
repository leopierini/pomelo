// Reads the files selected in Finder for the click-mode hotkey. Asking Finder needs Automation permission: macOS
// prompts the first time the hotkey is used (never at launch), and `NSAppleEventsUsageDescription` explains why.
//
// Threading: the permission check, which shows the prompt and can block until the user answers, runs off the main
// thread (`AEDeterminePermissionToAutomateTarget` is thread-safe and must not run on main). `NSAppleScript` is not
// thread-safe, so the script itself runs on the main actor, once permission is settled, with a 5 s AppleScript
// timeout so a busy Finder cannot hold the main thread for longer.
import AppKit
import CoreServices
import os

enum FinderSelection {
    /// Why the selection could not be read.
    enum Error: Swift.Error, Equatable {
        /// The user declined Automation of Finder (-1743). The wheel's hub asks to allow it.
        case notAuthorized
        case finderNotRunning
        /// Finder did not answer within the script's timeout.
        case timedOut
        /// Any other AppleScript error, by number when there is one. Only logged.
        case failed(code: Int?)
    }

    static let finderBundleIdentifier = "com.apple.finder"

    /// System Settings › Privacy & Security › Automation.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// The selection as a list of POSIX paths. Finder returns the aliases; the paths are taken outside the `tell`
    /// block because `POSIX path of` does not apply to a list (it fails with -1728 on two items or none).
    static let source = """
        with timeout of 5 seconds
            tell application "Finder" to set theItems to selection as alias list
        end timeout
        set thePaths to {}
        repeat with anItem in theItems
            set end of thePaths to POSIX path of (anItem as alias)
        end repeat
        return thePaths
        """

    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "click-mode")

    /// Settles Automation permission off the main thread (prompting on first use), then reads the selection.
    @MainActor
    static func selection() async throws -> [URL] {
        let status = await Task.detached { determinePermission() }.value
        switch Int(status) {
        case Int(noErr): break
        case errAEEventNotPermitted: throw Error.notAuthorized
        case procNotFound: throw Error.finderNotRunning
        default:
            // Let the script itself report anything else.
            log.error("Automation permission check returned \(status, privacy: .public)")
        }
        return try current()
    }

    /// Runs the script and returns the selected files, in Finder's order; empty when nothing is selected.
    ///
    /// On the main actor because `NSAppleScript` is not thread-safe, so the script blocks the main thread while it
    /// runs. That is bounded: the script's `with timeout of 5 seconds` makes a Finder that does not answer fail
    /// with `errAETimeout` (-1712) after at most 5 s; a responsive Finder answers in milliseconds. Call
    /// `selection()` instead unless permission is already settled: an undetermined permission makes macOS prompt,
    /// which would block here until answered.
    @MainActor
    static func current() throws -> [URL] {
        guard let script = NSAppleScript(source: source) else { throw Error.failed(code: nil) }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        // The result is only valid when no error was reported.
        if let info {
            let error = error(from: info as? [String: Any] ?? [:])
            log.error("Finder selection failed: \(String(describing: error), privacy: .public): \(info, privacy: .private)")
            throw error
        }
        return urls(from: result)
    }

    /// Asks whether Pomelo may send Apple Events to Finder, prompting the user if they have not decided yet.
    /// Blocks until they answer, so it must not run on the main thread.
    nonisolated private static func determinePermission() -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: finderBundleIdentifier)
        // `aeDesc` points into `target`, which must outlive the call.
        return withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        }
    }

    // MARK: - Parsing (pure, tested)

    /// The file URLs in a script result: a list of POSIX paths (or file URLs, or aliases), or a single one.
    /// Blank items and relative paths are skipped.
    static func urls(from descriptor: NSAppleEventDescriptor) -> [URL] {
        let items: [NSAppleEventDescriptor]
        if descriptor.descriptorType == typeAEList {
            items = descriptor.numberOfItems > 0 ? (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) } : []
        } else {
            items = [descriptor]
        }
        return items.compactMap(url(from:))
    }

    private static func url(from item: NSAppleEventDescriptor) -> URL? {
        switch item.descriptorType {
        case typeUnicodeText, typeUTF8Text:
            guard let path = item.stringValue, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        default:
            // A file URL or an alias coerces to a file URL.
            return item.fileURLValue
        }
    }

    /// Maps an `NSAppleScript` error dictionary to an `Error`.
    static func error(from info: [String: Any]) -> Error {
        guard let number = info[NSAppleScript.errorNumber] as? Int else { return .failed(code: nil) }
        switch number {
        case errAEEventNotPermitted: return .notAuthorized
        case procNotFound: return .finderNotRunning
        case errAETimeout: return .timedOut
        default: return .failed(code: number)
        }
    }
}
