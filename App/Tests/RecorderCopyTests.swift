#if DEBUG
import AppIntents
import AppKit
import Foundation
import PomeloCore
import PomeloEngines
import PomeloUIModel
import Testing
@testable import Pomelo

/// S34.1: the PomeloTrace copy records drags and runs no job, whatever launches it. Nothing here starts Shortcuts or
/// the system's services; the predicate is injected.
@MainActor
@Suite struct RecorderCopyTests {
    @Test func theFlagMakesTheRecorder() {
        #expect(RecorderCopy.isActive(arguments: ["Pomelo", "--record-drags", "/tmp/x"], bundleIdentifier: "io.github.pomelo-app.Pomelo"))
    }

    @Test func theTraceBundleIsTheRecorderWithoutTheFlag() {
        #expect(RecorderCopy.isActive(arguments: ["PomeloTrace"], bundleIdentifier: "io.github.pomelo-app.PomeloTrace"))
    }

    @Test func pomeloItselfIsNotTheRecorder() {
        #expect(!RecorderCopy.isActive(arguments: ["Pomelo"], bundleIdentifier: "io.github.pomelo-app.Pomelo"))
        #expect(!RecorderCopy.isActive(arguments: ["Pomelo"], bundleIdentifier: nil))
        #expect(!RecorderCopy.isActive(arguments: ["--record-drags", "Pomelo"], bundleIdentifier: nil))
    }

    @Test func theTraceBundleGetsInMemoryDefaults() {
        let kind = AppEnvironment.launchDefaults(arguments: ["PomeloTrace"], isRunningTests: false,
                                                 bundleIdentifier: "io.github.pomelo-app.PomeloTrace")
        #expect(kind == .ephemeral)
        let user = AppEnvironment.launchDefaults(arguments: ["Pomelo"], isRunningTests: false,
                                                 bundleIdentifier: "io.github.pomelo-app.Pomelo")
        #expect(user == .user)
    }

    @Test func intentsRefuseBeforeTouchingAnyFile() async throws {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "RecorderCopyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        var ran = false
        let runner = IntentRunner(
            registry: EngineRegistry(engines: [], priority: []), settings: SettingsStore(defaults: EphemeralDefaults()),
            run: { _, _ in ran = true; return [] }, workFolder: work, refusesWork: true
        )
        var worked = false
        await #expect(throws: IntentRunError.recorderCopy) {
            _ = try await runner.perform(on: [IntentFile(data: Data("x".utf8), filename: "a.png")]) { _ in
                worked = true
                return []
            }
        }
        #expect(!worked && !ran)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(IntentRunError.recorderCopy.message == "PomeloTrace only records drags.")
    }

    @Test func openedFilesAreIgnored() {
        let delegate = AppDelegate()
        var opened: [URL] = []
        delegate.openFiles = { opened += $0 }
        let url = URL(fileURLWithPath: "/tmp/recorder-copy-test/a.png")
        delegate.isRecorderCopy = true
        delegate.application(NSApplication.shared, open: [url])
        #expect(opened.isEmpty)
        delegate.isRecorderCopy = false
        delegate.application(NSApplication.shared, open: [url])
        #expect(opened == [url])
    }
}
#endif
