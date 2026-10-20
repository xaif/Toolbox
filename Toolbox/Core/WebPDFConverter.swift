import AppKit
import PDFKit
import WebKit

/// Paper size and margins for documents Toolbox lays out itself.
struct PDFPageSetup: Sendable, Equatable {
    enum Paper: String, CaseIterable, Identifiable {
        case a4, letter, legal
        var id: Self { self }
        var label: String {
            switch self {
            case .a4: "A4"
            case .letter: "US Letter"
            case .legal: "US Legal"
            }
        }
        /// Portrait size in points.
        var size: CGSize {
            switch self {
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            case .legal: CGSize(width: 612, height: 1008)
            }
        }
    }

    var size = Paper.a4.size
    var margin: CGFloat = 54

    static let a4 = PDFPageSetup()

    init(size: CGSize = Paper.a4.size, margin: CGFloat = 54) {
        self.size = size
        self.margin = margin
    }

    init(paper: Paper, landscape: Bool, margin: CGFloat) {
        let size = paper.size
        self.init(size: landscape ? CGSize(width: size.height, height: size.width) : size, margin: margin)
    }

    var contentSize: CGSize { CGSize(width: size.width - margin * 2, height: size.height - margin * 2) }
}

/// Renders HTML to paginated PDF with WebKit's print engine, so CSS, tables and images survive and the
/// text stays selectable. JavaScript is off: converted pages are documents, not apps.
@MainActor
enum WebPDFConverter {
    /// Renders an HTML string. Relative links resolve against `baseURL`.
    static func render(html: String, baseURL: URL?, to output: URL, page: PDFPageSetup = .a4) async throws {
        let renderer = WebPDFRenderer(page: page)
        try await renderer.load { $0.loadHTMLString(html, baseURL: baseURL) }
        try await renderer.print(to: output)
    }

    /// Renders an HTML file, letting it load stylesheets and images from its own folder.
    static func render(file: URL, readAccess: URL? = nil, to output: URL, page: PDFPageSetup = .a4) async throws {
        let renderer = WebPDFRenderer(page: page)
        try await renderer.load { $0.loadFileURL(file, allowingReadAccessTo: readAccess ?? file.deletingLastPathComponent()) }
        try await renderer.print(to: output)
    }
}

