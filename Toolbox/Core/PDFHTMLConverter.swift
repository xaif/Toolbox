import AppKit
import PDFKit
import Vision

/// PDF → a single self-contained HTML file with selectable text.
///
/// The page layout mode shows each page as an image with an invisible, positioned text layer on top
/// (like a browser's PDF viewer), so it looks like the original and text can be selected, searched and
/// copied. The reflow mode keeps only the text, grouped into headings and paragraphs.
enum PDFHTMLConverter {
    /// A line of text in display space: top-left origin, points.
    struct Line {
        var text: String
        var rect: CGRect
        var fontSize: CGFloat
    }

    static func convert(_ document: PDFDocument, title: String, reflow: Bool,
                        progress: ((Double) -> Void)? = nil) async throws -> String {
        var pages: [String] = []
        var allLines: [[Line]] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let lines = try await self.lines(of: page)
            if reflow { allLines.append(lines) } else { pages.append(try pageHTML(page, number: index + 1, lines: lines)) }
            progress?(Double(index + 1) / Double(document.pageCount))
        }
        if reflow { return wrap(flowing(allLines), title: title, style: flowingStyle) }
        return wrap(pages.joined(separator: "\n"), title: title, style: layoutStyle)
    }

    /// The page's text lines. Pages without a text layer (scans) are read with on-device OCR.
    static func lines(of page: PDFPage) async throws -> [Line] {
        let size = PDFOps.displaySize(of: page)
        let transform = page.transform(for: .cropBox)
        var result: [Line] = []
        let selections = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
        for selection in selections {
            let text = (selection.string ?? "").trimmingCharacters(in: .newlines)
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let bounds = selection.bounds(for: page).applying(transform)
            let rect = CGRect(x: bounds.minX, y: size.height - bounds.maxY, width: bounds.width, height: bounds.height)
            var fontSize = rect.height * 0.82
            if let attributed = selection.attributedString, attributed.length > 0,
               let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font.pointSize > 1 {
                fontSize = min(font.pointSize, rect.height * 1.2)
            }
            result.append(Line(text: text, rect: rect, fontSize: fontSize))
        }
        if result.isEmpty, let image = PDFOps.renderPage(page, scale: 2) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let box = observation.boundingBox
                let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                  width: box.width * size.width, height: box.height * size.height)
                result.append(Line(text: text, rect: rect, fontSize: rect.height * 0.82))
            }
        }
        return result.sorted { abs($0.rect.minY - $1.rect.minY) > 2 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
    }

    /// CSS pixels per PDF point, so a page appears at its real size.
    private static let scale: CGFloat = 4 / 3

    private static func pageHTML(_ page: PDFPage, number: Int, lines: [Line]) throws -> String {
        let size = PDFOps.displaySize(of: page)
        guard let image = PDFOps.renderPage(page, scale: 2),
              let data = PDFOps.encode(image, as: .jpeg, quality: 0.8, dpi: 144) else {
            throw ToolError.failed("Couldn't render page \(number).")
        }
        let measuringFont = NSFont(name: "Helvetica", size: 100) ?? .systemFont(ofSize: 100)
        let spans = lines.map { line -> String in
            let natural = (line.text as NSString).size(withAttributes: [.font: measuringFont]).width * line.fontSize / 100
            let stretch = natural > 0 ? min(max(line.rect.width / natural, 0.3), 3) : 1
            return String(format: "<span style=\"left:%.1fpx;top:%.1fpx;font-size:%.1fpx;transform:scaleX(%.3f)\">", line.rect.minX * scale,
                          line.rect.minY * scale, line.fontSize * scale, stretch) + DocumentConverter.xml(line.text) + "</span>"
        }
        return String(format: "<section class=\"page\" id=\"page-%d\" style=\"width:%.0fpx;height:%.0fpx\">", number, size.width * scale, size.height * scale)
            + "<img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" alt=\"Page \(number)\">"
            + "<div class=\"text\">\(spans.joined())</div></section>"
    }

    /// Groups lines into headings and paragraphs by font size and spacing.
    private static func flowing(_ pages: [[Line]]) -> String {
        let sizes = pages.flatMap { $0.flatMap { line in Array(repeating: line.fontSize, count: max(line.text.count / 10, 1)) } }.sorted()
        let body = sizes.isEmpty ? 11 : sizes[sizes.count / 2]
        var html = ""
        for (index, lines) in pages.enumerated() {
            if index > 0 { html += "<hr>" }
            var paragraph: [Line] = []
            func flush() {
                guard let first = paragraph.first else { return }
                var text = ""
                for line in paragraph {
                    if text.hasSuffix("-"), let next = line.text.first, next.isLowercase { text.removeLast(); text += line.text }
                    else { text += (text.isEmpty ? "" : " ") + line.text }
                }
                let size = paragraph.map(\.fontSize).max() ?? first.fontSize
                let tag = size >= body * 1.8 ? "h1" : size >= body * 1.3 ? "h2" : size >= body * 1.12 && text.count < 120 ? "h3" : "p"
                html += "<\(tag)>\(DocumentConverter.xml(text))</\(tag)>"
                paragraph = []
            }
            for line in lines {
                if let last = paragraph.last {
                    let gap = line.rect.minY - last.rect.maxY
                    if gap > last.rect.height * 0.6 || abs(line.fontSize - last.fontSize) > body * 0.15 || line.rect.minY < last.rect.minY { flush() }
                }
                paragraph.append(line)
            }
            flush()
        }
        return "<article>\(html)</article>"
    }

    private static func wrap(_ body: String, title: String, style: String) -> String {
        "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>\(DocumentConverter.xml(title))</title><style>\(style)</style></head><body>\(body)</body></html>"
    }

    private static let layoutStyle = """
    body { margin: 0; padding: 24px 0; background: #e8e8ed; }
    .page { position: relative; margin: 0 auto 24px; background: white; box-shadow: 0 2px 10px rgba(0,0,0,0.18); overflow: hidden; }
    .page > img { position: absolute; inset: 0; width: 100%; height: 100%; user-select: none; -webkit-user-select: none; }
    .text { position: absolute; inset: 0; }
    .text span { position: absolute; white-space: pre; color: transparent; line-height: 1; transform-origin: 0 0;
                 font-family: Helvetica, Arial, sans-serif; }
    .text span::selection { background: rgba(0, 110, 255, 0.3); }
    @media print { body { background: none; padding: 0; } .page { box-shadow: none; margin: 0; page-break-after: always; } }
    """

    private static let flowingStyle = """
    body { margin: 0; background: #fff; color: #1d1d1f; font: 17px/1.6 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
    article { max-width: 720px; margin: 0 auto; padding: 40px 24px; }
    h1, h2, h3 { line-height: 1.25; }
    hr { border: none; border-top: 1px solid #e0e0e5; margin: 32px 0; }
    """
}
