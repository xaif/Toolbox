import XCTest
import AppKit
import AVFoundation
import CoreText
import FoundationModels
import PDFKit
@testable import Toolbox

final class SpeechAITests: XCTestCase {
    private var root: URL!
    private var staging: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechAITests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in staging { OutputManager.discard(staging: folder) }
        staging = []
        try? FileManager.default.removeItem(at: root)
    }

    private func context(_ inputs: [URL] = []) throws -> JobContext {
        let context = try JobContext(destination: OutputDestination(folder: root.appendingPathComponent("results"), besideSources: false),
                                     inputs: inputs, runner: nil)
        if let folder = context.stagingRoot { staging.append(folder) }
        return context
    }

    private func outputs(_ context: JobContext) throws -> [URL] {
        try context.stagedResults.flatMap { try FileManager.default.contentsOfDirectory(at: $0.staging, includingPropertiesForKeys: nil) }
    }

    /// A PDF whose pages hold `pages` as real text. Pages listed in `scanned` are images of text instead.
    private func makePDF(_ pages: [String], scanned: Set<Int> = [], name: String = "doc.pdf") throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for (index, text) in pages.enumerated() {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: scanned.contains(index) ? 28 : 12)])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil)
            if scanned.contains(index) {
                let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(.white)
                bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                bitmap.scaleBy(x: 2, y: 2)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), bitmap)
                context.draw(try XCTUnwrap(bitmap.makeImage()), in: box)
            } else {
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private let manual = [
        "Welcome to the Zephyr kettle. This guide explains setup, cleaning and safety for your new appliance.",
        "Refund policy. Refunds are issued within 30 days of purchase when you return the kettle with its receipt. Shipping costs are not refunded.",
        "Descaling. Fill the kettle with equal parts white vinegar and water, boil it, and let it stand for an hour before rinsing.",
    ]

    func testChunksKeepPageNumbers() {
        let long = Array(repeating: "Sentence number filler text that keeps going.", count: 30).joined(separator: " ")
        let document = AIDocumentText(name: "doc", pages: [
            AIDocumentPage(number: 1, text: manual[0]), AIDocumentPage(number: 2, text: long), AIDocumentPage(number: 3, text: manual[2]),
        ], isPaged: true)
        let chunks = ChatIndex.chunks(document, limit: 300)
        XCTAssertEqual(Set(chunks.map(\.page)), [1, 2, 3])
        XCTAssertGreaterThan(chunks.filter { $0.page == 2 }.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 300)
            XCTAssertTrue(document.pages[chunk.page - 1].text.contains(chunk.text.prefix(40)), "chunk \(chunk.id) isn't from page \(chunk.page)")
        }
        XCTAssertEqual(chunks.map(\.id), Array(0..<chunks.count))
    }

    func testRetrievalRanksRelevantChunkFirst() {
        let pages = manual.enumerated().map { AIDocumentPage(number: $0.offset + 1, text: $0.element) }
            + (4...30).map { AIDocumentPage(number: $0, text: "Chapter \($0). Notes about brewing tea, water temperature and cups, page \($0).") }
        let document = AIDocumentText(name: "Manual", pages: pages, isPaged: true)
        let index = ChatIndex(chunks: ChatIndex.chunks(document))
        XCTAssertEqual(index.rank("What is the refund policy?").first?.chunk.page, 2)
        XCTAssertEqual(index.rank("How do I descale it with vinegar?").first?.chunk.page, 3)
        XCTAssertEqual(index.rank("refunds").first?.chunk.page, 2, "plural and singular should match")

        let excerpts = index.excerpts(for: "How many days do I have to ask for a refund?", budget: 400)
        XCTAssertEqual(excerpts.first?.page, 2)
        XCTAssertLessThanOrEqual(excerpts.reduce(0) { $0 + $1.text.count }, 400)

        // Questions about the whole document get excerpts from across it.
        XCTAssertTrue(ChatIndex.isBroad("Summarize this document"))
        XCTAssertFalse(ChatIndex.isBroad("What does it say about refunds?"))
        let spread = index.excerpts(for: "Summarize this document", budget: 600)
        XCTAssertGreaterThan(Set(spread.map(\.page)).count, 5)
        XCTAssertGreaterThan(spread.last?.page ?? 0, 15)

        // A short document goes in whole.
        let small = ChatIndex(chunks: ChatIndex.chunks(AIDocumentText(name: "m", pages: Array(pages.prefix(3)), isPaged: true)))
        XCTAssertEqual(small.excerpts(for: "anything", budget: 5000).count, 3)

        let prompt = ChatAnswerer.prompt("What is the refund window?", excerpts: excerpts, history: [ChatTurn(question: "Hi", answer: "Hello")], prefix: "p.")
        XCTAssertTrue(prompt.contains("[p. 2]\nRefund policy."))
        XCTAssertTrue(prompt.hasSuffix("Question: What is the refund window?"))
    }

    func testCitationsBecomePageLinks() throws {
        let answer = "Refunds take 30 days [p. 2]. Shipping is covered on [pp. 3, 5] and (p. 7–8). Nothing on [p. x]."
        XCTAssertEqual(ChatCitations.pages(in: answer), [2, 3, 5, 7, 8])
        let markdown = ChatCitations.linkedMarkdown(answer)
        let attributed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let links = attributed.runs.compactMap(\.link).compactMap(ChatCitations.page)
        XCTAssertEqual(links, [2, 3, 5, 7, 8])
        XCTAssertTrue(String(attributed.characters).contains("[p. 2]"))
        XCTAssertTrue(String(attributed.characters).contains("[p. x]"))
        XCTAssertNil(ChatCitations.page(for: URL(string: "https://example.com/3")!))
    }

    func testLoadsPDFPagesAndRecognizesScannedOnes() async throws {
        let url = try makePDF([manual[0], "SCANNED INVOICE TOTAL 4217"], scanned: [1])
        let document = try await AIDocumentText.load(url)
        XCTAssertTrue(document.isPaged)
        XCTAssertEqual(document.pages.map(\.number), [1, 2])
        XCTAssertTrue(document.pages[0].text.contains("Zephyr kettle"))
        XCTAssertTrue(document.pages[1].text.uppercased().contains("INVOICE"), "OCR read: \(document.pages[1].text)")

        let partial = try await AIDocumentText.load(url, pages: [0], ocr: false)
        XCTAssertEqual(partial.pages.map(\.number), [1])
        do {
            _ = try await AIDocumentText.load(url, pages: [1], ocr: false)
            XCTFail("A scanned page without OCR has no text")
        } catch {}

        let text = root.appendingPathComponent("notes.txt")
        try String(repeating: "A line of notes about the project.\n", count: 300).write(to: text, atomically: true, encoding: .utf8)
        let notes = try await AIDocumentText.load(text)
        XCTAssertFalse(notes.isPaged)
        XCTAssertGreaterThan(notes.pages.count, 1)
        XCTAssertEqual(notes.citationPrefix, "part")
    }

    func testSpeechScriptDropsHeadersFootersAndRejoinsLines() {
        let topics = ["revenue", "staffing", "outlook", "risks"]
        let pages = (1...4).map { number in
            AIDocumentPage(number: number, text: """
            ACME Annual Report 2025
            The \(topics[number - 1]) section wraps across sev-
            eral lines in the PDF and keeps going for a while so that
            the lines look like a real paragraph of running text.
            A short last line.
            Page \(number) of 4
            """)
        }
        let paragraphs = SpeechScript.paragraphs(from: pages, skipFurniture: true)
        let all = paragraphs.joined(separator: "\n")
        XCTAssertFalse(all.contains("ACME Annual Report"))
        XCTAssertFalse(all.contains("of 4"))
        XCTAssertTrue(all.contains("across several lines in the PDF and keeps going"))
        XCTAssertEqual(paragraphs.count, 4)

        let kept = SpeechScript.paragraphs(from: pages, skipFurniture: false).joined(separator: "\n")
        XCTAssertTrue(kept.contains("ACME Annual Report"))
        XCTAssertTrue(SpeechScript.isPageNumber("- 12 -"))
        XCTAssertTrue(SpeechScript.isPageNumber("iv"))
        XCTAssertFalse(SpeechScript.isPageNumber("12 apples"))
    }

    func testSpeechRendererWritesAudioFiles() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { throw XCTSkip("No speech voices installed.") }
        let document = AIDocumentText(name: "doc", pages: [
            AIDocumentPage(number: 1, text: "Hello there. This is a short test.\nIt has two paragraphs."),
        ], isPaged: true)
        for format in [SpeechAudioFormat.m4a, .wav, .aiff] {
            let url = root.appendingPathComponent("speech.\(format.fileExtension)")
            let duration = try await SpeechRenderer.render(document, skipFurniture: false, voice: SpeechSettings(), format: format, to: url) { _ in }
            XCTAssertGreaterThan(duration, 1, "\(format)")
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(Double(file.length) / file.fileFormat.sampleRate, 1, "\(format)")
        }
        XCTAssertNotNil(SpeechVoices.best(for: "Bonjour tout le monde, ceci est un document en français."))
    }

    @MainActor
    func testPDFToAudioJobWritesM4A() async throws {
        guard !AVSpeechSynthesisVoice.speechVoices().isEmpty else { throw XCTSkip("No speech voices installed.") }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "ai.pdf-to-audio.format")
        defaults.set("m4a", forKey: "ai.pdf-to-audio.format")
        defer { defaults.set(previous, forKey: "ai.pdf-to-audio.format") }
        let input = try makePDF([manual[0], manual[1]])
        let job = try XCTUnwrap(PDFToAudioView.Settings().job(pages: "2"))
        let context = try context([input])
        guard case .each(_, let body) = job else { return XCTFail("Expected a per-file job") }
        try await body(input, context, { _ in })
        let output = try XCTUnwrap(try outputs(context).first)
        XCTAssertEqual(output.lastPathComponent, "doc.m4a")
        let file = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(Double(file.length) / file.fileFormat.sampleRate, 3)
    }

    func testTranscriptPDFHasTitleTimestampsAndText() throws {
        let transcript = Transcript(phrases: [
            SubtitleCue(start: 0, end: 2, text: "Hello and welcome to the show."),
            SubtitleCue(start: 2.5, end: 4, text: "Today we talk about kettles."),
            SubtitleCue(start: 75, end: 78, text: "A second paragraph after a pause."),
        ], words: [])
        XCTAssertEqual(AITranscriptPDF.paragraphs(transcript).count, 2)
        let url = root.appendingPathComponent("talk.pdf")
        try AITranscriptPDF.write(transcript, title: "Kettle Talk", source: "talk.m4a", duration: 80, to: url)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        for expected in ["Kettle Talk", "Transcribed from talk.m4a", "00:00", "01:15", "Hello and welcome to the show. Today we talk about kettles.",
                         "A second paragraph after a pause.", "Page 1 of 1"] {
            XCTAssertTrue(text.contains(expected), "Missing “\(expected)” in \(text)")
        }

        let long = Transcript(phrases: (0..<400).map { SubtitleCue(start: Double($0) * 10, end: Double($0) * 10 + 3, text: "Sentence \($0) of a long talk that goes on and on.") }, words: [])
        let longURL = root.appendingPathComponent("long.pdf")
        try AITranscriptPDF.write(long, title: "Long", source: "long.m4a", duration: 4000, to: longURL)
        let pdf = try XCTUnwrap(PDFDocument(url: longURL))
        XCTAssertGreaterThan(pdf.pageCount, 3)
        XCTAssertTrue(pdf.string?.contains("1:06:30") == true)
    }

    func testRealChatAnswerCitesPage() async throws {
        guard AISummarizer.availability == .available else { throw XCTSkip("Apple Intelligence isn't available.") }
        let document = AIDocumentText(name: "Kettle manual", pages: manual.enumerated().map { AIDocumentPage(number: $0.offset + 1, text: $0.element) }, isPaged: true)
        let index = ChatIndex(chunks: ChatIndex.chunks(document))
        let answer = try await ChatAnswerer.answer("Within how many days are refunds issued?", document: document, index: index, history: []) { _ in }
        print("Chat answer: \(answer)")
        XCTAssertTrue(answer.contains("30"), answer)
    }
}
