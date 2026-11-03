import PomeloCore
import PomeloUIModel
import SwiftUI

/// Every wheel: each kind, with a disclosure of its formats. An orange dot marks a customized one (P179).
struct WheelListColumn: View {
    @ObservedObject var model: WheelEditorPaneModel
    @State private var expanded: Set<FormatCategory> = []

    var body: some View {
        List(selection: selection) {
            ForEach(WheelEditorPaneModel.kinds, id: \.self) { kind in
                let formats = model.formats(of: kind)
                if formats.isEmpty {
                    kindRow(kind)
                } else {
                    DisclosureGroup(isExpanded: isExpanded(kind)) {
                        ForEach(formats, id: \.id) { format in
                            row(format.displayName, customized: model.customized.contains(.format(format.id)))
                                .tag(WheelKey.format(format.id))
                                .listRowSeparator(.hidden)
                        }
                    } label: {
                        kindRow(kind)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .editorColumn()
        .onAppear { expanded = openKinds }
        .onChange(of: model.selection) { expanded.formUnion(openKinds) }
    }

    /// The kinds a customized format or the selected one hides in, so the list shows where they are.
    private var openKinds: Set<FormatCategory> {
        var kinds = Set(model.customized.compactMap { key -> FormatCategory? in
            guard case .format(let id) = key else { return nil }
            return FormatRegistry.builtIn.format(id: id)?.category
        })
        if case .format = model.selection { kinds.insert(model.kind) }
        return kinds
    }

    private var selection: Binding<WheelKey?> {
        Binding(get: { model.selection }, set: { key in if let key { model.select(key) } })
    }

    private func isExpanded(_ kind: FormatCategory) -> Binding<Bool> {
        Binding(get: { expanded.contains(kind) }, set: { isOpen in
            if isOpen { expanded.insert(kind) } else { expanded.remove(kind) }
        })
    }

    private func kindRow(_ kind: FormatCategory) -> some View {
        Label {
            row(kind.wheelTitle, customized: model.customized.contains(.kind(kind)))
        } icon: {
            Image(systemName: kind.listSymbol)
        }
        .tag(WheelKey.kind(kind))
        .listRowSeparator(.hidden)
    }

    private func row(_ title: String, customized: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if customized { CustomizedDot() }
        }
        .accessibilityElement(children: .combine)
    }
}

extension FormatCategory {
    fileprivate var listSymbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .text: "text.alignleft"
        case .subtitle: "captions.bubble"
        case .data: "tablecells"
        case .archive: "archivebox"
        case .font: "textformat"
        case .other: "doc"
        }
    }
}
