import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// State for Edit PDF: the open document, the current page, the edits and their undo history.
@MainActor
@Observable
final class PDFEditModel {
    enum Mode: String, CaseIterable, Identifiable {
        case select, editText, addText, whiteout, box
        var id: Self { self }

        var label: String {
            switch self {
            case .select: "Select"
            case .editText: "Edit Text"
            case .addText: "Add Text"
            case .whiteout: "Whiteout"
            case .box: "Box"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .editText: "character.cursor.ibeam"
            case .addText: "textformat"
            case .whiteout: "rectangle.fill"
            case .box: "rectangle"
            }
        }

        var help: String {
            switch self {
            case .select: "Click an edit to select it. Drag to move, drag the corner to resize, ⌫ deletes it."
            case .editText: "Click a line of text to retype it. Press Return when you're done."
            case .addText: "Click where the new text should start, then type."
            case .whiteout: "Drag over anything you want to hide. It's painted in the page's color."
            case .box: "Drag to draw a box."
            }
        }
    }

    static let shared = PDFEditModel()

    private(set) var url: URL?
    private(set) var document: PDFDocument?
    private(set) var needsPassword = false
    private(set) var loadError: String?
    private(set) var pageIndex = 0
    var mode = Mode.select
    /// 1 fits the page in the canvas.
    var zoom: CGFloat = 1
    private(set) var items: [PDFEditItem] = []
    var selection: PDFEditItem.ID?
    /// The text item being typed in.
    private(set) var editing: PDFEditItem.ID?
    /// Style for new text boxes. Follows the last style picked.
    var textStyle = PDFEditTextStyle()
    var boxColor = CGColor(srgbRed: 0.86, green: 0.12, blue: 0.12, alpha: 1)
    var boxFilled = false
    /// The line under the pointer in Edit Text mode, normalized.
    var hoverLine: CGRect?

    private var editingIsNew = false
    private var undoStack: [[PDFEditItem]] = []
    private var redoStack: [[PDFEditItem]] = []
    /// Consecutive changes with the same key (typing, nudging a size) share one undo step.
    private var lastChangeKey: String?
    private var pageImages: [Int: (image: NSImage, detail: Int)] = [:]

