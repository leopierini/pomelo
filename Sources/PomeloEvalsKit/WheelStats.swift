import Foundation

/// How long the wheel took to open, from the signpost export or the app's own clock.
public struct WheelMeasurement: Equatable, Sendable {
    public var p50Ms: Double
    public var p95Ms: Double
    public var count: Int

    public init(p50Ms: Double, p95Ms: Double, count: Int) {
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.count = count
    }

    public init(samplesMs: [Double]) {
        self.init(p50Ms: Percentile.of(0.5, in: samplesMs), p95Ms: Percentile.of(0.95, in: samplesMs), count: samplesMs.count)
    }

    /// The output of `Pomelo --eval-wheel-open`.
    public static func load(hook url: URL) throws -> WheelMeasurement {
        struct Hook: Decodable { var p50Ms: Double; var p95Ms: Double; var count: Int }
        let hook = try JSONDecoder().decode(Hook.self, from: Data(contentsOf: url))
        return WheelMeasurement(p50Ms: hook.p50Ms, p95Ms: hook.p95Ms, count: hook.count)
    }
}

/// The output of `Pomelo --eval-idle`.
public struct IdleMeasurement: Decodable, Equatable, Sendable {
    public var cpuPercent: Double
    public var footprintMB: Double
    public var wakeupsPerSecond: Double

    public static func load(_ url: URL) throws -> IdleMeasurement {
        try JSONDecoder().decode(IdleMeasurement.self, from: Data(contentsOf: url))
    }
}

extension WheelMeasurement {
    static let signpostSubsystem = "io.github.pomelo-app.Pomelo"
    static let signpostCategory = "wheel"
    static let signpostName = "open"

    /// The wheel's `open` interval from `xctrace export` of the `os-signpost` table.
    public static func load(signpostExport url: URL) throws -> WheelMeasurement {
        let samples = SignpostIntervals.durationsMs(
            exportData: try Data(contentsOf: url), subsystem: signpostSubsystem, category: signpostCategory,
            name: signpostName)
        guard !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return WheelMeasurement(samplesMs: samples)
    }
}

/// Pairs the Begin and End rows of an `os-signpost` table export into interval durations.
///
/// xctrace writes each distinct value once with an `id` and refers back to it with `ref` in later rows, so values
/// are resolved through a table. `beginInterval` without an explicit ID uses the exclusive ID for every interval,
/// so a Begin is matched to the next End of the same subsystem, category, name and ID.
enum SignpostIntervals {
    static func durationsMs(exportData: Data, subsystem: String, category: String, name: String) -> [Double] {
        let collector = RowCollector()
        let parser = XMLParser(data: exportData)
        parser.delegate = collector
        parser.parse()

        var open: [String: Double] = [:]
        var durations: [Double] = []
        for row in collector.rows {
            guard row["subsystem"] == subsystem, row["category"] == category, row["signpost-name"] == name,
                  let time = row["event-time"].flatMap(Double.init)
            else { continue }
            let key = row["os-signpost-identifier"] ?? ""
            switch row["event-type"] {
            case "Begin": open[key] = time
            case "End":
                if let began = open.removeValue(forKey: key) { durations.append((time - began) / 1_000_000) }
            default: break
            }
        }
        return durations
    }

    private static let columns: Set<String> = [
        "event-time", "event-type", "os-signpost-identifier", "signpost-name", "subsystem", "category",
    ]

    private final class RowCollector: NSObject, XMLParserDelegate {
        var rows: [[String: String]] = []
        private var values: [String: String] = [:]
        private var path: [String] = []
        private var row: [String: String]?
        private var column: (name: String, id: String?, fmt: String?)?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            defer { path.append(element) }
            if element == "row" {
                row = [:]
                return
            }
            guard path.last == "row", columns.contains(element) else { return }
            if let reference = attributes["ref"] {
                row?[element] = values[reference]
            } else {
                column = (element, attributes["id"], attributes["fmt"])
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if column != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            path.removeLast()
            if element == "row", let finished = row {
                rows.append(finished)
                row = nil
            }
            guard let current = column, current.name == element else { return }
            column = nil
            // The time is the raw nanoseconds; the other columns are read from their formatted value.
            let value = element == "event-time" ? text : (current.fmt ?? text)
            row?[element] = value
            if let id = current.id { values[id] = value }
        }
    }
}
