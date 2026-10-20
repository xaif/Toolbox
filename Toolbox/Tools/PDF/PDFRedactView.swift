import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// An area to black out. `rect` is normalized (0…1) on the page as displayed, origin bottom-left.
struct PDFRedaction: Sendable, Hashable {
    var pageIndex: Int
    var rect: CGRect
}

struct PDFRedactionOptions: Sendable {
    var dpi: CGFloat = 300
    /// Recognize the text left on redacted pages and add it back as an invisible layer.
    var keepsTextSearchable = true
    var removesMetadata = true
    var ocr = AIOCR.Options()
}

/// Permanent redaction. Pages with redactions are rebuilt from an image with the boxes burned in, so
/// nothing under a box (text, vectors, images or annotations) survives. Other pages are copied intact.
enum PDFRedactor {
    /// Common kinds of sensitive text.
    enum Preset: String, CaseIterable, Identifiable {
        case emails, phoneNumbers, cardNumbers
        var id: Self { self }

        var label: String {
            switch self {
            case .emails: "Email Addresses"
            case .phoneNumbers: "Phone Numbers"
            case .cardNumbers: "Card Numbers"
            }
        }

        var symbol: String {
            switch self {
            case .emails: "at"
            case .phoneNumbers: "phone"
            case .cardNumbers: "creditcard"
            }
        }

        var regex: NSRegularExpression {
            let pattern: String
            switch self {
            case .emails: pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
            case .phoneNumbers: pattern = #"(?<![\w+])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{1,4}\)[\s.-]?)?\d{2,5}(?:[\s.-]?\d{2,5}){1,4}(?!\w)"#
            case .cardNumbers: pattern = #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#
            }
            // The patterns are constant and known to be valid.
            return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        /// Filters out look-alikes such as dates and numbers that fail the card checksum.
        func accepts(_ match: String) -> Bool {
            let digits = match.filter(\.isNumber)
            switch self {
            case .emails: return true
            case .phoneNumbers:
                let date = #"^\d{1,4}[-./]\d{1,2}[-./]\d{1,4}$"#
                return (7...15).contains(digits.count) && match.range(of: date, options: .regularExpression) == nil
            case .cardNumbers: return (13...19).contains(digits.count) && PDFRedactor.passesLuhn(digits)
            }
        }
    }

    /// Text found on a page. `rect` is normalized like `PDFRedaction.rect`.
    struct Match: Sendable {
        var pageIndex: Int
        var rect: CGRect
        var text: String
    }

    static func regex(for text: String, wholeWords: Bool, matchCase: Bool) throws -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !escaped.isEmpty else { throw ToolError.failed("Enter text to find.") }
        let pattern = wholeWords ? #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"# : escaped
        return try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }

