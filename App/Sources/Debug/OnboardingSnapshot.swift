// DEBUG only: `Pomelo --snapshot-onboarding <out.png> [light|dark] [initial|held|converted] [page=1|2|3]` hosts the
// welcome view in a window, writes a PNG of it and exits. `held` lights the key glyph, `converted` shows the
// checkmark (both on page 1); `page=` picks the page, the first by default.
#if DEBUG
import AppKit
import PomeloUIModel
import SwiftUI

enum OnboardingSnapshot {
    static let flag = "--snapshot-onboarding"
    static let usage =
        "usage: Pomelo --snapshot-onboarding <out.png> [light|dark] [initial|held|converted] [page=1|2|3]"

    @MainActor
    static func runIfRequested(arguments: [String], environment: AppEnvironment) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return false }
        var rest = Array(arguments[(flagIndex + 1)...])
        var page = OnboardingPage.practice
        if let index = rest.firstIndex(where: { $0.hasPrefix("page=") }) {
            guard let number = Int(rest[index].dropFirst("page=".count)),
                  let parsed = OnboardingPage(rawValue: number - 1) else { DebugOutput.fail(usage, 64) }
            page = parsed
            rest.remove(at: index)
        }
        guard rest.count >= 1, rest.count <= 3,
              rest.count < 2 || ["light", "dark"].contains(rest[1]),
              rest.count < 3 || ["initial", "held", "converted"].contains(rest[2]) else {
            DebugOutput.fail(usage, 64)
        }
        let output = URL(fileURLWithPath: rest[0])
        let dark = rest.count >= 2 && rest[1] == "dark"
        let state = rest.count == 3 ? rest[2] : "initial"
        Task { await render(output: output, dark: dark, state: state, page: page, environment: environment) }
        return true
    }

    @MainActor
    private static func render(output: URL, dark: Bool, state: String, page: OnboardingPage,
                               environment: AppEnvironment) async {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.accessory)
        // A private folder, so a snapshot never touches a real practice run.
        let folder = PracticeFolder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Pomelo Snapshot \(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder.directory) }
        await environment.rebuildWheelContent()
        let model = OnboardingModel(trigger: environment.settingsStore.settings.trigger, folder: folder,
                                    wheelContent: { environment.contentBuilder })
        if state == "converted" {
            try? Data("png".utf8).write(to: folder.outputURL)
            model.refreshConverted()
        }
        if state == "held" { model.simulateTriggerHeld() }
        model.show(page)
        let host = NSHostingView(rootView: OnboardingView(model: model, settingsNavigation: SettingsNavigation()) {})
        let window = OnboardingController.makeWindow(content: host)
        window.appearance = appearance
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        guard let contentView = window.contentView?.superview ?? window.contentView else {
            DebugOutput.fail("snapshot failed: no bitmap")
        }
        DebugOutput.writeDisplay(of: contentView, to: output)
        model.teardown()
        print(output.path)
        exit(0)
    }
}
#endif
