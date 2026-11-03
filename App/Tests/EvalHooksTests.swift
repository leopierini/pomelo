import AppKit
import Foundation
import PomeloUIModel
import Testing
@testable import Pomelo

/// The measured launch (`--eval-launch`) starts the app as a user would, but never on the real defaults: it would
/// create `settings.v1` before the user's first launch and cancel the migration (P95).
@MainActor
@Suite struct EvalHooksTests {
    @Test func theLaunchMeasurementUsesInMemoryDefaults() throws {
        let arguments = ["PomeloEvals", EvalHooks.launchFlag, "/private/tmp/pomelo-evals/launch-1.json"]
        #expect(EvalHooks.isRequested(arguments))
        let kind = AppEnvironment.launchDefaults(arguments: arguments, isRunningTests: false)
        #expect(kind == .evals)
        let defaults = AppEnvironment.defaults(for: kind, arguments: arguments)
        #expect(defaults !== UserDefaults.standard)
        // Required before the settings are read: this host's `.standard` is the user's real domain.
        let ephemeral = try #require(defaults as? EphemeralDefaults)
        let settings = SettingsStore(defaults: ephemeral).settings
        #expect(settings.hasCompletedOnboarding)
        #expect(!settings.clickModeHotkeyEnabled)
    }

    /// The accessibility audit fills the Watch Folders pane with samples: only ever in memory.
    @Test func theAccessibilityAuditUsesInMemoryDefaults() {
        let arguments = ["PomeloEvals", AccessibilityEval.flag, "/private/tmp/corpus", "/private/tmp/a11y.json"]
        #expect(EvalHooks.isRequested(arguments))
        let kind = AppEnvironment.launchDefaults(arguments: arguments, isRunningTests: false)
        #expect(kind == .evals)
        #expect(AppEnvironment.defaults(for: kind, arguments: arguments) is EphemeralDefaults)
    }

    /// A settings file whose wheels the snapshots and the wheel-open measurement load into their in-memory defaults
    /// before AppEnvironment plans the wheel: only its wheels, over the launch's own settings.
    @Test func settingsArgumentLoads() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "EvalHooksTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var stored = AppSettings()
        stored.wheels = ["kind.image": CustomWheel(pages: [CustomPage(name: "Mine", slots: ["convert.jpg"])])]
        stored.trigger = .option
        stored.hasCompletedOnboarding = false
        let file = folder.appending(path: "settings.json")
        try JSONEncoder().encode(stored).write(to: file)
        let missing = folder.appending(path: "missing.json")

        let wheelSnapshot = ["Pomelo", WheelSnapshotRequest.flag, "/tmp/a.png", "/tmp/a-out.png", "1", "0",
                             "settings=\(file.path)", "dark"]
        let request = try #require(try WheelSnapshotRequest.parse(wheelSnapshot))
        #expect(request.page == .index(1) && request.hoverIndex == 0)
        #expect(request.dark)
        let settingsSnapshot = ["Pomelo", SettingsSnapshot.flag, "wheel", "/tmp/s.png", "settings=\(file.path)", "dark"]
        let measurement = ["Pomelo", EvalHooks.wheelFlag, "/tmp/a.png", "200", "/tmp/hook.json", file.path]
        for arguments in [wheelSnapshot, settingsSnapshot, measurement] {
            #expect(try EvalHooks.settingsFile(in: arguments) == file)
        }
        #expect(try EvalHooks.settingsFile(in: Array(measurement.dropLast())) == nil)
        #expect(try EvalHooks.settingsFile(in: ["Pomelo", SettingsSnapshot.flag, "wheel", "/tmp/s.png"]) == nil)

        for arguments in [wheelSnapshot, settingsSnapshot, measurement] {
            let pointing = arguments.map { $0.replacing(file.path, with: missing.path) }
            let error = #expect(throws: DebugOutput.Failure.self) { try EvalHooks.settingsFile(in: pointing) }
            #expect(error?.description.contains("usage:") == true)
        }
        #expect(throws: DebugOutput.Failure.self) {
            try WheelSnapshotRequest.parse(wheelSnapshot.map { $0.replacing(file.path, with: missing.path) })
        }
        // Refused from its path alone: the measured app never reads a protected folder.
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/settings.json").path
        let refusal = #expect(throws: DebugOutput.Failure.self) {
            try EvalHooks.settingsFile(in: Array(measurement.dropLast()) + [desktop])
        }
        #expect(refusal?.description.contains("protected folder") == true)

        let measured = try #require(AppEnvironment.defaults(for: .evals, arguments: measurement) as? EphemeralDefaults)
        let quiet = SettingsStore(defaults: measured).settings
        #expect(quiet.wheels == stored.wheels)
        #expect(quiet.trigger == .shift && quiet.hasCompletedOnboarding && !quiet.clickModeHotkeyEnabled)
        let snapshot = try #require(AppEnvironment.defaults(for: .ephemeral, arguments: wheelSnapshot) as? EphemeralDefaults)
        let shown = SettingsStore(defaults: snapshot).settings
        #expect(shown.wheels == stored.wheels)
        #expect(shown.trigger == .shift && !shown.hasCompletedOnboarding)
    }

    @Test func theProcessStartIsReadFromTheKernel() throws {
        let started = try #require(EvalHooks.processStart())
        let now = Date()
        #expect(started <= now)
        #expect(started > now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime))
    }
}
