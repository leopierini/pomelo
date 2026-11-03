import Foundation

/// One conversion the edges run performs with the CLI, and what its output must be.
public struct EvalCase: Codable, Equatable, Sendable {
    public var name: String
    /// A file of the corpus.
    public var input: String
    /// More corpus files after `input`, for a tool that combines several (Merge PDFs).
    public var moreInputs: [String]?
    public var to: String?
    public var preset: String?
    /// A JSON object handed to `pomelo convert --options` (an editor's edit, a size target).
    public var options: JSONValue?
    /// Executables, or `engine:<id>` engines, the case needs (see `Installed.has`); the case is skipped when one is
    /// missing.
    public var requires: [String]?
    /// Unmeasured runs before the measured one, for a case whose first run on a Mac pays a one-off cost (Vision
    /// compiles its text model on first use, which took 25 s).
    public var warmups: Int?
    public var expect: Expect

    public struct Expect: Codable, Equatable, Sendable {
        public var opens: Bool
        public var width: Int?
        public var height: Int?
        /// Checked within 0.15 s.
        public var durationSeconds: Double?
        public var frames: Int?
        /// A video's exact frame count (`OutputCheck.frameCount`), for a case that keeps duration and frame rate.
        public var frameCount: Int?
        public var pages: Int?
        public var audioChannels: Int?
        /// The least PSNR (dB) of the output against the input, both images.
        public var psnrMinDB: Double?
        /// The least SSIM of the output against the input (images, or the first frames of videos).
        public var ssimMin: Double?
        public var folderItems: Int?
        /// Text the output (a text file) must contain.
        public var textContains: String?
        /// Text the output (a text file) must start with.
        public var textStartsWith: String?
        /// The output (an xlsx workbook) has this many sheets: `OutputCheck` unzips it and counts them.
        public var xlsxSheets: Int?
        /// Top-level fields the output (a JSON file) must have, with these values; a number matches within 1e-9.
        public var jsonFields: [String: JSONValue]?
        /// The output (an image) has at least one transparent pixel.
        public var hasTransparency: Bool?
        /// The output is at most this many bytes.
        public var maxBytes: Int64?
        /// The output (an image) passes `RedactionCheck`: nothing but pixels.
        public var noMetadata: Bool?
        /// Every output carries Pomelo's mark (§3.4 rule 10), or none does.
        public var marked: Bool?
        /// The output's long side over its short side, so a portrait output checks as a landscape one does (R1).
        public var aspectRatio: AspectRatio?
        /// The output is at most this many pixels wide.
        public var maxWidth: Int?
        /// The output is at most this many pixels high.
        public var maxHeight: Int?
        /// Text Vision reads in the output (an image), ignoring case.
        public var imageTextContains: String?

        public struct AspectRatio: Codable, Equatable, Sendable {
            public var value: Double
            public var tolerance: Double
        }

        public init(
            opens: Bool = true, width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil,
            frames: Int? = nil, frameCount: Int? = nil, pages: Int? = nil, audioChannels: Int? = nil,
            psnrMinDB: Double? = nil, ssimMin: Double? = nil, folderItems: Int? = nil, textContains: String? = nil, textStartsWith: String? = nil,
            xlsxSheets: Int? = nil, jsonFields: [String: JSONValue]? = nil, hasTransparency: Bool? = nil,
            maxBytes: Int64? = nil, noMetadata: Bool? = nil, marked: Bool? = nil, aspectRatio: AspectRatio? = nil,
            maxWidth: Int? = nil, maxHeight: Int? = nil, imageTextContains: String? = nil
        ) {
            self.opens = opens
            self.width = width
            self.height = height
            self.durationSeconds = durationSeconds
            self.frames = frames
            self.frameCount = frameCount
            self.pages = pages
            self.audioChannels = audioChannels
            self.psnrMinDB = psnrMinDB
            self.ssimMin = ssimMin
            self.folderItems = folderItems
            self.textContains = textContains
            self.textStartsWith = textStartsWith
            self.xlsxSheets = xlsxSheets
            self.jsonFields = jsonFields
            self.hasTransparency = hasTransparency
            self.maxBytes = maxBytes
            self.noMetadata = noMetadata
            self.marked = marked
            self.aspectRatio = aspectRatio
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.imageTextContains = imageTextContains
        }
    }

    public init(name: String, input: String, moreInputs: [String]? = nil, to: String? = nil, preset: String? = nil,
                options: JSONValue? = nil, requires: [String]? = nil, warmups: Int? = nil, expect: Expect) {
        self.name = name
        self.input = input
        self.moreInputs = moreInputs
        self.to = to
        self.preset = preset
        self.options = options
        self.requires = requires
        self.warmups = warmups
        self.expect = expect
    }

    public static func load(from url: URL) throws -> [EvalCase] {
        try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
    }
}

/// What one run of the harness measured. `metrics` are baselined numbers; `checks` are pass/fail facts that fail the
/// run whatever the baseline says; `skipped` names the cases that could not run on this Mac.
public struct EvalResults: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var detail: String

        public init(name: String, ok: Bool, detail: String = "") {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    public static let modeKey = "mode"

    public var date: String
    public var meta: [String: String]
    public var metrics: [String: Double]
    public var checks: [Check]
    public var skipped: [String]

    public init(date: String = "", meta: [String: String] = [:], metrics: [String: Double] = [:],
                checks: [Check] = [], skipped: [String] = []) {
        self.date = date
        self.meta = meta
        self.metrics = metrics
        self.checks = checks
        self.skipped = skipped
    }

    public static func load(from url: URL) throws -> EvalResults {
        try JSONDecoder().decode(EvalResults.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
