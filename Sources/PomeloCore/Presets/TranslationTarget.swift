import Foundation

/// Which language Translate writes, and the output-name suffix that goes with it (`subs-it.srt`). One rule for the
/// CLI, Shortcuts and the wheel.
public enum TranslationTarget {
    /// The BCP-47 identifier of the target: the setting, else the system's first preferred language, else English.
    public static func identifier(_ language: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        [language, preferred.first]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "en"
    }

    /// The target's shortest language identifier ("it" for it-IT, "pt-PT" for Portuguese as spoken in Portugal),
    /// limited to letters, digits and hyphens: the setting is free text and ends up in a file name.
    public static func suffix(_ language: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        let minimal = Locale.Language(identifier: identifier(language, preferred: preferred)).minimalIdentifier
        let safe = String(minimal.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        return safe.isEmpty ? "translated" : safe
    }

    /// The target as people read it ("Italian", "Portuguese (Portugal)"), for the tool's name on the wheel. Falls back
    /// to the suffix when the locale has no name for it.
    public static func name(
        _ language: String?, preferred: [String] = Locale.preferredLanguages, locale: Locale = .current
    ) -> String {
        let minimal = Locale.Language(identifier: identifier(language, preferred: preferred)).minimalIdentifier
        return locale.localizedString(forIdentifier: minimal) ?? suffix(language, preferred: preferred)
    }
}
