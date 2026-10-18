import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Signature images

/// Turns ink strokes, typed names and imported pictures into transparent, tightly cropped signature images.
enum PDFSignatureArt {
    struct InkPoint: Hashable {
        var location: CGPoint
        var width: CGFloat
    }

    /// Script-style fonts that ship with macOS, by PostScript name. Only installed ones are offered.
    static let scriptFonts: [(name: String, label: String)] = [
        ("SnellRoundhand", "Snell Roundhand"),
        ("Zapfino", "Zapfino"),
        ("SavoyeLetPlain", "Savoye"),
        ("Apple-Chancery", "Apple Chancery"),
        ("BrushScriptMT", "Brush Script"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Noteworthy-Light", "Noteworthy"),
    ].filter { NSFont(name: $0.0, size: 12) != nil }

    /// Renders strokes (in points, origin bottom-left) as a trimmed image at `scale`.
    static func image(strokes: [[InkPoint]], color: NSColor, scale: CGFloat = 3) -> CGImage? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let maxWidth = points.map(\.width).max() ?? 2
        var bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.location, size: .zero)) }
        bounds = bounds.insetBy(dx: -maxWidth * 2, dy: -maxWidth * 2)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, let context = transparentContext(width: width, height: height) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawStrokes(strokes, color: color.cgColor, in: context)
        return context.makeImage()
    }

    /// Smooth strokes: quadratic curves through segment midpoints, with per-segment width for a pen-like feel.
    static func drawStrokes(_ strokes: [[InkPoint]], color: CGColor, in context: CGContext) {
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            if stroke.count == 1 {
                let r = first.width / 2
                context.fillEllipse(in: CGRect(x: first.location.x - r, y: first.location.y - r, width: r * 2, height: r * 2))
                continue
            }
            var previousMid = first.location
            for index in 1..<stroke.count {
                let previous = stroke[index - 1], current = stroke[index]
                let mid = CGPoint(x: (previous.location.x + current.location.x) / 2, y: (previous.location.y + current.location.y) / 2)
                context.beginPath()
                context.move(to: previousMid)
                context.addQuadCurve(to: mid, control: previous.location)
                context.setLineWidth((previous.width + current.width) / 2)
                context.strokePath()
                previousMid = mid
            }
            if let last = stroke.last {
                context.beginPath()
                context.move(to: previousMid)
                context.addLine(to: last.location)
                context.setLineWidth(last.width)
                context.strokePath()
            }
        }
    }

    /// Renders a typed name in a script font.
    static func image(text: String, fontName: String, color: NSColor, pointSize: CGFloat = 120) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = NSFont(name: fontName, size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: [.font: font, .foregroundColor: color]))
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let padding = pointSize * 0.15
        let width = Int(ceil(glyphBounds.width + padding * 2)), height = Int(ceil(glyphBounds.height + padding * 2))
        guard width > 0, height > 0, let context = transparentContext(width: width, height: height) else { return nil }
        context.textPosition = CGPoint(x: padding - glyphBounds.minX, y: padding - glyphBounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// Loads a picture of a signature, optionally turning a light paper background transparent.
    static func image(contentsOf url: URL, removeBackground: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary) else { return nil }
        guard removeBackground else { return trimmed(image) ?? image }
        let width = image.width, height = image.height
        guard let context = transparentContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let alpha = CGFloat(data[offset + 3]) / 255
                guard alpha > 0 else { continue }
                // Un-premultiply, then fade light pixels out with a soft ramp so edges stay smooth.
                let r = CGFloat(data[offset]) / 255 / alpha, g = CGFloat(data[offset + 1]) / 255 / alpha, b = CGFloat(data[offset + 2]) / 255 / alpha
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                let newAlpha = alpha * min(max((0.92 - luminance) / 0.30, 0), 1)
                data[offset] = UInt8(min(r * newAlpha, 1) * 255)
                data[offset + 1] = UInt8(min(g * newAlpha, 1) * 255)
                data[offset + 2] = UInt8(min(b * newAlpha, 1) * 255)
                data[offset + 3] = UInt8(newAlpha * 255)
            }
        }
        return context.makeImage().flatMap(trimmed)
    }

    /// Crops away fully transparent margins.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = transparentContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = context.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[y * stride + x * 4 + 3] > 6 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 4
        // Bitmap rows run top to bottom in memory, which matches CGImage cropping coordinates.
        let rect = CGRect(x: max(minX - pad, 0), y: max(minY - pad, 0),
                          width: min(maxX - minX + 1 + pad * 2, width), height: min(maxY - minY + 1 + pad * 2, height))
        return context.makeImage()?.cropping(to: rect)
    }

    private static func transparentContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