    /// Every match of `regex` in the document's text, one rect per line a match spans.
    static func matches(_ regex: NSRegularExpression, in document: PDFDocument, accepts: (String) -> Bool = { _ in true }) -> [Match] {
        var results: [Match] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let string = page.string else { continue }
            let text = string as NSString
            for match in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
                let found = text.substring(with: match.range)
                guard accepts(found), let selection = page.selection(for: match.range) else { continue }
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    results.append(Match(pageIndex: pageIndex, rect: normalizedRect(bounds.insetBy(dx: -1.5, dy: -1.5), on: page),
                                         text: found))
                }
            }
        }
        return results
    }

    /// Converts a rect in page space to normalized displayed space (origin bottom-left).
    static func normalizedRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let size = PDFOps.displaySize(of: page)
        let displayed = rect.applying(page.transform(for: .cropBox)).standardized
        let normalized = CGRect(x: displayed.minX / size.width, y: displayed.minY / size.height,
                                width: displayed.width / size.width, height: displayed.height / size.height)
        return normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 { value *= 2; if value > 9 { value -= 9 } }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Writes a redacted copy of `source` to `url`.
    static func redact(_ source: PDFDocument, redactions: [PDFRedaction], options: PDFRedactionOptions, to url: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !redactions.isEmpty else { throw ToolError.failed("Mark something to redact first.") }
        let document = PDFOps.document(from: source, indices: PDFOps.allPages(source))
        let byPage = Dictionary(grouping: redactions, by: \.pageIndex).sorted { $0.key < $1.key }
        for (position, (pageIndex, marks)) in byPage.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex) else { continue }
            let rects = marks.map(\.rect)
            guard let image = renderRedacted(page, rects: rects, dpi: options.dpi) else {
                throw ToolError.failed("Couldn't render page \(pageIndex + 1).")
            }
            let lines = options.keepsTextSearchable ? try await PDFTextLayer.recognize(image, options: options.ocr) : []
            let size = PDFOps.displaySize(of: page)
            let newPage = try PDFTextLayer.imagePage(image, size: size, lines: lines)
            let toDisplay = page.transform(for: .cropBox)
            let covered = rects.map { CGRect(x: $0.minX * size.width, y: $0.minY * size.height,
                                             width: $0.width * size.width, height: $0.height * size.height) }
            PDFTextLayer.replacePage(at: pageIndex, in: document, with: newPage) { annotation in
                // Everything else on the page is burned into the image; only links clear of every box stay.
                guard annotation.type == "Link" else { return false }
                let bounds = annotation.bounds.applying(toDisplay).standardized
                guard !covered.contains(where: { $0.intersects(bounds) }) else { return false }
                annotation.bounds = bounds
                return true
            }
            progress?(Double(position + 1) / Double(byPage.count) * 0.95)
        }
        if options.removesMetadata {
            document.documentAttributes = [PDFDocumentAttribute.producerAttribute: "Toolbox"]
        }
        try PDFOps.write(document, to: url)
        progress?(1)
    }

    /// The page as displayed at `dpi`, with solid black boxes drawn over `rects`.
    static func renderRedacted(_ page: PDFPage, rects: [CGRect], dpi: CGFloat) -> CGImage? {
        let size = PDFOps.displaySize(of: page)
        let scale = min(dpi / 72, 8000 / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: context)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            context.fill(CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                width: rect.width * size.width, height: rect.height * size.height))
        }
        return context.makeImage()
    }
}

// MARK: - Model

/// State for Redact PDF: the open PDF, the current page and the marked areas.
@MainActor
@Observable
final class PDFRedactModel {
    struct Mark: Identifiable {
        let id = UUID()
        var pageIndex: Int
        /// Normalized rect (0…1) on the displayed page, origin top-left.
        var rect: CGRect
        /// What was found there, or "Area" for boxes drawn by hand.
        var label: String
    }

    static let shared = PDFRedactModel()

    private(set) var url: URL?
    private(set) var document: PDFDocument?
    private(set) var needsPassword = false
    private(set) var loadError: String?
    var pageIndex = 0
    var marks: [Mark] = []
    var selectedMark: Mark.ID?
    private var pageImages: [Int: NSImage] = [:]

    var pageCount: Int { document?.pageCount ?? 0 }
    var isReady: Bool { document != nil && !needsPassword }

    func load(_ newURL: URL?) {
        guard newURL != url else { return }
        url = newURL
        document = nil
        needsPassword = false
        loadError = nil
        pageIndex = 0
        marks = []
        selectedMark = nil
        pageImages = [:]
        guard let newURL else { return }
        guard let opened = PDFDocument(url: newURL), opened.pageCount > 0 else {
            loadError = "Couldn't open “\(newURL.lastPathComponent)”."
            return
        }
        document = opened
        needsPassword = opened.isLocked
    }

    func unlock(_ password: String) -> Bool {
        guard let document, document.unlock(withPassword: password) else { return false }
        needsPassword = false
        return true
    }

