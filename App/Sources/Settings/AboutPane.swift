import SwiftUI

struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    // No public API gives the app icon for a given appearance (NSWorkspace follows the system icon
                    // style, the catalog's AppIcon is the light fallback): AboutIcon is AppIcon.icon rendered per
                    // appearance by ictool, so it follows this window's dark mode.
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("Pomelo").font(.title2.bold())
                    Text(AppInfo.versionString(from: Bundle.main.infoDictionary))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("License", value: "MIT License")
                LabeledContent("Source") {
                    Link("GitHub", destination: AppInfo.repositoryURL)
                }
            }
            Section("Acknowledgements") {
                LabeledContent("Filee", value: "MIT License")
                LabeledContent("ShiftDrop", value: "MIT License")
            }
        }
    }
}
