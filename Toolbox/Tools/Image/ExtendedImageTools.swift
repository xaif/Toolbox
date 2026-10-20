import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import Vision
import CoreText

enum ExtendedImageTools {
    static let all: [Tool] = [
        tool("edit", "Edit Photos", "Edit Photo", "slider.horizontal.3", "Adjust exposure, color, detail and effects with a live preview."),
        tool("annotate", "Annotate Photos", "Annotate", "pencil.and.outline", "Draw arrows, shapes, text and numbered callouts."),
        tool("background", "Add Image Background", "Add BG", "photo.artframe", "Frame a photo on a color, gradient or another image."),
        tool("crop", "Crop Images", "Crop", "crop", "Draw a crop or choose an aspect ratio and output dimensions."),
        tool("redact", "Redact Photos", "Redact", "eye.slash", "Cover private areas, faces or text with solid pixels or blur."),
        Tool(id: "image.collage", name: "Create Collage", category: .image, symbol: "rectangle.3.group",
             summary: "Arrange images in a grid, row, column or featured layout.", keywords: ["combine", "collage", "grid", "contact sheet"], input: .images) { CollageView(tool: $0) },
        Tool(id: "image.read-qr", name: "Read QR Codes", category: .image, symbol: "qrcode.viewfinder",
             summary: "Read QR and barcodes locally from images.", keywords: ["qr", "barcode", "scan"], input: .images) { QRCodeView(tool: $0) },
    ]
    private static func tool(_ id: String, _ name: String, _ short: String, _ symbol: String, _ summary: String) -> Tool {
        Tool(id: "image." + id, name: name, shortName: short, category: .image, symbol: symbol, summary: summary,
             keywords: [id, "photo", "edit"], input: .images) { ImageEditorView(tool: $0) }
    }
}

struct ImageMark: Identifiable, Sendable {
    var id = UUID()
    var rect: CGRect
    var kind: String
    var text: String
    var start: CGPoint? = nil
    var end: CGPoint? = nil
}
struct ImageEditOptions: @unchecked Sendable {
    var exposure = 0.0, brightness = 0.0, contrast = 1.0, saturation = 1.0, sharpness = 0.0, sepia = 0.0, vignette = 0.0
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var width = 0, height = 0
    var marks: [ImageMark] = []
    var color = NSColor.systemRed
    var background = NSColor.white
    var gradient = false
    var backgroundImage: URL?
    var aspect = 0.0
    var padding = 40
    var corner = 20
    var blur = false
    var detectFaces = false, detectText = false
}

