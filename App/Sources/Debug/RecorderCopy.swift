// DEBUG only. The PomeloTrace copy (the recorder, S34) runs beside the real Pomelo for days, and the system can reach
// it without the flag: an App Intent, an opened file, the Quick Action. It must run no job whatever launches it (S34.1).
#if DEBUG
import Foundation

enum RecorderCopy {
    static let bundleIdentifier = "io.github.pomelo-app.PomeloTrace"

    /// True for a `--record-drags` launch and for any launch of the PomeloTrace bundle.
    static func isActive(arguments: [String], bundleIdentifier: String?) -> Bool {
        arguments.dropFirst().contains(DragTraceRecorder.flag) || bundleIdentifier == Self.bundleIdentifier
    }

    static var isActive: Bool {
        isActive(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
#endif
