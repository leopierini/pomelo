import Foundation

/// What Extract data read off a receipt, invoice or similar document (P161), free of the model that read it, and its
/// JSON and CSV. `grounded(in:)` keeps only what the text shows: the model is told never to guess, and this makes sure.
public struct ExtractedData: Codable, Equatable, Sendable {
    public struct LineItem: Codable, Equatable, Sendable {
        public var name: String
        public var quantity: Double?
        public var amount: Double?

        public init(name: String, quantity: Double?, amount: Double?) {
            self.name = name
            self.quantity = quantity
            self.amount = amount
        }
    }

    /// What the document is ("receipt"): the one field that is a reading of the document rather than a copy of it.
    public var kind: String?
    public var issuer: String?
    /// ISO 8601, `YYYY-MM-DD`, once grounded; the model hands it over as printed ("12.10.2026", "3 Nov 2026") and
    /// `grounded(in:)` reads it, so the order of day and month is a rule, not the model's guess.
    public var date: String?
    public var total: Double?
    /// ISO 4217.
    public var currency: String?
    public var tax: Double?
    public var lineItems: [LineItem]?

    public init(
        kind: String? = nil, issuer: String? = nil, date: String? = nil, total: Double? = nil, currency: String? = nil,
        tax: Double? = nil, lineItems: [LineItem]? = nil
    ) {
        self.kind = kind
        self.issuer = issuer
        self.date = date
        self.total = total
        self.currency = currency
        self.tax = tax
        self.lineItems = lineItems
    }

    /// Anything beyond the kind.
    public var hasData: Bool {
        issuer != nil || date != nil || total != nil || currency != nil || tax != nil || lineItems != nil
    }

    // MARK: Grounding

    private static let maxKindLength = 80

