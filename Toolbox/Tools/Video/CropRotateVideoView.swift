import SwiftUI
import UniformTypeIdentifiers
import CoreImage

struct CropRotateVideoView: View {
    let tool: Tool

    enum Aspect: String, CaseIterable, Identifiable {
        case original, wide, vertical, square, classic, portrait
        var id: Self { self }
        var label: String {
            switch self {
            case .original: "Original"
            case .wide: "16:9"
            case .vertical: "9:16"
            case .square: "1:1"
            case .classic: "4:3"
            case .portrait: "4:5"
            }
        }
        /// Width : height of the final video, nil to keep the original framing.
        var ratio: VideoAspectRatio? {
            switch self {
            case .original: nil
            case .wide: VideoAspectRatio(width: 16, height: 9)
            case .vertical: VideoAspectRatio(width: 9, height: 16)
            case .square: VideoAspectRatio(width: 1, height: 1)
            case .classic: VideoAspectRatio(width: 4, height: 3)
            case .portrait: VideoAspectRatio(width: 4, height: 5)
            }
        }
    }

    @State private var aspect = Aspect.original
    @State private var rotation = 0
    @State private var flipH = false
    @State private var flipV = false
    @State private var runner: JobRunner

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var isNoOp: Bool { aspect == .original && rotation == 0 && !flipH && !flipV }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Apply", verb: "Processing",
                      noun: "videos", canRun: !isNoOp) {
            Picker("Crop to", selection: $aspect) {
                ForEach(Aspect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                Text("Rotate")
                Button { rotation = (rotation + 270) % 360 } label: { Label("Left", systemImage: "rotate.left") }
                Button { rotation = (rotation + 90) % 360 } label: { Label("Right", systemImage: "rotate.right") }
                Text(rotation == 0 ? "No rotation" : "\(rotation)° clockwise")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Toggle("Flip horizontally", isOn: $flipH).toggleStyle(.button)
                Toggle("Flip vertically", isOn: $flipV).toggleStyle(.button)
            }
            if let first = runner.inputs.first {
                CropRotatePreview(url: first, aspect: aspect.ratio, rotation: rotation, flipH: flipH, flipV: flipV)
                Text(runner.inputs.count > 1 ? "Preview of the first video. Each video is cropped around its center." : "The crop is centered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } each: { [aspect, rotation, flipH, flipV] input, context, progress in
            let info = try await FFmpeg.probe(input)
            guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
            let container = VideoEncoding.outputExtension(for: input)
            let output = context.output(for: input, suffix: "edited", extension: container)
            let filter = CropRotateVideoView.filter(aspect: aspect.ratio, rotation: rotation, flipH: flipH, flipV: flipV)
            let args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-vf", filter]
                + VideoEncoding.h264(crf: 18)
                + VideoEncoding.audio(info, container: container)
                + VideoEncoding.containerFlags(container) + [output.path]
            try await FFmpeg.run(args, duration: info.duration, progress: progress)
        }
    }

    /// Crop (centered) → rotate → flip. FFmpeg has already applied the source's own rotation metadata.
    nonisolated static func filter(aspect: VideoAspectRatio?, rotation: Int, flipH: Bool, flipV: Bool) -> String {
        var filters: [String] = []
        if let aspect {
            // The aspect describes the final video, so crop to the inverse before a quarter turn.
            let a = rotation % 180 == 0 ? aspect : aspect.inverted
            let (w, h) = (a.width, a.height)
            // Integer math keeps exact sizes, e.g. 16:9 of 1280x720 stays 1280x720.
            filters.append("crop='if(gt(iw*\(h),ih*\(w)),trunc(ih*\(w)/\(h)/2)*2,trunc(iw/2)*2)':'if(gt(iw*\(h),ih*\(w)),trunc(ih/2)*2,trunc(iw*\(h)/\(w)/2)*2)'")
        }
        switch rotation {
        case 90: filters.append("transpose=1")
        case 180: filters.append("hflip,vflip")
        case 270: filters.append("transpose=2")
        default: break
        }
        if flipH { filters.append("hflip") }
        if flipV { filters.append("vflip") }
        filters.append("setsar=1")
        return filters.joined(separator: ",")
    }
}

/// Renders the first frame exactly as it will look after cropping, rotating and flipping.
private struct CropRotatePreview: View {
    let url: URL
    let aspect: VideoAspectRatio?
    let rotation: Int
    let flipH: Bool
    let flipV: Bool

    @State private var frame: CGImage?
    @State private var result: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85))
            if let result {
                Image(decorative: result, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(8)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 260)
        .task(id: url) {
            frame = await VideoFrameGrabber.frame(of: url, at: 0.5, maxSize: 800)
            render()
        }
        .onChange(of: aspect) { render() }
        .onChange(of: rotation) { render() }
        .onChange(of: flipH) { render() }
        .onChange(of: flipV) { render() }
    }

    private func render() {
        guard let frame else { result = nil; return }
        var image = CIImage(cgImage: frame)
        if let aspect {
            let a = rotation % 180 == 0 ? aspect.value : aspect.inverted.value
            let w = image.extent.width, h = image.extent.height
            let cropSize = w / h > a ? CGSize(width: h * a, height: h) : CGSize(width: w, height: w / a)
            image = image.cropped(to: CGRect(x: (w - cropSize.width) / 2, y: (h - cropSize.height) / 2,
                                             width: cropSize.width, height: cropSize.height))
        }
        func normalize(_ img: CIImage) -> CIImage {
            img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        }
        image = normalize(image)
        if rotation != 0 {
            // CIImage is y-up, so a negative angle turns the picture clockwise.
            image = normalize(image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180)))
        }
        if flipH { image = normalize(image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if flipV { image = normalize(image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        result = CIContext().createCGImage(image, from: image.extent.integral)
    }
}

struct VideoAspectRatio: Equatable, Sendable {
    var width: Int
    var height: Int
    var value: Double { Double(width) / Double(height) }
    var inverted: VideoAspectRatio { VideoAspectRatio(width: height, height: width) }
}
