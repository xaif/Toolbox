import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// State for the Sign tool: the open PDF, the current page and signature placements.
@MainActor
@Observable
final class PDFSignModel {
    struct Placement: Identifiable {
        let id = UUID()
        var pageIndex: Int
        /// Normalized rect (0…1) on the displayed page, origin top-left.
        var rect: CGRect
        let image: CGImage

        var imageAspect: CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }
    }

    static let shared = PDFSignModel()

    private(set) var url: URL?
    private(set) var document: PDFDocument?
    private(set) var needsPassword = false
    private(set) var loadError: String?
    var pageIndex = 0
    var placements: [Placement] = []
    var selectedPlacement: Placement.ID?
    var activeSignature: PDFSavedSignature?
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
        placements = []
        selectedPlacement = nil
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
        let image = await Task.detached(priority: .userInitiated) { PDFOps.thumbnail(page, maxDimension: 900) }.value
        if let image, document?.page(at: index) === page { pageImages[index] = image }
    }

    /// Places the active signature centred on `point` (normalized, top-left origin).
    func place(at point: CGPoint) {
        guard let signature = activeSignature else { return }
        let pageAspect = pageAspect(pageIndex)
        let width: CGFloat = 0.3
        let height = width * pageAspect / signature.aspectRatio
        var rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
        rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
        let placement = Placement(pageIndex: pageIndex, rect: rect, image: signature.image)
        placements.append(placement)
        selectedPlacement = placement.id
    }

    func deleteSelected() {
        placements.removeAll { $0.id == selectedPlacement }
        selectedPlacement = nil
    }

    func count(onPage index: Int) -> Int { placements.filter { $0.pageIndex == index }.count }

    /// Placements converted for `PDFOps.applyStamps` (bottom-left origin).
    var stamps: [PDFStampPlacement] {
        placements.map {
            PDFStampPlacement(pageIndex: $0.pageIndex,
                              rect: CGRect(x: $0.rect.minX, y: 1 - $0.rect.maxY, width: $0.rect.width, height: $0.rect.height),
                              image: $0.image)
        }
    }
}

struct PDFSignView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model = PDFSignModel.shared
    @State private var store = PDFSignatureStore.shared
    @State private var showingMaker = false
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
                    signaturePalette
                        .frame(width: 210)
                    VStack(spacing: 10) {
                        pageNavigator
                        PDFSignCanvas(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Save Signed PDF", canRun: model.isReady && !model.placements.isEmpty,
                   hint: model.isReady ? "Place a signature on a page." : "Choose a PDF to sign.", action: save)
        }
        .sheet(isPresented: $showingMaker) {
            PDFSignatureMakerSheet { model.activeSignature = $0 }
        }
        .onChange(of: runner.inputs, initial: true) {
            model.load(runner.inputs.first)
            if !runner.isRunning { runner.reset() }
        }
        .onAppear {
            if model.activeSignature == nil { model.activeSignature = store.signatures.first }
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

    private var signaturePalette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signatures").font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.signatures) { signature in
                        let active = model.activeSignature?.id == signature.id
                        Button { model.activeSignature = signature } label: {
                            Image(nsImage: signature.nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 54)
                                .frame(maxWidth: .infinity)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(active ? Color.documentMarkup : Color.secondary.opacity(0.25), lineWidth: active ? 2.5 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(signature.fileURL == nil ? "Not saved — only for this session" : "Saved signature")
                        .contextMenu {
                            Button("Delete Signature", role: .destructive) {
                                if model.activeSignature?.id == signature.id { model.activeSignature = nil }
                                store.delete(signature)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Button { showingMaker = true } label: {
                Label("New Signature…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Text(model.activeSignature == nil
                 ? "Create a signature to get started."
                 : "Click the page to place the selected signature. Drag to move it, drag its corner to resize, ⌫ removes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageNavigator: some View {
        HStack(spacing: 10) {
            Button { model.pageIndex -= 1; model.selectedPlacement = nil } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Text("Page \(model.pageIndex + 1) of \(model.pageCount)").monospacedDigit()
            Button { model.pageIndex += 1; model.selectedPlacement = nil } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex >= model.pageCount - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
            Spacer()
            let total = model.placements.count
            if total > 0 {
                let pages = Set(model.placements.map(\.pageIndex)).count
                Text("\(total) signature\(total == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Button("Remove All", role: .destructive) { model.placements.removeAll(); model.selectedPlacement = nil }
            }
        }
        .buttonStyle(.bordered)
    }

    private func save() {
        guard let document = model.document, let url = model.url else { return }
        let stamps = model.stamps
        runner.start(title: tool.name) { context in
            context.setStatus("Signing \(url.lastPathComponent)")
            // A fresh copy keeps bookmarks intact when pages are replaced.
            let output = PDFOps.document(from: document, indices: PDFOps.allPages(document))
            try PDFOps.applyStamps(stamps, to: output)
            try PDFOps.write(output, to: context.output(for: url, suffix: "signed", extension: "pdf"))
        }
    }
}

/// The current page with draggable, resizable signature placements on top.
private struct PDFSignCanvas: View {
    @Bindable var model: PDFSignModel
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
                .offset(x: frame.minX, y: frame.minY)
                .onTapGesture(coordinateSpace: .local) { location in
                    focused = true
                    if model.selectedPlacement != nil {
                        model.selectedPlacement = nil
                    } else {
                        model.place(at: CGPoint(x: location.x / frame.width, y: location.y / frame.height))
                    }
                }
                .onContinuousHover { phase in
                    if case .active = phase, model.activeSignature != nil { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                }

                ForEach($model.placements) { $placement in
                    if placement.pageIndex == model.pageIndex {
                        PDFPlacementView(placement: $placement, frame: frame,
                                         selected: model.selectedPlacement == placement.id,
                                         onSelect: { model.selectedPlacement = placement.id; focused = true },
                                         onDelete: { model.selectedPlacement = placement.id; model.deleteSelected() })
                    }
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

private struct PDFPlacementView: View {
    @Binding var placement: PDFSignModel.Placement
    let frame: CGRect
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var dragStart: CGRect?

    var body: some View {
        let rect = CGRect(x: frame.minX + placement.rect.minX * frame.width,
                          y: frame.minY + placement.rect.minY * frame.height,
                          width: placement.rect.width * frame.width,
                          height: placement.rect.height * frame.height)
        Image(nsImage: NSImage(cgImage: placement.image, size: CGSize(width: placement.image.width, height: placement.image.height)))
            .resizable()
            .frame(width: rect.width, height: rect.height)
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.documentMarkup, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = placement.rect; onSelect() }
                        guard let start = dragStart else { return }
                        var moved = start.offsetBy(dx: value.translation.width / frame.width, dy: value.translation.height / frame.height)
                        moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                        moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                        placement.rect = moved
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(perform: onSelect)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button(action: onDelete) {
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
            .overlay(alignment: .bottomTrailing) {
                if selected { resizeHandle }
            }
            .offset(x: rect.minX, y: rect.minY)
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.documentMarkup)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .offset(x: 7, y: 7)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = placement.rect }
                        guard let start = dragStart else { return }
                        // Keep the signature's aspect ratio; height follows width.
                        let pageAspect = frame.width / max(frame.height, 1)
                        var width = start.width + value.translation.width / frame.width
                        width = min(max(width, 0.04), 1 - start.minX)
                        var height = width * pageAspect / placement.imageAspect
                        if start.minY + height > 1 {
                            height = 1 - start.minY
                            width = height * placement.imageAspect / pageAspect
                        }
                        placement.rect = CGRect(x: start.minX, y: start.minY, width: width, height: height)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
    }
}
