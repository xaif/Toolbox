import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// State for Compare PDFs: both documents, their text differences and what's selected.
@MainActor
@Observable
final class PDFCompareModel {
    enum Mode: String, CaseIterable, Identifiable {
        case text, visual
        var id: Self { self }
        var label: String { self == .text ? "Text Changes" : "Visual Overlay" }
    }

    static let shared = PDFCompareModel()

    private(set) var originalURL: URL?
    private(set) var revisedURL: URL?
    private(set) var original: PDFDocument?
    private(set) var revised: PDFDocument?
    private(set) var diff: PDFTextDiff?
    private(set) var isComparing = false
    private(set) var problem: String?
    private(set) var selectedChange: PDFTextDiff.Change.ID?
    var mode = Mode.text
    var syncScrolling = true { didSet { sync.isEnabled = syncScrolling } }
    var visualPage = 0
    private(set) var visual: PDFCompareOps.VisualDifference?
    /// Bumped to scroll both documents to the selected change.
    private(set) var jumpRequest = 0
    /// Bumped when highlight colors change.
    private(set) var highlightRevision = 0
    private(set) var originalHighlights: [PDFSelection] = []
    private(set) var revisedHighlights: [PDFSelection] = []
    @ObservationIgnored let sync = PDFCompareSync()
    @ObservationIgnored private var selectionsByChange: [Int: (original: [PDFSelection], revised: [PDFSelection])] = [:]
    @ObservationIgnored private var compareTask: Task<Void, Never>?

    var isReady: Bool { original != nil && revised != nil }
    var visualPageCount: Int { max(original?.pageCount ?? 0, revised?.pageCount ?? 0) }

    func load(original newOriginal: URL?, revised newRevised: URL?) {
        guard newOriginal != originalURL || newRevised != revisedURL else { return }
        compareTask?.cancel()
        originalURL = newOriginal
        revisedURL = newRevised
        diff = nil
        visual = nil
        visualPage = 0
        selectedChange = nil
        selectionsByChange = [:]
        originalHighlights = []
        revisedHighlights = []
        isComparing = false
        problem = nil
        original = open(newOriginal)
        revised = open(newRevised)
        guard let newOriginal, let newRevised, original != nil, revised != nil else { return }
        if newOriginal == newRevised { problem = "Both sides are the same file. Choose a different revision." }
        isComparing = true
        compareTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> PDFTextDiff? in
                guard let a = PDFDocument(url: newOriginal), let b = PDFDocument(url: newRevised) else { return nil }
                return PDFTextDiff(original: a, revised: b)
            }.value
            guard !Task.isCancelled, originalURL == newOriginal, revisedURL == newRevised else { return }
            isComparing = false
            guard let result else {
                problem = "Couldn't read the documents' text."
                return
            }
            show(result)
        }
    }

    func swap() { load(original: revisedURL, revised: originalURL) }

    private func open(_ url: URL?) -> PDFDocument? {
        guard let url else { return nil }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            problem = "Couldn't open “\(url.lastPathComponent)”."
            return nil
        }
        if document.isLocked {
            problem = "“\(url.lastPathComponent)” is password-protected. Unlock it first with Remove PDF Password."
            return nil
        }
        return document
    }

    private func show(_ result: PDFTextDiff) {
        diff = result
        guard let original, let revised else { return }
        for change in result.changes {
            selectionsByChange[change.id] = (PDFTextDiff.selections(change.removed, of: result.original, in: original),
                                             PDFTextDiff.selections(change.added, of: result.revised, in: revised))
        }
        recolor()
    }

    func select(_ id: PDFTextDiff.Change.ID?) {
        guard id != selectedChange else {
            if id != nil { jumpRequest += 1 }
            return
        }
        selectedChange = id
        recolor()
        if id != nil { jumpRequest += 1 }
    }

    func selections(for id: PDFTextDiff.Change.ID?, on side: PDFCompareSide) -> [PDFSelection] {
        guard let id, let pair = selectionsByChange[id] else { return [] }
        return side == .original ? pair.original : pair.revised
    }

    private func recolor() {
        let removed = NSColor.systemRed.withAlphaComponent(0.32), added = NSColor.systemGreen.withAlphaComponent(0.32)
        let current = NSColor.systemOrange.withAlphaComponent(0.55)
        var left: [PDFSelection] = [], right: [PDFSelection] = []
        for (id, pair) in selectionsByChange {
            for selection in pair.original { selection.color = id == selectedChange ? current : removed }
            for selection in pair.revised { selection.color = id == selectedChange ? current : added }
            left += pair.original
            right += pair.revised
        }
        originalHighlights = left
        revisedHighlights = right
        highlightRevision += 1
    }

    func renderVisual() async {
        guard let originalURL, let revisedURL else { return }
        let index = visualPage
        let result = await Task.detached(priority: .userInitiated) { () -> PDFCompareOps.VisualDifference? in
            // Separate copies: the on-screen documents belong to their views.
            let a = PDFDocument(url: originalURL), b = PDFDocument(url: revisedURL)
            return PDFCompareOps.visualDifference(original: a?.page(at: index), revised: b?.page(at: index))
        }.value
        if index == visualPage, originalURL == self.originalURL, revisedURL == self.revisedURL { visual = result }
    }
}

