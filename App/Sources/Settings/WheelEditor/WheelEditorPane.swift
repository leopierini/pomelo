// Settings › Wheel (P179): the list of wheels, the wheel itself as it looks in use with its page tabs, and what can go
// on it. Every edit is a menu item and a VoiceOver action here; ⌘Z and ⇧⌘Z undo and redo through the window.
import AppKit
import Combine
import PomeloCore
import PomeloUIModel
import SwiftUI

/// Makes the pane's model once the app has planned the wheel's content, and hands it every later plan, so the editor
/// draws over the engines and settings the wheel opens with. It lives as long as the Settings window's content, so the
/// model re-plans only while its pane is shown.
@MainActor
final class WheelEditorLoader: ObservableObject {
    @Published private(set) var model: WheelEditorPaneModel?
    private var subscription: AnyCancellable?

    init(environment: AppEnvironment) {
        let store = environment.settingsStore
        subscription = environment.$contentBuilder.sink { [weak self] builder in
            MainActor.assumeIsolated { self?.receive(builder, store: store) }
        }
    }

    private func receive(_ builder: WheelContentBuilder?, store: SettingsStore) {
        guard let builder else { return }
        if let model {
            model.update(builder: builder)
        } else {
            model = WheelEditorPaneModel(store: store, builder: builder, undoManager: nil)
        }
    }
}

struct WheelEditorPane: View {
    @ObservedObject var loader: WheelEditorLoader

    var body: some View {
        if let model = loader.model {
            WheelEditorContent(model: model)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WheelEditorContent: View {
    @ObservedObject var model: WheelEditorPaneModel
    @Environment(\.undoManager) private var undoManager
    @State private var confirmsReset = false
    @State private var isRenaming = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            // 182 + 340 (the ring, as in use) + 218 and the gaps fit the ~776 points beside the sidebar, so the
            // margins stay even.
            WheelListColumn(model: model)
                .frame(width: 182)
            middle
                .frame(maxWidth: .infinity)
            WheelChipsColumn(model: model)
                .frame(width: 218)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Anywhere off the ring, the chips column included, is "off the wheel": a slice dropped there is removed.
        .contentShape(Rectangle())
        .onDrop(of: [.wheelSlot], delegate: OffWheelDrop(model: model))
        .background(undoKeys)
        .onAppear {
            model.undoManager = undoManager
            model.isVisible = true
        }
        .onDisappear { model.isVisible = false }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { model.undoManager = undoManager }
        .alert(resetTitle, isPresented: $confirmsReset) {
            Button(resetButton, role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetMessage)
        }
    }

    // MARK: Middle

    private var middle: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            WheelEditorRing(model: model)
                .opacity(model.isFormatFollowingKind ? 0.4 : 1)
            WheelPageTabs(model: model, isRenaming: $isRenaming)
                .padding(.top, 16)
            footer
                .frame(height: 40)
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(model.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                headerButton
            }
            status
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if model.customized.contains(model.selection) {
                // The text beside it says it already.
                CustomizedDot()
                    .accessibilityHidden(true)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if model.isFormatFollowingKind {
            return "\(model.title) files use the \(model.kind.wheelTitle) wheel."
        }
        return model.customized.contains(model.selection) ? "Customized" : "Built-in until you change it"
    }

    @ViewBuilder private var headerButton: some View {
        if model.isFormatFollowingKind {
            Button("Customize for \(model.title)") { model.customizeFormat() }
                .buttonStyle(.borderedProminent)
        } else if case .format = model.selection {
            Button("Use the \(model.kind.wheelTitle) wheel") { confirmsReset = true }
        } else {
            Button("Reset to default") { confirmsReset = true }
                .disabled(!model.canReset)
        }
    }

    private var footer: some View {
        Group {
            if let message = model.message {
                Text("\(Image(systemName: "exclamationmark.circle")) \(message)")
                    .foregroundStyle(.primary)
                    .accessibilityLabel(message)
                    .transition(.opacity)
            } else if !model.isFormatFollowingKind {
                Text("Drag chips onto the wheel. Control-click a slice for more.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .animation(.easeOut(duration: 0.15), value: model.message)
    }

    // MARK: Reset

    private var resetTitle: String {
        if case .format = model.selection {
            return "Use the \(model.kind.wheelTitle) wheel for \(model.title) files?"
        }
        return "Reset the \(model.title) wheel?"
    }

    private var resetMessage: String {
        if case .format = model.selection {
            return "\(model.title) files open the \(model.kind.wheelTitle) wheel again."
        }
        return "Pomelo's own wheel for \(model.kind.sentenceName) comes back."
    }

    private var resetButton: String {
        if case .format = model.selection { return "Use the \(model.kind.wheelTitle) wheel" }
        return "Reset"
    }

    // MARK: Undo

    /// An agent app has no Edit menu, so ⌘Z and ⇧⌘Z are the pane's own. A tab being renamed keeps them for its text.
    private var undoKeys: some View {
        ZStack {
            Button("Undo") { if undoManager?.canUndo == true { undoManager?.undo() } }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { if undoManager?.canRedo == true { undoManager?.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .disabled(isRenaming)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// A slice let go off the wheel is removed, with the system's poof; a chip let go there was never placed.
private struct OffWheelDrop: DropDelegate {
    let model: WheelEditorPaneModel

    func validateDrop(info: DropInfo) -> Bool {
        if case .slice = model.dragging?.source { info.hasItemsConforming(to: [.wheelSlot]) } else { false }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let drag = model.dragging else { return false }
        model.dragging = nil
        if model.dropOutside(slot: drag.slot, from: drag.source) { poof() }
        return true
    }
}

extension View {
    /// A side column of the editor, boxed like a grouped form's section.
    func editorColumn() -> some View {
        background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .quaternarySystemFill)))
    }
}

/// The orange dot of a customized wheel.
struct CustomizedDot: View {
    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemOrange))
            .frame(width: 7, height: 7)
            .accessibilityLabel("Customized")
    }
}

extension FormatCategory {
    /// The kind in a sentence: "Pomelo's own wheel for images comes back."
    var sentenceName: String {
        switch self {
        case .pdf: "PDFs"
        case .other: "other files"
        default: wheelTitle.lowercased()
        }
    }
}
