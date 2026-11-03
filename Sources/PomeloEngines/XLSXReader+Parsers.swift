import Foundation

extension XLSXReader {
    /// A streaming `XMLParser` delegate that tracks the element path and stops, with a `failure`, on anything a
    /// workbook never needs: a DTD (entity declarations, the way a billion-laughs file starts), too deep a nesting,
    /// more text than its budget.
    class XLSXXMLDelegate: NSObject, XMLParserDelegate {
        private(set) var failure: Failure?
        private(set) var wasCancelled = false
        /// The names of the open elements, without a namespace prefix, outermost first.
        private(set) var path: [String] = []
        var characterBudget = Int.max
        private(set) var characters = 0
        private weak var parser: XMLParser?
        private var events = 0

        func attach(_ parser: XMLParser) {
            self.parser = parser
        }

        final func fail(_ failure: Failure) {
            guard self.failure == nil else { return }
            self.failure = failure
            parser?.abortParsing()
        }

        /// Counts text against the budget; false once it is over.
        final func spend(_ count: Int) -> Bool {
            characters += count
            if characters > characterBudget {
                fail(.tooLarge)
                return false
            }
            return true
        }

        func elementStarted(_ name: String, _ attributes: [String: String]) {}
        func elementEnded(_ name: String) {}
        func text(_ string: String) {}

        final func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            events += 1
            if events & 0xFFF == 0, Task.isCancelled {
                wasCancelled = true
                parser.abortParsing()
                return
            }
            guard path.count < XLSXReader.maxXMLDepth else { return fail(.damaged) }
            let name = Self.localName(elementName)
            elementStarted(name, attributeDict)
            path.append(name)
        }

