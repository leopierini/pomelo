import AppIntents
import Foundation

struct RunPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Tool"
    static let description = IntentDescription(
        "Runs a Pomelo tool, such as Compress or Remove background, on files. The originals stay as they are."
    )
    /// Runs in the menu-bar app, launched in the background when needed.
    static let openAppWhenRun = false

    // `supportedContentTypes:` needs macOS 15; the identifiers say the same on 14.
    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Tool")
    var tool: ToolEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$tool) on \(\.$files)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let intents = AppEnvironment.shared.intents
        let toolID = tool.id
        return .result(value: try await intents.perform(on: files) { try await intents.run(toolID: toolID, on: $0) })
    }
}
