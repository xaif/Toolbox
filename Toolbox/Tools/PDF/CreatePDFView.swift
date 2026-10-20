import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

enum CreatePDFTools {
    static let all: [Tool] = [
        Tool(id: "pdf.create", name: "Create PDF", category: .pdf, symbol: "doc.badge.plus",
             summary: "Write a document with styles and images, or paste HTML or Markdown, and save it as a PDF.",
             keywords: ["new", "write", "editor", "rich text", "compose", "document", "html to pdf", "markdown to pdf", "text editor"]) { CreatePDFView(tool: $0) },
    ]
}

/// What's being written. Shared so it survives switching tools.
@MainActor
@Observable
final class CreatePDFDraft {
    static let shared = CreatePDFDraft()

    enum Mode: String, CaseIterable, Identifiable {
        case richText, html, markdown
        var id: Self { self }
        var label: String {
            switch self {
            case .richText: "Rich Text"
            case .html: "HTML"
            case .markdown: "Markdown"
            }
        }
    }

    var mode = Mode.richText
    let richText = RichTextController()
    var html = """
    <!DOCTYPE html>
    <html>
    <head>
    <style>
      body { font-family: -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; }
      h1 { color: #d9342b; }
      .note { background: #f5f5f7; border-radius: 8px; padding: 12px 16px; }
    </style>
    </head>
    <body>
      <h1>Hello</h1>
      <p>Paste or write HTML here. Its CSS is kept in the PDF.</p>
      <p class="note">Tables, images and web fonts work too.</p>
    </body>
    </html>
    """
    var markdown = """
    # Title

    Write **Markdown** here. Headings, lists, `code`, quotes and tables are supported.

    - First point
    - Second point

    | Item   | Qty |
    |--------|----:|
    | Apples |   3 |
    | Pears  |  12 |
    """

    /// Names the file: the document title or first line.
    var title: String {
        let text: String
        switch mode {
        case .richText: text = richText.storage.string
        case .html:
            let pattern = try? NSRegularExpression(pattern: "<(title|h1)[^>]*>(.*?)</\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let match = pattern?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
            text = match.flatMap { Range($0.range(at: 2), in: html) }.map { DocumentConverter.plainHTML(String(html[$0])) } ?? ""
        case .markdown: text = markdown.replacingOccurrences(of: "(?m)^\\s*#+\\s*", with: "", options: .regularExpression)
        }
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "\u{FFFC}" } ?? ""
        return line.isEmpty ? "Document" : String(line.prefix(60))
    }

