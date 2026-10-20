import XCTest
import AppKit
import CoreText
import PDFKit
@testable import Toolbox

/// Make Searchable, Scan to PDF and Redact PDF, on generated documents.
final class PDFOCRTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFOCRTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private static let letter = CGSize(width: 612, height: 792)

    /// Text lines drawn at baselines (in points, origin bottom-left) with Helvetica.
    private struct Line {
        var text: String
        var x: CGFloat
        var baseline: CGFloat
        var size: CGFloat = 20
    }

    private func draw(_ lines: [Line], in context: CGContext) {
        for line in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes))
            context.textPosition = CGPoint(x: line.x, y: line.baseline)
            CTLineDraw(ctLine, context)
        }
    }

    /// A PDF with real (vector) text on each page.
    private func vectorPDF(_ pages: [[Line]], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: Self.letter)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            draw(lines, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// The lines rendered on white at 300 DPI, as a scan would be.
    private func scannedImage(_ lines: [Line], size: CGSize = letter) throws -> CGImage {
        let scale: CGFloat = 300 / 72
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        context.scaleBy(x: scale, y: scale)
        draw(lines, in: context)
        return try XCTUnwrap(context.makeImage())
    }

    /// A PDF whose pages are images of `pages` with no text layer. `vector` pages get real text instead.
    private func imagePDF(_ pages: [[Line]], vector: Set<Int> = [], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: Self.letter)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for (index, lines) in pages.enumerated() {
            context.beginPDFPage(nil)
            if vector.contains(index) { draw(lines, in: context) } else { context.draw(try scannedImage(lines), in: box) }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func brightness(_ image: CGImage, at points: [CGPoint]) throws -> [CGFloat] {
        let rep = NSBitmapImageRep(cgImage: image)
        return points.map { point in
            let color = rep.colorAt(x: Int(point.x * CGFloat(image.width - 1)), y: Int(point.y * CGFloat(image.height - 1)))
            return color?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
        }
    }

    /// Mean absolute difference of two same-size renders, 0…1.
    private func difference(_ a: CGImage, _ b: CGImage) throws -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let repA = NSBitmapImageRep(cgImage: a), repB = NSBitmapImageRep(cgImage: b)
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: a.height, by: 4) {
            for x in stride(from: 0, to: a.width, by: 4) {
                let ca = repA.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
                let cb = repB.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0
                total += abs(ca - cb)
                count += 1
            }
        }
        return total / max(count, 1)
    }

    // MARK: - Make Searchable

    func testScannedPDFBecomesSearchableWithWordsWhereTheyWereDrawn() async throws {
        let lines = [Line(text: "Quarterly Report 2026", x: 72, baseline: 680, size: 28),
                     Line(text: "Invoice number 4821 total due", x: 72, baseline: 600)]
        let input = try imagePDF([lines], name: "scan.pdf")
        XCTAssertFalse(PDFTextLayer.hasText(try XCTUnwrap(PDFDocument(url: input)?.page(at: 0))))

        let output = root.appendingPathComponent("searchable.pdf")
        let result = try await PDFTextLayer.makeSearchable(input, options: AIOCR.Options(), redo: false, dpi: 300, to: output) { _ in }
        XCTAssertEqual(result.recognizedPages, 1)

        let document = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = page.string ?? ""
        XCTAssertTrue(text.contains("Quarterly Report"), text)
        XCTAssertTrue(text.contains("4821"), text)

        // The word's selection sits on the drawn word: "Invoice" starts at x 72 on the 600 pt baseline.
        let selection = try XCTUnwrap(document.findString("Invoice", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        XCTAssertEqual(bounds.minX, 72, accuracy: 6)
        XCTAssertEqual(bounds.width, 66, accuracy: 12) // "Invoice" at 20 pt Helvetica is ~66 pt wide.
        XCTAssertTrue(bounds.minY < 600 && bounds.maxY > 610, "\(bounds)")
        XCTAssertLessThan(bounds.height, 40)
        // Words stay separate when copied.
        XCTAssertTrue(text.contains("number 4821"), text)

        // The page looks the same: the text layer is invisible.
        let original = try XCTUnwrap(PDFOps.renderPage(try XCTUnwrap(PDFDocument(url: input)?.page(at: 0)), scale: 1))
        let searchable = try XCTUnwrap(PDFOps.renderPage(page, scale: 1))
        XCTAssertLessThan(try difference(original, searchable), 0.005)
    }

    func testPagesWithTextAreKeptUnlessRedoing() async throws {
        let scanned = [Line(text: "Scanned page with words", x: 72, baseline: 600)]
        let digital = [Line(text: "Digital page already has a text layer", x: 72, baseline: 600)]
        let input = try imagePDF([scanned, digital], vector: [1], name: "mixed.pdf")
        let originalText = PDFDocument(url: input)?.page(at: 1)?.string

        let output = root.appendingPathComponent("mixed-searchable.pdf")
        let result = try await PDFTextLayer.makeSearchable(input, options: AIOCR.Options(), redo: false, dpi: 300, to: output) { _ in }
        XCTAssertEqual(result.recognizedPages, 1)
        XCTAssertEqual(result.skippedPages, 1)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Scanned page") == true)
        XCTAssertEqual(document.page(at: 1)?.string, originalText)

        let redone = root.appendingPathComponent("mixed-redone.pdf")
        let again = try await PDFTextLayer.makeSearchable(input, options: AIOCR.Options(), redo: true, dpi: 300, to: redone) { _ in }
        XCTAssertEqual(again.recognizedPages, 2)
        // Redone pages don't keep the old layer, so words aren't doubled.
        let redoneText = try XCTUnwrap(PDFDocument(url: redone)?.page(at: 1)?.string)
        XCTAssertEqual(redoneText.components(separatedBy: "Digital").count - 1, 1, redoneText)
    }

    // MARK: - Scan to PDF

    /// A photo of a page lying skewed on a dark desk. Returns the photo and the page's corners (normalized, bottom-left origin).
    private func deskPhoto() throws -> (CGImage, [CGPoint]) {
        let width = 1600, height = 1200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.18, green: 0.2, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let paper = CGSize(width: 640, height: 860)
        let angle: CGFloat = 10 * .pi / 180
        let center = CGPoint(x: 800, y: 600)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: -paper.width / 2, y: -paper.height / 2, width: paper.width, height: paper.height))
        draw([Line(text: "SCAN TEST DOCUMENT", x: -260, baseline: 300, size: 40),
              Line(text: "Second line of text", x: -260, baseline: 220, size: 32)], in: context)
        let image = try XCTUnwrap(context.makeImage())
        let corners = [CGPoint(x: -paper.width / 2, y: paper.height / 2), CGPoint(x: paper.width / 2, y: paper.height / 2),
                       CGPoint(x: paper.width / 2, y: -paper.height / 2), CGPoint(x: -paper.width / 2, y: -paper.height / 2)]
            .map { $0.applying(CGAffineTransform(rotationAngle: angle)) }
            .map { CGPoint(x: (center.x + $0.x) / CGFloat(width), y: (center.y + $0.y) / CGFloat(height)) }
        return (image, corners)
    }

    func testScanDetectsCropsAndStraightensSkewedPage() async throws {
        let (photo, corners) = try deskPhoto()
        let detected = await ScanProcessor.detectQuad(photo)
        let quad = try XCTUnwrap(detected)
        for (found, expected) in zip([quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft], corners) {
            XCTAssertEqual(found.x, expected.x, accuracy: 0.03, "\(quad)")
            XCTAssertEqual(found.y, expected.y, accuracy: 0.03, "\(quad)")
        }

        let page = try XCTUnwrap(ScanProcessor.process(photo, quad: quad, filter: .original, rotation: 0))
        XCTAssertEqual(Double(page.width) / Double(page.height), 640.0 / 860.0, accuracy: 0.05)
        // Cropped to the paper: the edges are light, not the dark desk.
        let edges = try brightness(page, at: [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.02), CGPoint(x: 0.02, y: 0.98),
                                              CGPoint(x: 0.98, y: 0.98), CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.5, y: 0.98)])
        XCTAssertTrue(edges.allSatisfy { $0 > 0.75 }, "\(edges)")
        // Straight: the text reads back.
        let text = try await AIOCR.recognize(page, options: AIOCR.Options())
        XCTAssertTrue(text.contains("SCAN TEST DOCUMENT"), text)

        let turned = try XCTUnwrap(ScanProcessor.process(photo, quad: quad, filter: .original, rotation: 90))
        XCTAssertEqual(turned.width, page.height)
        XCTAssertEqual(turned.height, page.width)

        // B&W is pure black and white, with white paper.
        let bw = try XCTUnwrap(ScanProcessor.process(photo, quad: quad, filter: .blackAndWhite, rotation: 0))
        let samples = try brightness(bw, at: (0..<200).map { CGPoint(x: 0.04 + Double($0 % 20) / 19 * 0.92, y: 0.04 + Double($0 / 20) / 9 * 0.92) })
        XCTAssertTrue(samples.allSatisfy { $0 < 0.05 || $0 > 0.95 }, "\(samples)")
        XCTAssertGreaterThan(samples.filter { $0 > 0.95 }.count, 180)
        let bwCorners = try brightness(bw, at: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)])
        XCTAssertTrue(bwCorners.allSatisfy { $0 > 0.5 }, "No dark edge: \(bwCorners)")
    }

    func testScanWritesSearchablePDF() async throws {
        let (photo, _) = try deskPhoto()
        let data = try XCTUnwrap(ScanProcessor.encode(photo))
        let detected = await ScanProcessor.detectQuad(photo)
        let quad = try XCTUnwrap(detected)
        let spec = ScanPageSpec(source: data, quad: quad, filter: .color, rotation: 0)
        let output = root.appendingPathComponent("scan.pdf")
        try await ScanProcessor.writePDF([spec, spec], to: output, pageSize: .a4, quality: 0.8, ocr: AIOCR.Options())
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size.width, 595.28, accuracy: 0.5)
        XCTAssertTrue(page.string?.contains("SCAN TEST") == true, page.string ?? "")
    }

    // MARK: - Redact

    private func redactionFixture() throws -> URL {
        let url = try vectorPDF([
            [Line(text: "Name: John Appleseed", x: 72, baseline: 700),
             Line(text: "Email: john.appleseed@example.com", x: 72, baseline: 660),
             Line(text: "Phone: +1 415 555 0132", x: 72, baseline: 620),
             Line(text: "Card: 4111 1111 1111 1111", x: 72, baseline: 580),
             Line(text: "Date: 2026-10-18 and ref 1234 5678 9012 3456", x: 72, baseline: 540),
             Line(text: "Public note stays visible", x: 72, baseline: 480)],
            [Line(text: "Second page is untouched by Appleseed redactions", x: 72, baseline: 700, size: 16)],
        ], name: "redact.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Jane Secret", PDFDocumentAttribute.titleAttribute: "Private"]
        XCTAssertTrue(document.write(to: url))
        return url
    }

    func testFindAndPresetsMarkTheRightText() throws {
        let document = try XCTUnwrap(PDFDocument(url: try redactionFixture()))
        let names = PDFRedactor.matches(try PDFRedactor.regex(for: "appleseed", wholeWords: true, matchCase: false), in: document)
        XCTAssertEqual(Set(names.map(\.pageIndex)), [0, 1])
        // The e-mail address counts too: "." separates words.
        XCTAssertEqual(names.filter { $0.pageIndex == 0 }.count, 2)
        XCTAssertTrue(PDFRedactor.matches(try PDFRedactor.regex(for: "APPLESEED", wholeWords: false, matchCase: true), in: document).isEmpty)

        func found(_ preset: PDFRedactor.Preset) -> [String] {
            PDFRedactor.matches(preset.regex, in: document, accepts: preset.accepts).map(\.text)
        }
        XCTAssertEqual(found(.emails), ["john.appleseed@example.com"])
        XCTAssertEqual(found(.phoneNumbers), ["+1 415 555 0132"])
        // The second number fails the card checksum.
        XCTAssertEqual(found(.cardNumbers), ["4111 1111 1111 1111"])

        let name = try XCTUnwrap(names.first { $0.pageIndex == 0 })
        // Normalized displayed space, origin bottom-left: the 700 pt baseline is near the top.
        XCTAssertEqual(name.rect.midY, 706 / 792, accuracy: 0.02)
        XCTAssertGreaterThan(name.rect.minX, 0.15)
    }

    func testRedactionRemovesTextUnderBoxesButKeepsTheRest() async throws {
        let input = try redactionFixture()
        let source = try XCTUnwrap(PDFDocument(url: input))
        let secondPageText = source.page(at: 1)?.string
        var redactions: [PDFRedaction] = []
        for regex in [try PDFRedactor.regex(for: "Appleseed", wholeWords: true, matchCase: false),
                      PDFRedactor.Preset.cardNumbers.regex, PDFRedactor.Preset.phoneNumbers.regex] {
            redactions += PDFRedactor.matches(regex, in: source).filter { $0.pageIndex == 0 }.map { PDFRedaction(pageIndex: 0, rect: $0.rect) }
        }
        let output = root.appendingPathComponent("redacted.pdf")
        try await PDFRedactor.redact(source, redactions: redactions, options: PDFRedactionOptions(), to: output)

        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let page = try XCTUnwrap(document.page(at: 0))
        let text = page.string ?? ""
        for secret in ["Appleseed", "appleseed", "4111", "415", "0132"] {
            XCTAssertFalse(text.contains(secret), "“\(secret)” survived: \(text)")
        }
        XCTAssertTrue(document.findString("Appleseed", withOptions: .caseInsensitive).allSatisfy { $0.pages.first === document.page(at: 1) })
        // The rest of the page is still searchable through the OCR layer.
        XCTAssertTrue(text.contains("Public note stays visible"), text)
        XCTAssertTrue(text.contains("Name"), text)
        XCTAssertFalse(document.findString("Public", withOptions: []).isEmpty)
        // The untouched page keeps its original text exactly, and document info is gone.
        XCTAssertEqual(document.page(at: 1)?.string, secondPageText)
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.titleAttribute])

        // Burned in: the redacted area renders black.
        let image = try XCTUnwrap(PDFOps.renderPage(page, scale: 1))
        let box = try XCTUnwrap(redactions.first).rect
        let center = try brightness(image, at: [CGPoint(x: box.midX, y: 1 - box.midY)])
        XCTAssertLessThan(center[0], 0.1)
    }

    func testRedactionWithoutOCRLeavesNoText() async throws {
        let input = try redactionFixture()
        let source = try XCTUnwrap(PDFDocument(url: input))
        let output = root.appendingPathComponent("redacted-flat.pdf")
        var options = PDFRedactionOptions()
        options.keepsTextSearchable = false
        options.removesMetadata = false
        try await PDFRedactor.redact(source, redactions: [PDFRedaction(pageIndex: 0, rect: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.05))],
                                     options: options, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual((document.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Jane Secret")
    }
}
