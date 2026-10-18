import SwiftUI
import UniformTypeIdentifiers

// MARK: - Convert

struct ConvertImagesView: View {
    let tool: Tool

    @State private var format = ImageFormat.jpeg
    @State private var quality = 0.85
    @State private var keepMetadata = true

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Convert", verb: "Converting", noun: "images") {
            Picker("Format", selection: $format) {
                ForEach(ImageFormat.writable) { Text($0.label).tag($0) }
            }
            if format.supportsQuality {
                ImageQualitySlider(quality: $quality)
            }
            Toggle("Keep metadata (date, camera, location)", isOn: $keepMetadata)
            if !format.supportsAlpha {
                Text("\(format.label) has no transparency, so transparent areas become white.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if format == .gif {
                Text("Animated GIFs stay animated. Other images are saved as a single frame.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } each: { [format, quality, keepMetadata] input, context, progress in
            let output = context.output(for: input, extension: format.fileExtension)
            try ImageIOHelpers.reencode(input, to: output, format: format, quality: quality, keepMetadata: keepMetadata)
            progress(1)
        }
    }
}

// MARK: - Compress

struct CompressImagesView: View {
    let tool: Tool

    enum Target: String, CaseIterable, Identifiable {
        case keep, jpeg, heic
        var id: Self { self }
        var label: String {
            switch self {
            case .keep: "Keep original format"
            case .jpeg: "JPEG"
            case .heic: "HEIC (smallest)"
            }
        }
    }

    @State private var target = Target.keep
    @State private var quality = 0.7
    @State private var maxDimension = 0
    @State private var keepMetadata = false
    @State private var runner: JobRunner

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Compress", verb: "Compressing", noun: "images") {
            Picker("Save as", selection: $target) {
                ForEach(Target.allCases) { Text($0.label).tag($0) }
            }
            ImageQualitySlider(quality: $quality)
            Picker("Max size", selection: $maxDimension) {
                Text("Keep dimensions").tag(0)
                Text("4096 px").tag(4096)
                Text("2560 px").tag(2560)
                Text("1920 px").tag(1920)
                Text("1280 px").tag(1280)
                Text("800 px").tag(800)
            }
            Toggle("Keep metadata (date, camera, location)", isOn: $keepMetadata)
            Text("Quality applies to JPEG and HEIC. PNG, GIF and TIFF are lossless, so pick JPEG/HEIC or a max size for big savings. If a result would be larger than the original, the original is kept.")
                .font(.callout).foregroundStyle(.secondary)
            if let summary = savingsSummary {
                Label(summary, systemImage: "chart.bar.xaxis")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }
        } each: { [target, quality, maxDimension, keepMetadata] input, context, progress in
            let format: ImageFormat = switch target {
            case .keep: ImageIOHelpers.keepFormat(for: input)
            case .jpeg: .jpeg
            case .heic: ImageFormat.writable.contains(.heic) ? .heic : .jpeg
            }
            let output = context.output(for: input, extension: format.fileExtension)
            try ImageIOHelpers.reencode(input, to: output, format: format, quality: quality, keepMetadata: keepMetadata) { image in
                guard maxDimension > 0, max(image.width, image.height) > maxDimension else { return image }
                let scale = Double(maxDimension) / Double(max(image.width, image.height))
                return try ImageIOHelpers.resize(image, width: Int((Double(image.width) * scale).rounded()),
                                                 height: Int((Double(image.height) * scale).rounded()))
            }
            // Never hand back a bigger file in the same format with the same dimensions.
            let sameFormat = ImageFormat.of(input) == format
            if sameFormat, maxDimension == 0, FileSize.bytes(for: output) >= FileSize.bytes(for: input) {
                try FileManager.default.removeItem(at: output)
                try FileManager.default.copyItem(at: input, to: output)
            }
            progress(1)
        }
    }

    private var savingsSummary: String? {
        guard runner.phase == .succeeded, !runner.outputs.isEmpty else { return nil }
        let before = runner.inputs.reduce(Int64(0)) { $0 + FileSize.bytes(for: $1) }
        let after = runner.outputs.reduce(Int64(0)) { $0 + FileSize.bytes(for: $1) }
        guard before > 0 else { return nil }
        let saved = before - after
        let percent = Int((Double(saved) / Double(before) * 100).rounded())
        let formatter = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return saved > 0
            ? "Last run: \(formatter(before)) → \(formatter(after)), saved \(percent)%"
            : "Last run: \(formatter(before)) → \(formatter(after)). These images were already well compressed."
    }
}

