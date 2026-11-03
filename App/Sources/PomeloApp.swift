import AppKit
import PomeloCore
import SwiftUI

@main
struct PomeloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment = AppEnvironment.shared
    #if DEBUG
    /// Set for a `--record-drags` launch, which runs the recorder instead of Pomelo (S34).
    private let recorder: DragTraceRecorder?
    #endif

    init() {
        #if DEBUG
        recorder = DragTraceRecorder.runIfRequested(arguments: CommandLine.arguments)
        if recorder != nil { return }
        // The system launched PomeloTrace for an intent or an opened file: it has no folder to record into, and
        // starting as a Pomelo would run the job (S34.1).
        if RecorderCopy.isActive { exit(0) }
        if WheelSnapshot.runIfRequested(arguments: CommandLine.arguments, environment: environment) { return }
        if SettingsSnapshot.runIfRequested(arguments: CommandLine.arguments, environment: environment) { return }
        if OnboardingSnapshot.runIfRequested(arguments: CommandLine.arguments, environment: environment) { return }
        if PillSnapshot.runIfRequested(arguments: CommandLine.arguments) { return }
        if ShelfSnapshot.runIfRequested(arguments: CommandLine.arguments) { return }
        if EditorSnapshot.runIfRequested(arguments: CommandLine.arguments) { return }
        #endif
        #if DEBUG || POMELO_EVALS
        if EvalHooks.runIfRequested(arguments: CommandLine.arguments, environment: environment) { return }
        #endif
        environment.start()
    }

    var body: some Scene {
        #if DEBUG
        MenuBarExtra {
            if let recorder {
                DragTraceRecorderMenu(recorder: recorder)
            } else {
                menu
            }
        } label: {
            // The recorder runs beside his Pomelo: its item must not look like Pomelo's.
            if recorder != nil {
                Label("PomeloTrace", systemImage: "record.circle")
            } else {
                Label("Pomelo", image: "MenuBarIcon")
            }
        }
        #else
        MenuBarExtra("Pomelo", image: "MenuBarIcon") {
            menu
        }
        #endif
        Settings {
            SettingsView(environment: environment)
        }
    }
}

extension PomeloApp {
    @ViewBuilder private var menu: some View {
        SettingsMenuItem(navigation: environment.settingsNavigation)
        Button("Show Welcome") {
            environment.onboarding.show()
        }
        Divider()
        ShelfMenuItems(shelf: environment.shelf)
        Divider()
        Button("Quit Pomelo") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// Quitting stops the work of running jobs (P24) and engine installs: a plugin's process (ffmpeg) or `ditto` leads its
/// own process group, so it would otherwise go on after Pomelo exits, writing into a staging folder nothing removes,
/// and an install's work folder would be left behind.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var isRecorderCopy = AppEnvironment.runsAsRecorderCopy
    var openFiles: ([URL]) -> Void = { AppEnvironment.shared.clickMode.openFiles($0) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved choices are dropped; a job the editor saved is among the running ones cancelled below.
        let environment = AppEnvironment.shared
        environment.editors.cancel()
        guard environment.hasRunningWork else { return .terminateNow }
        // Every path that replies false (none today) must call `jobs.quitWasCancelled()` first: `cancelAll` refuses
        // new jobs and silences their sounds until then (M2).
        Task {
            await environment.stopAllWork()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Files Pomelo is asked to open, from the Quick Action, `open -a Pomelo` or a drop on its icon: the click-mode
    /// wheel opens on them at the pointer (P101, P102).
    func application(_ application: NSApplication, open urls: [URL]) {
        // The PomeloTrace copy runs no job, and opening the wheel on a file is the way into one (S34.1).
        guard !isRecorderCopy else { return }
        openFiles(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The system drops a quitting process's progresses too; unpublishing them first is tidier.
        AppEnvironment.shared.jobs.endAllProgress()
        // A safety net for anything the bounded wait missed.
        ProcessRunner.signalAllChildren(SIGKILL)
    }
}

/// The "Settings…" item.
private struct SettingsMenuItem: View {
    let navigation: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            navigation.open(with: openSettings)
        }
        .keyboardShortcut(",")
    }
}
