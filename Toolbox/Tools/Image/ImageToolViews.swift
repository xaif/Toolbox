import SwiftUI
import UniformTypeIdentifiers

// MARK: - Convert

struct ConvertImagesView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Convert", noun: "images", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("image.convert.format") private var format = ImageFormat.jpeg
        @AppStorage("image.convert.quality") private var quality = 0.85
        @AppStorage("image.convert.keepMetadata") private var keepMetadata = true

        var body: some View {
            OptionPicker("Format", selection: $format, choices: ImageFormat.writable.map { OptionChoice($0, $0.label) })
            if format.supportsQuality {
                ImageQualitySlider(quality: $quality)
            }
            OptionToggle("Keep metadata (date, camera, location)", isOn: $keepMetadata)
            if !format.supportsAlpha {
                OptionNote("\(format.label) has no transparency, so transparent areas become white.")
            } else if format == .gif {
                OptionNote("Animated GIFs stay animated. Other images are saved as a single frame.")
            }
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Converting") { [format, quality, keepMetadata] input, context, progress in
                let output = context.output(for: input, extension: format.fileExtension)
                try ImageIOHelpers.reencode(input, to: output, format: format, quality: quality, keepMetadata: keepMetadata)
                progress(1)
            }
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

    @State private var runner: JobRunner

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Compress", noun: "images", job: { Settings().job(for: tool) }) {
            Settings()
            if let summary = savingsSummary {
                Label(summary, systemImage: "chart.bar.xaxis")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("image.compress.target") private var target = Target.keep
        @AppStorage("image.compress.quality") private var quality = 0.7
        @AppStorage("image.compress.maxDimension") private var maxDimension = 0
        @AppStorage("image.compress.keepMetadata") private var keepMetadata = false

        var body: some View {
            OptionPicker("Save as", selection: $target, choices: Target.allCases.map { OptionChoice($0, $0.label) })
            CompressionGoalControls(prefix: "image.compress.goal")
            ImageQualitySlider(quality: $quality)
            OptionPicker("Max size", selection: $maxDimension, choices: [
                OptionChoice(0, "Keep dimensions"),
                OptionChoice(4096, "4096 px"),
                OptionChoice(2560, "2560 px"),
                OptionChoice(1920, "1920 px"),
                OptionChoice(1280, "1280 px"),
                OptionChoice(800, "800 px"),
            ])
            OptionToggle("Keep metadata (date, camera, location)", isOn: $keepMetadata)
            OptionNote("Quality applies to JPEG and HEIC. PNG, GIF and TIFF are lossless, so pick JPEG/HEIC or a max size for big savings. If a result would be larger than the original, the original is kept.")
            OptionNote("Target size and percentage modes may reduce image dimensions to reach the requested size.")
        }

        func job(for tool: Tool) -> ToolJob? {
            let goal = CompressionGoal(prefix: "image.compress.goal")
            return .each(verb: "Compressing") { [target, quality, maxDimension, keepMetadata] input, context, progress in
                let format: ImageFormat = switch target {
                case .keep: ImageIOHelpers.keepFormat(for: input)
                case .jpeg: .jpeg
                case .heic: ImageFormat.writable.contains(.heic) ? .heic : .jpeg
                }
                let output = context.output(for: input, suffix: "compressed", extension: format.fileExtension)
                if let bytes = goal.bytes(for: input) {
                    try TargetCompression.image(input, to: output, format: format, bytes: bytes, maxDimension: maxDimension, keepMetadata: keepMetadata)
                    progress(1); return
                }
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

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Resize", noun: "images",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("image.resize.mode") private var mode = Mode.fit
        @AppStorage("image.resize.percent") private var percent = 50.0
        @AppStorage("image.resize.width") private var width = 1920
        @AppStorage("image.resize.height") private var height = 1080
        @AppStorage("image.resize.allowEnlarge") private var allowEnlarge = false

        var body: some View {
            OptionPicker("Resize by", selection: $mode, style: .segmented, choices: Mode.allCases.map { OptionChoice($0, $0.label) })

            switch mode {
            case .percent:
                OptionSlider("Scale", value: $percent, in: 5...400, step: 5) { "\(Int($0))%" }
            case .fit, .exact:
                OptionSizeFields(mode == .fit ? "Fit inside" : "Size", width: $width, height: $height)
            case .width:
                OptionNumberField("Width", value: $width, format: .number.grouping(.never), unit: "px", in: 1...50_000)
            case .height:
                OptionNumberField("Height", value: $height, format: .number.grouping(.never), unit: "px", in: 1...50_000)
            }
            if mode != .percent && mode != .exact {
                OptionToggle("Enlarge images smaller than this", isOn: $allowEnlarge)
            }
            OptionNote(mode == .exact ? "Exact size stretches images that have a different shape." : "Proportions are always kept.")
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Resizing") { [mode, percent, width, height, allowEnlarge] input, context, progress in
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

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Rotate", noun: "images",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("image.rotate.operation") private var operation = Operation.right

        var body: some View {
            OptionPicker("Action", selection: $operation, style: .radioGroup,
                         choices: Operation.allCases.map { OptionChoice($0, $0.label, symbol: $0.symbol) })
            OptionNote("Photos are first turned upright using their camera orientation, so they look the same in every app.")
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Rotating") { [operation] input, context, progress in
                let format = ImageIOHelpers.keepFormat(for: input)
                let output = context.output(for: input, suffix: "rotated", extension: format.fileExtension)
                try ImageIOHelpers.reencode(input, to: output, format: format, quality: 0.95) { image in
                    try ImageIOHelpers.apply(operation.orientation, to: image)
                }
                progress(1)
            }
        }
    }
}

// MARK: - Remove Metadata

struct RemoveMetadataView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, actionTitle: "Remove Metadata", noun: "images", job: { job }) {
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
        }
    }

    /// What the action button runs, with the current settings. The launcher's quick action runs it too.
    var job: ToolJob {
        .each(verb: "Cleaning") { input, context, progress in
            let format = ImageIOHelpers.keepFormat(for: input)
            let output = context.output(for: input, suffix: "clean", extension: format.fileExtension)
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
        OptionSlider("Quality", value: $quality, in: 0.1...1, step: 0.05, minimumLabel: "Smaller", maximumLabel: "Better") {
            "\(Int(($0 * 100).rounded()))%"
        }
    }
}