// MARK: - Resize

struct ResizeImagesView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case percent, fit, width, height, exact
        var id: Self { self }
        var label: String {
            switch self {
            case .percent: "Percentage"
            case .fit: "Fit within"
            case .width: "Width"
            case .height: "Height"
            case .exact: "Exact size"
            }
        }
    }

    @State private var mode = Mode.fit
    @State private var percent = 50.0
    @State private var width = 1920
    @State private var height = 1080
    @State private var allowEnlarge = false

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Resize", verb: "Resizing", noun: "images") {
            Picker("Resize by", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            switch mode {
            case .percent:
                LabeledContent("Scale") {
                    HStack {
                        Slider(value: $percent, in: 5...400, step: 5).frame(maxWidth: 260)
                        Text("\(Int(percent))%").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
            case .fit, .exact:
                LabeledContent(mode == .fit ? "Fit inside" : "Size") {
                    HStack {
                        ImagePixelField(value: $width)
                        Text("×").foregroundStyle(.secondary)
                        ImagePixelField(value: $height)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            case .width:
                LabeledContent("Width") { HStack { ImagePixelField(value: $width); Text("px").foregroundStyle(.secondary) } }
            case .height:
                LabeledContent("Height") { HStack { ImagePixelField(value: $height); Text("px").foregroundStyle(.secondary) } }
            }
            if mode != .percent && mode != .exact {
                Toggle("Enlarge images smaller than this", isOn: $allowEnlarge)
            }
            Text(mode == .exact ? "Exact size stretches images that have a different shape." : "Proportions are always kept.")
                .font(.callout).foregroundStyle(.secondary)
        } each: { [mode, percent, width, height, allowEnlarge] input, context, progress in
            let format = ImageIOHelpers.keepFormat(for: input)
            let output = context.output(for: input, suffix: "resized", extension: format.fileExtension)
            try ImageIOHelpers.reencode(input, to: output, format: format, quality: 0.92) { image in
                let size = ResizeImagesView.targetSize(width: image.width, height: image.height, mode: mode, percent: percent,
                                                       targetWidth: width, targetHeight: height, allowEnlarge: allowEnlarge)
                return try ImageIOHelpers.resize(image, width: size.width, height: size.height)
            }
            progress(1)
        }
    }

    nonisolated static func targetSize(width: Int, height: Int, mode: Mode, percent: Double, targetWidth: Int,
                                       targetHeight: Int, allowEnlarge: Bool) -> (width: Int, height: Int) {
        let w = Double(width), h = Double(height)
        var scale: Double
        switch mode {
        case .exact:
            return (max(targetWidth, 1), max(targetHeight, 1))
        case .percent:
            scale = percent / 100
        case .fit:
            scale = min(Double(targetWidth) / w, Double(targetHeight) / h)
        case .width:
            scale = Double(targetWidth) / w
        case .height:
            scale = Double(targetHeight) / h
        }
        if mode != .percent, !allowEnlarge { scale = min(scale, 1) }
        return (max(Int((w * scale).rounded()), 1), max(Int((h * scale).rounded()), 1))
    }
}

// MARK: - Rotate

struct RotateImagesView: View {
    let tool: Tool

    enum Operation: String, CaseIterable, Identifiable {
        case right, left, half, flipHorizontal, flipVertical
        var id: Self { self }
        var label: String {
            switch self {
            case .right: "Rotate right 90°"
            case .left: "Rotate left 90°"
            case .half: "Rotate 180°"
            case .flipHorizontal: "Flip horizontally"
            case .flipVertical: "Flip vertically"
            }
        }
        var symbol: String {
            switch self {
            case .right: "rotate.right"
            case .left: "rotate.left"
            case .half: "arrow.clockwise"
            case .flipHorizontal: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            case .flipVertical: "arrow.up.and.down.righttriangle.up.righttriangle.down"
            }
        }
        var orientation: CGImagePropertyOrientation {
            switch self {
            case .right: .right
            case .left: .left
            case .half: .down
            case .flipHorizontal: .upMirrored
            case .flipVertical: .downMirrored
            }
        }
    }

    @State private var operation = Operation.right

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Rotate", verb: "Rotating", noun: "images") {
            Picker("Action", selection: $operation) {
                ForEach(Operation.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Photos are first turned upright using their camera orientation, so they look the same in every app.")
                .font(.callout).foregroundStyle(.secondary)
        } each: { [operation] input, context, progress in
            let format = ImageIOHelpers.keepFormat(for: input)
            let output = context.output(for: input, suffix: "rotated", extension: format.fileExtension)
            try ImageIOHelpers.reencode(input, to: output, format: format, quality: 0.95) { image in
                try ImageIOHelpers.apply(operation.orientation, to: image)
            }
            progress(1)
        }
    }
}

// MARK: - Remove Metadata

struct RemoveMetadataView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Remove Metadata", verb: "Cleaning", noun: "images") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Removes:").font(.callout.weight(.medium))
                Label("Location (GPS coordinates)", systemImage: "location.slash")
                Label("Camera, lens and serial numbers", systemImage: "camera")
                Label("Capture dates and editing software", systemImage: "calendar")
                Label("Captions, keywords, copyright and XMP data", systemImage: "text.badge.xmark")
            }
            .foregroundStyle(.secondary)
            Text("Pixels stay as they are and the color profile is kept. Rotated photos are turned upright so they don't appear sideways once the orientation tag is gone.")
                .font(.callout).foregroundStyle(.secondary)
        } each: { input, context, progress in
            let format = ImageIOHelpers.keepFormat(for: input)
            let output = context.output(for: input, extension: format.fileExtension)
            try ImageMetadataStripper.strip(input, to: output, format: format)
            progress(1)
        }
    }
}

