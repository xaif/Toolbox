import XCTest
import AppKit
import PDFKit
@testable import Toolbox

/// HTML/Markdown/EPUB through WebKit, PDF → HTML, CSV tables, Kindle books, PDF → ZIP and Create PDF.
final class ConversionTests: XCTestCase {
    private var root: URL!
    private var staging: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConversionTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in staging { OutputManager.discard(staging: folder) }
        staging = []
        try? FileManager.default.removeItem(at: root)
    }

    private func context(_ inputs: [URL] = []) throws -> JobContext {
        let context = try JobContext(destination: OutputDestination(folder: root.appendingPathComponent("results"), besideSources: false), inputs: inputs, runner: nil)
        if let folder = context.stagingRoot { staging.append(folder) }
        return context
    }

    private func outputs(_ context: JobContext) throws -> [URL] {
        try context.stagedResults.flatMap { try FileManager.default.contentsOfDirectory(at: $0.staging, includingPropertiesForKeys: nil) }
    }

    private func convert(_ input: URL, to target: String, reflowHTML: Bool = false) async throws -> URL {
        let context = try context([input])
        guard case .each(_, let body) = ConversionEngine.job(target: target, reflowHTML: reflowHTML) else { throw ToolError.failed("Expected a per-file job") }
        try await body(input, context) { _ in }
        return try XCTUnwrap(try outputs(context).first { $0.pathExtension == target })
    }

    private func text(of document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// Whether any pixel of the rendered page is close to `color` (0…255 sRGB components).
    private func page(_ page: PDFPage, contains color: (Int, Int, Int)) throws -> Bool {
        let image = try XCTUnwrap(PDFOps.renderPage(page, scale: 1))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).contains { offset in
            abs(Int(pixels[offset]) - color.0) < 24 && abs(Int(pixels[offset + 1]) - color.1) < 24 && abs(Int(pixels[offset + 2]) - color.2) < 24
        }
    }

    private func makePDF(_ text: String) throws -> URL {
        let output = root.appendingPathComponent("Source-\(UUID().uuidString.prefix(4)).pdf")
        try DocumentConverter.renderPDF(DocumentConverter.styled(text), to: output)
        return output
    }

    func testHTMLToPDFKeepsCSSAndPaginates() async throws {
        let html = root.appendingPathComponent("Styled.html")
        try """
        <html><head><link rel="stylesheet" href="style.css"></head><body>
        <div class="box">Crimson Box</div>
        \((1...90).map { "<p>Paragraph number \($0)</p>" }.joined())
        </body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        try ".box { background: rgb(220, 20, 60); color: white; width: 300px; height: 120px; } p { font-size: 18px; }"
            .write(to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let output = try await convert(html, to: "pdf")
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(text(of: document).contains("Crimson Box"))
        XCTAssertTrue(text(of: document).contains("Paragraph number 90"))
        XCTAssertTrue(try page(try XCTUnwrap(document.page(at: 0)), contains: (220, 20, 60)), "The linked stylesheet's background color should print")
    }

    func testMarkdownRendersTablesAndHeadings() async throws {
        let markdown = root.appendingPathComponent("Notes.md")
        try "# Shopping\n\nSome **bold** text.\n\n| Item | Qty |\n|------|----:|\n| Apples | 3 |\n| Pears | 12 |\n\n```\nlet code = true\n```\n"
            .write(to: markdown, atomically: true, encoding: .utf8)
        let pdfURL = try await convert(markdown, to: "pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        let pdfText = text(of: pdf)
        for word in ["Shopping", "Apples", "Pears", "Qty", "let code = true"] { XCTAssertTrue(pdfText.contains(word), word) }
        let html = try String(contentsOf: try await convert(markdown, to: "html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<h1>Shopping</h1>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">Qty</th>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<pre><code>let code = true"))
    }

    func testEPUBToPDFKeepsChapterText() async throws {
        let epub = root.appendingPathComponent("Book.epub")
        try await DocumentConverter.writeEPUB(text: "Call me Ishmael.\nSome years ago.", title: "Book", to: epub, scratch: root.appendingPathComponent("write"))
        let pdfURL = try await convert(epub, to: "pdf")
        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertTrue(text(of: document).contains("Call me Ishmael."))
    }

    func testPDFToHTMLHasSelectableText() async throws {
        let input = try makePDF("Hello Toolbox\nQuarterly report & <summary>\n" + (1...80).map { "Line \($0)" }.joined(separator: "\n"))
        let layout = try String(contentsOf: try await convert(input, to: "html"), encoding: .utf8)
        XCTAssertTrue(layout.contains("<section class=\"page\" id=\"page-1\""))
        XCTAssertTrue(layout.contains("<section class=\"page\" id=\"page-2\""))
        XCTAssertTrue(layout.contains("Hello Toolbox"))
        XCTAssertTrue(layout.contains("Quarterly report &amp; &lt;summary&gt;"))
        XCTAssertTrue(layout.contains("data:image/jpeg;base64,"))
        let reflowed = try String(contentsOf: try await convert(input, to: "html", reflowHTML: true), encoding: .utf8)
        XCTAssertTrue(reflowed.contains("Hello Toolbox"))
        XCTAssertFalse(reflowed.contains("data:image"))
        XCTAssertTrue(reflowed.contains("<p>"))

        // Rotated pages map their text into the displayed (rotated) page.
        let document = try XCTUnwrap(PDFDocument(url: input))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        let size = PDFOps.displaySize(of: page)
        let lines = try await PDFHTMLConverter.lines(of: page)
        XCTAssertFalse(lines.isEmpty)
        for line in lines { XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(line.rect), "\(line.rect) outside \(size)") }
    }

    func testCSVBecomesPaginatedTableWithRepeatedHeader() async throws {
        let csv = root.appendingPathComponent("Sales.csv")
        let rows = (1...150).map { "Customer \($0),\"\($0 * 7),00\",\"Town, \($0 % 9)\"" }
        try (["Name,Amount,City"] + rows).joined(separator: "\r\n").write(to: csv, atomically: true, encoding: .utf8)
        let pdfURL = try await convert(csv, to: "pdf")
        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertGreaterThan(document.pageCount, 1)
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        let second = try XCTUnwrap(document.page(at: 1)?.string)
        XCTAssertTrue(first.contains("Sales"))
        XCTAssertTrue(first.contains("Town, 1"), "Quoted commas stay in one cell")
        XCTAssertTrue(second.contains("Name") && second.contains("Amount") && second.contains("City"), "Header repeats on page 2")
        XCTAssertTrue(second.contains("Page 2 of"))
    }

    func testTableParsingAndHeaderDetection() {
        XCTAssertEqual(TablePDFConverter.parse("a,\"b,c\",\"say \"\"hi\"\"\"\n1,\"two\nlines\",3\n\n", delimiter: ","),
                       [["a", "b,c", "say \"hi\""], ["1", "two\nlines", "3"]])
        XCTAssertEqual(TablePDFConverter.delimiter(in: "a;b;c\n1;2;3\n4;5;6"), ";")
        XCTAssertTrue(TablePDFConverter.hasHeader([["Name", "Age"], ["Ann", "31"], ["Bo", "42"]]))
        XCTAssertFalse(TablePDFConverter.hasHeader([["1", "2"], ["3", "4"]]))
        XCTAssertTrue(TablePDFConverter.hasHeader([["First", "Last"], ["Ann", "Lee"], ["Bob", "Stone"]]))
        XCTAssertEqual(TablePDFConverter.fit([50, 400, 400], into: 450), [50, 200, 200])
    }

    func testKindleBooksNeedCalibre() async throws {
        let book = root.appendingPathComponent("Novel.azw3")
        XCTAssertTrue(ConversionCatalog.targets(for: book).contains("pdf"))
        XCTAssertTrue(ConversionCatalog.targets(for: book).contains("epub"))
        XCTAssertEqual(ConversionCatalog.family(of: book), .ebook)
        guard let calibre = Dependencies.locate(.calibre) else {
            try Data("not a book".utf8).write(to: book)
            do {
                _ = try await convert(book, to: "pdf")
                XCTFail("Converting a Kindle book without Calibre should fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Calibre"), error.localizedDescription)
            }
            throw XCTSkip("Calibre isn't installed; skipped the real Kindle conversion.")
        }
        let epub = root.appendingPathComponent("Novel.epub")
        try await DocumentConverter.writeEPUB(text: "It was a dark and stormy night.", title: "Novel", to: epub, scratch: root.appendingPathComponent("write"))
        try await ProcessRunner.runChecked(calibre, arguments: [epub.path, book.path])
        let output = try String(contentsOf: try await convert(book, to: "txt"), encoding: .utf8)
        XCTAssertTrue(output.contains("dark and stormy"))
    }

    func testPDFToImagesCanBundleAZip() async throws {
        let input = try makePDF((1...120).map { "Line \($0)" }.joined(separator: "\n"))
        let defaults = UserDefaults.standard
        let keys = ["pdf.to-images.zip", "pdf.to-images.dpi", "pdf.to-images.format"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(true, forKey: "pdf.to-images.zip")
        defaults.set(72.0, forKey: "pdf.to-images.dpi")
        defaults.set(PDFImageFormat.jpeg.rawValue, forKey: "pdf.to-images.format")
        let context = try context([input])
        guard case .each(_, let body) = PDFToImagesView.Settings().job(pages: "") else { return XCTFail("Expected a per-file job") }
        try await body(input, context) { _ in }
        let results = try outputs(context)
        XCTAssertEqual(results.map(\.pathExtension), ["zip"])
        let unpacked = root.appendingPathComponent("unpacked")
        try await ArchiveEngine.extract(try XCTUnwrap(results.first), to: unpacked)
        let pages = try FileManager.default.contentsOfDirectory(atPath: unpacked.path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(pages.count, try XCTUnwrap(PDFDocument(url: input)).pageCount)
    }

    @MainActor
    func testRichTextPDFPaginatesWithPictures() throws {
        let picture = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor(red: 0, green: 0.4, blue: 0.9, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let rich = NSMutableAttributedString(string: "Quarterly Plan\n", attributes: RichTextStyle.title.attributes)
        let attachment = NSTextAttachment()
        attachment.image = picture
        rich.append(NSAttributedString(attachment: attachment))
        rich.append(NSAttributedString(string: "\n" + (1...160).map { "Body line \($0)" }.joined(separator: "\n"), attributes: RichTextStyle.body.attributes))
        let output = root.appendingPathComponent("Rich.pdf")
        try RichTextPDF.render(rich, setup: PDFPageSetup(paper: .letter, landscape: false, margin: 54), to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(text(of: document).contains("Quarterly Plan"))
        XCTAssertTrue(text(of: document).contains("Body line 160"))
        XCTAssertTrue(try page(try XCTUnwrap(document.page(at: 0)), contains: (0, 102, 230)), "The picture should be drawn")
    }

    @MainActor
    func testCreatePDFTitlesAndListToggle() throws {
        let draft = CreatePDFDraft()
        draft.mode = .markdown
        draft.markdown = "## Trip notes\n\nPack light."
        XCTAssertEqual(draft.title, "Trip notes")
        draft.mode = .html
        draft.html = "<html><head><title>Invoice &amp; Co</title></head><body></body></html>"
        XCTAssertEqual(draft.title, "Invoice & Co")

        let controller = draft.richText
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.layoutManager?.replaceTextStorage(controller.storage)
        controller.attach(textView)
        textView.insertText("Apples\nPears", replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: 0, length: controller.storage.length))
        controller.toggleList(numbered: true)
        XCTAssertEqual(controller.storage.string, "\t1.\tApples\n\t2.\tPears")
        textView.setSelectedRange(NSRange(location: 0, length: controller.storage.length))
        controller.toggleList(numbered: true)
        XCTAssertEqual(controller.storage.string, "Apples\nPears")
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        controller.toggleBold()
        let font = try XCTUnwrap(controller.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        draft.mode = .richText
        XCTAssertEqual(draft.title, "Apples")
    }

    func testSearchFindsConversionsByName() {
        XCTAssertTrue(ToolRegistry.search("word to pdf").contains { $0.id == "files.convert" })
        XCTAssertTrue(ToolRegistry.search("pdf to html").contains { $0.id == "files.convert" })
        XCTAssertTrue(ToolRegistry.search("mobi").contains { $0.id == "files.convert" })
        XCTAssertTrue(ToolRegistry.search("pdf to zip").contains { $0.id == "pdf.to-images" })
    }
}
