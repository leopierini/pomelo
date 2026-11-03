import AppIntents
import Foundation
import PomeloCore

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts files to another format. The originals stay as they are; the new files are saved next to them."
    )
    /// Runs in the menu-bar app, launched in the background when needed.
    static let openAppWhenRun = false

    // `supportedContentTypes:` needs macOS 15; the identifiers say the same on 14.
    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Format")
    var format: FormatEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let intents = AppEnvironment.shared.intents
        let target = FormatID(format.id)
        return .result(value: try await intents.perform(on: files) { try await intents.convert($0, to: target) })
    }
}