    /// Width ÷ height of a page as displayed.
    func pageAspect(_ index: Int) -> CGFloat {
        guard let page = document?.page(at: index) else { return 0.77 }
        let size = PDFOps.displaySize(of: page)
        return size.width / max(size.height, 1)
    }

    func image(for index: Int) -> NSImage? { pageImages[index] }

    func renderPage(_ index: Int) async {
        guard pageImages[index] == nil, let page = document?.page(at: index) else { return }
        let image = await Task.detached(priority: .userInitiated) { PDFOps.thumbnail(page, maxDimension: 1000) }.value
        if let image, document?.page(at: index) === page { pageImages[index] = image }
    }

    func addArea(_ rect: CGRect) {
        let mark = Mark(pageIndex: pageIndex, rect: rect, label: "Area")
        marks.append(mark)
        selectedMark = mark.id
    }

    /// Marks every match not already covered. Returns how many were added.
    @discardableResult
    func add(_ matches: [PDFRedactor.Match]) -> Int {
        var added = 0
        for match in matches {
            let rect = CGRect(x: match.rect.minX, y: 1 - match.rect.maxY, width: match.rect.width, height: match.rect.height)
            let duplicate = marks.contains { $0.pageIndex == match.pageIndex && $0.rect.insetBy(dx: -0.002, dy: -0.002).contains(rect) }
            guard !duplicate else { continue }
            marks.append(Mark(pageIndex: match.pageIndex, rect: rect, label: match.text))
            added += 1
        }
        return added
    }

    func select(_ mark: Mark) {
        pageIndex = mark.pageIndex
        selectedMark = mark.id
    }

    func remove(_ id: Mark.ID) {
        marks.removeAll { $0.id == id }
        if selectedMark == id { selectedMark = nil }
    }

    func deleteSelected() {
        if let selectedMark { remove(selectedMark) }
    }

    func count(onPage index: Int) -> Int { marks.filter { $0.pageIndex == index }.count }

    /// Marks converted for `PDFRedactor` (bottom-left origin).
    var redactions: [PDFRedaction] {
        marks.map { PDFRedaction(pageIndex: $0.pageIndex, rect: CGRect(x: $0.rect.minX, y: 1 - $0.rect.maxY,
                                                                      width: $0.rect.width, height: $0.rect.height)) }
    }
}

// MARK: - View

