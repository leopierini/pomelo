// What the Watch Folders pane does: adds, removes and edits the rules of `AppSettings.watchFolders`, and reads each
// folder's state from the manager.
import AppKit
import Combine
import Foundation
import PomeloCore
import PomeloUIModel

@MainActor
final class WatchFoldersPaneModel: ObservableObject {
    /// The line under a folder: why it isn't doing its work.
    enum Status: Equatable {
        case missing
        case problem(String)
    }

    /// One entry of a folder's action menu.
    struct Option: Identifiable, Equatable {
        let key: String
        let title: String
        var id: String { key }
    }

    struct ActionOptions: Equatable {
        var formats: [Option]
        var tools: [Option]
    }

    static let alreadyWatched = "That folder is already watched"
    static let missingText = "Can't find this folder"
    static let footer = """
        New files in these folders are converted as they arrive. A rule takes every file it can convert, so Convert \
        to JPEG takes PDFs too. The originals stay; the new files appear next to them. Files already there are left \
        alone. Folders on network drives only notice files added from this Mac.
        """

    /// Why the last "Add Folder" added nothing; cleared by the next one.
    @Published private(set) var message: String?
    @Published private(set) var formats: [FileFormat] = []
    @Published private(set) var tools: [Preset] = []

    private let store: SettingsStore
    private let manager: WatchFolderManager?
    private let chooseFolder: @MainActor () async -> URL?
    private let loadChoices: @MainActor () async -> (formats: [FileFormat], tools: [Preset])
    private var observers: [AnyCancellable] = []

    init(
        store: SettingsStore, manager: WatchFolderManager?, chooseFolder: @escaping @MainActor () async -> URL?,
        loadChoices: @escaping @MainActor () async -> (formats: [FileFormat], tools: [Preset])
    ) {
        self.store = store
        self.manager = manager
        self.chooseFolder = chooseFolder
        self.loadChoices = loadChoices
        observers.append(store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        if let manager {
            observers.append(manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    convenience init(environment: AppEnvironment) {
        let store = environment.settingsStore
        self.init(
            store: store, manager: environment.watchFolders, chooseFolder: { await Self.chooseFolderInPanel() },
            loadChoices: {
                let planner = await environment.registry.planner()
                let tools = IntentCatalog.tools(settings: store.settings, includingCombines: false)
                return WatchRules.choices(formats: .builtIn, planner: planner, tools: tools)
            }
        )
    }

    var folders: [WatchFolder] { store.settings.watchFolders }

    // MARK: - Editing

    /// Reads what the pane offers, and follows folders that were renamed or moved since the path was stored.
    func load() async {
        let choices = await loadChoices()
        formats = choices.formats
        tools = choices.tools
        await followMovedFolders()
    }

    /// Re-reads each folder's state: the pane shows what is true now, not what the last event said.
    func refreshStates() async {
        await manager?.recheck()
    }

    func add() async {
        message = nil
        guard let url = await chooseFolder() else { return }
        let folders = folders
        // Off the main thread: resolving the bookmark of a folder on a share that went away can block for seconds.
        let (isWatched, bookmark) = await Task.detached(priority: .userInitiated) {
            let place = Self.canonical(url.path)
            return (folders.contains { Self.currentPlace(of: $0) == place }, try? url.bookmarkData())
        }.value
        let path = url.standardizedFileURL.path
        guard !isWatched, !self.folders.contains(where: { $0.path == path }) else {
            message = Self.alreadyWatched
            return
        }
        store.settings.watchFolders.append(WatchFolder(path: path, bookmark: bookmark, action: .convert("jpg")))
    }

    /// Stops watching; the folder itself is never touched.
    func remove(_ id: UUID) {
        store.settings.watchFolders.removeAll { $0.id == id }
    }

    func setAction(_ action: WatchAction, for id: UUID) {
        update(id) { $0.action = action }
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        update(id) { $0.isEnabled = isEnabled }
    }

    private func update(_ id: UUID, _ change: (inout WatchFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        change(&folder)
        if folder != folders[index] { store.settings.watchFolders[index] = folder }
    }

    /// The manager follows a renamed folder through its bookmark on its own (P130) and takes this write as a no-op;
    /// storing the new path keeps the pane and the fallback right. A folder that can't be found keeps its path.
    private func followMovedFolders() async {
        let bookmarked = folders.filter { $0.bookmark != nil }
        let moves = await Task.detached(priority: .utility) {
            bookmarked.compactMap { folder -> (id: UUID, from: String, to: URL)? in
                guard let found = WatchFolderManager.resolve(folder),
                      Self.canonical(found.path) != Self.canonical(folder.path) else { return nil }
                return (folder.id, folder.path, found)
            }
        }.value
        for move in moves {
            guard let index = folders.firstIndex(where: { $0.id == move.id && $0.path == move.from }) else { continue }
            store.settings.watchFolders[index].path = move.to.standardizedFileURL.path
            if let fresh = try? move.to.bookmarkData() { store.settings.watchFolders[index].bookmark = fresh }
        }
    }

    // MARK: - Reading

    func status(of folder: WatchFolder) -> Status? {
        Self.status(isEnabled: folder.isEnabled, state: manager?.states[folder.id], problem: manager?.problems[folder.id])
    }

    nonisolated static func status(isEnabled: Bool, state: WatchFolderState?, problem: String?) -> Status? {
        guard isEnabled else { return nil }
        if state == .missing { return .missing }
        return problem.map(Status.problem)
    }

    /// The formats, then the tools; the folder's own action stays listed even when the engines no longer offer it, so
    /// the picker never shows a blank.
    func actionOptions(for folder: WatchFolder) -> ActionOptions {
        var options = ActionOptions(
            formats: formats.map { Option(key: Self.key(of: .convert($0.id)), title: $0.displayName) },
            tools: tools.map { Option(key: Self.key(of: .tool($0.id)), title: $0.name) }
        )
        let current = Self.key(of: folder.action)
        switch folder.action {
        case .convert(let format) where !options.formats.contains(where: { $0.key == current }):
            let title = FormatRegistry.builtIn.format(id: format)?.displayName ?? format.rawValue
            options.formats.append(Option(key: current, title: title))
        case .tool(let id) where !options.tools.contains(where: { $0.key == current }):
            options.tools.append(Option(key: current, title: ToolCatalog.info(id)?.name ?? id))
        default:
            break
        }
        return options
    }

    nonisolated static func key(of action: WatchAction) -> String {
        switch action {
        case .convert(let format): "convert:\(format.rawValue)"
        case .tool(let id): "tool:\(id)"
        }
    }

    nonisolated static func action(forKey key: String) -> WatchAction? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let value = String(key[key.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        return switch key[..<colon] {
        case "convert": .convert(FormatID(value))
        case "tool": .tool(value)
        default: nil
        }
    }

    nonisolated static func name(of folder: WatchFolder) -> String {
        URL(fileURLWithPath: folder.path).lastPathComponent
    }

    nonisolated static func displayPath(of folder: WatchFolder) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Places

    private nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Where the folder is now: its bookmark's place, else the stored path.
    private nonisolated static func currentPlace(of folder: WatchFolder) -> String {
        canonical(WatchFolderManager.resolve(folder)?.path ?? folder.path)
    }

    private static func chooseFolderInPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch"
        panel.message = "Choose a folder to watch."
        NSApp.activate()
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.url : nil
    }
}
