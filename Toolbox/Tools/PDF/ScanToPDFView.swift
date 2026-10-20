@preconcurrency import AVFoundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// The pages scanned so far. One model for the app, so a scan survives navigating away and back.
@MainActor
@Observable
final class ScanModel {
    struct Page: Identifiable {
        let id = UUID()
        /// The photo as captured, encoded.
        let source: Data
        /// A small copy of the photo for previews and the crop editor.
        let thumbnail: CGImage
        var quad: ScanQuad
        /// What detection found, for "Auto Detect" after manual edits.
        let detectedQuad: ScanQuad?
        var filter: ScanFilter
        var rotation = 0
        /// The processed page at preview size.
        var preview: NSImage?
        /// Bumped on every edit, so stale previews are dropped.
        var revision = 0

        var spec: ScanPageSpec { ScanPageSpec(source: source, quad: quad, filter: filter, rotation: rotation) }
    }

    static let shared = ScanModel()

    var pages: [Page] = []
    var selection: Page.ID?
    /// Photos still being read and detected.
    private(set) var pending = 0
    var message: String?

    var selectedIndex: Int? { pages.firstIndex { $0.id == selection } }

    /// Adds photos. With `detect`, finds each document's edges; otherwise keeps the whole photo
    /// (for scans that are already cropped, like iPhone document scans).
    func add(_ images: [CGImage], detect: Bool, filter: ScanFilter) {
        guard !images.isEmpty else { return }
        pending += images.count
        Task {
            var found = 0
            for image in images {
                let prepared = await Task.detached(priority: .userInitiated) { () -> (Data, CGImage, ScanQuad?)? in
                    guard let data = ScanProcessor.encode(image),
                          let thumbnail = ScanProcessor.image(from: data, maxPixels: 1400) else { return nil }
                    return (data, thumbnail, detect ? await ScanProcessor.detectQuad(thumbnail) : nil)
                }.value
                pending -= 1
                guard let (data, thumbnail, quad) = prepared else { continue }
                if quad != nil { found += 1 }
                let page = Page(source: data, thumbnail: thumbnail, quad: quad ?? .full, detectedQuad: quad, filter: filter)
                pages.append(page)
                selection = page.id
                refreshPreview(page.id)
            }
            if detect {
                let missed = images.count - found
                message = missed == 0 ? nil
                    : "Couldn't find the edges of \(missed == 1 ? "a page" : "\(missed) pages"). Use Adjust Crop to set them."
            }
        }
    }

    /// Imports images and PDFs from Finder.
    func importFiles(_ urls: [URL], filter: ScanFilter) {
        var photos: [CGImage] = []
        var scanned: [CGImage] = []
        for url in urls {
            if FileListInput.conforms(url, to: [.pdf]) {
                if let document = PDFDocument(url: url), !document.isLocked { scanned += ScanProcessor.images(fromPDF: document) }
            } else if let image = ScanProcessor.image(at: url) {
                photos.append(image)
            }
        }
        add(photos, detect: true, filter: filter)
        add(scanned, detect: false, filter: .original)
        if photos.isEmpty, scanned.isEmpty { message = "Those files couldn't be read as images or PDFs." }
    }

    /// Reads what Continuity Camera sends: a PDF for Scan Documents, an image for Take Photo.
    func importPasteboard(_ pasteboard: NSPasteboard, filter: ScanFilter) -> Bool {
        if let data = pasteboard.data(forType: .pdf), let document = PDFDocument(data: data) {
            add(ScanProcessor.images(fromPDF: document), detect: false, filter: .original)
            return true
        }
        let images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? [])
            .compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard !images.isEmpty else { return false }
        add(images, detect: true, filter: filter)
        return true
    }

    func update(_ id: Page.ID, _ change: (inout Page) -> Void) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        change(&pages[index])
        pages[index].revision += 1
        refreshPreview(id)
    }

    func rotate(_ id: Page.ID, by degrees: Int) {
        update(id) { $0.rotation = (($0.rotation + degrees) % 360 + 360) % 360 }
    }

    func delete(_ id: Page.ID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        if selection == id { selection = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id }
    }

    func setFilterForAll(_ filter: ScanFilter) {
        for page in pages where page.filter != filter { update(page.id) { $0.filter = filter } }
    }

    func removeAll() {
        pages = []
        selection = nil
        message = nil
    }

    private func refreshPreview(_ id: Page.ID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        let revision = page.revision
        let thumbnail = page.thumbnail, quad = page.quad, filter = page.filter, rotation = page.rotation
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ScanProcessor.process(thumbnail, quad: quad, filter: filter, rotation: rotation)
            }.value
            guard let image, let index = pages.firstIndex(where: { $0.id == id }), pages[index].revision == revision else { return }
            pages[index].preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
    }
}