@MainActor
private final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    /// Offscreen host window; the print operation needs one to run without a panel.
    private let window: NSWindow
    private let page: PDFPageSetup
    private var loading: CheckedContinuation<Void, Error>?
    private var printing: CheckedContinuation<Bool, Never>?

    init(page: PDFPageSetup) {
        self.page = page
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.websiteDataStore = .nonPersistent()
        let frame = CGRect(origin: .zero, size: page.size)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ start: (WKWebView) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            start(webView)
            // Slow remote images or fonts shouldn't hold the job forever; print what has loaded.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                self?.webView.stopLoading()
                self?.finishLoading(nil)
            }
        }
    }

    func print(to output: URL) async throws {
        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: output])
        info.paperSize = page.size
        info.topMargin = page.margin
        info.bottomMargin = page.margin
        info.leftMargin = page.margin
        info.rightMargin = page.margin
        info.orientation = page.size.width > page.size.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printing = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        window.close()
        guard success, let document = PDFDocument(url: output), document.pageCount > 0 else {
            throw ToolError.failed("Couldn't lay out this page as a PDF.")
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printing?.resume(returning: success)
        printing = nil
    }

    private func finishLoading(_ error: Error?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(ToolError.failed("Couldn't load the page: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(ToolError.failed("Couldn't load the page: \(error.localizedDescription)"))
    }
}

/// Markdown → HTML with a print-friendly stylesheet, built from Foundation's Markdown parser
/// (GitHub-flavored: tables, strikethrough, fenced code).
enum MarkdownHTML {
    static func document(_ markdown: String, title: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(DocumentConverter.xml(title))</title><style>\(stylesheet)</style></head><body>\(body(markdown))</body></html>"
    }

    static func body(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return "<pre>\(DocumentConverter.xml(markdown))</pre>"
        }
        var html = ""
        // Block intents currently open, outermost first.
        var open: [PresentationIntent.IntentType] = []
        var columns: [PresentationIntent.TableColumn] = []
        for run in parsed.runs {
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < min(open.count, blocks.count), open[shared].identity == blocks[shared].identity { shared += 1 }
            for block in open[shared...].reversed() { html += closeTag(block, in: open) }
            open.removeSubrange(shared...)
            for block in blocks[shared...] {
                if case .table(let tableColumns) = block.kind { columns = tableColumns }
                open.append(block)
                html += openTag(block, in: open, columns: columns)
            }
            // A thematic break's run holds a "⸻" placeholder; the <hr> is enough.
            if open.contains(where: { if case .thematicBreak = $0.kind { true } else { false } }) { continue }
            html += inline(run, text: String(parsed[run.range].characters), inCode: open.contains { if case .codeBlock = $0.kind { true } else { false } })
        }
        for block in open.reversed() { html += closeTag(block, in: open) }
        return html
    }

    private static func isHeaderCell(_ stack: [PresentationIntent.IntentType]) -> Bool {
        stack.contains { if case .tableHeaderRow = $0.kind { true } else { false } }
    }

    private static func openTag(_ block: PresentationIntent.IntentType, in stack: [PresentationIntent.IntentType],
                                columns: [PresentationIntent.TableColumn]) -> String {
        switch block.kind {
        case .paragraph: return "<p>"
        case .header(let level): return "<h\(min(max(level, 1), 6))>"
        case .orderedList: return "<ol>"
        case .unorderedList: return "<ul>"
        case .listItem: return "<li>"
        case .codeBlock(let language): return language.map { "<pre><code class=\"language-\(DocumentConverter.xml($0))\">" } ?? "<pre><code>"
        case .blockQuote: return "<blockquote>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table>"
        case .tableHeaderRow: return "<thead><tr>"
        case .tableRow: return "<tr>"
        case .tableCell(let column):
            let tag = isHeaderCell(stack) ? "th" : "td"
            let alignment = column < columns.count ? columns[column].alignment : .left
            switch alignment {
            case .center: return "<\(tag) style=\"text-align:center\">"
            case .right: return "<\(tag) style=\"text-align:right\">"
            default: return "<\(tag)>"
            }
        @unknown default: return "<div>"
        }
    }

    private static func closeTag(_ block: PresentationIntent.IntentType, in stack: [PresentationIntent.IntentType]) -> String {
        switch block.kind {
        case .paragraph: return "</p>"
        case .header(let level): return "</h\(min(max(level, 1), 6))>"
        case .orderedList: return "</ol>"
        case .unorderedList: return "</ul>"
        case .listItem: return "</li>"
        case .codeBlock: return "</code></pre>"
        case .blockQuote: return "</blockquote>"
        case .thematicBreak: return ""
        case .table: return "</tbody></table>"
        case .tableHeaderRow: return "</tr></thead><tbody>"
        case .tableRow: return "</tr>"
        case .tableCell: return isHeaderCell(stack) ? "</th>" : "</td>"
        @unknown default: return "</div>"
        }
    }

    private static func inline(_ run: AttributedString.Runs.Run, text: String, inCode: Bool) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.inlineHTML) || intent.contains(.blockHTML) { return text }
        if intent.contains(.lineBreak) { return "<br>" }
        if intent.contains(.softBreak) { return "\n" }
        if let image = run.imageURL {
            return "<img src=\"\(DocumentConverter.xml(image.absoluteString))\" alt=\"\(DocumentConverter.xml(text))\">"
        }
        var html = DocumentConverter.xml(text)
        if inCode { return html }
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if let link = run.link { html = "<a href=\"\(DocumentConverter.xml(link.absoluteString))\">\(html)</a>" }
        return html
    }

    static let stylesheet = """
    :root { color-scheme: light; }
    body { font: 11pt/1.5 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d1d1f; margin: 0; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.5em; page-break-after: avoid; }
    h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; } h4, h5, h6 { font-size: 12pt; }
    body > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 0.8em; }
    a { color: #0b63ce; text-decoration: none; }
    code { font: 0.9em ui-monospace, Menlo, monospace; background: #f1f1f4; padding: 0.1em 0.3em; border-radius: 4px; }
    pre { background: #f5f5f7; padding: 10px 12px; border-radius: 6px; white-space: pre-wrap; page-break-inside: avoid; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #d2d2d7; padding-left: 12px; color: #515154; margin-left: 0; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #d2d2d7; padding: 5px 8px; text-align: left; vertical-align: top; }
    th { background: #f1f1f4; }
    tbody tr:nth-child(even) td { background: #fafafc; }
    tr, img { page-break-inside: avoid; }
    img { max-width: 100%; }
    hr { border: none; border-top: 1px solid #d2d2d7; margin: 1.2em 0; }
    """
}
