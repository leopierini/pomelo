// The Resize editor (P197): width and height in pixels with a lock that keeps proportions, chips for common sizes
// and the first file's size now. The sizes are the upright picture's, read after the panel is up, as the engines
// resize what the person saw.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

@MainActor
final class ResizeSession: EditorSession, ObservableObject {
    let title = "Resize"
    var onChange: (() -> Void)?

    /// Changing it redraws the fields and tells the controller, since the blocker and note derive from it.
    var model: ResizeModel {
        willSet { objectWillChange.send() }
        didSet { onChange?() }
    }

    @Published private(set) var isLoaded = false {
        didSet { onChange?() }
    }

    @Published private(set) var loadFailed = false {
        didSet { onChange?() }
    }

    private let files: [URL]

    init(request: EditorRequest, memory: EditorMemory) {
        files = request.files
        let category = request.files.first.flatMap { FormatRegistry.builtIn.format(for: $0)?.category } ?? .image
        model = ResizeModel(category: category, sources: [], remembered: memory.resize[category.rawValue],
                            fileCount: request.files.count)
    }

    var confirmTitle: String { model.confirmTitle }

    var blocker: String? {
        if loadFailed { return "The file may be damaged" }
        guard isLoaded else { return "Reading the file\u{2026}" }
        return model.blocker
    }

    var note: String? { model.note }

    /// Every file's upright size: the fields follow the first, and "It's already that size" needs them all. A later
    /// file that can't be read is left to its job, which says why.
    func load() async {
        var sizes: [(width: Int, height: Int)] = []
        for (index, file) in files.enumerated() {
            // A closed panel stops reading a batch.
            guard !Task.isCancelled else { return }
            guard let size = await EditorMedia.picture(of: file)?.size else {
                guard index > 0 else {
                    if !Task.isCancelled { loadFailed = true }
                    return
                }
                continue
            }
            sizes.append((width: Int(size.width.rounded()), height: Int(size.height.rounded())))
        }
        guard !Task.isCancelled else { return }
        model.update(sources: sizes)
        isLoaded = true
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.edit = model.spec.map(EditSpec.resize)
        return options
    }

    func remember(into memory: inout EditorMemory) {
        guard let spec = model.spec else { return }
        memory.resize[model.category.rawValue] = spec
    }

    func makeContent() -> AnyView {
        AnyView(ResizeEditorView(session: self))
    }
}

/// The lock between the fields, as VoiceOver says it: "Keep proportions, on".
enum ResizeLock {
    static let label = "Keep proportions"

    static func value(locked: Bool) -> String { locked ? "on" : "off" }

    static func symbol(locked: Bool) -> String { locked ? "lock" : "lock.open" }
}

struct ResizeEditorView: View {
    @ObservedObject var session: ResizeSession
    @FocusState private var widthFocused: Bool
    @Environment(\.editorConfirm) private var confirm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                field("Width", text: Binding(get: { session.model.widthText }, set: { session.model.typeWidth($0) }))
                    .focused($widthFocused)
                Button {
                    session.model.toggleLock()
                } label: {
                    Image(systemName: ResizeLock.symbol(locked: session.model.isLocked))
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(ResizeLock.label)
                .accessibilityLabel(ResizeLock.label)
                .accessibilityValue(ResizeLock.value(locked: session.model.isLocked))
                field("Height", text: Binding(get: { session.model.heightText }, set: { session.model.typeHeight($0) }))
                Text("pixels")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(session.model.chips, id: \.self) { chip in
                    Button(chip.title) { session.model.choose(chip) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(chip.spokenTitle)
                }
            }
            Text(session.model.sourceLabel.isEmpty ? " " : session.model.sourceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(session.loadFailed)
        .focusedInPanel($widthFocused)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(title)
                // The field says it.
                .accessibilityHidden(true)
            // No placeholder: the title beside the field already says it.
            TextField(title, text: text, prompt: Text(""))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onSubmit { confirm() }
                .accessibilityLabel("\(title) in pixels")
        }
    }
}