// MARK: - View

struct ScanToPDFView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var model = ScanModel.shared
    @State private var showingCamera = false
    @State private var adjustingCrop = false
    @State private var dropTargeted = false
    @AppStorage("pdf.scan.filter") private var defaultFilter = ScanFilter.color
    @AppStorage("pdf.scan.pageSize") private var pageSize = PDFImageLayout.PageSize.fit
    @AppStorage("pdf.scan.ocr") private var searchable = true
    @AppStorage("pdf.scan.quality") private var quality = 0.8

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner, scrolls: false) {
            sources.disabled(runner.isRunning)
            if let message = model.message {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if model.pages.isEmpty, model.pending == 0 {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 16) {
                    pageList.frame(width: 170)
                    editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                .disabled(runner.isRunning)
                options.disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Save PDF", canRun: !model.pages.isEmpty && model.pending == 0,
                   hint: model.pending > 0 ? "Reading pages…" : "Scan or import pages to get started.", action: save)
        }
        .sheet(isPresented: $showingCamera) {
            ScanCameraSheet { model.add([$0], detect: true, filter: defaultFilter) }
        }
        .onChange(of: model.pages.count) { if !runner.isRunning { runner.reset() } }
    }

    private var sources: some View {
        HStack(spacing: 10) {
            ContinuityImportButton { model.importPasteboard($0, filter: defaultFilter) }
                .fixedSize()
                .help("Scan pages with your iPhone or iPad. Choose Scan Documents in the menu.")
            Button { showingCamera = true } label: { Label("Camera…", systemImage: "camera") }
                .help("Scan with this Mac's camera or a Continuity Camera")
            Button(action: choosePhotos) { Label("Import Photos…", systemImage: "photo.on.rectangle") }
            Spacer()
            if model.pending > 0 { ProgressView().controlSize(.small) }
            if !model.pages.isEmpty {
                Text("\(model.pages.count) page\(model.pages.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Button("Remove All", role: .destructive) { model.removeAll() }
            }
        }
        .controlSize(.large)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.viewfinder").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Scan paper documents").font(.title3.weight(.semibold))
            Text("Use your iPhone or iPad (Scan Documents), this Mac's camera, or drop photos of documents here. Pages are cropped and straightened automatically.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls, filter: defaultFilter)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var pageList: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                VStack(spacing: 4) {
                    Group {
                        if let preview = page.preview {
                            Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15)).aspectRatio(0.75, contentMode: .fit)
                                .overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .frame(height: 110)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    Text("Page \(index + 1)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .tag(page.id)
                .contextMenu {
                    Button("Rotate Left") { model.rotate(page.id, by: -90) }
                    Button("Rotate Right") { model.rotate(page.id, by: 90) }
                    Divider()
                    Button("Delete Page", role: .destructive) { model.delete(page.id) }
                }
            }
            .onMove { model.pages.move(fromOffsets: $0, toOffset: $1) }
            if model.pending > 0 {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 8)
            }
        }
        .onDeleteCommand { if let id = model.selection { model.delete(id) } }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls, filter: defaultFilter)
            return true
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var editor: some View {
        if let index = model.selectedIndex {
            let page = model.pages[index]
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Picker("View", selection: $adjustingCrop) {
                        Text("Result").tag(false)
                        Text("Adjust Crop").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if adjustingCrop {
                        Button("Auto Detect") { model.update(page.id) { $0.quad = $0.detectedQuad ?? .full } }
                            .disabled(page.detectedQuad == nil || page.quad == page.detectedQuad)
                        Button("Whole Photo") { model.update(page.id) { $0.quad = .full } }
                            .disabled(page.quad.isFull)
                    }
                    Spacer()
                    Button { model.rotate(page.id, by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                    Button { model.rotate(page.id, by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                    Button(role: .destructive) { model.delete(page.id) } label: { Image(systemName: "trash") }.help("Delete page")
                }
                Group {
                    if adjustingCrop {
                        ScanCropEditor(image: page.thumbnail, quad: page.quad) { quad in model.update(page.id) { $0.quad = quad } }
                    } else if let preview = page.preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                            .padding(16)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Picker("Filter", selection: Binding(get: { page.filter }, set: { filter in model.update(page.id) { $0.filter = filter } })) {
                        ForEach(ScanFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    Button("Use for All Pages") {
                        defaultFilter = page.filter
                        model.setFilterForAll(page.filter)
                    }
                    .disabled(model.pages.allSatisfy { $0.filter == page.filter })
                    Spacer()
                }
            }
        } else {
            Text("Select a page.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var options: some View {
        HStack(spacing: 20) {
            Picker("Page size", selection: $pageSize) {
                Text("Same as scan").tag(PDFImageLayout.PageSize.fit)
                Text("A4").tag(PDFImageLayout.PageSize.a4)
                Text("US Letter").tag(PDFImageLayout.PageSize.letter)
            }
            .fixedSize()
            Picker("Quality", selection: $quality) {
                Text("High").tag(0.9)
                Text("Medium").tag(0.8)
                Text("Small").tag(0.6)
            }
            .fixedSize()
            Toggle("Make text searchable (OCR)", isOn: $searchable)
            Spacer()
        }
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose photos of documents, or scanned PDFs."
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, filter: defaultFilter)
    }

    private func save() {
        let specs = model.pages.map(\.spec)
        let pageSize = pageSize, quality = CGFloat(quality)
        let ocr: AIOCR.Options? = searchable ? AIOCR.Options() : nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        let name = "Scan " + formatter.string(from: .now)
        runner.start(title: tool.name) { context in
            context.setStatus("Saving \(specs.count) page\(specs.count == 1 ? "" : "s")")
            try await ScanProcessor.writePDF(specs, to: context.output(named: name, extension: "pdf"), pageSize: pageSize,
                                             quality: quality, ocr: ocr) { context.setProgress($0) }
        }
    }
}

// MARK: - Crop editor

/// The photo with the document outline; drag a corner to move it.
private struct ScanCropEditor: View {
    let image: CGImage
    let quad: ScanQuad
    let onChange: (ScanQuad) -> Void
    @State private var editing: ScanQuad?

    var body: some View {
        GeometryReader { geometry in
            let frame = fit(in: geometry.size)
            let shown = editing ?? quad
            ZStack(alignment: .topLeading) {
                Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Path { path in
                    path.addLines(ScanQuad.Corner.allCases.map { point(shown[$0], in: frame) })
                    path.closeSubpath()
                }
                .fill(Color.accentColor.opacity(0.12))
                Path { path in
                    path.addLines(ScanQuad.Corner.allCases.map { point(shown[$0], in: frame) })
                    path.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 2)
                ForEach(ScanQuad.Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .contentShape(Circle().inset(by: -8))
                        .position(point(shown[corner], in: frame))
                        .gesture(
                            DragGesture(coordinateSpace: .named("crop"))
                                .onChanged { value in
                                    var updated = editing ?? quad
                                    updated[corner] = CGPoint(x: (value.location.x - frame.minX) / frame.width,
                                                              y: 1 - (value.location.y - frame.minY) / frame.height)
                                    editing = updated
                                }
                                .onEnded { _ in
                                    if let editing { onChange(editing) }
                                    editing = nil
                                }
                        )
                }
            }
            .coordinateSpace(name: "crop")
        }
    }

    private func point(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + (1 - normalized.y) * frame.height)
    }

    private func fit(in size: CGSize) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let available = CGSize(width: max(size.width - 40, 10), height: max(size.height - 40, 10))
        var width = available.width, height = width / aspect
        if height > available.height { height = available.height; width = height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

// MARK: - Continuity Camera

/// "iPhone or iPad…" button. Its menu holds AppKit's Continuity Camera item (Take Photo, Scan Documents),
/// and the button's view receives what the device sends.
private struct ContinuityImportButton: NSViewRepresentable {
    let onImport: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> ContinuityImportView {
        let view = ContinuityImportView()
        view.onImport = onImport
        return view
    }

    func updateNSView(_ view: ContinuityImportView, context: Context) { view.onImport = onImport }
}

final class ContinuityImportView: NSView, NSServicesMenuRequestor {
    var onImport: ((NSPasteboard) -> Bool)?
    private let button = NSButton(title: "iPhone or iPad…", target: nil, action: nil)
    private static let returnTypes: [NSPasteboard.PasteboardType] = [.pdf, .tiff, .png, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .large
        button.target = self
        button.action = #selector(showMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
    override var acceptsFirstResponder: Bool { true }

    @objc private func showMenu() {
        // AppKit asks the responder chain who accepts the photos, so this view must be first responder.
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, Self.returnTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool { onImport?(pasteboard) ?? false }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

// MARK: - Camera

/// A Mac camera (built-in, external or Continuity Camera) with live document detection.
@MainActor
@Observable
final class ScanCamera: NSObject {
    enum Status: Equatable { case starting, running, denied, noCamera, failed(String) }

    private(set) var status = Status.starting
    private(set) var devices: [AVCaptureDevice] = []
    private(set) var deviceID: String?
    /// The document outline in the latest frame, normalized with the origin at the bottom left.
    private(set) var liveQuad: ScanQuad?
    /// Width ÷ height of the video.
    private(set) var aspect: CGFloat = 4 / 3
    private(set) var isCapturing = false

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.fiaxe.toolbox.scan-camera")
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var onCapture: ((CGImage) -> Void)?
    /// Read and written only on `queue`.
    @ObservationIgnored nonisolated(unsafe) private var lastDetection = Date.distantPast

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .denied; return }
        default:
            status = .denied
            return
        }
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external, .deskViewCamera],
                                                   mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.deviceType == .continuityCamera }) ?? devices.first else {
            status = .noCamera
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        select(device)
        let session = session
        queue.async { session.startRunning() }
        status = .running
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
    }

    func select(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) { session.addInput(newInput); input = newInput }
            deviceID = device.uniqueID
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            if dimensions.height > 0 { aspect = CGFloat(dimensions.width) / CGFloat(dimensions.height) }
        } catch {
            status = .failed(error.localizedDescription)
        }
        session.commitConfiguration()
        liveQuad = nil
    }

    func selectDevice(id: String) {
        if let device = devices.first(where: { $0.uniqueID == id }) { select(device) }
    }

    func capture(_ completion: @escaping (CGImage) -> Void) {
        guard status == .running, !isCapturing else { return }
        isCapturing = true
        onCapture = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    fileprivate func finishCapture(_ image: CGImage?) {
        isCapturing = false
        if let image { onCapture?(image) }
        onCapture = nil
    }

    fileprivate func setLiveQuad(_ quad: ScanQuad?) { liveQuad = quad }
}

extension ScanCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A few detections a second keep the outline responsive without busying the CPU.
        guard Date.now.timeIntervalSince(lastDetection) > 0.2, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastDetection = .now
        let quad = ScanProcessor.detectQuad(in: pixelBuffer)
        Task { @MainActor in self.setLiveQuad(quad) }
    }
}

extension ScanCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = error == nil ? photo.cgImageRepresentation() : nil
        Task { @MainActor in self.finishCapture(image) }
    }
}