    var pageCount: Int { document?.pageCount ?? 0 }
    var isReady: Bool { document != nil && !needsPassword }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load(_ newURL: URL?) {
        guard newURL != url else { return }
        url = newURL
        document = nil
        needsPassword = false
        loadError = nil
        pageIndex = 0
        items = []
        selection = nil
        editing = nil
        hoverLine = nil
        undoStack = []
        redoStack = []
        lastChangeKey = nil
        pageImages = [:]
        zoom = 1
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

    func go(toPage index: Int) {
        guard index >= 0, index < pageCount, index != pageIndex else { return }
        endEditing()
        selection = nil
        hoverLine = nil
        pageIndex = index
    }

    // MARK: Pages

    /// Displayed size of a page in points.
    func pageSize(_ index: Int) -> CGSize {
        guard let page = document?.page(at: index) else { return CGSize(width: 612, height: 792) }
        return PDFOps.displaySize(of: page)
    }

    func image(for index: Int) -> NSImage? { pageImages[index]?.image }

    /// Renders a page for the canvas; `detail` 2 is sharper, for zooming in.
    func renderPage(_ index: Int, detail: Int) async {
        if let cached = pageImages[index], cached.detail >= detail { return }
        guard let page = document?.page(at: index) else { return }
        let image = await Task.detached(priority: .userInitiated) { PDFOps.thumbnail(page, maxDimension: CGFloat(900 * detail)) }.value
        if let image, document?.page(at: index) === page { pageImages[index] = (image, detail) }
    }

    func item(_ id: PDFEditItem.ID?) -> PDFEditItem? { items.first { $0.id == id } }

    func items(onPage index: Int) -> [PDFEditItem] { items.filter { $0.pageIndex == index } }

    // MARK: Undo

    /// Saves the current edits as an undo step before a change.
    func checkpoint(_ key: String? = nil) {
        if let key, key == lastChangeKey { return }
        lastChangeKey = key
        undoStack.append(items)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() {
        endEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        lastChangeKey = nil
        if item(selection) == nil { selection = nil }
    }

    func redo() {
        endEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        lastChangeKey = nil
        if item(selection) == nil { selection = nil }
    }

    // MARK: Editing

    /// A click on the page (normalized, top-left) where there's no edit.
    func tap(at point: CGPoint) {
        let wasEditing = editing != nil
        endEditing()
        switch mode {
        case .select, .whiteout, .box: selection = nil
        case .editText: editLine(at: point)
        case .addText: if !wasEditing { addText(at: point) } else { selection = nil }
        }
    }

    /// Starts retyping the line of existing text at `point`.
    @discardableResult
    func editLine(at point: CGPoint) -> Bool {
        guard let page = document?.page(at: pageIndex),
              let line = PDFEditOps.textLine(on: page, pageIndex: pageIndex, at: point) else { return false }
        checkpoint()
        items.append(line)
        textStyle = line.style
        beginEditing(line.id, isNew: true)
        return true
    }

    func addText(at point: CGPoint) {
        let size = pageSize(pageIndex)
        let width = min(0.4, 1 - point.x)
        let height = PDFEditOps.textSize("", style: textStyle, wraps: true, width: width * size.width).height / size.height
        let rect = CGRect(x: min(point.x, 1 - width), y: min(max(point.y - height / 2, 0), 1 - height), width: width, height: height)
        checkpoint()
        let item = PDFEditItem(pageIndex: pageIndex, rect: rect, kind: .text, style: textStyle)
        items.append(item)
        beginEditing(item.id, isNew: true)
        mode = .select
    }

    /// Adds a whiteout or box over `rect` (normalized), depending on the mode.
    func addBox(_ rect: CGRect) {
        var item = PDFEditItem(pageIndex: pageIndex, rect: rect, kind: .box)
        if mode == .whiteout {
            let page = document?.page(at: pageIndex)
            item.fill = page.map { PDFEditOps.sampleColors($0, in: PDFEditOps.displayRect(rect, pageSize: pageSize(pageIndex))).background }
                ?? CGColor(gray: 1, alpha: 1)
        } else {
            item.stroke = boxColor
            if boxFilled { item.fill = boxColor }
        }
        checkpoint()
        items.append(item)
        selection = item.id
    }

    /// Places a picture or signature in the middle of the current page, `width` of the page wide.
    func place(_ image: CGImage, width: CGFloat = 0.35) {
        endEditing()
        let size = pageSize(pageIndex)
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var w = width
        var h = w * (size.width / size.height) / imageAspect
        if h > 0.8 { w *= 0.8 / h; h = 0.8 }
        let item = PDFEditItem(pageIndex: pageIndex, rect: CGRect(x: 0.5 - w / 2, y: 0.5 - h / 2, width: w, height: h),
                               kind: .image, image: image)
        checkpoint()
        items.append(item)
        selection = item.id
        mode = .select
    }

    func beginEditing(_ id: PDFEditItem.ID, isNew: Bool = false) {
        guard item(id)?.kind == .text else { return }
        if editing != id { endEditing() }
        if !isNew { checkpoint() }
        editing = id
        editingIsNew = isNew
        selection = id
        lastChangeKey = "text-\(id)"
    }

    /// Finishes typing. Lines retyped back to their original words and empty new boxes are dropped.
    func endEditing() {
        guard let id = editing else { return }
        editing = nil
        lastChangeKey = nil
        guard let item = item(id) else { return }
        let unchanged = item.isReplacement ? item.text == item.original : item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard unchanged else { return }
        items.removeAll { $0.id == id }
        if selection == id { selection = nil }
        // A new edit that ended up changing nothing doesn't need the undo step taken when it began.
        if editingIsNew, undoStack.last.map({ $0.count == items.count }) == true { undoStack.removeLast() }
    }

    func setText(_ text: String, for id: PDFEditItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("text-\(id)")
        items[index].text = text
        refit(index)
    }

    func setStyle(_ style: PDFEditTextStyle, for id: PDFEditItem.ID?) {
        textStyle = style
        guard let id, let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .text else { return }
        checkpoint("style-\(id)")
        items[index].style = style
        refit(index)
    }

    func setColors(fill: CGColor?, stroke: CGColor?, for id: PDFEditItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("color-\(id)")
        items[index].fill = fill
        items[index].stroke = stroke
    }

    /// Moves or resizes an item without an undo step (callers take one when a drag starts).
    func setRect(_ rect: CGRect, for id: PDFEditItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].rect = rect
        if items[index].kind == .text { refit(index) }
    }

    /// Resizes a one-line text by changing its font size.
    func setFontSize(_ size: CGFloat, for id: PDFEditItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].style.size = min(max(size, 2), 400)
        textStyle = items[index].style
        refit(index)
    }