struct PDFRedactView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model = PDFRedactModel.shared
    @State private var password = ""
    @State private var wrongPassword = false
    @State private var query = ""
    @State private var findMessage: String?
    @State private var searching = false
    @AppStorage("pdf.redact.wholeWords") private var wholeWords = false
    @AppStorage("pdf.redact.matchCase") private var matchCase = false
    @AppStorage("pdf.redact.ocr") private var keepsTextSearchable = true
    @AppStorage("pdf.redact.metadata") private var removesMetadata = true
    @AppStorage("pdf.redact.dpi") private var dpi = 300.0

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, allowsMultiple: false, title: "PDF", noun: "a PDF")
                .disabled(runner.isRunning)
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if model.needsPassword {
                unlockPrompt
            } else if model.isReady {
                HStack(alignment: .top, spacing: 16) {
                    sidebar.frame(width: 260)
                    VStack(spacing: 10) {
                        pageNavigator
                        PDFRedactCanvas(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Redact & Save", canRun: model.isReady && !model.marks.isEmpty,
                   hint: model.isReady ? "Drag on the page or find text to mark what to remove." : "Choose a PDF to redact.",
                   action: save)
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
            findMessage = nil
            if !runner.isRunning { runner.reset() }
        }
    }

    private var unlockPrompt: some View {
        ToolSection("This PDF is locked") {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock).disabled(password.isEmpty)
                if wrongPassword { Text("Incorrect password").foregroundStyle(.red) }
            }
        }
    }

    private func unlock() {
        wrongPassword = !model.unlock(password)
        if !wrongPassword { password = "" }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find & Redact").font(.headline)
                    HStack {
                        TextField("Words or phrases", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(findText)
                        Button("Mark", action: findText)
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                    }
                    HStack(spacing: 14) {
                        Toggle("Whole words", isOn: $wholeWords)
                        Toggle("Match case", isOn: $matchCase)
                    }
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    Text("Or mark every").font(.callout).foregroundStyle(.secondary)
                    ForEach(PDFRedactor.Preset.allCases) { preset in
                        Button { find(preset) } label: {
                            Label(preset.label, systemImage: preset.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(searching)
                    }
                    if let findMessage {
                        Text(findMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }

                markList

                VStack(alignment: .leading, spacing: 8) {
                    Text("Options").font(.headline)
                    Toggle("Keep the rest of the text searchable", isOn: $keepsTextSearchable)
                    Toggle("Remove title, author and other document info", isOn: $removesMetadata)
                    Picker("Quality", selection: $dpi) {
                        Text("150 DPI").tag(150.0)
                        Text("300 DPI").tag(300.0)
                        Text("600 DPI").tag(600.0)
                    }
                    .fixedSize()
                    Text("Pages with redactions are rebuilt as images with the boxes burned in, so the text, pictures and comments underneath are gone for good. Other pages stay as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var markList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Marked").font(.headline)
                if !model.marks.isEmpty {
                    Text("\(model.marks.count)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    Button("Remove All", role: .destructive) { model.marks.removeAll(); model.selectedMark = nil }
                        .buttonStyle(.link)
                }
            }
            if model.marks.isEmpty {
                Text("Nothing yet. Drag on the page to cover an area.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.marks.sorted { ($0.pageIndex, $0.rect.minY) < ($1.pageIndex, $1.rect.minY) }) { mark in
                HStack(spacing: 6) {
                    Text("p. \(mark.pageIndex + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(mark.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.remove(mark.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("Don't redact this")
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(model.selectedMark == mark.id ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { model.select(mark) }
            }
        }
    }

    private var pageNavigator: some View {
        HStack(spacing: 10) {
            Button { model.pageIndex -= 1; model.selectedMark = nil } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Text("Page \(model.pageIndex + 1) of \(model.pageCount)").monospacedDigit()
            Button { model.pageIndex += 1; model.selectedMark = nil } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex >= model.pageCount - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
            Spacer()
            let onPage = model.count(onPage: model.pageIndex)
            if onPage > 0 {
                Text("\(onPage) on this page").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }

    private func findText() {
        do {
            let regex = try PDFRedactor.regex(for: query, wholeWords: wholeWords, matchCase: matchCase)
            search(regex, noun: "“\(query.trimmingCharacters(in: .whitespaces))”") { _ in true }
        } catch {
            findMessage = error.localizedDescription
        }
    }

    private func find(_ preset: PDFRedactor.Preset) {
        search(preset.regex, noun: preset.label.lowercased(), accepts: preset.accepts)
    }

    private func search(_ regex: NSRegularExpression, noun: String, accepts: @escaping @Sendable (String) -> Bool) {
        guard let document = model.document else { return }
        searching = true
        findMessage = "Searching…"
        Task {
            let matches = await Task.detached(priority: .userInitiated) {
                PDFRedactor.matches(regex, in: document, accepts: accepts)
            }.value
            let added = model.add(matches)
            searching = false
            let pages = Set(matches.map(\.pageIndex)).count
            if matches.isEmpty {
                let hasText = (0..<document.pageCount).contains { document.page(at: $0).map(PDFTextLayer.hasText) ?? false }
                findMessage = hasText ? "No \(noun) found." : "No \(noun) found. This PDF has no text layer — make it searchable first, or drag to cover areas."
            } else if added == 0 {
                findMessage = "Every match is already marked."
            } else {
                findMessage = "Marked \(added) match\(added == 1 ? "" : "es") on \(pages) page\(pages == 1 ? "" : "s")."
                if model.count(onPage: model.pageIndex) == 0, let first = matches.first {
                    model.pageIndex = first.pageIndex
                }
            }
        }
    }

    private func save() {
        guard let document = model.document, let url = model.url else { return }
        let options = PDFRedactionOptions(dpi: CGFloat(dpi), keepsTextSearchable: keepsTextSearchable, removesMetadata: removesMetadata)
        let redactions = model.redactions
        runner.start(title: tool.name, inputs: [url]) { context in
            context.setStatus("Redacting \(url.lastPathComponent)")
            try await PDFRedactor.redact(document, redactions: redactions, options: options,
                                         to: context.output(for: url, suffix: "redacted", extension: "pdf")) { context.setProgress($0) }
        }
    }
}

/// The current page with the marked areas on top. Drag to cover an area; drag a mark to move it.
private struct PDFRedactCanvas: View {
    @Bindable var model: PDFRedactModel
    @State private var draft: CGRect?
    @State private var moveStart: CGRect?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let frame = pageFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Group {
                    if let image = model.image(for: model.pageIndex) {
                        Image(nsImage: image).resizable()
                    } else {
                        Rectangle().fill(Color.white).overlay(ProgressView())
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .local)
                        .onChanged { value in
                            focused = true
                            draft = normalized(from: value.startLocation, to: value.location, in: frame)
                        }
                        .onEnded { _ in
                            if let draft, draft.width > 0.004, draft.height > 0.004 { model.addArea(draft) }
                            draft = nil
                        }
                )
                .onTapGesture { model.selectedMark = nil; focused = true }
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                }
                .offset(x: frame.minX, y: frame.minY)

                ForEach($model.marks) { $mark in
                    if mark.pageIndex == model.pageIndex {
                        markView($mark, frame: frame)
                    }
                }

                if let draft {
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .overlay(Rectangle().strokeBorder(Color.documentMarkup, lineWidth: 1))
                        .frame(width: draft.width * frame.width, height: draft.height * frame.height)
                        .offset(x: frame.minX + draft.minX * frame.width, y: frame.minY + draft.minY * frame.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand { model.deleteSelected() }
        .task(id: model.pageIndex) { await model.renderPage(model.pageIndex) }
    }

    private func markView(_ mark: Binding<PDFRedactModel.Mark>, frame: CGRect) -> some View {
        let rect = mark.wrappedValue.rect
        let selected = model.selectedMark == mark.wrappedValue.id
        return Rectangle()
            .fill(Color.black.opacity(selected ? 0.85 : 0.75))
            .overlay(Rectangle().strokeBorder(selected ? Color.documentMarkup : Color.red.opacity(0.7), lineWidth: selected ? 2 : 1))
            .frame(width: max(rect.width * frame.width, 2), height: max(rect.height * frame.height, 2))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if moveStart == nil { moveStart = rect; model.selectedMark = mark.wrappedValue.id; focused = true }
                        guard let start = moveStart else { return }
                        var moved = start.offsetBy(dx: value.translation.width / frame.width, dy: value.translation.height / frame.height)
                        moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                        moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                        mark.wrappedValue.rect = moved
                    }
                    .onEnded { _ in moveStart = nil }
            )
            .onTapGesture { model.selectedMark = mark.wrappedValue.id; focused = true }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button { model.remove(mark.wrappedValue.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 10, y: -10)
                    .help("Remove")
                }
            }
            .help(mark.wrappedValue.label)
            .offset(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height)
    }

    private func normalized(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect {
        func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        let x0 = clamp(start.x / frame.width), y0 = clamp(start.y / frame.height)
        let x1 = clamp(end.x / frame.width), y1 = clamp(end.y / frame.height)
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
    }

    /// The page's rect, aspect-fitted with a margin.
    private func pageFrame(in size: CGSize) -> CGRect {
        let aspect = model.pageAspect(model.pageIndex)
        let available = CGSize(width: max(size.width - 32, 10), height: max(size.height - 32, 10))
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
