import AppKit
import CoreText
import PDFKit
import Vision

/// A recognized word. Corners are normalized (0…1) in the recognized image, origin bottom-left.
struct PDFTextWord: Sendable {
    var text: String
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
    var topLeft: CGPoint
}

/// A recognized line of words in reading order.
struct PDFTextLine: Sendable {
    var words: [PDFTextWord]
}

/// Recognizes text with Vision and draws it as an invisible text layer, so scanned pages can be
/// searched, selected and copied. Shared by Make Searchable, Scan to PDF and Redact PDF.
enum PDFTextLayer {
    // MARK: - Recognition

    static func recognize(_ image: CGImage, options: AIOCR.Options) async throws -> [PDFTextLine] {
        lines(from: try await AIOCR.makeRequest(options).perform(on: image))
    }

    /// Splits each observation into words with their own boxes, top-to-bottom then left-to-right.
    static func lines(from observations: [RecognizedTextObservation]) -> [PDFTextLine] {
        let lines: [PDFTextLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            var words: [PDFTextWord] = []
            var wholeLine = false
            var index = string.startIndex
            while let start = string[index...].firstIndex(where: { !$0.isWhitespace }) {
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                if let box = candidate.boundingBox(for: start..<end) {
                    words.append(PDFTextWord(text: String(string[start..<end]), bottomLeft: box.bottomLeft.cgPoint,
                                             bottomRight: box.bottomRight.cgPoint, topLeft: box.topLeft.cgPoint))
                } else {
                    wholeLine = true
                }
                index = end
            }
            if wholeLine || words.isEmpty {
                // Without word boxes, the line is stretched over the observation as one run.
                let text = string.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                words = [PDFTextWord(text: text, bottomLeft: observation.bottomLeft.cgPoint,
                                     bottomRight: observation.bottomRight.cgPoint, topLeft: observation.topLeft.cgPoint)]
            }
            return PDFTextLine(words: words)
        }
        return lines.sorted { lhs, rhs in
            let a = lhs.words[0], b = rhs.words[0]
            let aMid = (a.bottomLeft.y + a.topLeft.y) / 2, bMid = (b.bottomLeft.y + b.topLeft.y) / 2
            let height = max(a.topLeft.y - a.bottomLeft.y, b.topLeft.y - b.bottomLeft.y, 0.001)
            return abs(aMid - bMid) > height / 2 ? aMid > bMid : a.bottomLeft.x < b.bottomLeft.x
        }
    }

    // MARK: - Drawing

    /// Draws `lines` as invisible text stretched over `rect` (in the context's current space, origin bottom-left).
    /// Each word is sized and scaled to its box, with a space drawn in each gap so copied text keeps its words apart.
    static func draw(_ lines: [PDFTextLine], in rect: CGRect, context: CGContext) {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        for line in lines {
            for (index, word) in line.words.enumerated() {
                let origin = point(word.bottomLeft), end = point(word.bottomRight), top = point(word.topLeft)
                let width = hypot(end.x - origin.x, end.y - origin.y)
                let height = hypot(top.x - origin.x, top.y - origin.y)
                guard width > 0.2, height > 0.2 else { continue }
                let angle = atan2(end.y - origin.y, end.x - origin.x)
                drawRun(word.text, at: origin, angle: angle, width: width, height: height, in: context)
                guard index + 1 < line.words.count else { continue }
                // Distance to the next word along this word's baseline.
                let next = point(line.words[index + 1].bottomLeft)
                let gap = (next.x - end.x) * cos(angle) + (next.y - end.y) * sin(angle)
                drawRun(" ", at: end, angle: angle, width: max(gap, height * 0.05), height: height, in: context)
            }
        }
        context.restoreGState()
    }

    private static let unitFont = CTFontCreateWithName("Helvetica" as CFString, 1, nil)

