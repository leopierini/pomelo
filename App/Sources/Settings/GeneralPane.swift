import PomeloUIModel
import SwiftUI

extension TriggerKey {
    /// How the trigger picker names the key.
    var settingsTitle: String {
        switch self {
        case .shift: "⇧ Shift"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        }
    }
}

struct GeneralPane: View {
    static let shakeLabel = "Shake to open the Shelf"
    static let shakeChoices = ShakeSensitivity.allCases

    @MainActor static func shakeBinding(_ store: SettingsStore) -> Binding<ShakeSensitivity> {
        Binding(get: { store.settings.shelfShake }, set: { store.settings.shelfShake = $0 })
    }

    @ObservedObject var store: SettingsStore
    @ObservedObject var loginItem: LoginItemModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isOn },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    LabeledContent("Waiting for your approval in System Settings") {
                        Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                    }
                }
                if let message = loginItem.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Picker("Open the wheel with", selection: $store.settings.trigger) {
                    ForEach(TriggerKey.allCases, id: \.self) { key in
                        Text(key.settingsTitle).tag(key)
                    }
                }
                Picker("The wheel opens on", selection: $store.settings.firstPage) {
                    Text("Convert").tag(WheelPageKind.convert)
                    Text("Tools").tag(WheelPageKind.tools)
                    Text("AI").tag(WheelPageKind.ai)
                }
            } footer: {
                Text("Tap the key while dragging files to open the wheel. Tap it again to switch between its pages.")
            }
            Section {
                Picker(Self.shakeLabel, selection: Self.shakeBinding(store)) {
                    ForEach(Self.shakeChoices, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Shake files while you drag them to put them on the Shelf. You can also drop them on Shelf in the wheel's Tools, or choose Show Shelf in the menu bar.")
            }
            Section {
                Toggle("Haptic feedback", isOn: $store.settings.hapticsEnabled)
                Toggle("Sounds", isOn: $store.settings.soundsEnabled)
                Toggle("Convert selection shortcut ⌥⌘K", isOn: $store.settings.clickModeHotkeyEnabled)
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
