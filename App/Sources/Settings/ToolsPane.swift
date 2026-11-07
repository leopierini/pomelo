import PomeloCore
import PomeloUIModel
import SwiftUI

/// The defaults of the tools that have settings and whether a tool replaces its original. What each wheel shows is
/// set in the wheel editor. Every change is stored at once through `ToolsPaneModel`.
struct ToolsPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var choices: ToolChoicesModel

    private var model: ToolsPaneModel { ToolsPaneModel(settings: store.settings) }

    static let wheelFooter = "Choose what each wheel shows in the Wheel pane."

    static let originalsFooter = """
        The result takes the original's place and the original goes to the Trash: after a conversion that keeps \
        the kind of file (HEIC to JPG, MOV to MP4), an editor (Crop, Trim, Resize, \u{2026}) or a tool (Compress, \
        Remove background, \u{2026}). Never when part of the file would be lost (a video's audio, a PSD's layers, an \
        animated GIF's frames, a document's export), for a merge, or when there are several results.
        """
    static let translationNote = """
        Translate writes into languages downloaded on this Mac. Download others in System Settings, General, \
        Language & Region.
        """

    static let speechNote = """
        A spoken language that isn't downloaded yet downloads the first time a file needs it.
        """

    var body: some View {
        let model = model
        Form {
            Section {
                ForEach(model.defaults) { entry in
                    Label(entry.name, systemImage: entry.info.symbol).fontWeight(.semibold)
                    if let reason = choices.unsupportedReasons[entry.info.id] {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(entry.info.settings.enumerated()), id: \.offset) { _, setting in
                            control(for: setting, of: entry, model: model)
                        }
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text(Self.wheelFooter)
            }
            Section {
                Toggle("Replace the original", isOn: Binding(
                    get: { store.settings.replaceOriginal },
                    set: { value in edit { $0.setReplaceOriginal(value) } }
                ))
            } header: {
                Text("Originals")
            } footer: {
                Text(Self.originalsFooter)
            }
            Section {
                Button("Restore Defaults") { edit { $0.restoreDefaults() } }
            }
        }
        .task { await choices.load() }
    }

    // MARK: - Controls

    @ViewBuilder
    private func control(for setting: ToolSetting, of entry: ToolsPaneModel.DefaultsEntry,
                         model: ToolsPaneModel) -> some View {
        let id = entry.info.id
        switch setting {
        case let .imageQuality(range, step):
            LabeledContent("Image quality") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { entry.options.quality },
                            set: { value in edit { $0.setQuality(value, for: id) } }
                        ),
                        in: range, step: step
                    )
                    .frame(width: 160)
                    .accessibilityLabel("Image quality for \(entry.name)")
                    Text(ToolsPaneModel.percentLabel(entry.options.quality))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
        case let .videoMaxHeight(heights):
            Picker("Video size", selection: Binding(
                get: { entry.options.videoMaxHeight ?? heights[0] },
                set: { value in edit { $0.setVideoMaxHeight(value, for: id) } }
            )) {
                ForEach(heights, id: \.self) { Text(ToolsPaneModel.videoSizeLabel($0)).tag($0) }
            }
            .accessibilityLabel("Video size for \(entry.name)")
        case let .audioBitrate(bitrates):
            Picker("Quality", selection: Binding(
                get: { entry.options.audioBitrate },
                set: { value in edit { $0.setAudioBitrate(value, for: id) } }
            )) {
                ForEach(bitrates, id: \.self) { Text(ToolsPaneModel.bitrateLabel($0)).tag($0) }
            }
            .accessibilityLabel("Quality for \(entry.name)")
        case let .speed(speeds):
            Picker("Speed", selection: Binding(
                get: { entry.options.speed ?? speeds[0] },
                set: { value in edit { $0.setSpeed(value, for: id) } }
            )) {
                ForEach(speeds, id: \.self) { Text(ToolsPaneModel.speedLabel($0)).tag($0) }
            }
            .accessibilityLabel("Speed for \(entry.name)")
        case let .loudness(levels):
            Picker("Loudness", selection: Binding(
                get: { entry.options.loudness },
                set: { value in edit { $0.setLoudness(value, for: id) } }
            )) {
                ForEach(ToolsPaneModel.loudnessChoices(levels), id: \.self) {
                    Text(ToolsPaneModel.loudnessLabel($0)).tag($0)
                }
            }
            .accessibilityLabel("Loudness for \(entry.name)")
        case .targetLanguage:
            VStack(alignment: .leading, spacing: 4) {
                LanguagePicker(
                    title: "Translate to", options: choices.languages[.translation] ?? [],
                    selection: Binding(
                        get: { entry.options.language },
                        set: { value in edit { $0.setLanguage(value, for: id) } }
                    ),
                    accessibilityLabel: "Language for \(entry.name)"
                )
                Text(Self.translationNote).font(.callout).foregroundStyle(.secondary)
            }
        case .spokenLanguage:
            VStack(alignment: .leading, spacing: 4) {
                LanguagePicker(
                    title: "Spoken language", options: choices.languages[.speech] ?? [],
                    selection: Binding(
                        get: { entry.options.language },
                        set: { value in edit { $0.setLanguage(value, for: id) } }
                    ),
                    accessibilityLabel: "Spoken language for \(entry.name)"
                )
                Text(Self.speechNote).font(.callout).foregroundStyle(.secondary)
            }
        case let .outputFormat(formats):
            Picker("Format", selection: Binding(
                get: { model.outputFormat(of: id) ?? formats[0] },
                set: { value in edit { $0.setOutputFormat(value, for: id) } }
            )) {
                ForEach(formats, id: \.self) { Text(ToolsPaneModel.formatLabel($0)).tag($0) }
            }
            .accessibilityLabel("Format for \(entry.name)")
        case let .cropShape(shapes):
            Picker("Shape", selection: Binding(
                get: { model.shape(of: id) },
                set: { value in edit { $0.setShape(value, for: id) } }
            )) {
                ForEach(shapes, id: \.self) { Text(ToolsPaneModel.shapeLabel($0)).tag($0) }
            }
            .accessibilityLabel("Shape for \(entry.name)")
        }
    }

    private func edit(_ change: (inout ToolsPaneModel) -> Void) {
        var model = model
        change(&model)
        if model.settings != store.settings { store.settings = model.settings }
    }
}