    var isEmpty: Bool {
        switch mode {
        case .richText: richText.isEmpty
        case .html: html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .markdown: markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct CreatePDFView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var draft = CreatePDFDraft.shared
    @AppStorage("pdf.create.paper") private var paper = PDFPageSetup.Paper.a4
    @AppStorage("pdf.create.landscape") private var landscape = false
    @AppStorage("pdf.create.margin") private var margin = 54.0

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var saveNote: String {
        AppSettings.outputMode == .ask ? "You'll choose where the PDF goes."
            : "The PDF is saved to \((OutputManager.fixedFolder ?? OutputManager.downloadsFolder).lastPathComponent)."
    }

    private var setup: PDFPageSetup { PDFPageSetup(paper: paper, landscape: landscape, margin: CGFloat(margin)) }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(CreatePDFDraft.Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Picker("Paper", selection: $paper) {
                        ForEach(PDFPageSetup.Paper.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Picker("Orientation", selection: $landscape) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .labelsHidden().fixedSize()
                    Picker("Margins", selection: $margin) {
                        Text("Narrow").tag(36.0)
                        Text("Normal").tag(54.0)
                        Text("Wide").tag(72.0)
                    }
                    .fixedSize()
                    Button("Open…", action: open).help("Start from an existing document")
                }
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(runner.isRunning)
        } footer: {
            JobBar(runner: runner, actionTitle: "Save PDF", canRun: !draft.isEmpty, hint: "Write something first.",
                   idleMessage: saveNote, action: save)
        }
        .onChange(of: setup, initial: true) { draft.richText.maxImageWidth = setup.contentSize.width }
    }

    @ViewBuilder
    private var editor: some View {
        switch draft.mode {
        case .richText:
            VStack(alignment: .leading, spacing: 8) {
                RichTextFormatBar(controller: draft.richText)
                RichTextEditor(controller: draft.richText)
                    .overlay(alignment: .topLeading) {
                        if draft.richText.isEmpty {
                            Text("Start writing. Use the bar above for styles, lists and pictures, or paste and drop images.")
                                .foregroundStyle(Color(white: 0.6)).padding(.horizontal, 33).padding(.vertical, 24)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            }
        case .html:
            SourceAndPreview(source: $draft.html, html: draft.html)
        case .markdown:
            SourceAndPreview(source: $draft.markdown, html: MarkdownHTML.document(draft.markdown, title: draft.title))
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        switch draft.mode {
        case .richText:
            panel.allowedContentTypes = [.rtf, .rtfd, .plainText, .html] + ["docx", "doc", "odt"].compactMap { UTType(filenameExtension: $0) }
        case .html: panel.allowedContentTypes = [.html, .plainText]
        case .markdown: panel.allowedContentTypes = ["md", "markdown"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch draft.mode {
            case .richText: try draft.richText.load(url)
            case .html: draft.html = try DocumentConverter.readText(url)
            case .markdown: draft.markdown = try DocumentConverter.readText(url)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func save() {
        let setup = setup
        let name = draft.title
        let source: CreatePDFSource
        switch draft.mode {
        case .richText: source = .richText(NSAttributedString(attributedString: draft.richText.storage))
        case .html: source = .html(draft.html)
        case .markdown: source = .html(MarkdownHTML.document(draft.markdown, title: name))
        }
        runner.start(title: tool.name) { context in
            context.setStatus("Laying out pages…")
            let output = context.output(named: name, extension: "pdf")
            switch source {
            case .richText(let text): try await RichTextPDF.render(text, setup: setup, to: output)
            case .html(let html): try await WebPDFConverter.render(html: html, baseURL: nil, to: output, page: setup)
            }
            context.setProgress(1)
        }
    }
}

/// Copied from the editor when saving starts.
private enum CreatePDFSource: @unchecked Sendable {
    case richText(NSAttributedString)
    case html(String)
}

// MARK: - Rich text

/// Paragraph styles offered in the format bar.
enum RichTextStyle: String, CaseIterable, Identifiable {
    case title, heading, subheading, body, quote, code
    var id: Self { self }

    var label: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .quote: "Quote"
        case .code: "Code"
        }
    }

    var font: NSFont {
        switch self {
        case .title: .systemFont(ofSize: 26, weight: .bold)
        case .heading: .systemFont(ofSize: 18, weight: .bold)
        case .subheading: .systemFont(ofSize: 14, weight: .semibold)
        case .body: .systemFont(ofSize: 12)
        case .quote: NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        case .code: .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
    }

    var color: NSColor { self == .quote ? NSColor(white: 0.35, alpha: 1) : .black }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = self == .code ? 1.1 : 1.2
        switch self {
        case .title: style.paragraphSpacing = 10
        case .heading: style.paragraphSpacingBefore = 12; style.paragraphSpacing = 6
        case .subheading: style.paragraphSpacingBefore = 8; style.paragraphSpacing = 4
        case .body: style.paragraphSpacing = 6
        case .quote: style.headIndent = 18; style.firstLineHeadIndent = 18; style.paragraphSpacing = 6
        case .code: style.headIndent = 10; style.firstLineHeadIndent = 10
        }
        return style
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
    }

    /// The style a paragraph's font most likely came from.
    static func matching(_ font: NSFont) -> RichTextStyle? {
        allCases.first { $0.font.pointSize == font.pointSize && $0.font.fontName == font.fontName }
    }
}

/// Owns the rich text and applies the format bar's commands to the editor's selection.
@MainActor
@Observable
final class RichTextController: NSObject, NSTextViewDelegate {
    @ObservationIgnored weak var textView: NSTextView?
    let storage = NSTextStorage()

    private(set) var bold = false
    private(set) var italic = false
    private(set) var underline = false
    private(set) var strikethrough = false
    private(set) var fontSize: CGFloat = 12
    private(set) var alignment = NSTextAlignment.left
    private(set) var style: RichTextStyle? = .body
    private(set) var isEmpty = true
    /// Wider pictures are scaled down to fit the page.
    var maxImageWidth: CGFloat = 480 { didSet { fitImages() } }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.delegate = self
        textView.typingAttributes = RichTextStyle.body.attributes
        refresh()
    }

    func load(_ url: URL) throws {
        let text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        storage.setAttributedString(text)
        // Plain text and HTML arrive without the document's colors; keep them readable on paper.
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value == nil { storage.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        fitImages()
        refresh()
    }

    // MARK: Selection state

    private var currentAttributes: [NSAttributedString.Key: Any] {
        guard let textView else { return RichTextStyle.body.attributes }
        let range = textView.selectedRange()
        if range.length > 0, range.location < storage.length { return storage.attributes(at: range.location, effectiveRange: nil) }
        return textView.typingAttributes
    }

    func refresh() {
        let attributes = currentAttributes
        let font = attributes[.font] as? NSFont ?? RichTextStyle.body.font
        let traits = font.fontDescriptor.symbolicTraits
        bold = traits.contains(.bold)
        italic = traits.contains(.italic)
        underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        fontSize = font.pointSize
        alignment = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
        style = RichTextStyle.matching(font)
        isEmpty = storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textViewDidChangeSelection(_ notification: Notification) { refresh() }

    func textDidChange(_ notification: Notification) {
        fitImages()
        refresh()
    }

    // MARK: Commands

    func toggleBold() { convertFonts(trait: .boldFontMask, on: !bold) }
    func toggleItalic() { convertFonts(trait: .italicFontMask, on: !italic) }
    func toggleUnderline() { setAttribute(.underlineStyle, underline ? nil : NSUnderlineStyle.single.rawValue) }
    func toggleStrikethrough() { setAttribute(.strikethroughStyle, strikethrough ? nil : NSUnderlineStyle.single.rawValue) }
    func setColor(_ color: NSColor) { setAttribute(.foregroundColor, color) }

    func setSize(_ size: CGFloat) {
        changeFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    func showFontPanel() {
        focus()
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    func showColorPanel() {
        focus()
        NSColorPanel.shared.orderFront(nil)
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        changeParagraphs { $0.alignment = alignment }
    }

    func apply(_ style: RichTextStyle) {
        guard let textView else { return }
        let range = paragraphRange
        var attributes = style.attributes
        if let alignment = (currentAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment,
           let paragraph = style.paragraphStyle.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.alignment = alignment
            attributes[.paragraphStyle] = paragraph
        }
        if range.length > 0 { edit(range) { _ in reset(range, to: attributes) } }
        textView.typingAttributes = attributes
        refresh()
        focus()
    }

    /// Adds or removes bullets or numbers on the selected paragraphs.
    func toggleList(numbered: Bool) {
        guard let textView else { return }
        let range = paragraphRange
        let currentStyle = currentAttributes[.paragraphStyle] as? NSParagraphStyle
        // The same kind of list toggles off; the other kind replaces it.
        let format = numbered ? NSTextList.MarkerFormat("{decimal}.") : .disc
        let removing = currentStyle?.textLists.first?.markerFormat == format
        let list = NSTextList(markerFormat: format, options: 0)
        let text = NSMutableAttributedString()
        var paragraphs: [NSAttributedString] = []
        if range.length == 0 {
            paragraphs = [NSAttributedString(string: "", attributes: textView.typingAttributes)]
        } else {
            (storage.string as NSString).enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
                paragraphs.append(self.storage.attributedSubstring(from: enclosing))
            }
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let line = NSMutableAttributedString(attributedString: paragraph)
            let attributes = line.length > 0 ? line.attributes(at: 0, effectiveRange: nil) : textView.typingAttributes
            let style = ((attributes[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            if let marker = line.string.range(of: "^\\t[^\\t\\n]*\\t", options: .regularExpression), !(style.textLists.isEmpty) {
                line.deleteCharacters(in: NSRange(marker, in: line.string))
            }
            if removing {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
                style.tabStops = NSParagraphStyle.default.tabStops
            } else {
                style.textLists = [list]
                style.headIndent = 28
                style.firstLineHeadIndent = 0
                style.tabStops = [NSTextTab(textAlignment: .right, location: 20), NSTextTab(textAlignment: .left, location: 28)]
                var markerAttributes = attributes
                markerAttributes.removeValue(forKey: .attachment)
                line.insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: index + 1))\t", attributes: markerAttributes), at: 0)
            }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            text.append(line)
        }
        guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        let caret = range.location + text.length - (text.string.hasSuffix("\n") ? 1 : 0)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        if text.length > 0 {
            var typing = text.attributes(at: text.length - 1, effectiveRange: nil)
            typing.removeValue(forKey: .attachment)
            textView.typingAttributes = typing
        }
        refresh()
        focus()
    }

    func insertImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, let textView else { return }
        let text = NSMutableAttributedString()
        for url in panel.urls {
            guard let wrapper = try? FileWrapper(url: url), NSImage(contentsOf: url) != nil else { continue }
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: "\n", attributes: textView.typingAttributes))
        }
        guard text.length > 0 else { return }
        text.addAttribute(.paragraphStyle, value: textView.typingAttributes[.paragraphStyle] ?? RichTextStyle.body.paragraphStyle,
                          range: NSRange(location: 0, length: text.length))
        textView.insertText(text, replacementRange: textView.selectedRange())
        fitImages()
        focus()
    }

    func clearFormatting() {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length > 0 { edit(range) { _ in reset(range, to: RichTextStyle.body.attributes) } }
        textView.typingAttributes = RichTextStyle.body.attributes
        refresh()
        focus()
    }

    // MARK: Helpers

    private var paragraphRange: NSRange {
        guard let textView else { return NSRange() }
        return (storage.string as NSString).paragraphRange(for: textView.selectedRange())
    }

    private func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// One undoable attribute change.
    private func edit(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let textView, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
    }

    /// Replaces the attributes in `range`, keeping its pictures.
    private func reset(_ range: NSRange, to attributes: [NSAttributedString.Key: Any]) {
        var attachments: [(NSRange, Any)] = []
        storage.enumerateAttribute(.attachment, in: range) { value, subrange, _ in
            if let value { attachments.append((subrange, value)) }
        }
        storage.setAttributes(attributes, range: range)
        for (subrange, attachment) in attachments { storage.addAttribute(.attachment, value: attachment, range: subrange) }
    }

    private func setAttribute(_ key: NSAttributedString.Key, _ value: Any?) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length > 0 {
            edit(range) { storage in
                if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
            }
        }
        var typing = textView.typingAttributes
        typing[key] = value
        textView.typingAttributes = typing
        refresh()
        focus()
    }

    private func convertFonts(trait: NSFontTraitMask, on: Bool) {
        changeFonts { on ? NSFontManager.shared.convert($0, toHaveTrait: trait) : NSFontManager.shared.convert($0, toNotHaveTrait: trait) }
    }

    private func changeFonts(_ change: (NSFont) -> NSFont) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length > 0 {
            edit(range) { storage in
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    storage.addAttribute(.font, value: change(value as? NSFont ?? RichTextStyle.body.font), range: subrange)
                }
            }
        }
        var typing = textView.typingAttributes
        typing[.font] = change(typing[.font] as? NSFont ?? RichTextStyle.body.font)
        textView.typingAttributes = typing
        refresh()
        focus()
    }

    private func changeParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let textView else { return }
        let range = paragraphRange
        func changed(_ value: Any?) -> NSParagraphStyle {
            let style = ((value as? NSParagraphStyle) ?? RichTextStyle.body.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
            change(style)
            return style
        }
        if range.length > 0 {
            edit(range) { storage in
                storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                    storage.addAttribute(.paragraphStyle, value: changed(value), range: subrange)
                }
            }
        }
        var typing = textView.typingAttributes
        typing[.paragraphStyle] = changed(typing[.paragraphStyle])
        textView.typingAttributes = typing
        refresh()
        focus()
    }

    /// Scales pictures wider than the page down to fit. Only the displayed size changes, so they stay sharp.
    func fitImages() {
        let limit = maxImageWidth
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let cell = attachment.attachmentCell as? NSTextAttachmentCell
            guard let image = attachment.image ?? cell?.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
                  image.size.width > limit + 0.5, let copy = image.copy() as? NSImage else { return }
            copy.size = NSSize(width: limit, height: image.size.height * limit / image.size.width)
            attachment.image = copy
            cell?.image = copy
            for manager in storage.layoutManagers { manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil) }
        }
    }
}

/// The editor: TextKit 1 so pictures, lists and pagination behave like TextEdit.
struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = NSLayoutManager()
        controller.storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.textContainerInset = NSSize(width: 28, height: 24)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.backgroundColor = .white
        scrollView.documentView = textView
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        // Paper stays white with black text in Dark Mode, matching the PDF.
        scrollView.appearance = NSAppearance(named: .aqua)
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ()) {
        guard let manager = (scrollView.documentView as? NSTextView)?.layoutManager else { return }
        manager.textStorage?.removeLayoutManager(manager)
    }
}