    /// Fits a text item's frame to its words: wrapping boxes grow downward, one-line text keeps its centre.
    private func refit(_ index: Int) {
        let item = items[index]
        guard item.kind == .text else { return }
        let size = pageSize(item.pageIndex)
        let needed = PDFEditOps.textSize(item.text, style: item.style, wraps: item.wraps, width: item.rect.width * size.width)
        if item.wraps {
            items[index].rect.size.height = needed.height / size.height
        } else {
            let height = max(needed.height / size.height, item.cover.map { $0.height * 0.9 } ?? 0)
            items[index].rect = CGRect(x: item.rect.minX, y: item.rect.midY - height / 2,
                                       width: needed.width / size.width, height: height)
        }
    }

    func delete(_ id: PDFEditItem.ID) {
        if editing == id { editing = nil }
        checkpoint()
        items.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func deleteSelected() {
        guard let selection, editing == nil else { return }
        delete(selection)
    }

    func removeAll() {
        endEditing()
        guard !items.isEmpty else { return }
        checkpoint()
        items = []
        selection = nil
    }

    func updateHover(at point: CGPoint?) {
        guard mode == .editText, let point, let page = document?.page(at: pageIndex),
              let line = PDFEditOps.lineSelection(on: page, at: point) else {
            if hoverLine != nil { hoverLine = nil }
            return
        }
        let rect = PDFEditOps.normalizedRect(line.bounds, pageSize: pageSize(pageIndex))
        if rect != hoverLine { hoverLine = rect }
    }
}

struct PDFEditView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model = PDFEditModel.shared
    @State private var showingSignatureMaker = false
    @State private var password = ""
    @State private var wrongPassword = false

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
                    PDFEditPalette(model: model, showingSignatureMaker: $showingSignatureMaker)
                        .frame(width: 220)
                    VStack(spacing: 10) {
                        PDFEditToolbar(model: model)
                        PDFEditCanvas(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Save Edited PDF", canRun: model.isReady && !model.items.isEmpty,
                   hint: model.isReady ? "Make a change to save a copy." : "Choose a PDF to edit.", action: save)
        }
        .sheet(isPresented: $showingSignatureMaker) {
            PDFSignatureMakerSheet { model.place($0.image, width: 0.3) }
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
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

    private func save() {
        model.endEditing()
        guard let document = model.document, let url = model.url, !model.items.isEmpty else { return }
        let items = model.items
        runner.start(title: tool.name) { context in
            context.setStatus("Saving \(url.lastPathComponent)")
            // A fresh copy keeps bookmarks intact when pages are replaced.
            let output = PDFOps.document(from: document, indices: PDFOps.allPages(document))
            try PDFEditOps.apply(items, to: output)
            try PDFOps.write(output, to: context.output(for: url, suffix: "edited", extension: "pdf"))
        }
    }
}

// MARK: - Palette

private struct PDFEditPalette: View {
    @Bindable var model: PDFEditModel
    @Binding var showingSignatureMaker: Bool
    @State private var store = PDFSignatureStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tools").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(PDFEditModel.Mode.allCases) { mode in
                        modeButton(mode)
                    }
                    paletteButton("Image…", symbol: "photo", active: false, action: chooseImage)
                }
                Text(model.mode.help)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                properties

                Divider()
                Text("Signatures").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(store.signatures) { signature in
                        Button { model.place(signature.image, width: 0.3) } label: {
                            Image(nsImage: signature.nsImage)
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 34).frame(maxWidth: .infinity)
                                .padding(5)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Place on this page")
                    }
                }
                Button { showingSignatureMaker = true } label: {
                    Label("New Signature…", systemImage: "signature").frame(maxWidth: .infinity)
                }

                Divider()
                Label("Retyped text is painted over, not deleted, so the old words can still be found by copy and search. Use Redact PDF to remove text for good.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private var properties: some View {
        let selected = model.item(model.editing ?? model.selection)
        if let selected, selected.kind == .text {
            Divider()
            Text(selected.isReplacement ? "Retyped Text" : "Text").font(.headline)
            PDFEditStyleControls(style: Binding(get: { model.item(selected.id)?.style ?? model.textStyle },
                                                set: { model.setStyle($0, for: selected.id) }))
            if let original = selected.original {
                Text("Was: \(original)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        } else if let selected, selected.kind == .box {
            Divider()
            Text("Box").font(.headline)
            ColorPicker("Color", selection: Binding(
                get: { model.item(selected.id).flatMap { $0.stroke ?? $0.fill } ?? model.boxColor },
                set: { color in
                    guard let item = model.item(selected.id) else { return }
                    model.setColors(fill: item.fill == nil ? nil : color, stroke: item.stroke == nil ? nil : color, for: selected.id)
                }))
        } else if let selected, selected.kind == .image {
            Divider()
            Text("Image").font(.headline)
            Text("Drag to move it; the corner handle resizes it and keeps its proportions.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if model.mode == .addText {
            Divider()
            Text("New Text").font(.headline)
            PDFEditStyleControls(style: Binding(get: { model.textStyle }, set: { model.setStyle($0, for: nil) }))
        } else if model.mode == .box {
            Divider()
            Text("New Box").font(.headline)
            ColorPicker("Color", selection: $model.boxColor)
            Toggle("Filled", isOn: $model.boxFilled)
        }
    }

    private func modeButton(_ mode: PDFEditModel.Mode) -> some View {
        paletteButton(mode.label, symbol: mode.symbol, active: model.mode == mode) {
            model.endEditing()
            model.mode = mode
            model.hoverLine = nil
        }
    }

    private func paletteButton(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15)).frame(height: 18)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.5))
            .foregroundStyle(active ? Color.accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to place on the page."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let image = PDFEditOps.loadImage(url) { model.place(image) }
    }
}

