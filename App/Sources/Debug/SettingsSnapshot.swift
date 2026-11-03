// DEBUG only: `Pomelo --snapshot-settings <general|wheel|tools|watchFolders[+sample]|engines[+sample]|about> <out.png> [light|dark] [height] [settings=<settings.json>]` hosts the Settings
// view in an off-screen window, writes a PNG of it and exits. List-backed controls do not draw through
// ImageRenderer, so this caches the window's real display instead. `settings=` loads a blob's customized wheels
// (`EvalHooks.inMemoryDefaults`). Its samples also serve the evals' accessibility audit, hence POMELO_EVALS.
#if DEBUG || POMELO_EVALS
import AppKit
import PomeloUIModel
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSnapshot {
    static let flag = "--snapshot-settings"
    static let usage = "usage: Pomelo --snapshot-settings <general|wheel|tools|watchFolders[+sample]|engines[+sample]|about> <out.png> [light|dark] [height] [settings=<settings.json>]"
    /// `engines+sample` shows an engine to install, one downloading at 40%, one whose download failed and one this Mac
    /// can't run.
    /// `watchFolders+sample` fills the Watch Folders pane with three folders: one missing, one with a problem and one
    /// turned off.
    static let sampleSuffix = "+sample"

    /// When the process was launched with `--snapshot-settings`, schedules the render (which exits the process) and
    /// returns true; otherwise returns false and the app launches normally.
    @MainActor
    static func runIfRequested(arguments: [String], environment: AppEnvironment) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return false }
        // The settings file was loaded with the launch's defaults.
        let rest = arguments[(flagIndex + 1)...].filter { !$0.hasPrefix(EvalHooks.settingsPrefix) }
        let paneName = rest.first.map { $0.hasSuffix(sampleSuffix) ? String($0.dropLast(sampleSuffix.count)) : $0 }
        let withSample = rest.first?.hasSuffix(sampleSuffix) == true
        guard rest.count >= 2, rest.count <= 4, let paneName, let pane = SettingsPane(rawValue: paneName),
              !withSample || pane == .watchFolders || pane == .engines,
              rest.count < 3 || ["light", "dark"].contains(rest[2]),
              rest.count < 4 || Double(rest[3]) != nil else {
            DebugOutput.fail(usage, 64)
        }
        let output = URL(fileURLWithPath: rest[1])
        let dark = rest.count >= 3 && rest[2] == "dark"
        // A taller window shows more of a long pane.
        let height = rest.count == 4 ? Double(rest[3])! : pane.size.height
        Task {
            if withSample && pane == .watchFolders { showSampleWatchFolders(in: environment) }
            await render(pane: pane, output: output, dark: dark, height: height, environment: environment,
                         engines: withSample && pane == .engines ? EnginesModel.sampleForSnapshot() : nil)
        }
        return true
    }

    /// Only in the in-memory settings of a snapshot launch (P95); the manager is never started, so nothing is watched.
    @MainActor
    static func showSampleWatchFolders(in environment: AppEnvironment) {
        guard environment.settingsStore.defaults is EphemeralDefaults else {
            DebugOutput.fail("snapshot refused: the settings are not in memory")
        }
        let lost = WatchFolder(path: "/Users/sample/Pictures/Scans", action: .convert("jpg"))
        let failing = WatchFolder(path: "/Users/sample/Library/Mobile Documents/com~apple~CloudDocs/Photos Inbox",
                                  action: .tool("compress"))
        let quiet = WatchFolder(path: "/Users/sample/Desktop", action: .convert("png"), isEnabled: false)
        environment.settingsStore.settings.watchFolders = [lost, failing, quiet]
        environment.watchFolders.showForSnapshot(
            states: [lost.id: .missing, failing.id: .watching, quiet.id: .off],
            problems: [failing.id: "Couldn't convert IMG_1.heic. The file may be damaged."]
        )
    }

    @MainActor
    private static func render(pane: SettingsPane, output: URL, dark: Bool, height: Double, environment: AppEnvironment,
                               engines: EnginesModel?) async {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.accessory)
        await environment.refreshEngines()
        let host = NSHostingView(rootView: SettingsView(environment: environment, pane: pane, height: height, engines: engines))
        let size = CGSize(width: pane.size.width, height: height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        // As in every production window: the default lets a close free the window before the capture reads it (SIGSEGV).
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = appearance
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI lay out and the Engines pane's `.task` finish loading.
        try? await Task.sleep(for: .seconds(1.5))
        guard let contentView = window.contentView?.superview ?? window.contentView else {
            DebugOutput.fail("snapshot failed: no bitmap")
        }
        DebugOutput.writeDisplay(of: contentView, to: output)
        print(output.path)
        exit(0)
    }
}
#endif