struct RichTextFormatBar: View {
    let controller: RichTextController

    private static let colors: [(String, NSColor)] = [
        ("Black", .black), ("Gray", NSColor(white: 0.45, alpha: 1)), ("Red", NSColor(red: 0.85, green: 0.2, blue: 0.17, alpha: 1)),
        ("Orange", NSColor(red: 0.93, green: 0.5, blue: 0.1, alpha: 1)), ("Green", NSColor(red: 0.15, green: 0.6, blue: 0.3, alpha: 1)),
        ("Blue", NSColor(red: 0.05, green: 0.4, blue: 0.85, alpha: 1)), ("Purple", NSColor(red: 0.5, green: 0.3, blue: 0.85, alpha: 1)),
    ]

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(RichTextStyle.allCases) { style in Button(style.label) { controller.apply(style) } }
            } label: {
                Text(controller.style?.label ?? "Custom").frame(width: 84, alignment: .leading)
            }
            .fixedSize().help("Paragraph style")
            Menu {
                ForEach([9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48], id: \.self) { size in
                    Button("\(size) pt") { controller.setSize(CGFloat(size)) }
                }
            } label: {
                Text("\(Int(controller.fontSize.rounded())) pt").monospacedDigit()
            }
            .fixedSize().help("Font size")
            FormatButton(symbol: "textformat", help: "Fonts…", action: controller.showFontPanel)
            Divider().frame(height: 18)
            FormatButton(symbol: "bold", help: "Bold", isOn: controller.bold, action: controller.toggleBold)
            FormatButton(symbol: "italic", help: "Italic", isOn: controller.italic, action: controller.toggleItalic)
            FormatButton(symbol: "underline", help: "Underline", isOn: controller.underline, action: controller.toggleUnderline)
            FormatButton(symbol: "strikethrough", help: "Strikethrough", isOn: controller.strikethrough, action: controller.toggleStrikethrough)
            Menu {
                ForEach(Self.colors, id: \.0) { name, color in
                    Button { controller.setColor(color) } label: { Label { Text(name) } icon: { Image(nsImage: swatch(color)) } }
                }
                Divider()
                Button("More Colors…", action: controller.showColorPanel)
            } label: {
                Image(systemName: "paintpalette")
            }
            .fixedSize().help("Text color")
            Divider().frame(height: 18)
            FormatButton(symbol: "text.alignleft", help: "Align left", isOn: controller.alignment == .left || controller.alignment == .natural) { controller.setAlignment(.left) }
            FormatButton(symbol: "text.aligncenter", help: "Center", isOn: controller.alignment == .center) { controller.setAlignment(.center) }
            FormatButton(symbol: "text.alignright", help: "Align right", isOn: controller.alignment == .right) { controller.setAlignment(.right) }
            FormatButton(symbol: "text.justify", help: "Justify", isOn: controller.alignment == .justified) { controller.setAlignment(.justified) }
            Divider().frame(height: 18)
            FormatButton(symbol: "list.bullet", help: "Bulleted list") { controller.toggleList(numbered: false) }
            FormatButton(symbol: "list.number", help: "Numbered list") { controller.toggleList(numbered: true) }
            FormatButton(symbol: "photo", help: "Insert pictures…", action: controller.insertImages)
            Spacer(minLength: 0)
            FormatButton(symbol: "eraser", help: "Clear formatting", action: controller.clearFormatting)
        }
        .menuStyle(.borderlessButton)
    }

    private func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct FormatButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Lays rich text out on pages with TextKit, page by page, keeping text selectable and pictures in place.
