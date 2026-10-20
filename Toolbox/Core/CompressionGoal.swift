import SwiftUI
import PDFKit

struct CompressionGoal: Sendable {
    enum Mode: String, CaseIterable { case quality, size, percentage }
    let mode: Mode
    let megabytes: Double
    let reduction: Double
    init(prefix: String) {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: prefix + ".mode") ?? "") ?? .quality
        megabytes = UserDefaults.standard.object(forKey: prefix + ".mb") as? Double ?? 1
        reduction = UserDefaults.standard.object(forKey: prefix + ".reduction") as? Double ?? 50
    }
    func bytes(for input: URL) -> Int64? {
        switch mode {
        case .quality: nil
        case .size: Int64(max(0.001, min(megabytes, 100_000))*1_000_000)
        case .percentage: Int64(Double(PDFOps.fileSize(input)) * (1-max(1,min(99,reduction))/100))
        }
    }
}

struct CompressionGoalControls: View {
    @AppStorage private var mode: CompressionGoal.Mode
    @AppStorage private var megabytes: Double
    @AppStorage private var reduction: Double
    init(prefix: String) {
        _mode = AppStorage(wrappedValue: .quality, prefix + ".mode")
        _megabytes = AppStorage(wrappedValue: 1, prefix + ".mb")
        _reduction = AppStorage(wrappedValue: 50, prefix + ".reduction")
    }
    var body: some View {
        OptionPicker("Compress by", selection: $mode, choices: [.init(.quality, "Quality preset"), .init(.size, "Target file size"), .init(.percentage, "Percentage reduction")])
        if mode == .size { OptionNumberField("Target size per file", value: $megabytes, format: .number, unit: "MB", in: 0.001...10_000, step: 0.1) }
        if mode == .percentage { OptionSlider("Reduce by", value: $reduction, in: 1...95, step: 1) { "\(Int($0))%" } }
    }
}

enum TargetCompression {
    static func image(_ input: URL, to output: URL, format: ImageFormat, bytes: Int64, maxDimension: Int, keepMetadata: Bool) throws {
        let image = try ImageEditorOps.load(input)
        var scale = maxDimension > 0 ? min(1, Double(maxDimension)/Double(max(image.width,image.height))) : 1
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("compress-\(UUID()).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        for _ in 0..<10 {
            var lower = 0.03, upper = 0.98
            var best: Data?
            for _ in 0..<(format.supportsQuality ? 8 : 1) {
                try Task.checkCancellation()
                let quality = (lower+upper)/2
                try ImageIOHelpers.reencode(input, to: scratch, format: format, quality: quality, keepMetadata: keepMetadata) { frame in
                    try ImageIOHelpers.resize(frame, width: max(1,Int(Double(frame.width)*scale)), height: max(1,Int(Double(frame.height)*scale)))
                }
                if PDFOps.fileSize(scratch) <= bytes { best = try Data(contentsOf: scratch); lower = quality }
                else { upper = quality }
            }
            if let best { try best.write(to: output); return }
            scale *= 0.7
        }
        throw ToolError.failed("Couldn't reach the target size. Try a larger target or a different image format.")
    }
    static func pdf(_ document: PDFDocument, to output: URL, bytes: Int64) throws {
        var dpi: CGFloat = 200
        for _ in 0..<9 {
            try Task.checkCancellation()
            try PDFOps.rasterize(document, to: output, dpi: dpi, quality: 0.55)
            if PDFOps.fileSize(output) <= bytes { return }
            dpi *= 0.72
        }
        throw ToolError.failed("Couldn't reach this target size. Choose a larger target.")
    }
}
