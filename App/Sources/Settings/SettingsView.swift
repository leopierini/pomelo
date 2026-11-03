import AppKit
import PomeloUIModel
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, wheel, tools, watchFolders, engines, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .wheel: "Wheel"
        case .tools: "Tools"
        case .watchFolders: "Watch Folders"
        case .engines: "Engines"
        case .about: "About"
        }
    }

    /// The window's size while the pane is shown: the wheel editor's three columns need the room (P179).
    var size: CGSize {
        self == .wheel ? CGSize(width: 980, height: 620) : SettingsView.size
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .wheel: "circle.circle"
        case .tools: "wrench.and.screwdriver"
        case .watchFolders: "folder.badge.gearshape"
        case .engines: "shippingbox"
        case .about: "info.circle"
        }
    }
}

/// Opens the Settings window, optionally on a given pane: the Settings scene's view is SwiftUI's to make, so a pane
/// is asked for here and the view switches to it when it appears or while it is shown.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var requestedPane: SettingsPane?

    /// `openSettings` in an agent (LSUIElement) app can open the window behind other apps, so this activates the app
    /// first and brings the window to the front once it exists.
    func open(_ pane: SettingsPane? = nil, with openSettings: OpenSettingsAction) {
        if let pane { requestedPane = pane }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// The Settings window: a sidebar of panes and a grouped form for the selected one. Every change is applied at
/// once; `AppEnvironment` observes the store.
struct SettingsView: View {
    nonisolated static let size = CGSize(width: 680, height: 480)

    private let store: SettingsStore
    @ObservedObject var engines: EnginesModel
    @StateObject private var wheel: WheelEditorLoader
    @StateObject private var watchFolders: WatchFoldersPaneModel
    @StateObject private var toolChoices: ToolChoicesModel
    @StateObject private var loginItem = LoginItemModel()
    @ObservedObject private var navigation: SettingsNavigation
    @State private var pane: SettingsPane
    /// A snapshot's taller window, else each pane's own height.
    private let height: Double?

    init(environment: AppEnvironment, pane: SettingsPane = .general, height: Double? = nil,
         engines: EnginesModel? = nil) {
        self.height = height
        store = environment.settingsStore
        self.engines = engines ?? environment.engines
        _wheel = StateObject(wrappedValue: WheelEditorLoader(environment: environment))
        _watchFolders = StateObject(wrappedValue: WatchFoldersPaneModel(environment: environment))
        _toolChoices = StateObject(wrappedValue: ToolChoicesModel(environment: environment))
        navigation = environment.settingsNavigation
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            // The frame is what holds: the column-width modifier alone left the sidebar at 144 pt, where "Watch
            // Folders" truncated.
            .navigationSplitViewColumnWidth(min: 170, ideal: 170, max: 200)
            .frame(minWidth: 170)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane(store: store, loginItem: loginItem)
                case .wheel: WheelEditorPane(loader: wheel)
                case .tools: ToolsPane(store: store, choices: toolChoices)
                case .watchFolders: WatchFoldersPane(model: watchFolders)
                case .engines: EnginesPane(model: engines)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: pane.size.width, height: height ?? pane.size.height)
        .onChange(of: navigation.requestedPane, initial: true) { _, requested in
            guard let requested else { return }
            pane = requested
            navigation.requestedPane = nil
        }
    }
}
