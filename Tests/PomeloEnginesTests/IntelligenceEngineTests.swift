import CoreGraphics
import Foundation
import ImageIO
import Testing
import PomeloCore
@testable import PomeloEngines
import PomeloTestSupport

@Suite struct IntelligenceEngineTests {
    private typealias Item = ExtractedData.LineItem

    static let hasModel: Bool = {
        if #available(macOS 26, *) { SystemLanguageModeling().status() == .available } else { false }
    }()

    private func runner(_ model: (any LanguageModeling)?) -> JobRunner {
        JobRunner(
            registry: EngineRegistry(engines: [IntelligenceEngine(model: model)], priority: ["intelligence"]),
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true })
        )
    }

    private func run(
        _ presetID: String, on source: URL, format: FormatID? = nil, model: (any LanguageModeling)?
    ) async throws -> FileResult {
        var preset = try #require(Preset.builtIns.first { $0.id == presetID })
        if let format { preset.target = format }
        let results = await runner(model).run(ConversionRequest.from(preset, inputs: [source]))
        return try #require(results.first)
    }

    private func succeeded(_ result: FileResult) throws -> URL {
        guard case .succeeded(_, let outputs, _) = result, outputs.count == 1 else { throw Fixtures.Failure("\(result)") }
        return outputs[0]
    }

    private func failure(_ result: FileResult) -> ConversionError? {
        if case .failed(_, let error) = result { error } else { nil }
    }

    /// The files in `dir` other than `source`.
    private func others(in dir: URL, than source: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != source.lastPathComponent }
    }

    private func textFile(_ text: String, named name: String = "notes.txt", in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A PDF whose pages are pictures of `texts`: no text layer, as a scanner makes them.
    private func scannedPDF(_ texts: [String], in dir: URL) throws -> URL {
        let url = dir.appending(path: "scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 450, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in texts {
            let png = try Fixtures.textImage(text, in: dir)
            defer { try? FileManager.default.removeItem(at: png) }
            let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private let receiptLines = Fixtures.receiptLines

    // MARK: Edges, availability, presets

    @Test func summarizeReadsDocumentsAndExtractDataReadsImagesAndPDFs() {
        let edges = IntelligenceEngine(model: FakeLanguageModel()).edges()
        func targets(_ operation: String) -> [FormatID: Set<FormatID>] {
            Dictionary(grouping: edges.filter { $0.operation == operation }, by: \.from).mapValues { Set($0.map(\.to)) }
        }
        #expect(targets("summarize") == Dictionary(
            uniqueKeysWithValues: ["pdf", "docx", "doc", "odt", "rtf", "html", "txt", "md"].map { (FormatID($0), Set<FormatID>(["md"])) }))
        #expect(targets("extract-data") == Dictionary(
            uniqueKeysWithValues: ["png", "jpg", "heic", "tiff", "pdf"].map { (FormatID($0), Set<FormatID>(["json", "csv"])) }))
        #expect(edges.count == 8 + 5 * 2)
        #expect(edges.allSatisfy { $0.engineID == "intelligence" && $0.cost == 10 && $0.flags == [.lossy] })
    }

    @Test func oneJobAtATimeForTheOneModel() {
        #expect(IntelligenceEngine(model: FakeLanguageModel()).maxConcurrentJobs == 1)
    }

    @Test func availabilityNamesWhatIsMissing() async {
        #expect(await IntelligenceEngine(model: nil).availability() == .unsupported(reason: "Needs macOS 26."))
        let cases: [(LanguageModelStatus, EngineAvailability)] = [
            (.available, .available(version: nil)),
            (.deviceNotEligible, .unsupported(reason: "Needs a Mac with Apple Intelligence.")),
            (.appleIntelligenceNotEnabled, .unsupported(reason: "Needs Apple Intelligence. Turn it on in System Settings.")),
            (.modelNotReady, .unsupported(reason: "Apple Intelligence is still getting ready. Try again in a few minutes.")),
        ]
        for (status, expected) in cases {
            #expect(await IntelligenceEngine(model: FakeLanguageModel(status: status)).availability() == expected)
        }
    }

    @Test func theRegistryAsksAgainOnRefresh() async {
        let model = FakeLanguageModel(status: .modelNotReady)
        let registry = EngineRegistry(engines: [IntelligenceEngine(model: model)], priority: ["intelligence"])
        #expect(await registry.unsupportedReasons()["intelligence"] != nil)
        model.setStatus(.available)
        await registry.refresh()
        #expect(await registry.unsupportedReasons().isEmpty)
    }

    /// A login launch finds the model still getting ready; once it is, the next job runs without a refresh, and the
    /// registry's answer (the wheel's next plan) follows. Below macOS 26 nothing is asked again.
    @Test func aModelThatBecomesReadyRunsTheNextJob() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("The council met on Monday.", in: dir)
        let model = FakeLanguageModel(status: .modelNotReady)
        let registry = EngineRegistry(engines: [IntelligenceEngine(model: model)], priority: ["intelligence"])
        let runner = JobRunner(registry: registry, destinations: DestinationResolver(downloadsFolder: dir, isWritable: { _ in true }))
        let request = ConversionRequest.from(try #require(Preset.builtIns.first { $0.id == "summarize" }), inputs: [source])

        let first = try #require(await runner.run(request).first)
        model.setStatus(.available)
        let second = try #require(await runner.run(request).first)

        #expect(failure(first) == .engineUnsupported(
            engine: "intelligence", reason: "Apple Intelligence is still getting ready. Try again in a few minutes."))
        #expect(try succeeded(second).lastPathComponent == "notes-summary.md")
        #expect(await registry.unsupportedReasons().isEmpty)
        #expect(IntelligenceEngine(model: model).availabilityIsVolatile)
        #expect(!IntelligenceEngine(model: nil).availabilityIsVolatile)
    }

    @Test func theDefaultRegistryHasTheEngine() async {
        let registry = DefaultEngines.makeRegistry(userPluginsFolder: nil)
        #expect(await registry.engine(id: "intelligence") != nil)
        #expect(DefaultEngines.priority.contains("intelligence"))
    }

    @Test func theTwoPresets() throws {
        let summarize = try #require(Preset.builtIns.first { $0.id == "summarize" })
        #expect(summarize.name == "Summarize" && summarize.target == "md" && summarize.nameSuffix == "summary")
        #expect(summarize.operation == "summarize" && summarize.categories == [.document, .text, .pdf])
        let data = try #require(Preset.builtIns.first { $0.id == "extract-data" })
        #expect(data.name == "Extract data" && data.target == "json" && data.nameSuffix == "data")
        #expect(data.operation == "extract-data" && data.categories == [.image, .pdf])
    }

    @Test func aModelThatIsNoLongerReadyFailsTheFileWithItsReason() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("Some text.", in: dir)
        let model = FakeLanguageModel()
        let registry = EngineRegistry(engines: [IntelligenceEngine(model: model)], priority: ["intelligence"])
        _ = await registry.planner()
        model.setStatus(.appleIntelligenceNotEnabled)
        let runner = JobRunner(
            registry: registry,
            destinations: DestinationResolver(downloadsFolder: FileManager.default.temporaryDirectory, isWritable: { _ in true }))
        let preset = try #require(Preset.builtIns.first { $0.id == "summarize" })
        let result = try #require(await runner.run(ConversionRequest.from(preset, inputs: [source])).first)
        #expect(failure(result) == .engineUnsupported(engine: "intelligence", reason: "Needs Apple Intelligence. Turn it on in System Settings."))
        #expect(model.calls.isEmpty)
        #expect(try others(in: dir, than: source).isEmpty)
    }

    // MARK: Summarize

    @Test func aShortTextIsOneCallWrittenAsTitleAndPoints() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("The council met on Monday.\n\nIt approved the budget.", in: dir)
        let model = FakeLanguageModel { _, _ in DocumentSummary(title: "Council meeting", points: ["Met on Monday.", "Approved the budget."]) }
        let output = try succeeded(try await run("summarize", on: source, model: model))
        #expect(output.lastPathComponent == "notes-summary.md")
        #expect(try String(contentsOf: output, encoding: .utf8) == "# Council meeting\n\n- Met on Monday.\n- Approved the budget.\n")
        #expect(model.calls.map(\.text) == ["The council met on Monday.\n\nIt approved the budget."])
        #expect(model.calls[0].instructions.contains("between 3 and 7 points"))
    }

    @Test func theModelsOwnMarkersAndLineBreaksAreTidiedAndAnEmptyTitleIsTheFileName() {
        let summary = DocumentSummary(title: "## A\ntitle", points: ["- first", "\u{2022} second\nline", "  ", "-5% costs"])
        #expect(IntelligenceEngine.markdown(summary, fallbackTitle: "notes") == "# A title\n\n- first\n- second line\n- -5% costs\n")
        #expect(IntelligenceEngine.markdown(DocumentSummary(title: " # ", points: ["x"]), fallbackTitle: "notes") == "# notes\n\n- x\n")
    }

    @Test func aLongTextIsSummarizedInChunksThenTheSummariesTogether() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let paragraphs = (1...12).map { "Paragraph \($0) " + Array(repeating: "word", count: 60).joined(separator: " ") }
        let source = try textFile(paragraphs.joined(separator: "\n\n"), in: dir)
        // The budget is the context less the fixed cost (100) and the answer's 1,000 tokens.
        let budget = 400
        let model = FakeLanguageModel(contextSize: 1_100 + budget, fixedCost: 100, bytesPerToken: 4) { text, index in
            text.hasPrefix(IntelligenceEngine.partsHeader)
                ? DocumentSummary(title: "Whole", points: ["All of it."])
                : DocumentSummary(title: "Part \(index)", points: ["Point \(index)."])
        }
        let output = try succeeded(try await run("summarize", on: source, model: model))
        #expect(try String(contentsOf: output, encoding: .utf8) == "# Whole\n\n- All of it.\n")

        let calls = model.calls
        let maps = calls.filter { !$0.text.hasPrefix(IntelligenceEngine.partsHeader) }
        #expect(maps.count > 1 && calls.last?.text.hasPrefix(IntelligenceEngine.partsHeader) == true)
        #expect(maps.allSatisfy { $0.text.utf8.count <= budget * 4 })
        // In order, and every paragraph read once.
        #expect(maps.map(\.text).joined(separator: "\n\n") == paragraphs.joined(separator: "\n\n"))
        let reduce = try #require(calls.last).text
        let positions = (0..<maps.count).map { reduce.range(of: "Part \($0)\n- Point \($0).")?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil } && positions == positions.sorted { $0! < $1! })
    }

    @Test func summariesTooManyForOneCallAreSummarizedInRounds() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile((1...40).map { "Paragraph \($0) " + String(repeating: "word ", count: 20) }.joined(separator: "\n\n"), in: dir)
        let model = FakeLanguageModel(contextSize: 1_100 + 60, fixedCost: 100, bytesPerToken: 4) { text, index in
            DocumentSummary(title: "S\(index)", points: [String(repeating: "x", count: 20)])
        }
        let output = try succeeded(try await run("summarize", on: source, model: model))
        let rounds = model.calls.filter { $0.text.hasPrefix(IntelligenceEngine.partsHeader) }
        #expect(rounds.count > 1)
        #expect(try String(contentsOf: output, encoding: .utf8).hasPrefix("# S\(model.calls.count - 1)\n"))
    }

    @Test func aChunkTheModelSaysIsTooLongIsTriedOnceMoreInHalves() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = "First sentence here. Second sentence here. Third sentence here. Fourth sentence here."
        let source = try textFile(text, in: dir)
        let model = FakeLanguageModel { text, index in
            if index == 0 { throw LanguageModelFailure.contextExceeded }
            return text.hasPrefix(IntelligenceEngine.partsHeader)
                ? DocumentSummary(title: "Whole", points: ["Done."]) : DocumentSummary(title: "Half", points: ["Half."])
        }
        let output = try succeeded(try await run("summarize", on: source, model: model))
        #expect(try String(contentsOf: output, encoding: .utf8) == "# Whole\n\n- Done.\n")
        let halves = model.calls.dropFirst().filter { !$0.text.hasPrefix(IntelligenceEngine.partsHeader) }
        #expect(halves.count >= 2 && halves.map(\.text).joined(separator: " ") == text)
    }

    @Test func tooLongEvenInHalvesIsCouldNotFinish() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("One sentence. Another sentence.", in: dir)
        let model = FakeLanguageModel { _, _ in throw LanguageModelFailure.contextExceeded }
        let result = try await run("summarize", on: source, model: model)
        #expect(failure(result) == .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence couldn't finish."))
        #expect(model.calls.count == 2)
        #expect(try others(in: dir, than: source).isEmpty)
    }

    @Test func aSummaryWithNoPointsIsCouldNotFinish() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("Some text to summarize.", in: dir)
        let model = FakeLanguageModel { _, _ in DocumentSummary(title: "Title", points: [" ", ""]) }
        #expect(failure(try await run("summarize", on: source, model: model)) == .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence couldn't finish."))
        #expect(try others(in: dir, than: source).isEmpty)
    }

    @Test func modelFailuresAreTheirSentences() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sentences = ["Kissa nukkuu sohvalla.", "Ulkona sataa tänään.", "Talo on lämmin ja kodikas."]
        let finnish = try textFile(sentences.joined(separator: " "), in: dir)
        let cases: [(LanguageModelFailure, ConversionError)] = [
            (.refused, .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence can't work with this document.")),
            (.unsupportedLanguage, .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence can't read Finnish yet.")),
            (.other, .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence couldn't finish.")),
            (.notReady, .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence is still getting ready. Try again in a few minutes.")),
        ]
        for (thrown, expected) in cases {
            let model = FakeLanguageModel { _, _ in throw thrown }
            #expect(failure(try await run("summarize", on: finnish, model: model)) == expected)
            let data = FakeLanguageModel(extractor: { _, _ in throw thrown })
            let pdf = try Fixtures.pdf(texts: sentences, in: dir)
            #expect(failure(try await run("extract-data", on: pdf, model: data)) == expected)
            try FileManager.default.removeItem(at: pdf)
        }
        #expect(try others(in: dir, than: finnish).isEmpty)
    }

    @Test func anUndeterminedLanguageIsNotNamed() {
        #expect(IntelligenceEngine.cantRead(nil) == "Apple Intelligence can't read this language yet.")
        #expect(IntelligenceEngine.cantRead(.japanese) == "Apple Intelligence can't read Japanese yet.")
    }

    @Test func theModelIsToldToWriteInTheDocumentsLanguage() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("Il gatto dorme sul divano mentre fuori piove. La casa è calda e accogliente.", in: dir)
        let model = FakeLanguageModel()
        _ = try succeeded(try await run("summarize", on: source, model: model))
        #expect(model.calls.first?.instructions.contains("Write in Italian, the language of the document.") == true)
    }

    /// A receipt is a few words: NaturalLanguage's best guess for this one is Romanian at 25 %, and the model, told to
    /// write Romanian, misspelt "receipt".
    @Test func aLanguageNaturalLanguageIsNotSureOfIsNotNamed() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile(receiptLines.joined(separator: "\n"), in: dir)
        let model = FakeLanguageModel { _, _ in throw LanguageModelFailure.unsupportedLanguage }
        let result = try await run("summarize", on: source, model: model)
        #expect(model.calls.first?.instructions.hasSuffix(" Write in the language of the document.") == true)
        #expect(failure(result) == .engineUnsupported(engine: "intelligence", reason: "Apple Intelligence can't read this language yet."))
    }

    @Test func aFileWithNoTextIsNoTextFound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile(" \n\t\n", in: dir)
        let model = FakeLanguageModel()
        #expect(failure(try await run("summarize", on: source, model: model)) == .notApplicable(reason: "No text found"))
        #expect(model.calls.isEmpty)
        #expect(try others(in: dir, than: source).isEmpty)
    }

    // MARK: Extract data

    @Test func extractDataWritesOnlyWhatIsPrintedAsSortedJSON() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(texts: ["COOP ZURICH", "12.10.2026", "Bread 3.50", "TOTAL 5.30"], in: dir)
        let model = FakeLanguageModel(extractor: { _, _ in
            ExtractedData(
                kind: "receipt", issuer: "COOP ZURICH", date: "12.10.2026", total: 5.3, currency: "USD", tax: 0.4,
                lineItems: [Item(name: "Bread", quantity: nil, amount: 3.5)])
        })
        let output = try succeeded(try await run("extract-data", on: pdf, model: model))
        #expect(output.lastPathComponent == "\(OutputNamer.stem(of: pdf))-data.json")
        let json = try String(contentsOf: output, encoding: .utf8)
        #expect(json.range(of: "\"date\"")!.lowerBound < json.range(of: "\"issuer\"")!.lowerBound)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(parsed.keys) == ["kind", "issuer", "date", "total", "lineItems"])
        #expect(parsed["total"] as? Double == 5.3 && parsed["date"] as? String == "2026-10-12")
        #expect(model.calls.first?.text == "COOP ZURICH\n\n12.10.2026\n\nBread 3.50\n\nTOTAL 5.30")
    }

    @Test func extractDataAsCSVIsAHeaderAndARow() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(texts: ["Bread 3.50 TOTAL 5.30"], in: dir)
        let model = FakeLanguageModel(extractor: { _, _ in
            ExtractedData(kind: "receipt", total: 5.3, lineItems: [Item(name: "Bread", quantity: nil, amount: 3.5)])
        })
        let output = try succeeded(try await run("extract-data", on: pdf, format: "csv", model: model))
        #expect(output.pathExtension == "csv")
        let csv = String(decoding: try Data(contentsOf: output).dropFirst(3), as: UTF8.self)
        #expect(csv == "kind,issuer,date,total,currency,tax\r\nreceipt,,,5.3,,\r\n")
    }

    @Test func nothingButTheKindIsNoDataFound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(texts: ["Meeting notes"], in: dir)
        let model = FakeLanguageModel(extractor: { _, _ in ExtractedData(kind: "notes", total: 12) })
        #expect(failure(try await run("extract-data", on: pdf, model: model)) == .notApplicable(reason: "No data found"))
        #expect(try others(in: dir, than: pdf).isEmpty)
    }

    @Test func aLongDocumentIsReadFromItsBeginningOnly() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pages = (1...30).map { "Page \($0) item 1.00" }
        let pdf = try Fixtures.pdf(texts: pages, in: dir)
        let model = FakeLanguageModel(contextSize: 1_100 + 100, fixedCost: 100, bytesPerToken: 4, extractor: { _, _ in
            ExtractedData(total: 1)
        })
        _ = try succeeded(try await run("extract-data", on: pdf, model: model))
        #expect(model.calls.count == 1)
        let sent = try #require(model.calls.first).text
        #expect(sent.hasPrefix("Page 1 ") && sent.utf8.count <= 400 && !sent.contains("Page 30"))
    }

    @Test func extractDataRetriesOnceOnHalfTheTextWhenItDoesNotFit() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(texts: ["Bread 3.50.", "Milk 1.80.", "Eggs 2.20.", "Total 7.50."], in: dir)
        let model = FakeLanguageModel(extractor: { text, index in
            if index == 0 { throw LanguageModelFailure.contextExceeded }
            return ExtractedData(total: 7.5, lineItems: [Item(name: "Bread", quantity: nil, amount: 3.5)])
        })
        let output = try succeeded(try await run("extract-data", on: pdf, model: model))
        #expect(model.calls.count == 2 && model.calls[1].text.utf8.count < model.calls[0].text.utf8.count)
        // Grounded in what the model was given the second time: the total is no longer in it.
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        #expect(parsed["total"] == nil && (parsed["lineItems"] as? [Any])?.count == 1)
    }

    // MARK: Document text

    @Test func plainTextFallsBackToWindows1252AndMarkdownIsReadAsIs() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let latin = dir.appending(path: "old.txt")
        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: latin)
        #expect(try await DocumentText.read(latin, as: try #require(FormatRegistry.builtIn.format(id: "txt"))) == "Café")
        let md = try textFile("# Title\n\n- item\n", named: "a.md", in: dir)
        #expect(try await DocumentText.read(md, as: try #require(FormatRegistry.builtIn.format(id: "md"))) == "# Title\n\n- item")
    }

    @Test func officeAndWebDocumentsAreReadThroughTheirText() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rtf = try Fixtures.rtf("Quarterly report", in: dir)
        #expect(try await DocumentText.read(rtf, as: try #require(FormatRegistry.builtIn.format(id: "rtf"))) == "Quarterly report")
        let html = try textFile("<html><body><h1>Héllo</h1><p>World</p></body></html>", named: "page.html", in: dir)
        let text = try await DocumentText.read(html, as: try #require(FormatRegistry.builtIn.format(id: "html")))
        #expect(text.contains("Héllo") && text.contains("World") && !text.contains("<p>"))
    }

    @Test func aPDFsTextLayerIsReadWithoutOCR() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try Fixtures.pdf(texts: ["First page", "Second page"], in: dir)
        #expect(try await DocumentText.read(pdf, as: try #require(FormatRegistry.builtIn.format(id: "pdf"))) == "First page\n\nSecond page")
    }

    @Test(.timeLimit(.minutes(2))) func aScannedPDFIsReadByOCRUpToTwentyPages() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try scannedPDF((1...21).map { "Page \($0) here" }, in: dir)
        let progress = ProgressLog()
        let text = try await DocumentText.read(pdf, as: try #require(FormatRegistry.builtIn.format(id: "pdf"))) { progress.add($0) }
        #expect(text.contains("Page 1 here") && text.contains("Page 20 here") && !text.contains("Page 21"))
        #expect(progress.values.last == 1 && progress.values == progress.values.sorted())
    }

    @Test(.timeLimit(.minutes(2))) func aBlankPDFOrPhotoIsNoTextFound() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let blank = dir.appending(path: "blank.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try #require(CGContext(blank as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let pdf = try #require(FormatRegistry.builtIn.format(id: "pdf"))
        await #expect(throws: ConversionError.notApplicable(reason: "No text found")) { try await DocumentText.read(blank, as: pdf) }
        let photo = try Fixtures.png(width: 200, height: 200, in: dir)
        let png = try #require(FormatRegistry.builtIn.format(id: "png"))
        await #expect(throws: ConversionError.notApplicable(reason: "No text found")) { try await DocumentText.read(photo, as: png) }
    }

    @Test func aLockedPDFFailsWithoutReachingTheModel() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let locked = try Fixtures.lockedPDF(in: dir)
        let model = FakeLanguageModel()
        let result = try await run("summarize", on: locked, model: model)
        guard case .engineFailed(_, let message)? = failure(result) else { Issue.record("\(result)"); return }
        #expect(message.contains("password protected"))
        #expect(model.calls.isEmpty)
    }

    // MARK: The real model (macOS 26 with Apple Intelligence on; skipped elsewhere)

    @Test(.enabled(if: IntelligenceEngineTests.hasModel), .timeLimit(.minutes(2)))
    func theRealModelReadsTheReceiptsPrintedTotal() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let receipt = try Fixtures.textImage(lines: receiptLines, in: dir)
        let output = try succeeded(try await run("extract-data", on: receipt, model: IntelligenceEngine.systemModelForTests()))
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        #expect(parsed["total"] as? Double == 5.3)
        #expect(parsed["date"] == nil || parsed["date"] as? String == "2026-10-12")
        #expect(parsed["issuer"] == nil || (parsed["issuer"] as? String)?.localizedCaseInsensitiveContains("coop") == true)
    }

    @Test(.enabled(if: IntelligenceEngineTests.hasModel), .timeLimit(.minutes(2)))
    func theRealModelWritesAMarkdownSummary() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try textFile("""
            The town council met on Monday evening to discuss the new library. After a long debate, the members \
            approved a budget of two million euros for the building, which will open in the spring of 2028.

            The council also agreed to extend the opening hours of the public swimming pool during the summer, and \
            to plant two hundred trees along the river before the end of the year.
            """, in: dir)
        let output = try succeeded(try await run("summarize", on: source, model: IntelligenceEngine.systemModelForTests()))
        let markdown = try String(contentsOf: output, encoding: .utf8)
        let lines = markdown.split(separator: "\n")
        #expect(markdown.hasPrefix("# ") && lines.count >= 2 && lines.dropFirst().allSatisfy { $0.hasPrefix("- ") })
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Double] = []

    var values: [Double] { lock.withLock { log } }

    func add(_ value: Double) {
        lock.withLock { log.append(value) }
    }
}

extension IntelligenceEngine {
    static func systemModelForTests() -> (any LanguageModeling)? {
        if #available(macOS 26, *) { SystemLanguageModeling() } else { nil }
    }
}
