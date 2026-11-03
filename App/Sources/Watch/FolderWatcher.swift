// Tells when one folder's entries change, or when the folder itself goes away. A kernel event source on the folder:
// no polling, so a watched folder at rest costs no wakeups. It reports entries added, removed or renamed, not a
// file growing in place (a settle poll covers that while something is pending).
import Foundation

final class FolderWatcher: Sendable {
    private let source: any DispatchSourceFileSystemObject

    private static let queue = DispatchQueue(label: "io.github.pomelo-app.Pomelo.folder-watcher", qos: .utility)

    /// Throws when the folder can't be opened (missing, or not readable). `onChange` and `onGone` run on a private
    /// queue; after `onGone` the watcher reports nothing more that is useful and should be cancelled.
    init(folder: URL, onChange: @escaping @Sendable () -> Void, onGone: @escaping @Sendable () -> Void) throws {
        // O_EVTONLY: a descriptor for events only, which never stops the volume from being unmounted.
        let descriptor = open(folder.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: Self.queue
        )
        source.setEventHandler { [unowned source] in
            let events = source.data
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                onGone()
            } else if events.contains(.write) {
                onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Stops the events and closes the folder. Safe to call more than once.
    func cancel() {
        source.cancel()
    }
}