struct PDFCompareView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model = PDFCompareModel.shared

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            HStack(alignment: .top, spacing: 16) {
                FileListInput(files: slot(.original), accepts: UTType.pdfInputs, allowsMultiple: false, title: "Original", noun: "a PDF")
                if model.originalURL != nil || model.revisedURL != nil {
                    Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .help("Swap original and revised")
                        .padding(.top, 26)
                }
                FileListInput(files: slot(.revised), accepts: UTType.pdfInputs, allowsMultiple: false, title: "Revised", noun: "a PDF")
            }
            .disabled(runner.isRunning)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if model.isReady {
                toolbar
                switch model.mode {
                case .text: textComparison
                case .visual: visualComparison
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Export Report", canRun: model.diff != nil,
                   hint: model.isReady ? "Comparing…" : "Choose the original and revised PDFs.",
                   idleMessage: "Export a PDF listing every change.", action: exportReport)
        }
        .onChange(of: runner.inputs, initial: true) {
            // Files handed over from the launcher or Finder: the first is the original, the second the revision.
            let pdfs = runner.inputs.filter { $0.pathExtension.lowercased() == "pdf" }
            if pdfs.count >= 2 { model.load(original: pdfs[0], revised: pdfs[1]) }
            else if let first = pdfs.first, model.originalURL == nil { model.load(original: first, revised: model.revisedURL) }
            if !runner.isRunning { runner.reset() }
        }
    }

    private func slot(_ side: PDFCompareSide) -> Binding<[URL]> {
        Binding(get: {
            (side == .original ? model.originalURL : model.revisedURL).map { [$0] } ?? []
        }, set: { urls in
            if side == .original { model.load(original: urls.first, revised: model.revisedURL) }
            else { model.load(original: model.originalURL, revised: urls.first) }
            runner.reset()
        })
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $model.mode) {
                ForEach(PDFCompareModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if model.mode == .text {
                Toggle("Sync scrolling", isOn: $model.syncScrolling)
            }
            Spacer()
            if model.isComparing {
                ProgressView().controlSize(.small)
                Text("Comparing text…").foregroundStyle(.secondary)
            } else if let diff = model.diff {
                if diff.changes.isEmpty {
                    Label(diff.original.isEmpty && diff.revised.isEmpty ? "No text found — try Visual Overlay" : "No text differences",
                          systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Text("\(diff.changes.count) change\(diff.changes.count == 1 ? "" : "s")").fontWeight(.semibold)
                    Text("−\(diff.removedWordCount)").foregroundStyle(.red).monospacedDigit()
                        .help("Words only in the original")
                    Text("+\(diff.addedWordCount)").foregroundStyle(.green).monospacedDigit()
                        .help("Words only in the revision")
                }
            }
        }
    }

    // MARK: Text changes

    private var textComparison: some View {
        HStack(spacing: 12) {
            if let original = model.original, let revised = model.revised {
                documentPane("Original", url: model.originalURL) {
                    PDFCompareDocumentView(document: original, side: .original, model: model,
                                           highlightRevision: model.highlightRevision, jumpRequest: model.jumpRequest)
                }
                documentPane("Revised", url: model.revisedURL) {
                    PDFCompareDocumentView(document: revised, side: .revised, model: model,
                                           highlightRevision: model.highlightRevision, jumpRequest: model.jumpRequest)
                }
            }
            changesList.frame(width: 250)
        }
        .frame(maxHeight: .infinity)
    }

    private func documentPane(_ title: String, url: URL?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(url?.lastPathComponent ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            content()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var changesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes").font(.headline)
            Group {
                if let diff = model.diff, !diff.changes.isEmpty {
                    List(selection: Binding(get: { model.selectedChange }, set: { model.select($0) })) {
                        ForEach(diff.changes) { change in
                            PDFCompareChangeRow(change: change, diff: diff).tag(change.id)
                        }
                    }
                    .listStyle(.inset)
                } else {
                    VStack {
                        if model.isComparing { ProgressView() }
                        else { Text("Differences appear here.").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.06))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(spacing: 10) {
                Label("Removed", systemImage: "square.fill").foregroundStyle(.red.opacity(0.7))
                Label("Added", systemImage: "square.fill").foregroundStyle(.green.opacity(0.7))
            }
            .font(.caption)
        }
    }

    // MARK: Visual overlay

    private var visualComparison: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.visualPage -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(model.visualPage == 0)
                Text("Page \(model.visualPage + 1) of \(model.visualPageCount)").monospacedDigit()
                Button { model.visualPage += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(model.visualPage >= model.visualPageCount - 1)
                Spacer()
                Label("Only in original", systemImage: "square.fill").foregroundStyle(.red)
                Label("Only in revised", systemImage: "square.fill").foregroundStyle(.green)
                if let visual = model.visual {
                    Text(visual.changedFraction == 0 ? "Pages are identical"
                         : "\(String(format: visual.changedFraction < 0.001 ? "%.2f" : "%.1f", visual.changedFraction * 100))% of the page differs")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .buttonStyle(.bordered)
            Group {
                if let visual = model.visual {
                    Image(nsImage: NSImage(cgImage: visual.image, size: CGSize(width: visual.image.width, height: visual.image.height)))
                        .resizable().aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxHeight: .infinity)
        .task(id: "\(model.visualPage)-\(model.originalURL?.path ?? "")-\(model.revisedURL?.path ?? "")") { await model.renderVisual() }
    }

    private func exportReport() {
        guard let diff = model.diff, let originalURL = model.originalURL, let revisedURL = model.revisedURL else { return }
        let name = "\(originalURL.deletingPathExtension().lastPathComponent) vs \(revisedURL.deletingPathExtension().lastPathComponent)"
        runner.start(title: tool.name, inputs: [revisedURL]) { context in
            context.setStatus("Writing the report")
            let report = PDFCompareOps.report(diff, originalName: originalURL.lastPathComponent, revisedName: revisedURL.lastPathComponent)
            try DocumentConverter.renderPDF(report, to: context.output(named: name + " changes", extension: "pdf", nextTo: revisedURL))
        }
    }
}

private struct PDFCompareChangeRow: View {
    let change: PDFTextDiff.Change
    let diff: PDFTextDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text("Page \(diff.page(of: change, on: .original) + 1) → \(diff.page(of: change, on: .revised) + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !change.removed.isEmpty {
                Text(snippet(diff.text(of: change, on: .original))).strikethrough().foregroundStyle(.red).lineLimit(3)
            }
            if !change.added.isEmpty {
                Text(snippet(diff.text(of: change, on: .revised))).foregroundStyle(.green).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch change.kind {
        case .removed: "minus.circle.fill"
        case .added: "plus.circle.fill"
        case .changed: "arrow.left.arrow.right.circle.fill"
        }
    }

    private var tint: Color {
        switch change.kind {
        case .removed: .red
        case .added: .green
        case .changed: .orange
        }
    }

    private func snippet(_ text: String) -> String { text.count > 160 ? String(text.prefix(160)) + "…" : text }
}

/// One side of the comparison, with highlights, and scrolling and zoom kept in step with the other side.
private struct PDFCompareDocumentView: NSViewRepresentable {
    let document: PDFDocument
    let side: PDFCompareSide
    let model: PDFCompareModel
    /// Passed in so SwiftUI updates the view when highlights change or a jump is requested.
    let highlightRevision: Int
    let jumpRequest: Int

    final class Coordinator {
        var highlightRevision = -1
        var jumpRequest = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.underPageBackgroundColor
        view.document = document
        model.sync.register(view, side: side)
        context.coordinator.jumpRequest = jumpRequest
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            model.sync.register(view, side: side)
            context.coordinator.highlightRevision = -1
        }
        if context.coordinator.highlightRevision != highlightRevision {
            context.coordinator.highlightRevision = highlightRevision
            view.highlightedSelections = side == .original ? model.originalHighlights : model.revisedHighlights
        }
        if context.coordinator.jumpRequest != jumpRequest {
            context.coordinator.jumpRequest = jumpRequest
            model.sync.pause()
            if let selection = model.selections(for: model.selectedChange, on: side).first {
                view.go(to: selection)
            } else if let id = model.selectedChange, let change = model.diff?.changes.first(where: { $0.id == id }),
                      let page = document.page(at: model.diff?.page(of: change, on: side) ?? 0) {
                view.go(to: page)
            }
        }
    }
}

/// Keeps two PDF views at the same page and spot on the page, and at the same zoom.
@MainActor
final class PDFCompareSync {
    var isEnabled = true
    private weak var original: PDFView?
    private weak var revised: PDFView?
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var isApplying = false
    private var pausedUntil = Date.distantPast

    func register(_ view: PDFView, side: PDFCompareSide) {
        if side == .original { original = view } else { revised = view }
        // The scroll view exists once the document is laid out.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.observe(view)
        }
    }

    /// Stops syncing briefly while both sides jump to a change on their own.
    func pause() { pausedUntil = Date().addingTimeInterval(0.4) }

    private func observe(_ view: PDFView) {
        let key = ObjectIdentifier(view)
        observers[key]?.forEach(NotificationCenter.default.removeObserver)
        var tokens: [NSObjectProtocol] = []
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            // Delivered synchronously, so `isApplying` stops the other view echoing the scroll back.
            tokens.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self, weak view] _ in
                MainActor.assumeIsolated { if let view { self?.scrolled(view) } }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: nil) { [weak self, weak view] _ in
            MainActor.assumeIsolated { if let view { self?.zoomed(view) } }
        })
        observers[key] = tokens
    }

    private func counterpart(of view: PDFView) -> PDFView? { view === original ? revised : (view === revised ? original : nil) }

    private func scrolled(_ source: PDFView) {
        guard isEnabled, !isApplying, Date() > pausedUntil, let target = counterpart(of: source),
              let position = Self.position(in: source) else { return }
        isApplying = true
        Self.scroll(target, to: position)
        isApplying = false
    }

    private func zoomed(_ source: PDFView) {
        guard isEnabled, !isApplying, let target = counterpart(of: source), abs(target.scaleFactor - source.scaleFactor) > 0.001 else { return }
        isApplying = true
        target.scaleFactor = source.scaleFactor
        isApplying = false
    }

    private static func topPoint(of view: PDFView) -> CGPoint {
        CGPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY + 1 : view.bounds.maxY - 1)
    }

    /// The page at the top of the view and how far down it the view starts (0…1).
    static func position(in view: PDFView) -> (page: Int, fraction: CGFloat)? {
        guard let document = view.document else { return nil }
        let top = topPoint(of: view)
        guard let page = view.page(for: top, nearest: true) else { return nil }
        let point = view.convert(top, to: page)
        let bounds = page.bounds(for: view.displayBox)
        return (document.index(for: page), (bounds.maxY - point.y) / max(bounds.height, 1))
    }

    static func scroll(_ view: PDFView, to position: (page: Int, fraction: CGFloat)) {
        guard let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(max(position.page, 0), document.pageCount - 1)),
              let documentView = view.documentView, let scrollView = documentView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let bounds = page.bounds(for: view.displayBox)
        let pagePoint = CGPoint(x: bounds.midX, y: bounds.maxY - min(max(position.fraction, 0), 1) * bounds.height)
        let wanted = documentView.convert(view.convert(pagePoint, from: page), from: view)
        let current = documentView.convert(topPoint(of: view), from: view)
        var origin = clip.bounds.origin
        origin.y += wanted.y - current.y
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(constrained.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: constrained)
        scrollView.reflectScrolledClipView(clip)
    }
}
