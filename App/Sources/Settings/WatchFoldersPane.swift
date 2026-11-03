import AppKit
import PomeloUIModel
import SwiftUI

/// The folders Pomelo converts files in as they arrive, each with its action. Every change is stored at once through
/// `WatchFoldersPaneModel`.
struct WatchFoldersPane: View {
    @ObservedObject var model: WatchFoldersPaneModel

    var body: some View {
        Form {
            ForEach(model.folders) { folder in
                Section { FolderRows(folder: folder, model: model) }
            }
            Section {
                Button("Add Folder\u{2026}") { Task { await model.add() } }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text(WatchFoldersPaneModel.footer)
            }
        }
        .task {
            await model.load()
            await model.refreshStates()
        }
        // Pomelo's only titled window is Settings; panels (the wheel, the editors, a folder chooser) don't count.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
            Task { await model.refreshStates() }
        }
    }
}

private struct FolderRows: View {
    let folder: WatchFolder
    @ObservedObject var model: WatchFoldersPaneModel

    var body: some View {
        let name = WatchFoldersPaneModel.name(of: folder)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold)
                Text(WatchFoldersPaneModel.displayPath(of: folder))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove") { model.remove(folder.id) }
                .help("Stops watching this folder. The folder and its files stay where they are.")
                .accessibilityLabel("Remove \(name)")
        }
        actionPicker(name: name)
        Toggle("On", isOn: Binding(
            get: { folder.isEnabled },
            set: { model.setEnabled($0, for: folder.id) }
        ))
        .accessibilityLabel("Watch \(name)")
        if let status = model.status(of: folder) {
            Text(text(of: status)).font(.callout).foregroundStyle(.red)
        }
    }

    private func actionPicker(name: String) -> some View {
        let options = model.actionOptions(for: folder)
        // The label says what the chosen entry means: "JPEG" alone doesn't.
        let label = if case .convert = folder.action { "Convert to" } else { "Tool" }
        return Picker(label, selection: Binding(
            get: { WatchFoldersPaneModel.key(of: folder.action) },
            set: { key in
                if let action = WatchFoldersPaneModel.action(forKey: key) { model.setAction(action, for: folder.id) }
            }
        )) {
            Section("Convert to") {
                ForEach(options.formats) { Text($0.title).tag($0.key) }
            }
            if !options.tools.isEmpty {
                Section("Tools") {
                    ForEach(options.tools) { Text($0.title).tag($0.key) }
                }
            }
        }
        .accessibilityLabel("Action for \(name)")
    }

    private func text(of status: WatchFoldersPaneModel.Status) -> String {
        switch status {
        case .missing: WatchFoldersPaneModel.missingText
        case .problem(let sentence): sentence
        }
    }
}