enum ImageMetadataStripper {
    /// Strips metadata. Uses a lossless copy when the image is upright and keeps its format,
    /// otherwise re-encodes with orientation baked in.
    static func strip(_ input: URL, to output: URL, format: ImageFormat) throws {
        let source = try ImageIOHelpers.source(for: input)
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let upright = ImageIOHelpers.orientation(ImageIOHelpers.properties(source, index: primary)) == .up
        if upright, CGImageSourceGetCount(source) == 1, ImageFormat.of(input) == format,
           let destination = CGImageDestinationCreateWithURL(output as CFURL, format.utType.identifier as CFString, 1, nil) {
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
               remainingMetadata(at: output).isEmpty {
                return
            }
            try? FileManager.default.removeItem(at: output)
        }
        try ImageIOHelpers.reencode(input, to: output, format: format, quality: 0.95, keepMetadata: false)
        let leftover = remainingMetadata(at: output)
        guard leftover.isEmpty else {
            throw ToolError.failed("Couldn't remove: \(leftover.joined(separator: ", ")).")
        }
    }

    /// Names of sensitive metadata groups still present in a file.
    static func remainingMetadata(at url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let properties = ImageIOHelpers.properties(source, index: CGImageSourceGetPrimaryImageIndex(source))
        var found: [String] = []
        if properties[kCGImagePropertyGPSDictionary] != nil { found.append("location") }
        if properties[kCGImagePropertyIPTCDictionary] != nil { found.append("IPTC") }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff.keys.contains(where: { [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                                         kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright].contains($0) }) {
            found.append("camera info")
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let harmless: Set<String> = [kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
                                         kCGImagePropertyExifColorSpace as String]
            if exif.keys.contains(where: { !harmless.contains($0 as String) }) { found.append("Exif") }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag],
           tags.contains(where: { (CGImageMetadataTagCopyPrefix($0) as String?) == "dc" || (CGImageMetadataTagCopyPrefix($0) as String?) == "photoshop" }) {
            found.append("XMP")
        }
        return found
    }
}

// MARK: - Shared controls

struct ImageQualitySlider: View {
    @Binding var quality: Double

    var body: some View {
        LabeledContent("Quality") {
            HStack {
                Text("Smaller").font(.caption).foregroundStyle(.secondary)
                Slider(value: $quality, in: 0.1...1, step: 0.05).frame(maxWidth: 240)
                Text("Better").font(.caption).foregroundStyle(.secondary)
                Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}

struct ImagePixelField: View {
    @Binding var value: Int

    var body: some View {
        TextField("px", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .onChange(of: value) { if value < 1 { value = 1 } else if value > 50_000 { value = 50_000 } }
    }
}
