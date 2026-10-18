import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Picks one PDF and shows loading problems or the unlock prompt. Shared by the grid tools.
private struct PDFSingleFileHeader: View {
    @Bindable var runner: JobRunner
    let model: PDFPageGridModel

    var body: some View {
        FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, allowsMultiple: false, title: "PDF", noun: "a PDF")
            .disabled(runner.isRunning)
        if let error = model.loadError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if model.needsPassword {
            PDFUnlockPrompt(model: model)
        }
    }
}

/// Field for typing page ranges that drives the grid selection.
private struct PDFRangeSelector: View {
    let model: PDFPageGridModel
    let label: String
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            TextField("e.g. 1-3, 5, 8-", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(apply)
            Button("Select", action: apply).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Button("Select All") { model.selectAll() }
            Button("Clear") { model.clearSelection() }.disabled(model.selection.isEmpty)
        }
        .onChange(of: model.selection) {
            // Reflect clicks in the field so both stay in sync.
            if error == nil { text = PDFOps.rangeString(model.selectedSourceIndices) }
        }
    }

    private func apply() {
        do {
            model.select(sourceIndices: try PDFOps.indices(text, pageCount: model.pageCount))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Organize

struct PDFOrganizeView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model: PDFPageGridModel

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _model = State(initialValue: PDFPageGridModel.shared(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            PDFSingleFileHeader(runner: runner, model: model)
            if model.isReady {
                HStack(spacing: 8) {
                    Group {
                        Button { model.rotateSelected(by: -90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                        Button { model.rotateSelected(by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                        Button { model.duplicateSelected() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                            .disabled(model.selection.count >= model.items.count)
                    }
                    .disabled(model.selection.isEmpty)
                    Spacer()
                    Button("Select All") { model.selectAll() }
                    Button("Revert") { model.resetPages() }.disabled(!model.isEdited)
                }
                .disabled(runner.isRunning)
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                Text(hint).font(.callout).foregroundStyle(.secondary)
                PDFPageGrid(model: model, style: .organize)
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Save PDF", canRun: model.isReady && !model.items.isEmpty,
                   hint: "Choose a PDF to rearrange its pages.", action: save)
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
            if !runner.isRunning { runner.reset() }
        }
    }

    private var hint: String {
        let selected = model.selection.count
        let base = "\(model.items.count) pages"
        let detail = selected > 0 ? " · \(selected) selected" : ""
        return base + detail + " · Drag pages to reorder, ⌘/⇧-click to select several, ⌫ deletes, ⌥←/→ moves."
    }

    private func save() {
        guard let document = model.document, let url = model.url else { return }
        let pages = model.pageRefs
        runner.start(title: tool.name) { context in
            context.setStatus("Saving \(url.lastPathComponent)")
            let output = PDFOps.document(from: document, pages: pages)
            try PDFOps.write(output, to: context.output(for: url, suffix: "organized", extension: "pdf"))
        }
    }
}

// MARK: - Delete pages

struct PDFDeletePagesView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model: PDFPageGridModel

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _model = State(initialValue: PDFPageGridModel.shared(for: tool.id))
    }

    private var selectedCount: Int { model.selection.count }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            PDFSingleFileHeader(runner: runner, model: model)
            if model.isReady {
                PDFRangeSelector(model: model, label: "Pages to delete:")
                    .disabled(runner.isRunning)
                Text(selectedCount == 0
                     ? "Click the pages you want to remove (⇧-click selects a run)."
                     : "\(selectedCount) of \(model.items.count) pages will be deleted.")
                    .font(.callout).foregroundStyle(selectedCount >= model.items.count ? .red : .secondary)
                PDFPageGrid(model: model, style: .markForDeletion)
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner,
                   actionTitle: selectedCount > 0 ? "Delete \(selectedCount) Page\(selectedCount == 1 ? "" : "s")" : "Delete Pages",
                   canRun: model.isReady && selectedCount > 0 && selectedCount < model.items.count,
                   hint: !model.isReady ? "Choose a PDF." : (selectedCount >= model.items.count && selectedCount > 0 ? "A PDF needs at least one page." : "Select pages to delete."),
                   action: run)
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
            if !runner.isRunning { runner.reset() }
        }
    }

    private func run() {
        guard let document = model.document, let url = model.url else { return }
        let keep = model.items.filter { !model.selection.contains($0.id) }.map { PDFPageRef(index: $0.sourceIndex) }
        runner.start(title: tool.name) { context in
            context.setStatus("Saving \(url.lastPathComponent)")
            let output = PDFOps.document(from: document, pages: keep)
            try PDFOps.write(output, to: context.output(for: url, suffix: "edited", extension: "pdf"))
        }
    }
}

// MARK: - Extract pages

struct PDFExtractPagesView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model: PDFPageGridModel
    @State private var separateFiles = false

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _model = State(initialValue: PDFPageGridModel.shared(for: tool.id))
    }

    private var selectedCount: Int { model.selection.count }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            PDFSingleFileHeader(runner: runner, model: model)
            if model.isReady {
                PDFRangeSelector(model: model, label: "Pages to extract:")
                    .disabled(runner.isRunning)
                HStack {
                    Text(selectedCount == 0 ? "Click the pages you want to keep." : "\(selectedCount) of \(model.items.count) pages selected.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Save each page as a separate PDF", isOn: $separateFiles)
                }
                .disabled(runner.isRunning)
                PDFPageGrid(model: model, style: .check)
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Extract", canRun: model.isReady && selectedCount > 0,
                   hint: model.isReady ? "Select pages to extract." : "Choose a PDF.", action: run)
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
            if !runner.isRunning { runner.reset() }
        }
    }

    private func run() {
        guard let document = model.document, let url = model.url else { return }
        let pages = model.selectedSourceIndices
        let separate = separateFiles
        let pageCount = model.pageCount
        runner.start(title: tool.name) { context in
            let base = url.deletingPathExtension().lastPathComponent
            if separate {
                let folder = try context.outputFolder(named: base)
                for (position, index) in pages.enumerated() {
                    try Task.checkCancellation()
                    context.setStatus("Saving page \(index + 1)")
                    let name = "\(base) \(PDFOps.label(for: [index], pageCount: pageCount))"
                    try PDFOps.write(PDFOps.document(from: document, indices: [index]),
                                     to: PDFOps.uniqueURL(in: folder, name: name, extension: "pdf"))
                    context.setProgress(Double(position + 1) / Double(pages.count))
                }
            } else {
                context.setStatus("Saving \(url.lastPathComponent)")
                let ranges = PDFOps.rangeString(pages)
                let suffix = ranges.count <= 30 ? "pages \(ranges)" : "extracted"
                try PDFOps.write(PDFOps.document(from: document, indices: pages),
                                 to: context.output(for: url, suffix: suffix, extension: "pdf"))
            }
        }
    }
}