/// Font, size, style, alignment and color for text.
private struct PDFEditStyleControls: View {
    @Binding var style: PDFEditTextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font", selection: $style.family) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                TextField("Size", value: size, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 52)
                Stepper("Size", value: size, in: 2...400, step: 1).labelsHidden()
                Text("pt").foregroundStyle(.secondary)
                Spacer()
                ColorPicker("Color", selection: $style.color).labelsHidden()
            }
            HStack(spacing: 6) {
                Toggle(isOn: $style.bold) { Image(systemName: "bold") }.toggleStyle(.button).help("Bold")
                Toggle(isOn: $style.italic) { Image(systemName: "italic") }.toggleStyle(.button).help("Italic")
                Picker("Alignment", selection: $style.alignment) {
                    Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                    Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    private var size: Binding<Double> {
        Binding(get: { Double(style.size) }, set: { style.size = CGFloat(min(max($0, 2), 400)) })
    }

    private var families: [String] {
        PDFEditTextStyle.families.contains(style.family) ? PDFEditTextStyle.families : [style.family] + PDFEditTextStyle.families
    }
}

// MARK: - Toolbar

private struct PDFEditToolbar: View {
    @Bindable var model: PDFEditModel
    private static let zooms: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    var body: some View {
        HStack(spacing: 10) {
            Button { model.go(toPage: model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0)
                .help("Previous page")
            Text("Page \(model.pageIndex + 1) of \(model.pageCount)").monospacedDigit()
            Button { model.go(toPage: model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex >= model.pageCount - 1)
                .help("Next page")
            Divider().frame(height: 16)
            Button { step(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.zoom <= Self.zooms.first!)
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out")
            Button(model.zoom == 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%") { model.zoom = 1 }
                .monospacedDigit().frame(minWidth: 52)
                .help("Fit the page")
            Button { step(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.zoom >= Self.zooms.last!)
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in")
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.editing != nil)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo || model.editing != nil)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")
            let count = model.items.count
            if count > 0 {
                let pages = Set(model.items.map(\.pageIndex)).count
                Text("\(count) edit\(count == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Button("Remove All", role: .destructive) { model.removeAll() }
            }
        }
        .buttonStyle(.bordered)
    }

    private func step(_ direction: Int) {
        let zooms = Self.zooms
        if direction > 0 { model.zoom = zooms.first { $0 > model.zoom + 0.01 } ?? zooms.last! }
        else { model.zoom = zooms.last { $0 < model.zoom - 0.01 } ?? zooms.first! }
    }
}

// MARK: - Canvas

/// The current page with the edits drawn on top, plus the handles for selecting, moving and typing.
private struct PDFEditCanvas: View {
    @Bindable var model: PDFEditModel
    @FocusState private var focused: Bool
    @FocusState private var focusedEditor: PDFEditItem.ID?
    /// The box being dragged out in Whiteout and Box modes, normalized.
    @State private var band: CGRect?

    private var detail: Int { model.zoom > 1.3 ? 2 : 1 }

    var body: some View {
        GeometryReader { geometry in
            let fit = fitSize(in: geometry.size)
            let size = CGSize(width: fit.width * model.zoom, height: fit.height * model.zoom)
            ScrollView([.horizontal, .vertical]) {
                page(size: size)
                    .padding(16)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(model.zoom > 1 ? .automatic : .never)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand { model.deleteSelected() }
        .onExitCommand { model.endEditing(); model.selection = nil }
        .task(id: "\(model.pageIndex)-\(detail)-\(model.url?.path ?? "")") { await model.renderPage(model.pageIndex, detail: detail) }
        .onChange(of: model.editing) { focusedEditor = model.editing }
        .onChange(of: focusedEditor) { old, new in
            // Clicking anywhere else ends typing.
            if let old, new != old, model.editing == old { model.endEditing() }
        }
    }

    private func fitSize(in available: CGSize) -> CGSize {
        let pageSize = model.pageSize(model.pageIndex)
        let aspect = pageSize.width / max(pageSize.height, 1)
        let space = CGSize(width: max(available.width - 32, 10), height: max(available.height - 32, 10))
        var width = space.width
        var height = width / aspect
        if height > space.height {
            height = space.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    private func page(size: CGSize) -> some View {
        let pageSize = model.pageSize(model.pageIndex)
        let items = model.items(onPage: model.pageIndex)
        let editing = model.editing
        return ZStack(alignment: .topLeading) {
            Group {
                if let image = model.image(for: model.pageIndex) {
                    Image(nsImage: image).resizable()
                } else {
                    Rectangle().fill(Color.white).overlay(ProgressView())
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .contentShape(Rectangle())
            .gesture(pageGesture(size: size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    model.updateHover(at: normalized(location, in: size))
                    cursor.set()
                case .ended:
                    model.updateHover(at: nil)
                    NSCursor.arrow.set()
                }
            }

            // The same drawing code writes the saved PDF.
            Canvas { context, canvasSize in
                context.withCGContext { cg in
                    cg.translateBy(x: 0, y: canvasSize.height)
                    cg.scaleBy(x: canvasSize.width / pageSize.width, y: -canvasSize.height / pageSize.height)
                    for item in items { PDFEditOps.draw(item, in: cg, pageSize: pageSize, includeText: item.id != editing) }
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)

            if let line = model.hoverLine, model.mode == .editText {
                let rect = frame(line, in: size)
                Rectangle().fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                    .frame(width: rect.width + 4, height: rect.height + 4)
                    .offset(x: rect.minX - 2, y: rect.minY - 2)
                    .allowsHitTesting(false)
            }

            ForEach(items) { item in
                if item.id != editing {
                    PDFEditItemHandle(model: model, item: item, frame: frame(item.rect, in: size), pageFrame: size,
                                      selected: model.selection == item.id, onFocus: { focused = true })
                }
            }

            if let band {
                let rect = frame(band, in: size)
                Rectangle()
                    .fill(model.mode == .whiteout ? Color.white.opacity(0.85) : (model.boxFilled ? Color(cgColor: model.boxColor).opacity(0.5) : .clear))
                    .overlay(Rectangle().strokeBorder(model.mode == .whiteout ? Color.accentColor : Color(cgColor: model.boxColor),
                                                      style: StrokeStyle(lineWidth: 1.5, dash: model.mode == .whiteout ? [4, 3] : [])))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

            if let editing, let item = model.item(editing), item.pageIndex == model.pageIndex {
                editor(for: item, size: size, scale: size.width / pageSize.width)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var cursor: NSCursor {
        switch model.mode {
        case .select: .arrow
        case .editText: model.hoverLine == nil ? .arrow : .iBeam
        case .addText: .iBeam
        case .whiteout, .box: .crosshair
        }
    }

    private func editor(for item: PDFEditItem, size: CGSize, scale: CGFloat) -> some View {
        let rect = frame(item.rect, in: size)
        let text = Binding(get: { model.item(item.id)?.text ?? "" }, set: { model.setText($0, for: item.id) })
        let alignment: TextAlignment = item.style.alignment == .center ? .center : (item.style.alignment == .right ? .trailing : .leading)
        return Group {
            if item.wraps {
                TextField("Type here", text: text, axis: .vertical)
                    .frame(width: rect.width, alignment: .topLeading)
            } else {
                TextField("Type here", text: text)
                    .fixedSize()
                    .frame(minWidth: rect.width, minHeight: rect.height, alignment: .leading)
            }
        }
        .textFieldStyle(.plain)
        .font(Font(item.style.font(scale: scale)))
        .foregroundStyle(Color(cgColor: item.style.color))
        .multilineTextAlignment(alignment)
        .background(item.isReplacement ? Color.clear : Color.white.opacity(0.55))
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1).padding(-2))
        .focused($focusedEditor, equals: item.id)
        .onSubmit { model.endEditing() }
        .id(item.id)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func pageGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.mode == .whiteout || model.mode == .box else { return }
                let a = normalized(value.startLocation, in: size), b = normalized(value.location, in: size)
                band = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 3
                if moved, let band, band.width > 0.004, band.height > 0.003 {
                    model.endEditing()
                    model.addBox(band)
                } else if !moved {
                    model.tap(at: normalized(value.location, in: size))
                }
                band = nil
                if model.editing == nil { focused = true }
            }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    private func frame(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }
}

/// The invisible hit area over an edit: select, move, resize, delete and double-click to retype.
private struct PDFEditItemHandle: View {
    let model: PDFEditModel
    let item: PDFEditItem
    let frame: CGRect
    let pageFrame: CGSize
    let selected: Bool
    let onFocus: () -> Void

    @State private var dragStart: CGRect?
    @State private var fontSizeStart: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: max(frame.width, 6), height: max(frame.height, 6))
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).padding(-2)
                } else if hovering {
                    Rectangle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1).padding(-2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(moveGesture)
            .onTapGesture(count: 2) { if item.kind == .text { model.beginEditing(item.id) } }
            .onTapGesture {
                if item.kind == .text, model.mode == .editText || model.mode == .addText {
                    model.beginEditing(item.id)
                } else {
                    model.endEditing()
                    model.selection = item.id
                    onFocus()
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button { model.delete(item.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 11, y: -11)
                    .help("Remove")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected { resizeHandle }
            }
            .offset(x: frame.minX, y: frame.minY)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    model.endEditing()
                    model.checkpoint()
                    dragStart = item.rect
                    model.selection = item.id
                    onFocus()
                }
                guard let start = dragStart else { return }
                var moved = start.offsetBy(dx: value.translation.width / pageFrame.width, dy: value.translation.height / pageFrame.height)
                moved.origin.x = min(max(moved.minX, -moved.width * 0.5), 1 - moved.width * 0.5)
                moved.origin.y = min(max(moved.minY, -moved.height * 0.5), 1 - moved.height * 0.5)
                model.setRect(moved, for: item.id)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .offset(x: 9, y: 9)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil {
                            model.checkpoint()
                            dragStart = item.rect
                            fontSizeStart = item.style.size
                        }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / pageFrame.width, dy = value.translation.height / pageFrame.height
                        switch item.kind {
                        case .image:
                            // Keep the picture's proportions; height follows width.
                            let aspect = item.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
                            let width = max(start.width + dx, 0.03)
                            model.setRect(CGRect(x: start.minX, y: start.minY, width: width,
                                                 height: width * (pageFrame.width / pageFrame.height) / aspect), for: item.id)
                        case .text where !item.wraps:
                            let factor = max(start.height + dy, 0.004) / start.height
                            model.setFontSize((fontSizeStart * factor * 2).rounded() / 2, for: item.id)
                        case .text:
                            model.setRect(CGRect(x: start.minX, y: start.minY, width: max(start.width + dx, 0.04), height: start.height), for: item.id)
                        case .box:
                            model.setRect(CGRect(x: start.minX, y: start.minY, width: max(start.width + dx, 0.005),
                                                 height: max(start.height + dy, 0.004)), for: item.id)
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
}
