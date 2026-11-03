import Foundation
import PomeloCore

/// Writes the smallest SpreadsheetML package Excel, Numbers and Sheets open: one sheet per table, text as inline
/// strings, plain decimal numbers as numbers. No cell is ever a formula, so a scanned `=1+1` stays text.
public enum XLSXWriter {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static let bsdtar = URL(filePath: "/usr/bin/bsdtar")
    /// Excel refuses a cell with more characters (UTF-16 units) than this.
    static let maxCellCharacters = 32_767

    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// `sheets[i]` is the rows of the sheet called `sheetNames[i]` ("Table i+1" without one; Excel's name rules are
    /// the caller's) and `merges[i]`, when given, the spans to merge in it (the text sits in each span's top-left
    /// cell). `decimalComma` reads cells as `CSVReader.numberValue` does for a comma-decimal file. The package is built
    /// next to `url` in a folder of its own, zipped to `url` with the system's bsdtar and listed back before the
    /// folder is removed.
    public static func write(
        sheets: [[[String]]], merges: [[RecognizedDocument.TableMerge]] = [], sheetNames: [String]? = nil,
        decimalComma: Bool = false, to url: URL, runner: ProcessRunner = ProcessRunner(timeout: .seconds(120))
    ) async throws {
        try await write(
            sheets: sheets, merges: merges, sheetNames: sheetNames, decimalComma: decimalComma, to: url, runner: runner,
            bsdtar: bsdtar)
    }

    /// Tests run stand-ins for the archiver.
    static func write(
        sheets: [[[String]]], merges: [[RecognizedDocument.TableMerge]] = [], sheetNames: [String]? = nil,
        decimalComma: Bool = false, to url: URL, runner: ProcessRunner = ProcessRunner(timeout: .seconds(120)),
        bsdtar: URL
    ) async throws {
        guard !sheets.isEmpty else { throw Failure("a workbook needs at least one sheet") }
        try await zipPackage(
            parts(for: sheets, merges: merges, sheetNames: sheetNames, decimalComma: decimalComma), to: url,
            folderPrefix: "xlsx", noun: "workbook", runner: runner, bsdtar: bsdtar)
    }

