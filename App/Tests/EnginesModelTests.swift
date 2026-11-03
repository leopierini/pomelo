import Combine
import Foundation
import PomeloCore
import PomeloEngines
import Testing

@testable import Pomelo

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Availability {
    private(set) var installed = false
    private(set) var refreshes = 0
    func markInstalled() { installed = true }
    func refreshed() { refreshes += 1 }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let cwebpMissing = EngineStatus(id: "cwebp", displayName: "WebP", availability: .missing(installHint: "brew install webp"))
private let cwebpThere = EngineStatus(id: "cwebp", displayName: "WebP", availability: .available(version: "1.6.0"))
private let unarMissing = EngineStatus(id: "unar", displayName: "The Unarchiver",
                                       availability: .missing(installHint: "brew install unar"))
private let ffmpegThere = EngineStatus(id: "ffmpeg", displayName: "FFmpeg", availability: .available(version: "9.0.2"))

@MainActor
private func makeModel(
    availability: Availability = Availability(), stageInterval: TimeInterval = 0.02,
    install: @escaping (EngineID, @escaping @Sendable (InstallStage) -> Void) async throws -> URL
) -> EnginesModel {
    EnginesModel(
        loadStatuses: { [availability] in await availability.installed ? [cwebpThere] : [cwebpMissing] },
        refresh: { [availability] in await availability.refreshed() },
        install: install, installable: ["cwebp"], stageInterval: stageInterval
    )
}

@MainActor
@Suite struct EnginesModelInstallTests {
    @Test func installShowsItsStagesThenRefreshes() async {
        let availability = Availability()
        let gate = Gate()
        let model = makeModel(availability: availability) { _, stage in
            stage(.downloading(fraction: 0.4))
            await gate.wait()
            stage(.verifying)
            await availability.markInstalled()
            return URL(fileURLWithPath: "/engines/cwebp/bin/cwebp")
        }
        await model.load()
        #expect(model.statuses == [cwebpMissing])

        let running = Task { await model.install("cwebp") }
        #expect(await eventually { model.installs["cwebp"] != nil })
        #expect(await eventually { model.installs["cwebp"] == .working(.downloading(fraction: 0.4)) })
        await gate.open()
        #expect(await eventually { model.installs["cwebp"] == .working(.verifying) || model.installs["cwebp"] == nil })
        await running.value

        #expect(model.installs.isEmpty)
        #expect(model.statuses == [cwebpThere])
        #expect(await availability.refreshes == 1)
    }

    @Test func aFailureShowsItsReason() async {
        let calls = Counter()
        let model = makeModel { _, _ in
            await calls.increment()
            if await calls.value == 1 { throw InstallError.checksumMismatch }
            throw InstallError.downloadFailed
        }
        await model.load()
        await model.install("cwebp")
        #expect(model.installs["cwebp"] == .failed("The download didn't match its checksum"))

        // Trying again replaces the failure.
        await model.install("cwebp")
        #expect(model.installs["cwebp"] == .failed("The download failed"))
        #expect(await calls.value == 2)
    }

    @Test func anErrorThatIsNotAnInstallErrorReadsAsAFailedDownload() async {
        struct Odd: Error {}
        let model = makeModel { _, _ in throw Odd() }
        await model.install("cwebp")
        #expect(model.installs["cwebp"] == .failed("The download failed"))
    }

    @Test func cancellingShowsNothing() async {
        let started = Gate()
        let model = makeModel { _, stage in
            stage(.downloading(fraction: 0.1))
            await started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch { throw InstallError.cancelled }
            return URL(fileURLWithPath: "/never")
        }
        await model.load()
        let running = Task { await model.install("cwebp") }
        await started.wait()
        model.cancelInstall("cwebp")
        await running.value
        #expect(model.installs.isEmpty)
        #expect(model.cancelling.isEmpty)
        #expect(model.statuses == [cwebpMissing])
    }

    /// P132: the installer hands a call that joins a cancelled install a `.cancelled` the person never asked for.
    @Test func installDoesNotReenterWhileACancelUnwinds() async {
        let started = Gate()
        let unwind = Gate()
        let calls = Counter()
        let model = makeModel { _, _ in
            await calls.increment()
            await started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await unwind.wait()
                throw InstallError.cancelled
            }
            return URL(fileURLWithPath: "/never")
        }
        await model.load()
        let running = Task { await model.install("cwebp") }
        await started.wait()
        model.cancelInstall("cwebp")
        #expect(model.cancelling == ["cwebp"])
        #expect(model.installs["cwebp"] != nil)

        await model.install("cwebp")
        #expect(await calls.value == 1)
        #expect(model.installs["cwebp"] != nil)

        await unwind.open()
        await running.value
        #expect(model.installs.isEmpty)
        #expect(model.cancelling.isEmpty)

        // Free again: a new install runs.
        let again = Task { await model.install("cwebp") }
        while await calls.value < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        model.cancelInstall("cwebp")
        await unwind.open()
        await again.value
    }

    @Test func aSecondInstallOfTheSameEngineDoesNothingWhileItWorks() async {
        let started = Gate()
        let release = Gate()
        let calls = Counter()
        let model = makeModel { _, _ in
            await calls.increment()
            await started.open()
            await release.wait()
            return URL(fileURLWithPath: "/engines/cwebp/bin/cwebp")
        }
        let first = Task { await model.install("cwebp") }
        await started.wait()
        await model.install("cwebp")
        #expect(await calls.value == 1)
        await release.open()
        await first.value
    }

    @Test func onlyMissingInstallableEnginesOfferInstall() {
        let model = makeModel { _, _ in URL(fileURLWithPath: "/x") }
        #expect(model.canInstall(cwebpMissing))
        #expect(!model.canInstall(cwebpThere))
        #expect(!model.canInstall(unarMissing))
        #expect(!model.canInstall(ffmpegThere))
    }

    /// Installing can't fix an engine this Mac can't run: no Install button, no Homebrew line, no download note.
    @Test func anUnsupportedEngineIsNeverOfferedForInstall() async {
        let unsupported = EngineStatus(id: "cwebp", displayName: "WebP", availability: .unsupported(reason: "Needs macOS 26."))
        let model = EnginesModel(loadStatuses: { [unsupported] }, refresh: {}, installable: ["cwebp"])
        await model.load()
        #expect(!model.canInstall(unsupported))
        #expect(model.homebrewLine(for: unsupported) == nil && model.homebrewCommand(for: unsupported) == nil)
        #expect(!model.footer.contains(EnginesModel.installNote))
    }

    @Test func anEngineThatIsNotInstallableIsNeverInstalled() async {
        let calls = Counter()
        let model = makeModel { _, _ in
            await calls.increment()
            return URL(fileURLWithPath: "/x")
        }
        await model.install("unar")
        #expect(await calls.value == 0)
        #expect(model.installs.isEmpty)
    }

    @Test func stageUpdatesAreThrottledAndTheLastOneIsShown() async {
        let hold = Gate()
        let model = makeModel(stageInterval: 0.05) { _, stage in
            for step in 0..<2000 { stage(.downloading(fraction: Double(step) / 1999)) }
            await hold.wait()
            return URL(fileURLWithPath: "/engines/cwebp/bin/cwebp")
        }
        var published = 0
        let watch = model.$installs.dropFirst().sink { _ in published += 1 }
        let running = Task { await model.install("cwebp") }
        #expect(await eventually { model.installs["cwebp"] == .working(.downloading(fraction: 1)) })
        #expect(published < 40)
        await hold.open()
        await running.value
        watch.cancel()
    }

    @Test func aLateStageNeverBringsBackAFinishedInstall() async {
        let model = makeModel(stageInterval: 0.2) { _, stage in
            stage(.downloading(fraction: 0.2))
            stage(.downloading(fraction: 0.9))
            throw InstallError.downloadFailed
        }
        await model.install("cwebp")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.installs["cwebp"] == .failed("The download failed"))
    }

    @Test func theHomebrewHintIsASecondLineForAnInstallableEngine() {
        let model = makeModel { _, _ in URL(fileURLWithPath: "/x") }
        #expect(model.homebrewLine(for: cwebpMissing) == "Or with Homebrew: brew install webp")
        #expect(model.homebrewCommand(for: cwebpMissing) == "brew install webp")
        #expect(model.homebrewLine(for: unarMissing) == nil)
        #expect(model.homebrewLine(for: cwebpThere) == nil)
    }

    /// The footer speaks of downloads only when the pane shows an Install button, and names no publisher: FFmpeg's
    /// build is Martin Riedl's, not FFmpeg's own.
    @Test func theFooterTellsOfDownloadsOnlyWhenSomethingCanBeInstalled() async {
        for (statuses, shows) in [([cwebpMissing, ffmpegThere], true), ([unarMissing, ffmpegThere], false),
                                  ([cwebpThere], false)] {
            let model = EnginesModel(loadStatuses: { statuses }, refresh: {}, installable: ["cwebp"])
            await model.load()
            #expect(model.footer.contains(EnginesModel.installNote) == shows, "\(statuses.map(\.id))")
            #expect(model.footer.hasPrefix("Missing engines are optional."))
        }
        #expect(EnginesModel.installNote.contains("the publisher's build"))
        #expect(!EnginesModel.installNote.contains("official"))
    }
}