        final func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
        ) {
            guard !path.isEmpty else { return }
            let name = path.removeLast()
            elementEnded(name)
        }

        final func parser(_ parser: XMLParser, foundCharacters string: String) {
            text(string)
        }

        final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text(String(decoding: CDATABlock, as: UTF8.self))
        }

        final func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(.damaged)
        }

        final func parser(
            _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?
        ) {
            fail(.damaged)
        }

        final func parser(
            _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
            systemID: String?, notationName: String?
        ) {
            fail(.damaged)
        }

        static func localName(_ qualified: String) -> String {
            qualified.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? qualified
        }

        /// An attribute by its local name, whatever namespace prefix it has (`r:id`).
        static func attribute(_ local: String, in attributes: [String: String], prefixed: Bool = false) -> String? {
            for (key, value) in attributes where localName(key) == local && key.contains(":") == prefixed { return value }
            return nil
        }
    }

    // MARK: workbook.xml

    final class WorkbookParser: XLSXXMLDelegate {
        struct SheetRef {
            var name: String
            var relationshipID: String
            var isHidden: Bool
        }

        private(set) var sheets: [SheetRef] = []
        private(set) var date1904 = false

        override func elementStarted(_ name: String, _ attributes: [String: String]) {
            if name == "workbookPr", path == ["workbook"] {
                date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
            } else if name == "sheet", path == ["workbook", "sheets"] {
                guard sheets.count < XLSXReader.maxEntries else { return fail(.tooLarge) }
                guard let name = attributes["name"],
                      let id = Self.attribute("id", in: attributes, prefixed: true) else { return fail(.damaged) }
                sheets.append(SheetRef(
                    name: name, relationshipID: id, isHidden: ["hidden", "veryHidden"].contains(attributes["state"] ?? "")))
            }
        }
    }

    // MARK: workbook.xml.rels

    final class RelationshipsParser: XLSXXMLDelegate {
        struct Target {
            var type: String
            var target: String
            var isWorksheet: Bool { type.hasSuffix("/worksheet") }
        }

        private static let maxRelationships = 10_000
        private(set) var targets: [String: Target] = [:]

        override func elementStarted(_ name: String, _ attributes: [String: String]) {
            guard name == "Relationship", path == ["Relationships"], attributes["TargetMode"] != "External" else { return }
            guard targets.count < Self.maxRelationships else { return fail(.tooLarge) }
            guard let id = attributes["Id"], let type = attributes["Type"], let target = attributes["Target"] else {
                return fail(.damaged)
            }
            targets[id] = Target(type: type, target: target)
        }

        /// The target of the relationship of a type such as `sharedStrings` (the first by id, should a file have two).
        func partForType(_ suffix: String) -> String? {
            targets.filter { $0.value.type.hasSuffix("/" + suffix) }.min { $0.key < $1.key }?.value.target
        }
    }

    // MARK: styles.xml

    final class StylesParser: XLSXXMLDelegate {
        /// Per cell format (`cellXfs`, in order): whether its number format is a date.
        private(set) var isDate: [Bool] = []
        private static let maxFormats = 100_000
        private var customFormats: [Int: Bool] = [:]

        override func elementStarted(_ name: String, _ attributes: [String: String]) {
            if name == "numFmt", path == ["styleSheet", "numFmts"] {
                guard customFormats.count < Self.maxFormats else { return fail(.tooLarge) }
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                    customFormats[id] = XLSXReader.isDateFormat(code: code)
                }
            } else if name == "xf", path == ["styleSheet", "cellXfs"] {
                guard isDate.count < Self.maxFormats else { return fail(.tooLarge) }
                let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
                isDate.append(customFormats[id] ?? XLSXReader.isDateFormat(id: id, code: nil))
            }
        }
    }

    // MARK: sharedStrings.xml

    final class SharedStringsParser: XLSXXMLDelegate {
        private static let maxStrings = 10_000_000
        private(set) var strings: [String] = []
        private var current: String?
        private var collecting = false

        override func elementStarted(_ name: String, _ attributes: [String: String]) {
            if name == "si", path == ["sst"] {
                guard strings.count < Self.maxStrings else { return fail(.tooLarge) }
                current = ""
            } else if name == "t", path == ["sst", "si"] || path == ["sst", "si", "r"] {
                collecting = true
            }
        }

        override func elementEnded(_ name: String) {
            if name == "t" { collecting = false } else if name == "si", let current {
                strings.append(current)
                self.current = nil
            }
        }

        override func text(_ string: String) {
            guard collecting, spend(string.utf8.count) else { return }
            current?.append(string)
        }
    }

    // MARK: A sheet

    /// The cells of one sheet. Rows are filled only where a cell has text, and a cell may not widen the sheet
    /// beyond what is left of the cell budget (rows times width), so a far reference allocates nothing.
    final class SheetParser: XLSXXMLDelegate {
        private(set) var rows: [[String]] = []
        private(set) var cellsUsed = 0
        private let shared: [String]
        private let dateStyles: [Bool]
        private let date1904: Bool
        private let cellBudget: Int
        private var width = 0
        private var row = -1
        private var nextColumn = 0
        private var cell: Cell?

        private struct Cell {
            var row: Int
            var column: Int
            var type: String
            var isDate: Bool
            var value: String?
            var inline = ""
            var collecting = Collecting.nothing
        }

        private enum Collecting { case nothing, value, inline }

        init(shared: [String], dateStyles: [Bool], date1904: Bool, cellBudget: Int, characterBudget: Int) {
            self.shared = shared
            self.dateStyles = dateStyles
            self.date1904 = date1904
            self.cellBudget = cellBudget
            super.init()
            self.characterBudget = characterBudget
        }

        override func elementStarted(_ name: String, _ attributes: [String: String]) {
            switch (name, path.count) {
            case ("row", 2) where path == ["worksheet", "sheetData"]: startRow(attributes["r"])
            case ("c", 3) where path.last == "row" && path.first == "worksheet": startCell(attributes)
            case ("v", 4) where path.last == "c": cell?.collecting = .value
            case ("t", 5) where path.last == "is": cell?.collecting = .inline
            case ("t", 6) where path.last == "r" && path[4] == "is": cell?.collecting = .inline
            default: break
            }
        }

        override func elementEnded(_ name: String) {
            switch name {
            case "v", "t": cell?.collecting = .nothing
            case "c" where path.count == 3 && path.last == "row": finishCell()
            default: break
            }
        }

        override func text(_ string: String) {
            guard let collecting = cell?.collecting, collecting != .nothing, spend(string.utf8.count) else { return }
            // Taken out of `cell` while it grows, so the string is appended to in place.
            guard var current = cell else { return }
            cell = nil
            if collecting == .value {
                if current.value == nil { current.value = "" }
                current.value?.append(string)
            } else {
                current.inline.append(string)
            }
            cell = current
        }

        private func startRow(_ reference: String?) {
            if let reference {
                guard let number = Int(reference), number >= 1 else {
                    return fail(reference.utf8.allSatisfy { (0x30...0x39).contains($0) } && !reference.isEmpty ? .tooLarge : .damaged)
                }
                guard number <= XLSXReader.maxRows else { return fail(.tooLarge) }
                row = number - 1
            } else {
                row += 1
            }
            nextColumn = 0
        }

        private func startCell(_ attributes: [String: String]) {
            var target = (row: max(row, 0), column: nextColumn)
            if let reference = attributes["r"] {
                guard let parsed = parse(reference: reference) else { return }
                target = parsed
            }
            guard target.row < XLSXReader.maxRows, target.column < XLSXReader.maxColumns else { return fail(.tooLarge) }
            nextColumn = target.column + 1
            let style = attributes["s"].flatMap(Int.init)
            cell = Cell(
                row: target.row, column: target.column, type: attributes["t"] ?? "n",
                isDate: style.map { dateStyles.indices.contains($0) && dateStyles[$0] } ?? false)
        }

        /// `B12` as zero-based (row, column). A reference past Excel's grid is too large; anything not shaped like
        /// letters then digits is damaged.
        private func parse(reference: String) -> (row: Int, column: Int)? {
            var column = 0, letters = 0, digits = 0, number = 0
            for byte in reference.utf8 {
                switch byte {
                case 0x41...0x5A where digits == 0, 0x61...0x7A where digits == 0:
                    letters += 1
                    column = min(column * 26 + Int(byte & 0x1F), XLSXReader.maxColumns + 1)
                case 0x30...0x39 where letters > 0:
                    digits += 1
                    number = min(number * 10 + Int(byte - 0x30), XLSXReader.maxRows + 1)
                default:
                    fail(.damaged)
                    return nil
                }
            }
            guard letters > 0, digits > 0, number > 0 else {
                fail(.damaged)
                return nil
            }
            guard letters <= 3, column <= XLSXReader.maxColumns, number <= XLSXReader.maxRows else {
                fail(.tooLarge)
                return nil
            }
            return (number - 1, column - 1)
        }

        private func finishCell() {
            guard failure == nil, let finished = cell else { return }
            cell = nil
            guard let text = value(of: finished), !text.isEmpty, spend(text.utf8.count) else { return }
            place(text, row: finished.row, column: finished.column)
        }

        private func value(of cell: Cell) -> String? {
            switch cell.type {
            case "s":
                guard let raw = cell.value else { return nil }
                guard let index = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), shared.indices.contains(index) else {
                    fail(.damaged)
                    return nil
                }
                return shared[index]
            case "inlineStr": return cell.inline
            case "b":
                let raw = cell.value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return raw == "1" ? "TRUE" : raw == "0" ? "FALSE" : raw
            case "str", "e", "d": return cell.value
            default:
                guard let raw = cell.value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
                if cell.isDate, let serial = Double(raw), let date = XLSXReader.isoDate(serial: serial, date1904: date1904) {
                    return date
                }
                return XLSXReader.plainNumber(raw)
            }
        }

        private func place(_ text: String, row: Int, column: Int) {
            let newRows = max(rows.count, row + 1)
            let newWidth = max(width, column + 1)
            let (cells, overflow) = newRows.multipliedReportingOverflow(by: newWidth)
            guard !overflow, cells <= cellBudget else { return fail(.tooLarge) }
            while rows.count < newRows { rows.append([]) }
            if rows[row].count <= column {
                rows[row].append(contentsOf: repeatElement("", count: column + 1 - rows[row].count))
            }
            rows[row][column] = text
            width = newWidth
            cellsUsed = cells
        }
    }
}
