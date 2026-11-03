// Click mode: the wheel opens on files without a drag, from the ⌥⌘K hotkey (the Finder selection), the
// "Convert with Pomelo…" service, the Finder Quick Action or files the app is asked to open, at the cursor, key and
// keyboard-driven. There are no notices (P23): a press with nothing to open does nothing visible, and problems
// reading the selection only go to the log. The one exception is a denied Automation permission, which the wheel
// itself asks for, in its red hub.
import AppKit
import os

extension WheelAlert {
    /// The click-mode wheel's hub when Pomelo may not control Finder.
    static let allowAutomation = WheelAlert(
        title: "Allow Pomelo to read Finder's selection",
        subtitle: "Click to open System Settings",
        symbol: "hand.raised.fill"
    )
}

/// What a ⌥⌘K press leads to, given how reading the Finder selection went. Pure, so it can be tested.
enum ClickModeResponse: Equatable {
    case open([URL])
    /// Pomelo may not control Finder (-1743): the wheel opens with no slices and asks for the permission.
    case askForAutomation
    /// Nothing visible: nothing is selected, or the selection could not be read (the error is logged).
    case ignore

    init(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let files): self = files.isEmpty ? .ignore : .open(files)
        case .failure(FinderSelection.Error.notAuthorized): self = .askForAutomation
        case .failure: self = .ignore
        }
    }
}

/// Owns the hotkey and the Services provider, and opens the wheel in click mode for them and for opened files.
@MainActor
final class ClickModeController {
    private let wheel: WheelController
    private var hotkey: GlobalHotkey?
    private var servicesProvider: ServicesProvider?
    /// True while the Finder selection is being read (the Automation prompt may be up): further presses wait.
    private var isReadingSelection = false
    /// Files that arrived before the wheel's content was planned (a request that launched the app).
    private(set) var pendingFiles: [URL]?
    /// Asked first on ⌥⌘K: true when the Shelf is key and opened the wheel on its own files instead (S17).
    var shelfTakesHotkey: (() -> Bool)?
    /// Called before each wheel this controller opens (on Finder's selection, opened files or the service): that
    /// wheel is never the Shelf's (S37).
    var willOpenWheel: (() -> Void)?
    /// Replaced by the tests: nothing there reads the real Finder or the frontmost app.
    var isFinderFrontmost: () -> Bool = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderSelection.finderBundleIdentifier
    }
    var readSelection: () async throws -> [URL] = { try await FinderSelection.selection() }

    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "click-mode")

    init(wheel: WheelController) {
        self.wheel = wheel
    }

    /// Provides the service and, when `hotkeyEnabled`, registers the hotkey.
    func start(hotkeyEnabled: Bool) {
        let provider = ServicesProvider { [weak self] files in self?.openFiles(files) }
        servicesProvider = provider
        NSApplication.shared.servicesProvider = provider
        NSUpdateDynamicServices()
        setHotkeyEnabled(hotkeyEnabled)
    }

    /// Registers or unregisters the hotkey (`AppSettings.clickModeHotkeyEnabled`).
    func setHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            guard hotkey == nil else { return }
            let hotkey = GlobalHotkey { [weak self] in self?.hotkeyPressed() }
            if !hotkey.isRegistered { Self.log.error("the click-mode hotkey ⌥⌘K could not be registered") }
            self.hotkey = hotkey
        } else {
            hotkey?.unregister()
            hotkey = nil
        }
    }

    /// Opens the wheel at the pointer in click mode on the file URLs among `urls`, each once: from the Quick Action,
    /// `open -a Pomelo` or a drop on the app's icon (P101, P102), the service, and ⌥⌘K's Finder selection. Before the
    /// wheel's content is planned (a request that launched the app) they wait for it.
    func openFiles(_ urls: [URL]) {
        var seen: Set<String> = []
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else { return }
        guard wheel.contentBuilder != nil else {
            pendingFiles = files
            return
        }
        willOpenWheel?()
        wheel.open(files: files, at: NSEvent.mouseLocation, clickMode: true)
    }

    /// The wheel's content is planned: opens any files that were waiting for it.
    func contentBecameReady() {
        guard let files = pendingFiles else { return }
        pendingFiles = nil
        openFiles(files)
    }

    /// ⌥⌘K: a key Shelf is asked first and opens the wheel on its own files (S17); otherwise reads the Finder
    /// selection, if Finder is the app in front, and opens the wheel on it.
    func hotkeyPressed() {
        if shelfTakesHotkey?() == true { return }
        guard !isReadingSelection else { return }
        // Only Finder's selection is read: in any other app the shortcut cannot know which files are meant.
        guard isFinderFrontmost() else {
            Self.log.info("⌥⌘K ignored: Finder is not the frontmost app")
            return
        }
        isReadingSelection = true
        Task {
            defer { isReadingSelection = false }
            let result: Result<[URL], any Error>
            do {
                result = .success(try await readSelection())
            } catch {
                result = .failure(error)
            }
            respond(to: ClickModeResponse(result), result: result)
        }
    }

    // MARK: - Private

    private func respond(to response: ClickModeResponse, result: Result<[URL], any Error>) {
        switch response {
        case .open(let files):
            openFiles(files)
        case .askForAutomation:
            Self.log.info("⌥⌘K: Pomelo may not control Finder; asking in the wheel")
            willOpenWheel?()
            wheel.showAutomationPrompt(at: NSEvent.mouseLocation)
        case .ignore:
            if case .failure(let error) = result {
                Self.log.error("⌥⌘K: couldn't read the Finder selection: \(String(describing: error), privacy: .private)")
            } else {
                Self.log.info("⌥⌘K ignored: nothing is selected in Finder")
            }
        }
    }
}
