// Every string the Shelf shows or speaks (P32: no "·" or "—" as a separator).
import Foundation

public enum ShelfCopy {
    public static let shelf = "Shelf"
    public static let dropHere = "Drop files here"
    public static let dragHint = "Drag to copy. Hold Command to move."
    public static let movedToTrash = "Moved to the Trash"
    public static let cantBeFound = "Can't be found"
    public static let empty = "Empty"
    public static let close = "Close"
    public static let clearShelf = "Clear Shelf"
    public static let openWheel = "Open the Wheel"
    public static let quickLook = "Quick Look"
    public static let showInFinder = "Show in Finder"
    public static let copy = "Copy"
    public static let move = "Move"
    public static let remove = "Remove from Shelf"
    public static let tuckAway = "Tuck Away"
    public static let bringBack = "Bring Back"
    public static let expand = "Expand"
    public static let collapse = "Collapse"

    public static func fileCount(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// The tab, for VoiceOver (S22).
    public static func tab(_ count: Int) -> String {
        "\(shelf), \(fileCount(count))"
    }

    public static func added(_ names: [String]) -> String {
        names.count == 1 ? "Added \(names[0]) to the Shelf" : "Added \(fileCount(names.count)) to the Shelf"
    }

    public static func left(_ count: Int) -> String {
        "\(fileCount(count)) left the Shelf"
    }

    public static func became(_ old: String, _ new: String) -> String {
        "\(old) became \(new)"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