    /// Writes `parts` into a folder of its own next to `url`, zips them to `url` and lists the archive back before
    /// the folder is removed; `DOCXWriter` builds its package the same way.
    static func zipPackage(
        _ parts: [(name: String, text: String)], to url: URL, folderPrefix: String, noun: String, runner: ProcessRunner,
        bsdtar: URL
    ) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("\(url.lastPathComponent) already exists") }
        let folder = url.deletingLastPathComponent().appending(
            path: "\(folderPrefix)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            for (name, text) in parts {
                let file = folder.appending(path: name, directoryHint: .notDirectory)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
        } catch {
            throw Failure("cannot write the \(noun) parts")
        }
        let names = parts.map(\.name)
        do {
            // `[Content_Types].xml` first, as Office writes it.
            _ = try await runner.run(
                executable: bsdtar, arguments: ["-c", "--format", "zip", "-f", url.path, "-C", folder.path] + names)
            let listing = try await runner.run(executable: bsdtar, arguments: ["-t", "-f", url.path])
            let listed = Set(listing.stdout.split(separator: "\n").map(String.init))
            guard listed == Set(names) else { throw Failure("the \(noun) does not read back") }
        } catch let error as ProcessRunnerError {
            try? FileManager.default.removeItem(at: url)
            throw failure(error)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func failure(_ error: ProcessRunnerError) -> Failure {
        switch error {
        case .nonZeroExit(let code, let tail):
            let text = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            return Failure(text.isEmpty ? "bsdtar exited with code \(code)" : text)
        case .timedOut: return Failure("bsdtar timed out")
        case .launchFailed(let code): return Failure("could not launch bsdtar: \(String(cString: strerror(code)))")
        }
    }

    // MARK: Parts

    static func parts(
        for sheets: [[[String]]], merges: [[RecognizedDocument.TableMerge]] = [], sheetNames: [String]? = nil,
        decimalComma: Bool = false
    ) -> [(name: String, text: String)] {
        let numbers = sheets.indices.map { $0 + 1 }
        var contentTypes = header
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for number in numbers {
            contentTypes += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        contentTypes += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>"

        let rootRelationships = header + "<Relationships xmlns=\"\(packageRelationships)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relationshipsNamespace)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

        let workbook = header + "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipsNamespace)\"><sheets>"
            + numbers.map { number in
                let name = sheetNames.flatMap { $0.indices.contains(number - 1) ? $0[number - 1] : nil } ?? "Table \(number)"
                return "<sheet name=\"\(escaped(name))\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            }.joined()
            + "</sheets></workbook>"

        let workbookRelationships = header + "<Relationships xmlns=\"\(packageRelationships)\">"
            + numbers.map {
                "<Relationship Id=\"rId\($0)\" Type=\"\(relationshipsNamespace)/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
            }.joined()
            + "<Relationship Id=\"rId\(numbers.count + 1)\" Type=\"\(relationshipsNamespace)/styles\" Target=\"styles.xml\"/></Relationships>"

        let styles = header + "<styleSheet xmlns=\"\(mainNamespace)\">"
            + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"

        return [
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rootRelationships), ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", workbookRelationships), ("xl/styles.xml", styles),
        ] + sheets.enumerated().map { ("xl/worksheets/sheet\($0.offset + 1).xml", sheetXML($0.element, merges: $0.offset < merges.count ? merges[$0.offset] : [], decimalComma: decimalComma)) }
    }

    static func sheetXML(
        _ rows: [[String]], merges: [RecognizedDocument.TableMerge] = [], decimalComma: Bool = false
    ) -> String {
        var xml = header + "<worksheet xmlns=\"\(mainNamespace)\"><sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            var cells = ""
            for (column, value) in row.enumerated() where !value.isEmpty {
                let reference = "\(columnName(column))\(rowIndex + 1)"
                if let number = CSVReader.numberValue(value, decimalComma: decimalComma) {
                    cells += "<c r=\"\(reference)\"><v>\(number)</v></c>"
                } else {
                    cells += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped(value))</t></is></c>"
                }
            }
            if !cells.isEmpty { xml += "<row r=\"\(rowIndex + 1)\">\(cells)</row>" }
        }
        xml += "</sheetData>"
        if !merges.isEmpty {
            xml += "<mergeCells count=\"\(merges.count)\">"
                + merges.map { "<mergeCell ref=\"\(reference(of: $0))\"/>" }.joined() + "</mergeCells>"
        }
        return xml + "</worksheet>"
    }

    /// `B1:C1` for a span of two columns whose top-left cell is B1.
    static func reference(of merge: RecognizedDocument.TableMerge) -> String {
        let first = "\(columnName(merge.column))\(merge.row + 1)"
        let last = "\(columnName(merge.column + merge.columnSpan - 1))\(merge.row + merge.rowSpan)"
        return "\(first):\(last)"
    }

    /// 0 is A, 25 is Z, 26 is AA.
    static func columnName(_ index: Int) -> String {
        var name = ""
        var rest = index
        repeat {
            name = String(UnicodeScalar(UInt8(65 + rest % 26))) + name
            rest = rest / 26 - 1
        } while rest >= 0
        return name
    }

    /// P165: a plain decimal, and no more than Excel keeps exactly; `CSVReader` holds the rule.
    static func isNumber(_ text: String) -> Bool { CSVReader.isPlainDecimal(text) }

    /// XML 1.0 text: the five markup characters escaped, characters XML forbids dropped, and no more than a cell may
    /// hold (a Word paragraph passes `Int.max`).
    static func escaped(_ text: String, maxUnits: Int = maxCellCharacters) -> String {
        var out = ""
        var units = 0
        for scalar in text.unicodeScalars {
            units += scalar.utf16.count
            if units > maxUnits { break }
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default: out.unicodeScalars.append(scalar)
                }
            default: break
            }
        }
        return out
    }
}
