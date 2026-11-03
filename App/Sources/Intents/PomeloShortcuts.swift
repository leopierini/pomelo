import AppIntents

/// What Spotlight and Shortcuts offer with no setup.
struct PomeloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFilesIntent(), phrases: ["Convert files with \(.applicationName)"],
            shortTitle: "Convert Files", systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: RunPresetIntent(), phrases: ["Run a \(.applicationName) tool"],
            shortTitle: "Run a Tool", systemImageName: "wrench.and.screwdriver"
        )
    }
}