// MARK: - Saved signatures

struct PDFSavedSignature: Identifiable, Hashable {
    let id: UUID
    let image: CGImage
    /// Nil for signatures that are only kept for this session.
    let fileURL: URL?

    var aspectRatio: CGFloat { CGFloat(image.width) / CGFloat(max(image.height, 1)) }
    var nsImage: NSImage { NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Signatures saved as PNGs in ~/Library/Application Support/Toolbox/Signatures.
@MainActor
@Observable
final class PDFSignatureStore {
    static let shared = PDFSignatureStore()

    private(set) var signatures: [PDFSavedSignature] = []

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Toolbox/Signatures", isDirectory: true)
    }

    private init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let saved = urls.filter { $0.pathExtension.lowercased() == "png" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .compactMap { url -> PDFSavedSignature? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
                return PDFSavedSignature(id: id, image: image, fileURL: url)
            }
        signatures = signatures.filter { $0.fileURL == nil } + saved
    }

    /// Adds a signature, saving it to disk when `persist` is true.
    @discardableResult
    func add(_ image: CGImage, persist: Bool) -> PDFSavedSignature {
        let id = UUID()
        var fileURL: URL?
        if persist, let data = PDFOps.encode(image, as: .png, quality: 1, dpi: nil) {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let url = Self.folder.appendingPathComponent("\(id.uuidString).png")
            if (try? data.write(to: url)) != nil { fileURL = url }
        }
        let signature = PDFSavedSignature(id: id, image: image, fileURL: fileURL)
        signatures.insert(signature, at: 0)
        return signature
    }

    func delete(_ signature: PDFSavedSignature) {
        if let url = signature.fileURL { try? FileManager.default.removeItem(at: url) }
        signatures.removeAll { $0.id == signature.id }
    }
}

// MARK: - Maker sheet

/// Sheet for creating a signature by drawing, typing or importing a picture.
struct PDFSignatureMakerSheet: View {
    enum Method: String, CaseIterable, Identifiable {
        case draw, type, image
        var id: Self { self }
        var label: String {
            switch self {
            case .draw: "Draw"
            case .type: "Type"
            case .image: "Image"
            }
        }
    }

    enum Ink: String, CaseIterable, Identifiable {
        case black, blue, darkBlue
        var id: Self { self }
        var color: NSColor {
            switch self {
            case .black: NSColor(white: 0.08, alpha: 1)
            case .blue: NSColor(red: 0.10, green: 0.30, blue: 0.85, alpha: 1)
            case .darkBlue: NSColor(red: 0.05, green: 0.12, blue: 0.40, alpha: 1)
            }
        }
    }

    let onCreate: (PDFSavedSignature) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var method = Method.draw
    @State private var ink = Ink.black
    @State private var strokes: [[PDFSignatureArt.InkPoint]] = []
    @State private var typedName = ""
    @State private var fontName = PDFSignatureArt.scriptFonts.first?.name ?? "Helvetica"
    @State private var importedURL: URL?
    @State private var importedImage: CGImage?
    @State private var removeBackground = true
    @State private var saveForLater = true

    private var preview: CGImage? {
        switch method {
        case .draw: PDFSignatureArt.image(strokes: strokes, color: ink.color)
        case .type: PDFSignatureArt.image(text: typedName, fontName: fontName, color: ink.color)
        case .image: importedImage
        }
    }