private struct ScanCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Show the page as it reads rather than mirrored, so the outline matches the frames Vision sees.
        if let connection = (view.layer as? AVCaptureVideoPreviewLayer)?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}

/// Live camera view with a capture button. Each capture becomes a page.
private struct ScanCameraSheet: View {
    let onCapture: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera = ScanCamera()
    @State private var captured = 0
    @State private var flash = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Scan with Camera").font(.headline)
                Spacer()
                if camera.devices.count > 1 {
                    Picker("Camera", selection: Binding(get: { camera.deviceID ?? "" }, set: { camera.selectDevice(id: $0) })) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .fixedSize()
                }
            }
            ZStack {
                Color.black
                switch camera.status {
                case .running:
                    ScanCameraPreview(session: camera.session)
                    GeometryReader { geometry in
                        let frame = fit(camera.aspect, in: geometry.size)
                        if let quad = camera.liveQuad {
                            Path { path in
                                path.addLines(ScanQuad.Corner.allCases.map {
                                    CGPoint(x: frame.minX + quad[$0].x * frame.width, y: frame.minY + (1 - quad[$0].y) * frame.height)
                                })
                                path.closeSubpath()
                            }
                            .fill(Color.accentColor.opacity(0.2))
                            .overlay {
                                Path { path in
                                    path.addLines(ScanQuad.Corner.allCases.map {
                                        CGPoint(x: frame.minX + quad[$0].x * frame.width, y: frame.minY + (1 - quad[$0].y) * frame.height)
                                    })
                                    path.closeSubpath()
                                }
                                .stroke(Color.accentColor, lineWidth: 3)
                            }
                        }
                    }
                    if flash { Color.white.opacity(0.7) }
                case .starting:
                    ProgressView().tint(.white)
                case .denied:
                    message("Toolbox doesn't have access to the camera.", action: "Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                case .noCamera:
                    message("No camera found. Connect a camera, or bring your iPhone near to use it as a Continuity Camera.")
                case .failed(let error):
                    message("The camera couldn't start: \(error)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(minWidth: 640, minHeight: 440)
            HStack {
                Text(camera.liveQuad == nil ? "Hold the page in view on a contrasting surface." : "Page found.")
                    .foregroundStyle(.secondary)
                Spacer()
                if captured > 0 {
                    Text("\(captured) captured").foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: capture) { Label("Capture", systemImage: "camera.shutter.button") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(camera.status != .running || camera.isCapturing)
            }
            .controlSize(.large)
        }
        .padding(20)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    private func capture() {
        camera.capture { image in
            onCapture(image)
            captured += 1
        }
        flash = true
        withAnimation(.easeOut(duration: 0.3)) { flash = false }
    }

    private func message(_ text: String, action: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action { Button(action, action: perform) }
        }
    }

    private func fit(_ aspect: CGFloat, in size: CGSize) -> CGRect {
        var width = size.width, height = width / aspect
        if height > size.height { height = size.height; width = height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}
