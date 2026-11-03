// What is watched and what happens to a file that arrives. Settings keep these in the `settings.v1` blob.
import Foundation
import PomeloCore

/// What a watch folder does with each arrival: convert it, or run a tool that takes no input from the person.
public enum WatchAction: Codable, Sendable, Equatable {
    case convert(FormatID)
    case tool(String)

    private enum CodingKeys: String, CodingKey {
        case kind, format, tool
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "convert": self = .convert(try c.decode(FormatID.self, forKey: .format))
        case "tool": self = .tool(try c.decode(String.self, forKey: .tool))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .convert(let format):
            try c.encode("convert", forKey: .kind)
            try c.encode(format, forKey: .format)
        case .tool(let id):
            try c.encode("tool", forKey: .kind)
            try c.encode(id, forKey: .tool)
        }
    }
}

public struct WatchFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// What the pane shows, and where to look when `bookmark` can't be resolved.
    public var path: String
    /// A plain bookmark (Pomelo isn't sandboxed, so no security scope): it finds the folder again after a rename or move.
    public var bookmark: Data?
    public var action: WatchAction
    public var isEnabled: Bool

    public init(id: UUID = UUID(), path: String, bookmark: Data? = nil, action: WatchAction, isEnabled: Bool = true) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.action = action
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, bookmark, action, isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
        action = try c.decode(WatchAction.self, forKey: .action)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }
}