    private static func drawRun(_ text: String, at origin: CGPoint, angle: CGFloat, width: CGFloat, height: CGFloat,
                                in context: CGContext) {
        let fontSize = height / max(CTFontGetAscent(unitFont) + CTFontGetDescent(unitFont), 0.1)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard natural > 0 else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: angle)
        context.scaleBy(x: width / natural, y: 1)
        context.textPosition = CGPoint(x: 0, y: CTFontGetDescent(font))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Draws `image` filling `rect`, embedded as JPEG at `quality`, with its text layer on top.
    static func drawImage(_ image: CGImage, in rect: CGRect, lines: [PDFTextLine], quality: CGFloat, context: CGContext) throws {
        guard let data = PDFOps.encode(image, as: .jpeg, quality: quality, dpi: nil),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ToolError.failed("Couldn't encode the page image.") }
        context.interpolationQuality = .high
        context.draw(jpeg, in: rect)
        draw(lines, in: rect, context: context)
    }

    // MARK: - Pages

    /// A copy of `page` (same boxes and rotation) with the text layer over its original content.
    /// `lines` are normalized to the page as displayed.
    static func searchablePage(_ page: PDFPage, lines: [PDFTextLine]) throws -> PDFPage {
        guard let pageRef = page.pageRef else { throw ToolError.failed("Couldn't read the page.") }
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed("Couldn't create the page.")
        }
        context.beginPDFPage(PDFOps.pageInfo(mediaBox: &mediaBox))
        context.drawPDFPage(pageRef)
        // Lines are in displayed space; map them back into page space.
        context.concatenate(page.transform(for: .cropBox).inverted())
        draw(lines, in: CGRect(origin: .zero, size: PDFOps.displaySize(of: page)), context: context)
        context.endPDFPage()
        context.closePDF()
        guard let copy = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage else {
            throw ToolError.failed("Couldn't create the page.")
        }
        copy.rotation = page.rotation
        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            copy.setBounds(page.bounds(for: box), for: box)
        }
        return copy
    }

    /// A new upright page of `size` points showing only `image` and its text layer.
    static func imagePage(_ image: CGImage, size: CGSize, lines: [PDFTextLine], quality: CGFloat = 0.9) throws -> PDFPage {
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed("Couldn't create the page.")
        }
        context.beginPDFPage(PDFOps.pageInfo(mediaBox: &mediaBox))
        try drawImage(image, in: mediaBox, lines: lines, quality: quality, context: context)
        context.endPDFPage()
        context.closePDF()
        guard let page = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage else {
            throw ToolError.failed("Couldn't create the page.")
        }
        return page
    }

    /// Swaps the page at `index` for `newPage`. Annotations that `keep` returns true for move over;
    /// bookmarks and links that pointed at the old page point at the new one.
    static func replacePage(at index: Int, in document: PDFDocument, with newPage: PDFPage,
                            keep: (PDFAnnotation) -> Bool = { _ in true }) {
        guard let old = document.page(at: index) else { return }
        for annotation in old.annotations {
            old.removeAnnotation(annotation)
            if keep(annotation) { newPage.addAnnotation(annotation) }
        }
        document.insert(newPage, at: index)
        document.removePage(at: index + 1)
        if let root = document.outlineRoot { retarget(root, from: old, to: newPage) }
        for pageIndex in 0..<document.pageCount {
            for annotation in document.page(at: pageIndex)?.annotations ?? [] {
                if let destination = annotation.destination, destination.page === old {
                    annotation.destination = PDFDestination(page: newPage, at: destination.point)
                }
            }
        }
    }

    private static func retarget(_ item: PDFOutline, from old: PDFPage, to new: PDFPage) {
        for index in 0..<item.numberOfChildren {
            guard let child = item.child(at: index) else { continue }
            if let destination = child.destination, destination.page === old {
                child.destination = PDFDestination(page: new, at: destination.point)
            }
            retarget(child, from: old, to: new)
        }
    }

    // MARK: - Helpers

    /// Whether a page already has real text (not just a stray page number).
    static func hasText(_ page: PDFPage) -> Bool {
        (page.string ?? "").filter { !$0.isWhitespace }.count >= 20
    }

    /// Renders a page as displayed at `dpi`, capped so very large pages stay manageable.
    static func render(_ page: PDFPage, dpi: CGFloat, maxPixels: CGFloat = 7000) -> CGImage? {
        let size = PDFOps.displaySize(of: page)
        return PDFOps.renderPage(page, scale: min(dpi / 72, maxPixels / max(size.width, size.height, 1)))
    }
}

/// Make Searchable's per-file result.
struct PDFOCRResult: Sendable {
    var recognizedPages = 0
    var skippedPages = 0
}

extension PDFTextLayer {
    /// Writes a searchable copy of `input`. Pages without text get an invisible text layer over their original
    /// content. With `redo`, pages that already had text are replaced by an image of the page with a new layer.
    static func makeSearchable(_ input: URL, options: AIOCR.Options, redo: Bool, dpi: CGFloat, to output: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> PDFOCRResult {
        let source = try PDFOps.open(input)
        let document = PDFOps.document(from: source, indices: PDFOps.allPages(source))
        var result = PDFOCRResult()
        let count = document.pageCount
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let hasText = hasText(page)
            if hasText, !redo {
                result.skippedPages += 1
            } else {
                guard let image = render(page, dpi: dpi) else { throw ToolError.failed("Couldn't render page \(index + 1).") }
                let lines = try await recognize(image, options: options)
                let newPage = hasText
                    ? try imagePage(image, size: PDFOps.displaySize(of: page), lines: lines, quality: 0.85)
                    : try searchablePage(page, lines: lines)
                replacePage(at: index, in: document, with: newPage) { annotation in
                    // Image pages are upright in displayed space; move annotations along with the content.
                    if hasText { annotation.bounds = annotation.bounds.applying(page.transform(for: .cropBox)) }
                    return true
                }
                result.recognizedPages += 1
            }
            progress(Double(index + 1) / Double(count))
        }
        try PDFOps.write(document, to: output)
        return result
    }
}
