import Foundation

/// Workbooks built byte by byte (stored zip entries), so a test can declare any size or name, which no archiver writes.
enum XLSXFixture {
    struct Part {
        var name: String
        var data: Data
        /// What the headers claim, when it differs from the data.
        var declaredSize: UInt32?
        /// The unix mode in the central directory, which is how a zip says "symlink".
        var unixMode: UInt32?

        init(_ name: String, _ text: String, declaredSize: UInt32? = nil, unixMode: UInt32? = nil) {
            self.init(name, Data(text.utf8), declaredSize: declaredSize, unixMode: unixMode)
        }

        init(_ name: String, _ data: Data, declaredSize: UInt32? = nil, unixMode: UInt32? = nil) {
            self.name = name
            self.data = data
            self.declaredSize = declaredSize
            self.unixMode = unixMode
        }
    }

    struct Sheet {
        var name: String
        var cells: String
        var state: String?

        init(_ name: String, cells: String, state: String? = nil) {
            self.name = name
            self.cells = cells
            self.state = state
        }
    }

    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func worksheet(_ cells: String) -> String {
        "<?xml version=\"1.0\"?><worksheet xmlns=\"\(main)\"><sheetData>\(cells)</sheetData></worksheet>"
    }

    static func inline(_ reference: String, _ text: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }

    static func number(_ reference: String, _ text: String, style: Int? = nil) -> String {
        "<c r=\"\(reference)\"\(style.map { " s=\"\($0)\"" } ?? "")><v>\(text)</v></c>"
    }

    static func row(_ number: Int, _ cells: String) -> String { "<row r=\"\(number)\">\(cells)</row>" }

    static func sharedStrings(_ strings: [String]) -> String {
        "<?xml version=\"1.0\"?><sst xmlns=\"\(main)\">" + strings.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
    }

    /// Cell styles: index 0 general, 1 is built-in 14, 2 is a custom `dd/mm/yyyy`, 3 is built-in 22.
    static let datesStyles = """
        <?xml version="1.0"?><styleSheet xmlns="\(main)">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>\
        <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>\
        <cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="22"/></cellXfs>\
        </styleSheet>
        """

    static func parts(
        sheets: [Sheet], shared: [String]? = nil, styles: String? = nil, date1904: Bool = false
    ) -> [Part] {
        var workbook = "<?xml version=\"1.0\"?><workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\">"
        workbook += date1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>"
        workbook += "<sheets>"
        var rels = "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        var parts: [Part] = []
        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            workbook += "<sheet name=\"\(sheet.name)\" sheetId=\"\(number)\"\(sheet.state.map { " state=\"\($0)\"" } ?? "") r:id=\"rId\(number)\"/>"
            rels += "<Relationship Id=\"rId\(number)\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"
            parts.append(Part("xl/worksheets/sheet\(number).xml", worksheet(sheet.cells)))
        }
        workbook += "</sheets></workbook>"
        rels += "</Relationships>"
        parts.insert(Part("xl/workbook.xml", workbook), at: 0)
        parts.insert(Part("xl/_rels/workbook.xml.rels", rels), at: 1)
        if let shared { parts.append(Part("xl/sharedStrings.xml", sharedStrings(shared))) }
        if let styles { parts.append(Part("xl/styles.xml", styles)) }
        return parts
    }

    @discardableResult
    static func write(_ parts: [Part], to url: URL) throws -> URL {
        try zip(parts).write(to: url)
        return url
    }

    static func zip(_ parts: [Part]) -> Data {
        var archive = Data()
        var central = Data()
        for part in parts {
            let name = Data(part.name.utf8)
            let crc = crc32(part.data)
            let size = UInt32(part.data.count)
            let declared = part.declaredSize ?? size
            let offset = UInt32(archive.count)
            archive += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
            archive += le32(crc) + le32(declared) + le32(declared) + le16(UInt16(name.count)) + le16(0) + name + part.data
            let made: UInt16 = part.unixMode == nil ? 20 : 0x031E
            central += le32(0x0201_4B50) + le16(made) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21)
            central += le32(crc) + le32(declared) + le32(declared) + le16(UInt16(name.count)) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32((part.unixMode ?? 0) << 16) + le32(offset) + name
        }
        let directoryOffset = UInt32(archive.count)
        archive += central
        archive += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(parts.count)) + le16(UInt16(parts.count))
        archive += le32(UInt32(central.count)) + le32(directoryOffset) + le16(0)
        return archive
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }

    private static func le32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