// MARK: - Split

struct PDFSplitView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: Self { self }
        var label: String {
            switch self {
            case .everyPage: "Every page"
            case .everyN: "Every N pages"
            case .ranges: "Custom ranges"
            }
        }
    }

    @State private var runner: JobRunner
    @State private var preview: PDFPageGridModel
    @State private var mode = Mode.everyPage
    @State private var pagesPerFile = 2
    @State private var ranges = ""

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _preview = State(initialValue: PDFPageGridModel.shared(for: tool.id))
    }

    private var splitMode: PDFSplitMode {
        switch mode {
        case .everyPage: .everyPage
        case .everyN: .everyN(pagesPerFile)
        case .ranges: .ranges(ranges)
        }
    }

    /// Groups for the previewed PDF, or an error message for invalid ranges.
    private var previewGroups: Result<[[Int]], Error>? {
        guard preview.isReady else { return nil }
        if mode == .ranges, ranges.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return Result { try PDFOps.splitGroups(splitMode, pageCount: preview.pageCount) }
    }

    private var canRun: Bool {
        guard !runner.inputs.isEmpty else { return false }
        if mode == .ranges {
            guard !ranges.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            if case .failure = previewGroups { return false }
        }
        return true
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            ToolSection("Split") {
                Picker("Split into", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                switch mode {
                case .everyPage:
                    Text("Each page becomes its own PDF.").foregroundStyle(.secondary)
                case .everyN:
                    Stepper("Pages per file: \(pagesPerFile)", value: $pagesPerFile, in: 1...999)
                case .ranges:
                    HStack {
                        TextField("Ranges, e.g. 1-3, 4-6, 7-", text: $ranges)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        Text("One file per range. “7-” means page 7 to the end.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if case .failure(let error) = previewGroups {
                    Text(error.localizedDescription).foregroundStyle(.red)
                } else if case .success(let groups) = previewGroups {
                    Text("“\(preview.url?.lastPathComponent ?? "")” → \(groups.count) file\(groups.count == 1 ? "" : "s"). Each PDF's files go into their own folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(runner.isRunning)
            if preview.isReady, case .success(let groups) = previewGroups {
                let lookup = Dictionary(groups.enumerated().flatMap { group, pages in pages.map { ($0, group) } },
                                        uniquingKeysWith: { first, _ in first })
                PDFPageGrid(model: preview, style: .preview(group: { lookup[$0] }), thumbnailSize: 96)
                    .frame(minHeight: 160, maxHeight: .infinity)
            } else if preview.needsPassword {
                Label("This PDF is password-protected. Remove the password first with Remove PDF Password.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Split", canRun: canRun,
                   hint: runner.inputs.isEmpty ? "Add PDFs to split." : "Enter page ranges.", action: run)
        }
        .onChange(of: runner.inputs, initial: true) {
            preview.load(runner.inputs.first)
            if !runner.isRunning { runner.reset() }
        }
    }

    private func run() {
        let inputs = runner.inputs
        let mode = splitMode
        runner.start(title: tool.name) { context in
            try await context.forEach(inputs, verb: "Splitting") { input, progress in
                let document = try PDFOps.open(input)
                let groups = try PDFOps.splitGroups(mode, pageCount: document.pageCount)
                let base = input.deletingPathExtension().lastPathComponent
                let folder = try context.outputFolder(named: base)
                for (index, group) in groups.enumerated() {
                    try Task.checkCancellation()
                    let name = "\(base) \(PDFOps.label(for: group, pageCount: document.pageCount))"
                    try PDFOps.write(PDFOps.document(from: document, indices: group),
                                     to: PDFOps.uniqueURL(in: folder, name: name, extension: "pdf"))
                    progress(Double(index + 1) / Double(groups.count))
                }
            }
        }
    }
}
