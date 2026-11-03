import AppKit

/// A view that takes file drops, the wheel's and the Shelf's: entering it and moving over it ask
/// `dropOperation(for:)`, leaving it calls `dropLeft()`. Subclasses register `.fileURL` and perform the drop.
class FileDropView: NSView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(for: sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(for: sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropLeft() }

    func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation { [] }

    func dropLeft() {}

    /// Subclasses answer `hitTest` for the SwiftUI host they hold, to take drops and clicks, and VoiceOver would stop
    /// there: its hit test goes on into the host, whose elements are the ones to read.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // Accessibility asks on the main thread.
        let host: NSView? = MainActor.assumeIsolated {
            guard let window else { return nil }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            return subviews.last { !$0.isHidden && $0.frame.contains(local) }
        }
        return host?.accessibilityHitTest(point) ?? super.accessibilityHitTest(point)
    }
}

extension NSPasteboard {
    private static var fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }

    /// The file URLs on the pasteboard, in order; text, web links and file promises carry none.
    var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly) as? [URL]) ?? []
    }

    var hasFileURLs: Bool {
        canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly)
    }
}