enum ImageEditorOps {
    static func load(_ url: URL) throws -> CGImage {
        let source = try ImageIOHelpers.source(for: url)
        return try ImageIOHelpers.orientedImage(source, index: CGImageSourceGetPrimaryImageIndex(source))
    }
    static func apply(_ image: CGImage, operation: String, options: ImageEditOptions) throws -> CGImage {
        switch operation {
        case "edit":
            var result = CIImage(cgImage: image)
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: options.exposure])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: options.brightness, kCIInputContrastKey: options.contrast, kCIInputSaturationKey: options.saturation])
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: options.sharpness])
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: options.sepia])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: options.vignette, kCIInputRadiusKey: Double(min(image.width, image.height))/2])
            return try ImageIOHelpers.render(result.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)), like: image)
        case "crop":
            let crop = options.crop
            let rect = CGRect(x: crop.minX*CGFloat(image.width), y: crop.minY*CGFloat(image.height), width: crop.width*CGFloat(image.width), height: crop.height*CGFloat(image.height)).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else { throw ToolError.failed("Draw a crop inside the image.") }
            if options.width > 0 || options.height > 0 {
                let w = options.width > 0 ? options.width : max(1, Int(Double(cropped.width) * Double(options.height)/Double(cropped.height)))
                let h = options.height > 0 ? options.height : max(1, Int(Double(cropped.height) * Double(options.width)/Double(cropped.width)))
                return try ImageIOHelpers.resize(cropped, width: w, height: h)
            }
            return cropped
        case "background": return try background(image, options: options)
        case "annotate", "redact":
            guard let context = ImageIOHelpers.makeContext(width: image.width, height: image.height, like: image, forceAlpha: true) else { throw ToolError.failed("Couldn't draw image.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var marks = options.marks
            if operation == "redact", options.detectFaces || options.detectText {
                let handler = VNImageRequestHandler(cgImage: image)
                var boxes: [CGRect] = []
                if options.detectFaces {
                    let request = VNDetectFaceRectanglesRequest(); try handler.perform([request])
                    boxes += (request.results ?? []).map { $0.boundingBox.insetBy(dx: -0.015, dy: -0.015).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                }
                if options.detectText {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; try handler.perform([request])
                    boxes += (request.results ?? []).map(\.boundingBox)
                }
                marks += boxes.map { ImageMark(rect: CGRect(x: $0.minX, y: 1-$0.maxY, width: $0.width, height: $0.height), kind: "box", text: "") }
            }
            for (index, mark) in marks.enumerated() {
                let rect = pixelRect(mark.rect, image: image)
                if operation == "redact" {
                    if options.blur {
                        let blurred = CIImage(cgImage: image).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(20, min(rect.width, rect.height)/5)]).cropped(to: rect)
                        if let cg = ImageIOHelpers.ciContext.createCGImage(blurred, from: rect) { context.draw(cg, in: rect) }
                    } else { context.setFillColor(options.color.cgColor); context.fill(rect) }
                    continue
                }
                context.setStrokeColor(options.color.cgColor); context.setFillColor(options.color.cgColor)
                let lineWidth = max(CGFloat(image.width)/260, 3)
                context.setLineWidth(lineWidth)
                switch mark.kind {
                case "oval": context.strokeEllipse(in: rect)
                case "text": drawText(mark.text, in: rect, color: options.color, context: context)
                case "number":
                    let circle = CGRect(x: rect.midX-rect.height/2, y: rect.minY, width: rect.height, height: rect.height)
                    context.fillEllipse(in: circle)
                    drawText(String(index+1), in: circle.insetBy(dx: circle.width*0.25, dy: circle.height*0.2), color: .white, context: context)
                case "arrow":
                    let start = mark.start.map { CGPoint(x: $0.x*CGFloat(image.width), y: (1-$0.y)*CGFloat(image.height)) } ?? CGPoint(x: rect.minX, y: rect.minY)
                    let end = mark.end.map { CGPoint(x: $0.x*CGFloat(image.width), y: (1-$0.y)*CGFloat(image.height)) } ?? CGPoint(x: rect.maxX, y: rect.maxY)
                    context.move(to: start); context.addLine(to: end); context.strokePath()
                    let angle = atan2(end.y-start.y, end.x-start.x), size = lineWidth*5
                    context.move(to: end)
                    context.addLine(to: CGPoint(x: end.x-size*cos(angle-0.5), y: end.y-size*sin(angle-0.5)))
                    context.addLine(to: CGPoint(x: end.x-size*cos(angle+0.5), y: end.y-size*sin(angle+0.5)))
                    context.closePath(); context.fillPath()
                default: context.stroke(rect)
                }
            }
            guard let result = context.makeImage() else { throw ToolError.failed("Couldn't draw image.") }
            return result
        default: return image
        }
    }
    static func pixelRect(_ rect: CGRect, image: CGImage) -> CGRect {
        CGRect(x: rect.minX*CGFloat(image.width), y: (1-rect.maxY)*CGFloat(image.height), width: rect.width*CGFloat(image.width), height: rect.height*CGFloat(image.height))
    }
    static func drawText(_ text: String, in rect: CGRect, color: NSColor, context: CGContext) {
        let size = max(12, min(rect.height*0.8, rect.width/max(CGFloat(text.count)*0.55, 1)))
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
        context.textPosition = CGPoint(x: rect.minX, y: rect.midY-size*0.35)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    static func background(_ image: CGImage, options: ImageEditOptions) throws -> CGImage {
        let padding = max(options.padding, 0)
        var w = image.width+padding*2, h = image.height+padding*2
        if options.aspect > 0 {
            if Double(w)/Double(h) > options.aspect { h = Int(Double(w)/options.aspect) } else { w = Int(Double(h)*options.aspect) }
        }
        guard w <= 20_000, h <= 20_000, let context = ImageIOHelpers.makeContext(width: w, height: h, like: image, forceAlpha: true) else { throw ToolError.failed("The background is too large.") }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(options.background.cgColor); context.fill(bounds)
        if let url = options.backgroundImage, let bg = try? load(url) {
            let scale = max(CGFloat(w)/CGFloat(bg.width), CGFloat(h)/CGFloat(bg.height))
            context.draw(bg, in: CGRect(x: (CGFloat(w)-CGFloat(bg.width)*scale)/2, y: (CGFloat(h)-CGFloat(bg.height)*scale)/2, width: CGFloat(bg.width)*scale, height: CGFloat(bg.height)*scale))
        } else if options.gradient, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [options.background.cgColor, NSColor.black.cgColor] as CFArray, locations: [0,1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        let rect = CGRect(x: (w-image.width)/2, y: (h-image.height)/2, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(options.corner), cornerHeight: CGFloat(options.corner), transform: nil)); context.clip()
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ToolError.failed("Couldn't render background.") }
        return result
    }
}