@MainActor
enum RichTextPDF {
    static func render(_ text: NSAttributedString, setup: PDFPageSetup, to url: URL) throws {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: setup.contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            layoutManager.ensureLayout(for: container)
        } while NSMaxRange(layoutManager.glyphRange(for: containers[containers.count - 1])) < layoutManager.numberOfGlyphs
            && containers.count < 10_000

        var mediaBox = CGRect(origin: .zero, size: setup.size)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        // Resolve dynamic colors as on paper, not in the current appearance.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for container in containers {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                context.translateBy(x: 0, y: setup.size.height)
                context.scaleBy(x: 1, y: -1)
                let range = layoutManager.glyphRange(for: container)
                let origin = CGPoint(x: setup.margin, y: setup.margin)
                layoutManager.drawBackground(forGlyphRange: range, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}

// MARK: - HTML and Markdown

/// Source on the left, a live WebKit preview on the right.
private struct SourceAndPreview: View {
    @Binding var source: String
    let html: String

    var body: some View {
        HStack(spacing: 12) {
            CodeEditor(text: $source)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            HTMLPreview(html: html)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        }
    }
}

/// Plain-text editor for code: monospaced, no smart quotes or autocorrect.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Shows HTML as it will print. Updates are debounced while typing.
struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        webView.underPageBackgroundColor = .white
        context.coordinator.show(html, in: webView, immediately: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(html, in: webView, immediately: false)
    }

    @MainActor
    final class Coordinator {
        private var shown: String?
        private var pending: Task<Void, Never>?

        func show(_ html: String, in webView: WKWebView, immediately: Bool) {
            guard html != shown else { return }
            shown = html
            pending?.cancel()
            pending = Task { [weak webView] in
                if !immediately { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }
                webView?.loadHTMLString(html, baseURL: nil)
            }
        }
    }
}
