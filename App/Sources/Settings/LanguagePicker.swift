import SwiftUI

/// A language setting: "System language" (stored as nil) first, then the downloaded languages, then the others. A
/// stored language the list doesn't hold (not loaded yet, or set from the CLI's options) still shows as chosen.
struct LanguagePicker: View {
    let title: String
    let options: [LanguageOption]
    @Binding var selection: String?
    let accessibilityLabel: String

    var body: some View {
        let installed = options.filter(\.isInstalled)
        let others = options.filter { !$0.isInstalled }
        Picker(title, selection: $selection) {
            Text(ToolsPaneModel.systemLanguageLabel).tag(String?.none)
            if let selection, !options.contains(where: { $0.identifier == selection }) {
                Text(ToolChoicesModel.name(of: selection, in: .current)).tag(String?.some(selection))
            }
            // Without a downloaded one there is nothing to tell apart, so no headings.
            if installed.isEmpty {
                rows(others)
            } else {
                Section("Downloaded") { rows(installed) }
                if !others.isEmpty {
                    Section("Not downloaded") { rows(others) }
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func rows(_ options: [LanguageOption]) -> some View {
        ForEach(options) { Text($0.name).tag(String?.some($0.identifier)) }
    }
}