struct ImageEditorView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var options = ImageEditOptions()
    @State private var preview: CGImage?
    @State private var kind = "box"
    @State private var text = "Label"
    @State private var aspect = 0.0
    @State private var color = Color.red
    @State private var background = Color.white
    @State private var selection = CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    private var operation: String { String(tool.id.split(separator: ".").last ?? "edit") }
    private var snapshot: ImageEditOptions {
        var result = options; result.color = NSColor(color); result.background = NSColor(background)
        if operation == "crop" { result.crop = selection }
        result.aspect = aspect
        return result
    }
    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Save Copy", noun: "images") {
            if let first = runner.inputs.first {
                if let preview {
                    ImageSelectionCanvas(image: preview, selection: $selection, selectable: ["crop", "annotate", "redact"].contains(operation), aspectRatio: operation == "crop" && aspect > 0 ? aspect : nil, onVector: { start, end in
                        if operation == "annotate" && kind == "arrow" {
                            options.marks.append(ImageMark(rect: selection, kind: kind, text: "", start: start, end: end))
                        }
                    }) { rect in
                        if operation != "crop" && !(operation == "annotate" && kind == "arrow") { options.marks.append(ImageMark(rect: rect, kind: kind, text: text)) }
                    }
                    .frame(maxHeight: 360)
                }
                Button("Update Preview") { updatePreview(first) }
            }
            if let previewError { Text(previewError).foregroundStyle(.orange) }
            controls
            Text("Edits are saved to a new PNG. For a batch, the same settings and relative regions apply to every image.").font(.caption).foregroundStyle(.secondary)
        } each: { [operation, options = snapshot] input, context, progress in
            let image = try ImageEditorOps.load(input)
            let result = try ImageEditorOps.apply(image, operation: operation, options: options)
            guard let data = PDFOps.encode(result, as: .png, quality: 1, dpi: nil) else { throw ToolError.failed("Couldn't encode image.") }
            try data.write(to: context.output(for: input, suffix: operation, extension: "png")); progress(1)
        }
        .task(id: runner.inputs.first) { if let first = runner.inputs.first { updatePreview(first) } else { preview = nil } }
        .onChange(of: options.exposure) { _, _ in refresh() }
        .onChange(of: options.brightness) { _, _ in refresh() }
        .onChange(of: options.contrast) { _, _ in refresh() }
        .onChange(of: options.saturation) { _, _ in refresh() }
        .onChange(of: options.sharpness) { _, _ in refresh() }
        .onChange(of: options.sepia) { _, _ in refresh() }
        .onChange(of: options.vignette) { _, _ in refresh() }
        .onDisappear { previewTask?.cancel() }
    }
    @ViewBuilder private var controls: some View {
        switch operation {
        case "edit":
            slider("Exposure", $options.exposure, -3...3); slider("Brightness", $options.brightness, -0.5...0.5)
            slider("Contrast", $options.contrast, 0.2...2); slider("Saturation", $options.saturation, 0...2)
            slider("Sharpness", $options.sharpness, 0...2); slider("Sepia", $options.sepia, 0...1); slider("Vignette", $options.vignette, 0...2)
            Button("Reset Adjustments") { options = ImageEditOptions(); refresh() }
        case "crop":
            Text("Drag on the preview to choose a crop.")
            Picker("Aspect ratio", selection: $aspect) { Text("Freeform").tag(0.0); Text("Square").tag(1.0); Text("16:9").tag(16.0/9); Text("9:16").tag(9.0/16); Text("4:5").tag(0.8) }
                .onChange(of: aspect) { _, value in
                    guard value > 0, let preview else { return }
                    let imageAspect = Double(preview.width)/Double(preview.height)
                    let w = min(1, value/imageAspect), h = min(1, imageAspect/value)
                    selection = CGRect(x: (1-w)/2, y: (1-h)/2, width: w, height: h)
                }
            HStack { TextField("Output width (0 = automatic)", value: $options.width, format: .number); TextField("Output height (0 = automatic)", value: $options.height, format: .number) }
        case "annotate", "redact":
            if operation == "annotate" {
                Picker("Draw", selection: $kind) { Text("Rectangle").tag("box"); Text("Ellipse").tag("oval"); Text("Arrow").tag("arrow"); Text("Text").tag("text"); Text("Number").tag("number") }
                TextField("Text", text: $text)
            } else {
                Toggle("Blur private regions", isOn: $options.blur)
                Toggle("Detect and cover faces locally", isOn: $options.detectFaces)
                Toggle("Detect and cover all text locally", isOn: $options.detectText)
            }
            ColorPicker(operation == "redact" ? "Cover color" : "Color", selection: $color)
            Text("Drag to add a region, then update the preview. \(options.marks.count) manual regions.")
            HStack { Button("Undo Last Region") { _ = options.marks.popLast(); refresh() }.disabled(options.marks.isEmpty); Button("Clear Regions") { options.marks = []; refresh() } }
            ForEach(options.marks) { mark in Text("\(mark.kind.capitalized) · \(mark.text)").font(.caption) }
        case "background":
            ColorPicker("Background", selection: $background)
            Toggle("Gradient to black", isOn: $options.gradient)
            Picker("Aspect ratio", selection: $aspect) { Text("Fit image").tag(0.0); Text("Square").tag(1.0); Text("Landscape").tag(16.0/9); Text("Portrait").tag(9.0/16) }
            Stepper("Padding: \(options.padding) px", value: $options.padding, in: 0...1000, step: 10)
            Stepper("Corner radius: \(options.corner) px", value: $options.corner, in: 0...500, step: 5)
            HStack {
                Button("Choose Background Image…") {
                    let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]
                    if picker.runModal() == .OK { options.backgroundImage = picker.url }
                }
                if options.backgroundImage != nil { Button("Remove Background Image") { options.backgroundImage = nil } }
            }
        default: EmptyView()
        }
    }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack { Text(title).frame(width: 90, alignment: .leading); Slider(value: value, in: range); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 45) }
    }
    private func refresh() { if let first = runner.inputs.first { updatePreview(first) } }
    private func updatePreview(_ url: URL) {
        let settings = snapshot, operation = operation
        previewError = nil
        previewTask?.cancel()
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                let image = try await Task.detached(priority: .userInitiated) {
                    let original = try ImageEditorOps.load(url)
                    // Crop selection always overlays the complete source.
                    return operation == "crop" ? original : try ImageEditorOps.apply(original, operation: operation, options: settings)
                }.value
                try Task.checkCancellation()
                preview = image
            } catch is CancellationError { } catch { if !Task.isCancelled { previewError = error.localizedDescription } }
        }
    }
}

