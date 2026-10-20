import SwiftUI
import UniformTypeIdentifiers
import Vision

struct CollageView: View {
    let tool: Tool
    @AppStorage("image.collage.layout") private var layout = "grid"
    @AppStorage("image.collage.columns") private var columns = 2
    @AppStorage("image.collage.cellSize") private var cellSize = 600
    @AppStorage("image.collage.spacing") private var spacing = 20
    @AppStorage("image.collage.corner") private var corner = 12
    @State private var background = Color.white
    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, minimumFiles: 2, actionTitle: "Create Collage", noun: "images") {
            Picker("Layout", selection: $layout) { Text("Grid").tag("grid"); Text("Row").tag("row"); Text("Column").tag("column"); Text("Featured").tag("featured") }
            Stepper("Columns: \(columns)", value: $columns, in: 1...12)
            Stepper("Cell size: \(cellSize) px", value: $cellSize, in: 100...2000, step: 100)
            Stepper("Spacing: \(spacing) px", value: $spacing, in: 0...200, step: 5)
            Stepper("Corner radius: \(corner) px", value: $corner, in: 0...200, step: 5)
            ColorPicker("Background", selection: $background)
            Text("Drag the file rows to arrange images. Each cell fills its frame with a centered crop. The featured layout makes the first image twice as large.").font(.caption).foregroundStyle(.secondary)
        } all: { [layout, columns, cellSize, spacing, corner, color = NSColor(background)] inputs, context in
            let featured = layout == "featured"
            let cols = layout == "row" ? inputs.count : layout == "column" ? 1 : max(featured ? 2 : 1, columns)
            var placements: [(Int, Int, Int, Int)] = []
            var occupied = Set<Int>()
            var cursor = 0
            for index in inputs.indices {
                if featured && index == 0 {
                    placements.append((0, 0, 2, 2)); occupied.formUnion([0, 1, cols, cols+1])
                } else {
                    while occupied.contains(cursor) { cursor += 1 }
                    placements.append((cursor % cols, cursor/cols, 1, 1)); occupied.insert(cursor); cursor += 1
                }
            }
            let rows = placements.map { $0.1+$0.3 }.max() ?? 1
            let w = cols*cellSize+(cols+1)*spacing, h = rows*cellSize+(rows+1)*spacing
            guard w <= 20_000, h <= 20_000, w*h <= 100_000_000,
                  let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ToolError.failed("This collage is too large. Reduce the cell size or number of images.")
            }
            cg.setFillColor(color.cgColor); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let image = try ImageEditorOps.load(input)
                let (col, row, spanW, spanH) = placements[index]
                let width = spanW*cellSize+(spanW-1)*spacing, height = spanH*cellSize+(spanH-1)*spacing
                let rect = CGRect(x: spacing+col*(cellSize+spacing), y: h-(spacing+row*(cellSize+spacing))-height, width: width, height: height)
                cg.saveGState()
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(corner), cornerHeight: CGFloat(corner), transform: nil)); cg.clip()
                let scale = max(rect.width/CGFloat(image.width), rect.height/CGFloat(image.height))
                cg.draw(image, in: CGRect(x: rect.midX-CGFloat(image.width)*scale/2, y: rect.midY-CGFloat(image.height)*scale/2, width: CGFloat(image.width)*scale, height: CGFloat(image.height)*scale))
                cg.restoreGState()
                context.setProgress(Double(index+1)/Double(inputs.count))
            }
            guard let image = cg.makeImage(), let data = PDFOps.encode(image, as: .png, quality: 1, dpi: nil) else { throw ToolError.failed("Couldn't render collage.") }
            try data.write(to: context.output(named: "Collage", extension: "png"))
        }
    }
}

struct QRCodeView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var results: [String] = []
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.imageInputs, noun: "images")
            ForEach(Array(results.enumerated()), id: \.offset) { _, value in
                HStack { Text(value).textSelection(.enabled); Spacer(); AICopyButton(text: value) }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Read Codes", canRun: !runner.inputs.isEmpty) {
                results = []
                runner.start(title: tool.name, publishesFiles: false) { [inputs = runner.inputs] context in
                    var found: [String] = []
                    for input in inputs {
                        try Task.checkCancellation()
                        let request = VNDetectBarcodesRequest()
                        try VNImageRequestHandler(url: input).perform([request])
                        found += (request.results ?? []).compactMap(\.payloadStringValue)
                    }
                    let values = Array(Set(found)).sorted()
                    await MainActor.run { results = values.isEmpty ? ["No QR codes or barcodes found."] : values }
                }
            }
        }
    }
}
