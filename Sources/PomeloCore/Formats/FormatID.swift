import Foundation

/// Lowercase identifier of a file format, e.g. `png`, `jpg`, `docx`.
public struct FormatID: StringIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }
}

public enum FormatCategory: String, Codable, Sendable, CaseIterable {
    case image, video, audio, pdf, document, text, archive, data, subtitle, font, other
}

public struct FileFormat: Hashable, Sendable {
    public let id: FormatID
    public let displayName: String
    public let category: FormatCategory
    /// Lowercase extensions; the first is canonical, the rest are aliases.
    public let extensions: [String]
    public let utTypeIdentifier: String?

    public init(
        id: FormatID,
        displayName: String,
        category: FormatCategory,
        extensions: [String],
        utTypeIdentifier: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.extensions = extensions.map { $0.lowercased() }
        self.utTypeIdentifier = utTypeIdentifier
    }
}