    /// The fields `text` shows: names found in it (ignoring case, accents and spacing), amounts printed in it in any
    /// common notation, a printed date that reads as a real one, a currency whose code or sign is printed. A line item
    /// keeps its printed quantity and amount and is left out when it has neither.
    public func grounded(in text: String) -> ExtractedData {
        let printed = PrintedText(text)
        var result = ExtractedData()
        if let kind = kind.map(Self.oneLine), !kind.isEmpty, kind.count <= Self.maxKindLength { result.kind = kind }
        result.issuer = issuer.map(Self.oneLine).flatMap { printed.shows($0) ? $0 : nil }
        result.total = total.flatMap { printed.shows($0) ? $0 : nil }
        result.currency = currency.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.flatMap { printed.showsCurrency($0) ? $0 : nil }
        result.date = date.map(Self.oneLine).flatMap {
            printed.shows($0) ? PrintedDate.iso($0, slashOrder: PrintedDate.slashOrder(currency: result.currency)) : nil
        }
        result.tax = tax.flatMap { printed.shows($0) ? $0 : nil }
        let items = (lineItems ?? []).compactMap { item -> LineItem? in
            let name = Self.oneLine(item.name)
            guard printed.shows(name) else { return nil }
            let kept = LineItem(
                name: name, quantity: item.quantity.flatMap { printed.shows($0) ? $0 : nil },
                amount: item.amount.flatMap { printed.shows($0) ? $0 : nil })
            return kept.quantity == nil && kept.amount == nil ? nil : kept
        }
        result.lineItems = items.isEmpty ? nil : items
        return result
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Writing

    /// Pretty-printed with sorted keys; missing fields are left out.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// One header row and one row, the same columns whatever was found so many files' rows line up. Line items are in
    /// the JSON only.
    public func csv() -> Data {
        CSVWriter.write(rows: [
            ["kind", "issuer", "date", "total", "currency", "tax"],
            [kind ?? "", issuer ?? "", date ?? "", Self.number(total), currency ?? "", Self.number(tax)],
        ])
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}

/// The text of a document, read the ways `grounded(in:)` needs.
private struct PrintedText {
    private let folded: String
    /// Every number token read as a whole: with its last separator as the decimal point, and with no separator.
    private let amounts: [Double]
    /// Runs of letters, upper-cased, for currency codes and names.
    private let words: Set<String>
    private let raw: String

    private static let signs: [String: Set<String>] = [
        "€": ["EUR"], "£": ["GBP"], "¥": ["JPY", "CNY"], "₹": ["INR"], "₩": ["KRW"], "₺": ["TRY"], "₽": ["RUB"],
        "$": ["USD", "CAD", "AUD", "NZD", "HKD", "SGD", "MXN", "BRL", "TWD"],
    ]
    private static let currencyWords: [String: Set<String>] = [
        "EURO": ["EUR"], "EUROS": ["EUR"], "FR": ["CHF"], "SFR": ["CHF"], "KR": ["SEK", "NOK", "DKK"],
        "ZŁ": ["PLN"], "YEN": ["JPY"], "DOLLAR": ["USD"], "DOLLARS": ["USD"],
    ]

    init(_ text: String) {
        raw = text
        folded = Self.fold(text)
        var amounts: [Double] = []
        for token in Self.numberTokens(in: text) {
            let parts = token.split { !$0.isNumber }
            if let whole = Double(parts.joined()) { amounts.append(whole) }
            if parts.count > 1, let decimal = Double(parts.dropLast().joined() + "." + parts[parts.count - 1]) {
                amounts.append(decimal)
            }
        }
        self.amounts = amounts
        words = Set(text.uppercased().split { !$0.isLetter }.map(String.init))
    }

    func shows(_ name: String) -> Bool {
        let needle = Self.fold(name)
        return !needle.isEmpty && folded.contains(needle)
    }

    func shows(_ value: Double) -> Bool {
        amounts.contains { abs($0 - abs(value)) < 0.000_5 }
    }

    func showsCurrency(_ code: String) -> Bool {
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return false }
        if words.contains(code) { return true }
        if Self.currencyWords.contains(where: { words.contains($0.key) && $0.value.contains(code) }) { return true }
        return Self.signs.contains { raw.contains($0.key) && $0.value.contains(code) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A space groups thousands (`1 234,50`, French and Nordic, with U+00A0 or the U+202F macOS's formatter
    /// prints) only before exactly three digits, so `Qty 2 3.50` stays two numbers.
    private static let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]

    /// Digits with the separators a printed amount or date uses between them (`1.234,50`, `12.10.2026`, `1'200`,
    /// `1 234,50`). A token with a space also yields its space-separated pieces, in case they were two numbers.
    private static func numberTokens(in text: String) -> [Substring] {
        let separators: Set<Character> = [".", ",", "'", "\u{2019}"]
        func isDigit(_ index: String.Index) -> Bool { index < text.endIndex && text[index].isASCII && text[index].isNumber }
        func groupsThousands(_ space: String.Index) -> Bool {
            guard isDigit(text.index(before: space)) else { return false }
            var cursor = text.index(after: space)
            for _ in 0..<3 {
                guard isDigit(cursor) else { return false }
                cursor = text.index(after: cursor)
            }
            return !isDigit(cursor)
        }
        var tokens: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isASCII, text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var end = text.index(after: index)
            var cursor = end
            while cursor < text.endIndex,
                isDigit(cursor) || separators.contains(text[cursor]) || (spaces.contains(text[cursor]) && groupsThousands(cursor))
            {
                cursor = text.index(after: cursor)
                if text[text.index(before: cursor)].isNumber { end = cursor }
            }
            let token = text[start..<end]
            tokens.append(token)
            if token.contains(where: spaces.contains) { tokens += token.split(whereSeparator: spaces.contains) }
            index = cursor
        }
        return tokens
    }
}

/// A date as a document prints it, read as ISO 8601: year first (`2026-10-12`, `2026年10月12日`), day and month with
/// a month name in one of the model's languages (`3 novembre 2026`, `Oct 12, 26`), or as numbers. Numbers with dots
/// or dashes are day first (12.10.2026). With slashes a number above 12 settles the order; when both are 12 or less
/// `slashOrder` does, and without one (no currency to tell an American document) the date is left out.
enum PrintedDate {
    enum SlashOrder {
        case dayFirst, monthFirst, unknown
    }

    /// USD prints month first; Canada writes both orders; any other currency settles day first.
    static func slashOrder(currency: String?) -> SlashOrder {
        switch currency {
        case nil, "CAD": .unknown
        case "USD": .monthFirst
        default: .dayFirst
        }
    }

    static func iso(_ printed: String, slashOrder: SlashOrder) -> String? {
        guard let (numbers, month) = parts(of: printed) else { return nil }
        let date = if let month { named(month, numbers: numbers) } else { numeric(numbers, slashOrder: slashOrder) }
        guard let (year, monthNumber, day) = date else { return nil }
        let fullYear = year >= 100 ? year : (year < 70 ? 2000 + year : 1900 + year)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard DateComponents(year: fullYear, month: monthNumber, day: day).isValidDate(in: calendar) else { return nil }
        return String(format: "%04d-%02d-%02d", fullYear, monthNumber, day)
    }

    private typealias PrintedNumber = (value: Int, digits: Int, separator: Character?)
    private typealias Parts = (year: Int, month: Int, day: Int)

    /// The numbers of the text, each with the character after it, and its first month name. Nil when a run of digits
    /// is too long to be part of a date.
    private static func parts(of printed: String) -> (numbers: [PrintedNumber], month: Int?)? {
        let text = printed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var numbers: [PrintedNumber] = []
        var month: Int?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isASCII, character.isNumber {
                let run = text[index...].prefix { $0.isASCII && $0.isNumber }
                index = run.endIndex
                guard run.count <= 4, let value = Int(run) else { return nil }
                numbers.append((value, run.count, index < text.endIndex ? text[index] : nil))
            } else if character.isLetter {
                let run = text[index...].prefix(while: \.isLetter)
                index = run.endIndex
                if month == nil, let named = months[String(run)] { month = named }
            } else {
                index = text.index(after: index)
            }
        }
        return (numbers, month)
    }

    /// With a month name: a day and a year among the first two numbers, the four-digit one the year (`Oct 12, 2026`,
    /// `2026 12 ottobre`), else the second (`12 ott 26`).
    private static func named(_ month: Int, numbers: [PrintedNumber]) -> Parts? {
        guard numbers.count >= 2 else { return nil }
        let pair = numbers.prefix(2)
        guard let yearIndex = pair.lastIndex(where: { $0.digits == 4 }) ?? (pair.allSatisfy { $0.digits <= 2 } ? 1 : nil),
              pair[1 - yearIndex].digits <= 2 else { return nil }
        return (pair[yearIndex].value, month, pair[1 - yearIndex].value)
    }

    /// Numbers only: year first, else day and month in the order the separator and `slashOrder` settle.
    private static func numeric(_ numbers: [PrintedNumber], slashOrder: SlashOrder) -> Parts? {
        guard numbers.count >= 3 else { return nil }
        let (a, b, c) = (numbers[0], numbers[1], numbers[2])
        if a.digits == 4, b.digits <= 2, c.digits <= 2 { return (a.value, b.value, c.value) }
        guard a.digits <= 2, b.digits <= 2, c.digits == 4 || c.digits == 2 else { return nil }
        let isSlashed = a.separator == "/"
        if isSlashed, a.value <= 12, b.value <= 12, slashOrder == .unknown { return nil }
        var (day, month) = isSlashed && slashOrder == .monthFirst ? (b.value, a.value) : (a.value, b.value)
        if month > 12, day <= 12 { swap(&day, &month) }
        return (c.value, month, day)
    }

    /// Month names, long and short, of the languages the on-device model reads, folded as `iso` folds the text. A name
    /// two languages give different months is left out.
    private static let months: [String: Int] = {
        var table: [String: Int] = [:]
        var clashes: Set<String> = []
        for language in ["en", "de", "fr", "it", "es", "pt", "nl", "sv", "da", "nb", "tr"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language)
            let lists = [formatter.monthSymbols, formatter.shortMonthSymbols, formatter.standaloneMonthSymbols]
            for list in lists.compactMap({ $0 }) {
                for (offset, name) in list.enumerated() {
                    let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        .filter(\.isLetter)
                    guard !key.isEmpty else { continue }
                    if let known = table[key], known != offset + 1 { clashes.insert(key) }
                    table[key] = offset + 1
                }
            }
        }
        return table.filter { !clashes.contains($0.key) }
    }()
}
