// The editors (P27, P31): tools that need more input than a drop gives, so they open a small panel where the file
// was dropped instead of running. Each is a catalog tool (`ToolInfo.editor`) on the Tools page.
import Foundation

public enum EditorKind: String, Codable, Sendable, CaseIterable {
    case trim, crop, split, targetSize, redact, organizePages, resize, rotate
}