    /// Background removal walks every pixel, so it runs once per change rather than on every redraw.
    private func processImport() {
        guard let url = importedURL else { importedImage = nil; return }
        let remove = removeBackground
        Task {
            let image = await Task.detached { PDFSignatureArt.image(contentsOf: url, removeBackground: remove) }.value
            if importedURL == url, removeBackground == remove { importedImage = image }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Signature").font(.title2.weight(.semibold))
            Picker("Method", selection: $method) {
                ForEach(Method.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch method {
                case .draw: drawPane
                case .type: typePane
                case .image: imagePane
                }
            }
            .frame(height: 220)

            if method != .image {
                Picker("Ink", selection: $ink) {
                    ForEach(Ink.allCases) { option in
                        Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: option.color)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Toggle("Save this signature for next time", isOn: $saveForLater)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Signature") {
                    guard let image = preview else { return }
                    onCreate(PDFSignatureStore.shared.add(image, persist: saveForLater))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onChange(of: importedURL) { processImport() }
        .onChange(of: removeBackground) { processImport() }
    }

    private var drawPane: some View {
        ZStack(alignment: .bottomTrailing) {
            PDFInkCanvas(strokes: $strokes, color: ink.color)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    VStack(spacing: 4) {
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1)
                        Text("Sign above the line with your mouse or trackpad").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            Button("Clear") { strokes = [] }
                .padding(10)
                .disabled(strokes.isEmpty)
        }
    }

    private var typePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Your name", text: $typedName)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(PDFSignatureArt.scriptFonts, id: \.name) { font in
                        Button { fontName = font.name } label: {
                            HStack {
                                Text(typedName.isEmpty ? font.label : typedName)
                                    .font(.custom(font.name, size: 30))
                                    .foregroundStyle(Color(nsColor: ink.color))
                                    .lineLimit(1)
                                Spacer()
                                if fontName == font.name { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(fontName == font.name ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var imagePane: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                if let image = preview {
                    Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
                        .resizable().aspectRatio(contentMode: .fit).padding(16)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Choose a photo or scan of your signature").foregroundStyle(.secondary)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { FileListInput.conforms($0, to: [.image]) }) else { return false }
                importedURL = url
                return true
            }
            HStack {
                Button("Choose Image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK { importedURL = panel.url }
                }
                Toggle("Remove white background", isOn: $removeBackground)
                Spacer()
            }
        }
    }
}

/// Mouse/trackpad drawing surface. Points are stored in view coordinates (origin bottom-left).
struct PDFInkCanvas: NSViewRepresentable {
    @Binding var strokes: [[PDFSignatureArt.InkPoint]]
    var color: NSColor

    func makeNSView(context: Context) -> InkView {
        let view = InkView()
        view.onChange = { strokes = $0 }
        return view
    }

    func updateNSView(_ view: InkView, context: Context) {
        view.onChange = { strokes = $0 }
        view.color = color
        if view.strokes != strokes {
            view.strokes = strokes
            view.needsDisplay = true
        }
    }

    final class InkView: NSView {
        var strokes: [[PDFSignatureArt.InkPoint]] = []
        var color: NSColor = .black { didSet { needsDisplay = true } }
        var onChange: (([[PDFSignatureArt.InkPoint]]) -> Void)?
        private var lastEvent: (point: CGPoint, time: TimeInterval)?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            lastEvent = (point, event.timestamp)
            strokes.append([PDFSignatureArt.InkPoint(location: point, width: 3.2)])
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard var stroke = strokes.popLast() else { return }
            // Faster movement draws a thinner line, like a real pen.
            var width: CGFloat = 3.2
            if let last = lastEvent {
                let distance = hypot(point.x - last.point.x, point.y - last.point.y)
                guard distance > 0.8 else { strokes.append(stroke); return }
                let speed = distance / CGFloat(max(event.timestamp - last.time, 0.001))
                let target: CGFloat = min(max(4.2 - speed / 450, 1.4), 4.2)
                width = (stroke.last?.width ?? target) * 0.6 + target * 0.4
            }
            stroke.append(PDFSignatureArt.InkPoint(location: point, width: width))
            strokes.append(stroke)
            lastEvent = (point, event.timestamp)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            lastEvent = nil
            onChange?(strokes)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            PDFSignatureArt.drawStrokes(strokes, color: color.cgColor, in: context)
        }
    }
}
