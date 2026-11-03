import CoreGraphics
import Foundation
import PomeloCore
import Vision

/// Vision's `RecognizeDocumentsRequest` behind the `DocumentRecognizing` seam (macOS 26).
@available(macOS 26, *)
struct SystemDocumentRecognizer: DocumentRecognizing {
    /// The default (1/32 of the page) lost a lone digit in a table cell; a 200 dpi render has no text this small to
    /// ignore, so the fraction is lowered rather than given up on.
    static let minimumTextHeightFraction: Float = 0.005

    func recognize(_ page: CGImage) async throws -> [RecognizedDocument.Block] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.minimumTextHeightFraction = Self.minimumTextHeightFraction
        let observations = try await request.perform(on: page)
        return observations.flatMap { Self.blocks(of: $0.document) }
    }

    private static func blocks(of container: DocumentObservation.Container) -> [RecognizedDocument.Block] {
        DocumentBlocks.assemble(
            paragraphs: container.paragraphs.map { (text: $0.transcript, box: unitBox($0)) },
            lists: container.lists.map { list in
                (items: list.items.map { $0.itemString.trimmingCharacters(in: .whitespacesAndNewlines) }, box: unitBox(list))
            },
            tables: container.tables.map { table in
                // A merged cell is listed once, with the ranges it covers: place it by them, not by its position in
                // its row, or every cell after it moves one column left.
                let cells = table.rows.joined().map {
                    DocumentBlocks.Cell(
                        text: $0.content.text.transcript, rows: $0.rowRange.lowerBound...$0.rowRange.upperBound,
                        columns: $0.columnRange.lowerBound...$0.columnRange.upperBound)
                }
                return (cells: cells, box: unitBox(table))
            }
        )
    }

    private static func unitBox(_ block: some BoundingRegionProviding) -> UnitRect {
        let box = block.boundingRegion.normalizedPath.boundingBox
        return DocumentBlocks.unitRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
    }
}

/// Vision's output as `RecognizedDocument` blocks, free of the framework so it runs on any Mac.
enum DocumentBlocks {
    /// Vision's boxes have their origin at the lower left; a `UnitRect` has it at the top left.
    static func unitRect(x: Double, y: Double, width: Double, height: Double) -> UnitRect {
        UnitRect(x: x, y: 1 - y - height, width: width, height: height)
    }

    /// `paragraphs` repeats every list item and every table cell as a paragraph of its own, so a paragraph whose
    /// centre lies inside a list or a table is that block's text, not a block of its own.
    static func assemble(
        paragraphs: [(text: String, box: UnitRect)], lists: [(items: [String], box: UnitRect)],
        tables: [(cells: [Cell], box: UnitRect)]
    ) -> [RecognizedDocument.Block] {
        let inside = lists.map(\.box) + tables.map(\.box)
        let loose = paragraphs.filter { paragraph in
            let centre = (x: paragraph.box.x + paragraph.box.width / 2, y: paragraph.box.y + paragraph.box.height / 2)
            return !inside.contains { box in
                centre.x >= box.x && centre.x <= box.x + box.width && centre.y >= box.y && centre.y <= box.y + box.height
            }
        }
        return loose.map { .init(.paragraph($0.text), box: $0.box) }
            + lists.map { .init(.list($0.items), box: $0.box) }
            + tables.map {
                let grid = grid(of: $0.cells)
                return .init(.table(grid.rows), box: $0.box, merges: grid.merges)
            }
    }

    /// One cell of a Vision table with the rows and columns it covers (zero-based, a merged cell covers several).
    struct Cell: Equatable {
        var text: String
        var rows: ClosedRange<Int>
        var columns: ClosedRange<Int>
    }

    /// Cells beyond this are not Vision's idea of a table; they would only make a huge empty grid.
    private static let maxIndex = 10_000

    /// The table as a grid: each cell's text at the top-left position of its ranges, the other positions it covers
    /// empty, and one merge for every cell that covers more than one position.
    static func grid(of cells: [Cell]) -> (rows: [[String]], merges: [RecognizedDocument.TableMerge]) {
        let usable = cells.filter { $0.rows.lowerBound >= 0 && $0.columns.lowerBound >= 0 && $0.rows.upperBound <= maxIndex && $0.columns.upperBound <= maxIndex }
        let height = (usable.map(\.rows.upperBound).max() ?? -1) + 1
        let width = (usable.map(\.columns.upperBound).max() ?? -1) + 1
        var rows = Array(repeating: Array(repeating: "", count: width), count: height)
        var merges: [RecognizedDocument.TableMerge] = []
        for cell in usable {
            rows[cell.rows.lowerBound][cell.columns.lowerBound] = cell.text
            let merge = RecognizedDocument.TableMerge(
                row: cell.rows.lowerBound, column: cell.columns.lowerBound, rowSpan: cell.rows.count, columnSpan: cell.columns.count)
            if (merge.rowSpan > 1 || merge.columnSpan > 1), !merges.contains(merge) { merges.append(merge) }
        }
        return (rows, merges)
    }
}
