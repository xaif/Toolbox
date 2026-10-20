import XCTest
import AppKit
import PDFKit
@testable import Toolbox

final class PDFStampTests: XCTestCase {
    private var root: URL!
    private var staging: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFStampTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in staging { OutputManager.discard(staging: folder) }
        staging = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func context(_ inputs: [URL] = []) throws -> JobContext {
        let context = try JobContext(destination: OutputDestination(folder: root.appendingPathComponent("results"), besideSources: false),
                                     inputs: inputs, runner: nil)
        if let folder = context.stagingRoot { staging.append(folder) }
        return context
    }

    private func outputs(_ context: JobContext) throws -> [URL] {
        try context.stagedResults.flatMap { try FileManager.default.contentsOfDirectory(at: $0.staging, includingPropertiesForKeys: nil) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Runs `job` on `input` and returns the one PDF it writes.
    private func run(_ job: ToolJob, on input: URL) async throws -> PDFDocument {
        let results = try await runAll(job, on: input)
        XCTAssertEqual(results.count, 1)
        return try XCTUnwrap(PDFDocument(url: try XCTUnwrap(results.first)))
    }

    private func runAll(_ job: ToolJob, on input: URL) async throws -> [URL] {
        let context = try context([input])
        switch job {
        case .each(_, let body): try await body(input, context, { _ in })
        case .all(let body): try await body([input], context)
        }
        return try outputs(context)
    }

    /// A PDF with one line of text near the top left of each page.
    private func makePDF(_ name: String = "Source.pdf", pages: [String], size: CGSize = CGSize(width: 612, height: 792)) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "Test Title"] as CFDictionary))
        for text in pages {
            context.beginPDFPage(nil)
            PDFStampOps.draw(PDFTextStyle(size: 18).line(text), at: CGPoint(x: 72, y: size.height - 90), in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// RGB (0…255) at a point in the page's displayed space, rendered at 72 DPI.
    private func pixel(_ page: PDFPage, x: CGFloat, y: CGFloat) throws -> (r: Int, g: Int, b: Int) {
        let image = try XCTUnwrap(PDFOps.renderPage(page, scale: 1))
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let row = height - 1 - min(max(Int(y), 0), height - 1)
        let index = row * width * 4 + min(max(Int(x), 0), width - 1) * 4
        return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
    }

    private func text(_ document: PDFDocument, page: Int) -> String { document.page(at: page)?.string ?? "" }

    /// `makePDF` pages in a document PDFKit made. Links and bookmarks added to a document opened from a file
    /// lose their target page when it's saved.
    private func makeEditablePDF(_ name: String = "Source.pdf", pages: [String]) throws -> PDFDocument {
        let file = try XCTUnwrap(PDFDocument(url: try makePDF(name, pages: pages)))
        return PDFOps.document(from: file, indices: PDFOps.allPages(file))
    }

    // MARK: - Rotate

    func testRotateScopesAreLossless() async throws {
        let input = try makePDF(pages: ["One", "Two", "Three", "Four"])
        let odd = try await run(PDFRotateView.job(degrees: 90, scope: .odd, range: ""), on: input)
        XCTAssertEqual((0..<4).map { odd.page(at: $0)!.rotation }, [90, 0, 90, 0])
        XCTAssertEqual(text(odd, page: 2), "Three")

        let custom = try await run(PDFRotateView.job(degrees: 180, scope: .custom, range: "2-3"), on: input)
        XCTAssertEqual((0..<4).map { custom.page(at: $0)!.rotation }, [0, 180, 180, 0])
        let even = try await run(PDFRotateView.job(degrees: 270, scope: .even, range: ""), on: input)
        XCTAssertEqual((0..<4).map { even.page(at: $0)!.rotation }, [0, 270, 0, 270])

        do {
            _ = try await run(PDFRotateView.job(degrees: 90, scope: .custom, range: "7"), on: input)
            XCTFail("Out-of-range pages should fail")
        } catch {}
    }

    // MARK: - Crop & resize

    func testCropMarginsAndTrimWhitespace() async throws {
        let input = try makePDF(pages: ["Margins"])
        let cropped = try await run(PDFCropResizeView.job(PDFCropResize(top: 72, right: 36, bottom: 144, left: 18)), on: input)
        let crop = cropped.page(at: 0)!.bounds(for: .cropBox)
        XCTAssertEqual(crop, CGRect(x: 18, y: 144, width: 612 - 54, height: 792 - 216))
        XCTAssertEqual(cropped.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792), "Cropping is lossless")
        XCTAssertEqual(text(cropped, page: 0), "Margins")

        let trimmed = try await run(PDFCropResizeView.job(PDFCropResize(trimWhitespace: true)), on: input)
        let trim = trimmed.page(at: 0)!.bounds(for: .cropBox)
        XCTAssertLessThan(trim.width, 200)
        XCTAssertLessThan(trim.height, 40)
        XCTAssertGreaterThan(trim.minX, 60)
        XCTAssertGreaterThan(trim.minY, 680)

        do {
            _ = try await run(PDFCropResizeView.job(PDFCropResize(right: 300, left: 400)), on: input)
            XCTFail("Margins wider than the page should fail")
        } catch {}
    }

    func testCropRespectsDisplayedOrientation() throws {
        let document = try XCTUnwrap(PDFDocument(url: try makePDF(pages: ["Turned"])))
        document.page(at: 0)!.rotation = 90
        // Displayed, the page is 792 wide and 612 tall; cutting 100 off the displayed top…
        let output = try PDFStampOps.cropResize(document, options: PDFCropResize(top: 100))
        let page = try XCTUnwrap(output.page(at: 0))
        XCTAssertEqual(PDFOps.displaySize(of: page), CGSize(width: 792, height: 512))
        // …cuts the unrotated page's left side.
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 100, y: 0, width: 512, height: 792))
    }

    func testResizeFitsPagesOntoPaperKeepingTextAndLinks() async throws {
        let source = try makeEditablePDF(pages: ["Letter page", "Second"])
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 120, height: 24), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: source.page(at: 1)!, at: CGPoint(x: 0, y: 792)))
        source.page(at: 0)!.addAnnotation(link)
        source.page(at: 1)!.rotation = 90
        let linked = root.appendingPathComponent("Linked.pdf")
        XCTAssertTrue(source.write(to: linked))

        let resized = try await run(PDFCropResizeView.job(PDFCropResize(paper: PDFPaperSize.a4.size)), on: linked)
        XCTAssertEqual(resized.pageCount, 2)
        let first = try XCTUnwrap(resized.page(at: 0)), second = try XCTUnwrap(resized.page(at: 1))
        XCTAssertEqual(first.bounds(for: .mediaBox).size.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(first.bounds(for: .mediaBox).size.height, 841.89, accuracy: 0.01)
        // The rotated page fits a landscape sheet, baked upright.
        XCTAssertEqual(second.rotation, 0)
        XCTAssertGreaterThan(second.bounds(for: .mediaBox).width, second.bounds(for: .mediaBox).height)
        XCTAssertEqual(text(resized, page: 0), "Letter page")
        XCTAssertEqual(text(resized, page: 1), "Second")

        let links = first.annotations.filter(PDFStampOps.isLink)
        XCTAssertEqual(links.count, 1)
        // Scaled by 595.28 / 612 and moved with the content.
        XCTAssertEqual(links[0].bounds.width, 120 * 595.28 / 612, accuracy: 0.5)
        let target = try XCTUnwrap((links[0].action as? PDFActionGoTo)?.destination.page)
        XCTAssertEqual(resized.index(for: target), 1)
    }

    // MARK: - Watermark

    func testTextWatermarkIsVectorAndRespectsScope() async throws {
        let input = try makePDF(pages: ["Body one", "Body two"])
        let mark = PDFWatermark(content: .text("CONFIDENTIAL", PDFTextStyle(size: 72, bold: true, color: PDFStampColor.red.cgColor)),
                                opacity: 0.5, rotation: 0, tiled: false, position: .center)
        let output = try await run(PDFWatermarkView.job(mark, scope: .custom, range: "1"), on: input)
        XCTAssertTrue(text(output, page: 0).contains("CONFIDENTIAL"))
        XCTAssertTrue(text(output, page: 0).contains("Body one"))
        XCTAssertFalse(text(output, page: 1).contains("CONFIDENTIAL"))

        // Somewhere along the middle of the page, a half-transparent red.
        var found = false
        for x in stride(from: 100, to: 500, by: 4) {
            let color = try pixel(output.page(at: 0)!, x: CGFloat(x), y: 396)
            if color.r > 200, color.g < 200, color.g > 60 { found = true; break }
        }
        XCTAssertTrue(found, "Expected translucent red text across the center")
    }

    func testTiledAndImageWatermarks() async throws {
        let input = try makePDF(pages: ["Tiles"])
        let tiled = PDFWatermark(content: .text("DRAFT", PDFTextStyle(size: 30)), opacity: 0.2, rotation: 45, tiled: true)
        let output = try await run(PDFWatermarkView.job(tiled), on: input)
        XCTAssertGreaterThan(text(output, page: 0).components(separatedBy: "DRAFT").count - 1, 6)

        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)).then {
            $0.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let logo = PDFWatermark(content: .image(image, widthFraction: 0.5), opacity: 1, rotation: 0, position: .bottomRight)
        let stamped = try await run(PDFWatermarkView.job(logo), on: input)
        // 306 pt wide, 153 tall, 36 pt in from the bottom right corner.
        let inside = try pixel(stamped.page(at: 0)!, x: 612 - 36 - 150, y: 36 + 70)
        XCTAssertLessThan(inside.r, 40)
        XCTAssertGreaterThan(inside.b, 200)
        let outside = try pixel(stamped.page(at: 0)!, x: 100, y: 300)
        XCTAssertGreaterThan(outside.r, 240)
    }

    // MARK: - Page numbers, headers and footers

    func testPageNumbersFormatsAndSkippingTheCover() async throws {
        let input = try makePDF(pages: ["Cover", "A", "B", "C", "D"])
        var numbering = PDFPageNumbering(format: .pageOfTotal, position: .bottomRight)
        numbering.skipFirst = true
        let output = try await run(PDFPageNumbersView.job(numbering), on: input)
        XCTAssertFalse(text(output, page: 0).contains("Page"))
        XCTAssertTrue(text(output, page: 1).contains("Page 1 of 4"))
        XCTAssertTrue(text(output, page: 4).contains("Page 4 of 4"))

        let roman = try await run(PDFPageNumbersView.job(PDFPageNumbering(format: .roman, start: 3), scope: .even), on: input)
        XCTAssertTrue(text(roman, page: 1).hasSuffix("iii"))
        XCTAssertTrue(text(roman, page: 3).hasSuffix("iv"))
        XCTAssertEqual(text(roman, page: 0), "Cover")
        XCTAssertEqual(PDFPageNumberFormat.roman(1994), "mcmxciv")
        XCTAssertEqual(PDFPageNumberFormat.dashes.text(7, total: 9), "- 7 -")
        XCTAssertEqual(PDFPageNumberFormat.slash.text(7, total: 9), "7 / 9")
    }

    func testPageNumbersSitAtTheChosenEdge() throws {
        let document = try XCTUnwrap(PDFDocument(url: try makePDF(pages: ["Edges"])))
        let numbering = PDFPageNumbering(format: .number, position: .topRight, start: 8, style: PDFTextStyle(size: 30), margin: 20)
        let output = try PDFStampOps.addPageNumbers(document, numbering: numbering, pages: [0])
        let selection = try XCTUnwrap(output.findString("8", withOptions: []).first)
        let bounds = selection.bounds(for: output.page(at: 0)!)
        XCTAssertGreaterThan(bounds.minX, 540)
        XCTAssertGreaterThan(bounds.minY, 720)
    }

    func testHeadersAndFootersResolveTokens() async throws {
        let input = try makePDF("Quarterly Report.pdf", pages: ["Intro", "Numbers", "End"])
        var layout = PDFHeaderFooter(texts: [.topLeft: "{title}", .topRight: "{filename}", .bottom: "Page {page} of {pages}"])
        layout.skipFirst = true
        layout.rules = true
        let output = try await run(PDFHeadersFootersView.job(layout), on: input)
        XCTAssertEqual(text(output, page: 0), "Intro")
        let second = text(output, page: 1)
        XCTAssertTrue(second.contains("Test Title"), second)
        XCTAssertTrue(second.contains("Quarterly Report"), second)
        XCTAssertTrue(second.contains("Page 2 of 3"), second)
        XCTAssertTrue(text(output, page: 2).contains("Page 3 of 3"))

        let fixed = PDFHeaderFooter(dateStyle: .iso, date: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(fixed.resolve("{DATE} · {Page}/{pages}", page: 2, pages: 5, fileName: "f", title: "t"),
                       "2025-10-09 · 2/5")
    }

    // MARK: - Colors

    func testInvertModesKeepTextSelectable() async throws {
        let input = try makePDF(pages: ["Readable text"])
        let expectations: [(PDFColorMode, ClosedRange<Int>)] = [(.dark, 0...8), (.softDark, 25...60), (.grayscale, 247...255)]
        for (mode, paper) in expectations {
            let output = try await run(PDFInvertColorsView.job(mode), on: input)
            XCTAssertEqual(text(output, page: 0), "Readable text", "\(mode)")
            let background = try pixel(output.page(at: 0)!, x: 300, y: 300)
            XCTAssertTrue(paper.contains(background.r) && paper.contains(background.g) && paper.contains(background.b),
                          "\(mode) paper is \(background)")
        }
        let sepia = try await run(PDFInvertColorsView.job(.sepia), on: input)
        let paper = try pixel(sepia.page(at: 0)!, x: 300, y: 300)
        XCTAssertEqual(paper.r, 244, accuracy: 4)
        XCTAssertEqual(paper.g, 236, accuracy: 4)
        XCTAssertEqual(paper.b, 216, accuracy: 4)
        XCTAssertEqual(text(sepia, page: 0), "Readable text")
    }

    func testGrayscaleRemovesColor() throws {
        let url = root.appendingPathComponent("Red.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        let output = try PDFStampOps.recolor(try XCTUnwrap(PDFDocument(url: url)), mode: .grayscale)
        let color = try pixel(output.page(at: 0)!, x: 100, y: 100)
        XCTAssertEqual(color.r, color.g, accuracy: 3)
        XCTAssertEqual(color.g, color.b, accuracy: 3)
        XCTAssertLessThan(color.r, 200)
    }

    // MARK: - Flatten

    func testFlattenBurnsInAnnotationsAndKeepsLinks() async throws {
        let source = try XCTUnwrap(PDFDocument(url: try makePDF(pages: ["Form"])))
        let page = try XCTUnwrap(source.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 240, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "FREE NOTE"
        note.font = NSFont.systemFont(ofSize: 18)
        note.fontColor = .black
        note.color = .clear
        page.addAnnotation(note)
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 400, width: 240, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "name"
        field.widgetStringValue = "FIELDVALUE"
        field.font = NSFont.systemFont(ofSize: 14)
        page.addAnnotation(field)
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 100, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        let input = root.appendingPathComponent("Annotated.pdf")
        XCTAssertTrue(source.write(to: input))

        let kept = try await run(PDFFlattenView.job(keepLinks: true), on: input)
        let keptPage = try XCTUnwrap(kept.page(at: 0))
        XCTAssertEqual(keptPage.annotations.map { $0.type ?? "" }, ["Link"])
        XCTAssertEqual((keptPage.annotations.first?.action as? PDFActionURL)?.url?.host(), "example.com")
        let flatText = keptPage.string ?? ""
        XCTAssertTrue(flatText.contains("FREE NOTE"), flatText)
        XCTAssertTrue(flatText.contains("FIELDVALUE"), flatText)
        XCTAssertTrue(flatText.contains("Form"), flatText)

        let bare = try await run(PDFFlattenView.job(keepLinks: false), on: input)
        XCTAssertTrue(bare.page(at: 0)!.annotations.isEmpty)
    }

    func testFlattenDropsScriptsAndForms() async throws {
        // A hand-written PDF with a form and a script that runs when it opens.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /JavaScript /JS (app.alert\\(1\\)) >> /AcroForm << /Fields [] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length 44 >>\nstream\nBT /F1 24 Tf 40 150 Td (Scripted) Tj ET\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let input = root.appendingPathComponent("Scripted.pdf")
        try pdf.write(to: input, atomically: true, encoding: .ascii)
        XCTAssertEqual(PDFDocument(url: input)?.page(at: 0)?.string, "Scripted")

        let results = try await runAll(PDFFlattenView.job(keepLinks: true), on: input)
        let raw = try String(contentsOf: try XCTUnwrap(results.first), encoding: .isoLatin1)
        XCTAssertFalse(raw.contains("JavaScript"))
        XCTAssertFalse(raw.contains("OpenAction"))
        XCTAssertFalse(raw.contains("AcroForm"))
        XCTAssertEqual(PDFDocument(url: results[0])?.page(at: 0)?.string, "Scripted")
    }

    // MARK: - Fingerprint

    func testFingerprintCopiesRoundTripAndLookUnchanged() async throws {
        let input = try makePDF("Plan.pdf", pages: ["Secret plan", "Page two"])
        let recipients = PDFFingerprintView.recipients(in: "alice@example.com\n\n  Zoë Müller \nALICE@example.com\n")
        XCTAssertEqual(recipients, ["alice@example.com", "Zoë Müller"])
        let results = try await runAll(PDFFingerprintView.job(recipients: recipients), on: input)
        XCTAssertEqual(results.count, 2)
        let original = try XCTUnwrap(PDFDocument(url: input))
        for (url, recipient) in zip(results, ["Plan-alice@example.com.pdf", "Plan-Zoë Müller.pdf"].sorted()) {
            XCTAssertEqual(url.lastPathComponent.precomposedStringWithCanonicalMapping, recipient.precomposedStringWithCanonicalMapping)
            let copy = try XCTUnwrap(PDFDocument(url: url))
            let found = PDFStampOps.fingerprints(in: copy)
            XCTAssertEqual(found.count, 1)
            XCTAssertEqual(found.first?.pages, [1, 2])
            XCTAssertTrue(recipients.contains(found.first?.fingerprint.recipient ?? ""))
            XCTAssertEqual(found.first?.fingerprint.code.count, 10)
            XCTAssertTrue(text(copy, page: 0).contains("Secret plan"))
            // Invisible: renders exactly like the original.
            for point in [CGPoint(x: 0.06 * 612 + 4, y: 0.04 * 792 + 1), CGPoint(x: 306 + 4, y: 396 + 1), CGPoint(x: 100, y: 702)] {
                let before = try pixel(original.page(at: 0)!, x: point.x, y: point.y)
                let after = try pixel(copy.page(at: 0)!, x: point.x, y: point.y)
                XCTAssertEqual(before.r, after.r, accuracy: 2)
            }
        }
        // The metadata copy survives when the page text is gone.
        let fingerprint = PDFFingerprint(recipient: "Bob", code: "ABC123")
        let blank = PDFDocument()
        blank.insert(PDFPage(), at: 0)
        blank.documentAttributes = [PDFFingerprint.metadataKey: fingerprint.token]
        XCTAssertEqual(PDFStampOps.fingerprints(in: blank).map(\.fingerprint), [fingerprint])
        XCTAssertEqual(PDFStampOps.fingerprints(in: blank).first?.pages, [])
        XCTAssertEqual(PDFFingerprint.find(in: "noise\(fingerprint.token)Next word"), [fingerprint])
    }

    // MARK: - Shared

    func testOverlaysKeepBookmarksLinksAndMetadata() throws {
        let source = try XCTUnwrap(PDFDocument(url: try makePDF(pages: ["One", "Two", "Three"])))
        let outline = PDFOutline()
        let item = PDFOutline()
        item.label = "Chapter 3"
        item.destination = PDFDestination(page: source.page(at: 2)!, at: CGPoint(x: 0, y: 792))
        outline.insertChild(item, at: 0)
        source.outlineRoot = outline
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 60, height: 24), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: source.page(at: 2)!, at: .zero))
        source.page(at: 0)!.addAnnotation(link)
        source.page(at: 1)!.rotation = 180

        let output = try PDFStampOps.addPageNumbers(source, numbering: PDFPageNumbering(), pages: [0, 1, 2])
        XCTAssertEqual(output.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Test Title")
        XCTAssertEqual(output.page(at: 1)?.rotation, 180)
        let bookmark = try XCTUnwrap(output.outlineRoot?.child(at: 0))
        XCTAssertEqual(bookmark.label, "Chapter 3")
        XCTAssertEqual(output.index(for: try XCTUnwrap(bookmark.destination?.page)), 2)
        let target = try XCTUnwrap((output.page(at: 0)?.annotations.first?.action as? PDFActionGoTo)?.destination.page)
        XCTAssertEqual(output.index(for: target), 2)
        // Upside-down page: the number is still drawn upright at the displayed bottom.
        let selection = try XCTUnwrap(output.page(at: 1)?.selection(for: output.page(at: 1)!.bounds(for: .cropBox)))
        XCTAssertTrue((selection.string ?? "").contains("2"))
    }

    func testLinksAndBookmarksSurviveSaving() async throws {
        let source = try makeEditablePDF(pages: ["One", "Two", "Three"])
        let jump = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 60, height: 24), forType: .link, withProperties: nil)
        jump.action = PDFActionGoTo(destination: PDFDestination(page: source.page(at: 2)!, at: CGPoint(x: 0, y: 792)))
        source.page(at: 0)!.addAnnotation(jump)
        let external = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 60, height: 24), forType: .link, withProperties: nil)
        external.url = URL(string: "https://example.com/doc")
        source.page(at: 0)!.addAnnotation(external)
        let outline = PDFOutline()
        let item = PDFOutline()
        item.label = "Two"
        item.destination = PDFDestination(page: source.page(at: 1)!, at: CGPoint(x: 0, y: 792))
        outline.insertChild(item, at: 0)
        source.outlineRoot = outline
        let input = root.appendingPathComponent("Links.pdf")
        XCTAssertTrue(source.write(to: input))

        let jobs: [(String, ToolJob)] = [
            ("rotate", PDFRotateView.job(degrees: 90, scope: .all, range: "")),
            ("crop", PDFCropResizeView.job(PDFCropResize(top: 10))),
            ("resize", PDFCropResizeView.job(PDFCropResize(paper: PDFPaperSize.a5.size))),
            ("numbers", PDFPageNumbersView.job(PDFPageNumbering())),
            ("watermark", PDFWatermarkView.job(PDFWatermark(content: .text("X", PDFTextStyle())))),
            ("invert", PDFInvertColorsView.job(.dark)),
            ("flatten", PDFFlattenView.job(keepLinks: true)),
        ]
        for (name, job) in jobs {
            let output = try await run(job, on: input)
            let annotations = try XCTUnwrap(output.page(at: 0)).annotations
            let goTo = annotations.compactMap { $0.action as? PDFActionGoTo }.first
            XCTAssertEqual(goTo?.destination.page.map { output.index(for: $0) }, 2, name)
            XCTAssertEqual(annotations.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }, ["https://example.com/doc"], name)
            let bookmark = output.outlineRoot?.child(at: 0)
            XCTAssertEqual(bookmark?.label, "Two", name)
            XCTAssertEqual(bookmark?.destination?.page.map { output.index(for: $0) }, 1, name)
        }
    }

    func testPageScopes() throws {
        XCTAssertEqual(try PDFPageScope.odd.pages(range: "", pageCount: 5), [0, 2, 4])
        XCTAssertEqual(try PDFPageScope.even.pages(range: "", pageCount: 5), [1, 3])
        XCTAssertEqual(try PDFPageScope.custom.pages(range: "2, 4-", pageCount: 5), [1, 3, 4])
        XCTAssertThrowsError(try PDFPageScope.custom.pages(range: "9", pageCount: 5))
    }
}

private extension CGContext {
    /// Runs `draw` on this context and returns the image it made.
    func then(_ draw: (CGContext) -> Void) throws -> CGImage {
        draw(self)
        return try XCTUnwrap(makeImage())
    }
}
