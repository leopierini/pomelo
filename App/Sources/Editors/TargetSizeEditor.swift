// The Compress to size editor (P27): "Under [ size ] [KB|MB]", chips for common sizes and what the files weigh now.
// The first editor, and the one that shows typing works in a panel that never activates Pomelo.
import AppKit
import PomeloCore
import PomeloUIModel
import SwiftUI

@MainActor
final class TargetSizeSession: EditorSession, ObservableObject {
    let title = "Compress to size"
    var onChange: (() -> Void)?

    /// Changing it redraws the field and tells the controller, since the blocker and note derive from it. The field
    /// writes its text back unchanged as it takes focus, mid-layout: that is no change, so nothing is sent.
    var model: TargetSizeModel {
        willSet { if newValue != model { objectWillChange.send() } }
        didSet { if model != oldValue { onChange?() } }
    }

    var confirmTitle: String { model.confirmTitle }
    var blocker: String? { model.blocker }
    var note: String? { model.note }

    private let files: [URL]

    init(request: EditorRequest, memory: EditorMemory, locale: Locale = .current) {
        files = request.files
        let category = request.files.first.flatMap { FormatRegistry.builtIn.format(for: $0)?.category } ?? .image
        // A stat per file is cheap enough for `open`; what needs the media (durations, sizes) comes in `load`.
        let sources = request.files.map { SourceSize(bytes: Self.fileSize($0)) }
        model = TargetSizeModel(category: category, sources: sources, remembered: memory.targetBytes[category.rawValue],
                                locale: locale)
    }

    func load() async {
        var sources: [SourceSize] = []
        for file in files {
            guard let info = try? await EditorMedia.info(of: file) else {
                sources.append(SourceSize(bytes: Self.fileSize(file)))
                continue
            }
            sources.append(SourceSize(
                bytes: info.bytes, durationSeconds: info.durationSeconds,
                width: info.encodedSize.map { Int($0.width.rounded()) }, height: info.encodedSize.map { Int($0.height.rounded()) },
                frameRate: info.frameRate, hasAudio: info.hasAudio
            ))
        }
        // An image's facts are its size, already known: an unchanged update would still count as a change (P78).
        guard !Task.isCancelled, sources != model.sources else { return }
        model.update(sources: sources)
    }

    func options(base: PresetOptions) -> PresetOptions {
        var options = base
        options.targetBytes = model.targetBytes
        return options
    }

    func nameSuffix(base: String?) -> String? {
        model.targetBytes.map(TargetSize.nameSuffix(bytes:)) ?? base
    }

    func remember(into memory: inout EditorMemory) {
        guard let bytes = model.targetBytes else { return }
        memory.targetBytes[model.category.rawValue] = bytes
    }

    func makeContent() -> AnyView {
        AnyView(TargetSizeEditorView(session: self))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
    }
}

struct TargetSizeEditorView: View {
    @ObservedObject var session: TargetSizeSession
    @FocusState private var fieldFocused: Bool
    @Environment(\.editorConfirm) private var confirm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Under")
                TextField("Size", text: $session.model.text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($fieldFocused)
                    .onSubmit { confirm() }
                    .accessibilityLabel("Size limit")
                Picker("Unit", selection: $session.model.unit) {
                    ForEach(SizeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Unit")
            }
            HStack(spacing: 6) {
                ForEach(session.model.chips, id: \.self) { bytes in
                    let label = TargetSize.label(bytes: bytes, locale: session.model.locale)
                    Button(label) { session.model.choose(bytes) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Under \(label)")
                }
            }
            Text(session.model.sourceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .focusedInPanel($fieldFocused)
    }
}