/// Quitting cancels a running install and waits, within the quit's bound, for it to unwind,
/// so its work folder is gone before the app exits.
@MainActor
@Suite struct EnginesModelQuitTests {
    @Test func quittingCancelsAnInstallAndWaitsForItsCleanUp() async throws {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "pomelo-install-work-\(UUID().uuidString)", directoryHint: .isDirectory)
        let started = Gate()
        let model = makeModel { _, _ in
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: work) }
            await started.open()
            do { try await Task.sleep(for: .seconds(60)) } catch { throw InstallError.cancelled }
            return URL(fileURLWithPath: "/never")
        }
        await model.load()
        let running = Task { await model.install("cwebp") }
        await started.wait()
        #expect(model.isInstalling)
        #expect(FileManager.default.fileExists(atPath: work.path))

        let start = ContinuousClock.now
        await model.cancelInstalls(waitingUntil: start + .seconds(3))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(!model.isInstalling)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        await running.value
    }

    @Test func quittingWaitsForAnInstallNoLongerThanItsBound() async {
        let started = Gate()
        let release = Gate()
        let model = makeModel { _, _ in
            await started.open()
            await release.wait()
            throw InstallError.cancelled
        }
        await model.load()
        let running = Task { await model.install("cwebp") }
        await started.wait()

        let start = ContinuousClock.now
        await model.cancelInstalls(waitingUntil: start + .milliseconds(200))
        #expect(ContinuousClock.now - start >= .milliseconds(200))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(model.isInstalling)
        await release.open()
        await running.value
        #expect(!model.isInstalling)
    }
}

/// P133: the install state outlives the Settings window, so every SettingsView shows the one model the app holds.
@MainActor
@Suite struct SettingsEnginesModelTests {
    @Test func everySettingsViewSharesTheAppsEnginesModel() {
        let environment = AppEnvironment.shared
        let first = SettingsView(environment: environment)
        let second = SettingsView(environment: environment)
        #expect(first.engines === second.engines)
        #expect(first.engines === environment.engines)
    }
}
