import PomeloCore
import PomeloEngines
import SwiftUI

struct EnginesPane: View {
    @ObservedObject var model: EnginesModel
    @State private var folderError: String?

    var body: some View {
        Form {
            Section {
                ForEach(model.statuses, id: \.id) { status in
                    EngineRow(status: status, model: model)
                }
            } header: {
                Text("Engines")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.footer)
                    Text("Installed one yourself? Choose Refresh; the wheel enables its formats.")
                }
            }
            Section {
                LabeledContent("Plugins folder") {
                    Button("Show in Finder") {
                        do {
                            folderError = nil
                            try EnginesModel.showPluginsFolderInFinder()
                        } catch {
                            folderError = error.localizedDescription
                        }
                    }
                }
                if let folderError {
                    Text(folderError).font(.callout).foregroundStyle(.red)
                }
                LabeledContent("Availability") {
                    HStack(spacing: 8) {
                        if model.isRefreshing { ProgressView().controlSize(.small) }
                        Button("Refresh") { Task { await model.refresh() } }
                            .disabled(model.isRefreshing)
                    }
                }
            }
        }
        .task { await model.load() }
    }
}

private struct EngineRow: View {
    let status: EngineStatus
    @ObservedObject var model: EnginesModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(isAvailable ? Color.green : Color.gray)
                .accessibilityHidden(true)
            switch status.availability {
            case .available(let version):
                if let detail = model.detail(for: status) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.displayName)
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(status.displayName)
                }
                Spacer()
                if let version, let text = EngineVersionText.short(version) {
                    Text(text).foregroundStyle(.secondary).lineLimit(1)
                }
            case .missing(let hint):
                missing(hint: hint)
            case .unsupported(let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.displayName)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func missing(hint: String) -> some View {
        let state = model.installs[status.id]
        VStack(alignment: .leading, spacing: 4) {
            Text(status.displayName)
            if case .working(let stage)? = state {
                progress(stage)
            } else if case .failed(let reason)? = state {
                Text(reason).font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text(model.homebrewLine(for: status) ?? (hint.isEmpty ? "Not installed" : hint))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let command = model.homebrewCommand(for: status) ?? (hint.isEmpty ? nil : hint) {
                    Button("Copy") { EnginesModel.copy(command) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy the command for \(status.displayName)")
                }
            }
        }
        Spacer()
        if case .working? = state {
            if !model.cancelling.contains(status.id) {
                Button("Cancel") { model.cancelInstall(status.id) }
                    .accessibilityLabel("Cancel installing \(status.displayName)")
            }
        } else if model.canInstall(status) {
            Button("Install") { Task { await model.install(status.id) } }
                .accessibilityLabel("Install \(status.displayName)")
        }
    }

    @ViewBuilder
    private func progress(_ stage: InstallStage) -> some View {
        if model.cancelling.contains(status.id) {
            Text("Cancelling").font(.callout).foregroundStyle(.secondary)
        } else if case .downloading(let fraction?) = stage {
            HStack(spacing: 8) {
                Text(stage.label).font(.callout).foregroundStyle(.secondary)
                ProgressView(value: fraction)
                    .frame(maxWidth: 140)
                    .accessibilityLabel("\(stage.label) \(status.displayName)")
            }
        } else {
            HStack(spacing: 8) {
                Text(stage.label).font(.callout).foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(stage.label) \(status.displayName)")
            }
        }
    }

    private var isAvailable: Bool {
        if case .available = status.availability { return true }
        return false
    }
}

extension InstallStage {
    /// What the pane says while this stage runs: the download, then the fingerprint check, then the rest.
    var label: String {
        switch self {
        case .downloading: "Downloading"
        case .verifying: "Checking"
        case .unpacking, .checking: "Installing"
        }
    }
}

/// Engine versions are whatever the tool printed (ffmpeg gives its whole banner line, Pandoc "pandoc 3.13"); the pane
/// shows the number.
enum EngineVersionText {
    /// The token after "version" when there is one ("ffmpeg version 8.1.1 Copyright …" gives "8.1.1"), else the
    /// first token that looks like a version ("pandoc 3.13" gives "3.13"), else the first line, cut to 24 characters.
    /// Nil for an empty string.
    static func short(_ raw: String) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        let words = line.split(separator: " ")
        if let at = words.firstIndex(where: { $0.lowercased() == "version" }), at + 1 < words.count {
            return String(words[at + 1])
        }
        if let number = words.lazy.compactMap({ $0.prefixMatch(of: /\d+(\.\d+)+/).map { String($0.output.0) } }).first {
            return number
        }
        return line.count > 24 ? String(line.prefix(23)) + "…" : line
    }
}
