import Foundation

/// A string wrapped in its own type so a format id can't be passed where an engine id goes. Coded as the bare string.
public protocol StringIdentifier: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    var rawValue: String { get }
    init(_ rawValue: String)
}

extension StringIdentifier {
    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
