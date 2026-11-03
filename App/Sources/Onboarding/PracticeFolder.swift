// The practice folder of the onboarding window: Pomelo's own copy of the sample photo, and the watcher that
// notices when the conversion's output lands next to it. No AppKit beyond Foundation.
import Foundation

/// Pomelo's scratch folder for one onboarding practice drag. It lives in the temporary directory and holds only
/// Pomelo's own copy of the sample, never a user file. Each run gets a new folder (P21), so nothing is ever removed:
/// the system clears the temporary directory on its own.
struct PracticeFolder: Sendable {
    static let sampleName = "Sample.heic"
    static let outputName = "Sample.png"

    let directory: URL

    /// `<temporary directory>/Pomelo Practice`, the parent of every run's folder.
    static let standardRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pomelo Practice", isDirectory: true)

    /// A new run's folder: a fresh UUID subfolder of `root`, so a run never meets what an earlier one left.
    static func fresh(in root: URL = standardRoot) -> PracticeFolder {
        PracticeFolder(directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    var sampleURL: URL { directory.appendingPathComponent(Self.sampleName) }
    var outputURL: URL { directory.appendingPathComponent(Self.outputName) }

    /// True once the PNG conversion of the sample exists. Outputs are published with an atomic rename, so the
    /// file is complete when it appears.
    var hasConvertedOutput: Bool {
        FileManager.default.fileExists(atPath: outputURL.path)
    }

    /// Creates the folder and copies the bundled sample in. Returns the copy's URL. The folder is new, so the
    /// checkmark reflects this run only.
    @discardableResult
    func prepare(copying bundledSample: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundledSample, to: sampleURL)
        return sampleURL
    }
}

/// Calls `onChange` on the main actor whenever an entry is added to or removed from the watched folder.
@MainActor
final class PracticeFolderWatcher {
    private var source: (any DispatchSourceFileSystemObject)?

    /// Returns nil when the folder cannot be opened for event notifications.
    init?(directory: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Stops watching and closes the descriptor. Safe to call more than once.
    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