struct ImageSelectionCanvas: View {
    let image: CGImage
    @Binding var selection: CGRect
    var selectable = true
    var aspectRatio: Double? = nil
    var onVector: ((CGPoint, CGPoint) -> Void)? = nil
    var onSelect: (CGRect) -> Void
    var body: some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    if selectable {
                        Rectangle().stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [5,3]))
                            .frame(width: selection.width*geometry.size.width, height: selection.height*geometry.size.height)
                            .position(x: selection.midX*geometry.size.width, y: selection.midY*geometry.size.height)
                    }
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                            guard selectable else { return }
                            selection = normalized(value, size: geometry.size)
                        }.onEnded { value in
                            guard selectable else { return }
                            let rect = normalized(value, size: geometry.size)
                            if rect.width > 0.002 && rect.height > 0.002 {
                                onSelect(rect)
                                let start = CGPoint(x: min(max(value.startLocation.x/geometry.size.width, 0),1), y: min(max(value.startLocation.y/geometry.size.height, 0),1))
                                let end = CGPoint(x: min(max(value.location.x/geometry.size.width, 0),1), y: min(max(value.location.y/geometry.size.height, 0),1))
                                onVector?(start, end)
                            }
                        })
                }
            }
    }
    private func normalized(_ value: DragGesture.Value, size: CGSize) -> CGRect {
        let x = min(max(min(value.startLocation.x, value.location.x)/size.width, 0), 1)
        let y = min(max(min(value.startLocation.y, value.location.y)/size.height, 0), 1)
        var w = min(abs(value.location.x-value.startLocation.x)/size.width, 1-x)
        var h = min(abs(value.location.y-value.startLocation.y)/size.height, 1-y)
        if let aspectRatio {
            h = w*size.width/(size.height*aspectRatio)
            if h > 1-y { h = 1-y; w = h*size.height*aspectRatio/size.width }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
