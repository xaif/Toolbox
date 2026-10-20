import XCTest
import AppKit
import CoreText
import PDFKit
@testable import Toolbox

final class PDFEditorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFEditorTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Letter pages with one 14 pt Helvetica line every 40 pt, the first baseline at y = 700.
    private func makePDF(_ name: String, pages: [[String]]) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = NSFont(name: "Helvetica", size: 14)!
        for lines in pages {
            context.beginPDFPage(nil)
            for (index, text) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(index) * 40)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// The normalized, top-left point a little into line `index` of `makePDF`'s layout.
    private func linePoint(_ index: Int) -> CGPoint {
        let baseline: CGFloat = 700 - CGFloat(index) * 40
        return CGPoint(x: 90.0 / 612, y: 1 - (baseline + 4) / 792)
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func components(_ color: CGColor) -> [CGFloat] {
        color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? []
    }

    func testRetypedTextBoxesAndImagesAreWrittenAndDocumentKeepsLinksAndBookmarks() throws {
        let source = try makePDF("source.pdf", pages: [["Invoice 2024", "Total due: 120 USD"], ["Second page text"], ["Third page"]])
        // Add a link and a bookmark to page 2 to check they survive the redraw.
        // PDFKit only writes bookmarks added to a document it built itself.
        let loaded = try XCTUnwrap(PDFDocument(url: source))
        let original = PDFDocument()
        for index in 0..<loaded.pageCount { original.insert(loaded.page(at: index)!.copy() as! PDFPage, at: index) }
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 120, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        original.page(at: 1)?.addAnnotation(link)
        original.outlineRoot = PDFOutline()
        let bookmark = PDFOutline()
        bookmark.label = "Second"
        bookmark.destination = PDFDestination(page: original.page(at: 1)!, at: CGPoint(x: 0, y: 792))
        original.outlineRoot?.insertChild(bookmark, at: 0)
        let prepared = root.appendingPathComponent("prepared.pdf")
        XCTAssertTrue(original.write(to: prepared))

        let document = try XCTUnwrap(PDFDocument(url: prepared))
        var line = try XCTUnwrap(PDFEditOps.textLine(on: document.page(at: 0)!, pageIndex: 0, at: linePoint(1)))
        XCTAssertEqual(line.original, "Total due: 120 USD")
        XCTAssertEqual(line.style.size, 14, accuracy: 1.5)
        XCTAssertEqual(components(line.coverColor).prefix(3).map { ($0 * 255).rounded() }, [255, 255, 255])
        XCTAssertLessThan(components(line.style.color).prefix(3).reduce(0, +), 0.3)
        line.text = "Total due: 95 USD"

        var image: CGImage {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            return context.makeImage()!
        }
        let items = [
            line,
            PDFEditItem(pageIndex: 1, rect: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.04), kind: .text, text: "Added note 123",
                        style: PDFEditTextStyle(size: 12)),
            PDFEditItem(pageIndex: 2, rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), kind: .image, image: image),
        ]
        let output = PDFOps.document(from: document, indices: PDFOps.allPages(document))
        try PDFEditOps.apply(items, to: output)
        let saved = root.appendingPathComponent("edited.pdf")
        try PDFOps.write(output, to: saved)

        let result = try XCTUnwrap(PDFDocument(url: saved))
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.page(at: 0)?.string?.contains("Total due: 95 USD") == true)
        XCTAssertTrue(result.page(at: 0)?.string?.contains("Invoice 2024") == true, "Untouched text stays selectable")
        XCTAssertTrue(result.page(at: 1)?.string?.contains("Added note 123") == true)
        XCTAssertEqual(result.page(at: 1)?.annotations.filter { $0.type == "Link" }.count, 1)
        let destination = try XCTUnwrap(result.outlineRoot?.child(at: 0)?.destination?.page)
        XCTAssertEqual(result.index(for: destination), 1)

        let render = try XCTUnwrap(PDFOps.renderPage(result.page(at: 2)!, scale: 1))
        let center = rgb(render, x: render.width / 2, y: render.height / 2)
        XCTAssertGreaterThan(center.0, 200); XCTAssertLessThan(center.1, 60); XCTAssertLessThan(center.2, 60)
        // The original "120" sits under the cover, so it doesn't show.
        let edited = try XCTUnwrap(PDFOps.renderPage(result.page(at: 0)!, scale: 2))
        let coverRect = PDFEditOps.displayRect(try XCTUnwrap(line.cover), pageSize: CGSize(width: 612, height: 792))
        let newWidth = PDFEditOps.textSize(line.text, style: line.style, wraps: false, width: 0).width
        var dark = 0
        for x in stride(from: Int((coverRect.minX + newWidth + 3) * 2), to: Int(coverRect.maxX * 2), by: 1) {
            let pixel = rgb(edited, x: x, y: Int((792 - coverRect.midY) * 2))
            if pixel.0 < 100 { dark += 1 }
        }
        XCTAssertLessThan(dark, 4, "Nothing of the old line remains past the shorter replacement")
    }

    func testWrappedTextGrowsInsteadOfClippingAndRotatedPagesStayUpright() throws {
        let source = try makePDF("rotated.pdf", pages: [["Body text"]])
        let document = try XCTUnwrap(PDFDocument(url: source))
        document.page(at: 0)?.rotation = 90
        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let items = [
            PDFEditItem(pageIndex: 0, rect: CGRect(x: 0.05, y: 0.05, width: 0.4, height: 0.03), kind: .text, text: "Corner"),
            PDFEditItem(pageIndex: 0, rect: CGRect(x: 0.5, y: 0.3, width: 0.25, height: 0.02), kind: .text, text: words,
                        style: PDFEditTextStyle(size: 10)),
        ]
        try PDFEditOps.apply(items, to: document)
        let saved = root.appendingPathComponent("rotated-edited.pdf")
        try PDFOps.write(document, to: saved)
        let result = try XCTUnwrap(PDFDocument(url: saved))
        let page = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(page.rotation, 90)
        let text = page.string ?? ""
        XCTAssertTrue(text.contains("word1 ") && text.contains("word40"), "Every word of a long box is written")
        let corner = try XCTUnwrap(result.findString("Corner", withOptions: []).first)
        let displayed = corner.bounds(for: page).applying(page.transform(for: .cropBox))
        let size = PDFOps.displaySize(of: page)
        XCTAssertEqual(size.width, 792, accuracy: 0.5)
        XCTAssertLessThan(displayed.minX, size.width * 0.2)
        XCTAssertGreaterThan(displayed.maxY, size.height * 0.85, "Text placed at the top of the displayed page lands there")
        XCTAssertGreaterThan(displayed.width, displayed.height, "Text runs left to right on the displayed page")
    }

    @MainActor
    func testEditModelDropsUnchangedLinesAndUndoes() throws {
        let source = try makePDF("model.pdf", pages: [["Alpha beta gamma", "Second line"]])
        let model = PDFEditModel()
        model.load(source)
        XCTAssertTrue(model.isReady)
        model.mode = .editText
        model.tap(at: linePoint(0))
        let id = try XCTUnwrap(model.editing)
        XCTAssertEqual(model.item(id)?.text, "Alpha beta gamma")
        model.endEditing()
        XCTAssertTrue(model.items.isEmpty, "A line retyped to the same words is no edit")
        XCTAssertFalse(model.canUndo)

        model.tap(at: linePoint(1))
        let second = try XCTUnwrap(model.editing)
        model.setText("Second line, revised", for: second)
        model.setText("Second line, revised!", for: second)
        model.endEditing()
        XCTAssertEqual(model.items.count, 1)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertGreaterThan(item.rect.width, try XCTUnwrap(item.cover).width, "One-line text widens to fit longer words")
        model.undo()
        XCTAssertTrue(model.items.isEmpty, "Typing is one undo step")
        model.redo()
        XCTAssertEqual(model.items.first?.text, "Second line, revised!")

        model.mode = .whiteout
        model.addBox(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
        XCTAssertEqual(model.items.count, 2)
        model.deleteSelected()
        XCTAssertEqual(model.items.count, 1)
    }

    func testTextDiffFindsChangedRemovedAndAddedWords() throws {
        let original = try XCTUnwrap(PDFDocument(url: try makePDF("a.pdf", pages: [["The quick brown fox jumps over the lazy dog"], ["Unchanged ending"]])))
        let revised = try XCTUnwrap(PDFDocument(url: try makePDF("b.pdf", pages: [["The quick red fox jumps over the dog today"], ["Unchanged ending"]])))
        let diff = PDFTextDiff(original: original, revised: revised)
        XCTAssertEqual(diff.changes.count, 3)
        XCTAssertEqual(diff.changes.map(\.kind), [.changed, .removed, .added])
        XCTAssertEqual(diff.text(of: diff.changes[0], on: .original), "brown")
        XCTAssertEqual(diff.text(of: diff.changes[0], on: .revised), "red")
        XCTAssertEqual(diff.text(of: diff.changes[1], on: .original), "lazy")
        XCTAssertEqual(diff.text(of: diff.changes[2], on: .revised), "today")
        XCTAssertEqual(diff.removedWordCount, 2)
        XCTAssertEqual(diff.addedWordCount, 2)
        let selection = try XCTUnwrap(PDFTextDiff.selections(diff.changes[0].removed, of: diff.original, in: original).first)
        XCTAssertEqual(selection.string, "brown")
        XCTAssertEqual(diff.page(of: diff.changes[2], on: .original), 0)

        // Text that moved to another page isn't a change.
        let flowA = try XCTUnwrap(PDFDocument(url: try makePDF("flow-a.pdf", pages: [["one two three"], ["four five"]])))
        let flowB = try XCTUnwrap(PDFDocument(url: try makePDF("flow-b.pdf", pages: [["one two"], ["three four five"]])))
        XCTAssertTrue(PDFTextDiff(original: flowA, revised: flowB).changes.isEmpty)

        let report = PDFCompareOps.report(diff, originalName: "a.pdf", revisedName: "b.pdf")
        XCTAssertTrue(report.string.contains("− brown") && report.string.contains("+ today"))
        let reportURL = root.appendingPathComponent("report.pdf")
        try DocumentConverter.renderPDF(report, to: reportURL)
        XCTAssertTrue(PDFDocument(url: reportURL)?.string?.contains("3 changes") == true)
    }

    func testLargeDifferentDocumentsAreComparedPageByPage() {
        func words(_ prefix: String, pages: Int, perPage: Int) -> [PDFTextDiff.Word] {
            (0..<pages * perPage).map { index in
                let text = index % perPage == 0 ? "same" : "\(prefix)\(index)"
                return PDFTextDiff.Word(page: index / perPage, range: NSRange(location: 0, length: 1), text: text, key: text)
            }
        }
        let a = words("a", pages: 10, perPage: 600), b = words("b", pages: 10, perPage: 600)
        let start = Date()
        let diff = PDFTextDiff(original: a, revised: b)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertEqual(diff.removedWordCount, 10 * 599)
        XCTAssertEqual(diff.addedWordCount, 10 * 599)
    }

    func testVisualDifferenceMarksOnlyChangedInk() throws {
        let a = try XCTUnwrap(PDFDocument(url: try makePDF("va.pdf", pages: [["Same line", "Old words"]])))
        let b = try XCTUnwrap(PDFDocument(url: try makePDF("vb.pdf", pages: [["Same line", "New words"]])))
        let same = try XCTUnwrap(PDFCompareOps.visualDifference(original: a.page(at: 0), revised: a.page(at: 0), maxDimension: 600))
        XCTAssertEqual(same.changedFraction, 0)
        let changed = try XCTUnwrap(PDFCompareOps.visualDifference(original: a.page(at: 0), revised: b.page(at: 0), maxDimension: 600))
        XCTAssertGreaterThan(changed.changedFraction, 0)
        XCTAssertLessThan(changed.changedFraction, 0.02)
        let missing = try XCTUnwrap(PDFCompareOps.visualDifference(original: a.page(at: 0), revised: nil, maxDimension: 600))
        XCTAssertGreaterThan(missing.changedFraction, changed.changedFraction)
    }
}
