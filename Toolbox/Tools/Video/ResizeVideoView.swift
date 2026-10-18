import SwiftUI
import UniformTypeIdentifiers

struct ResizeVideoView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case preset, width, height, percent
        var id: Self { self }
        var label: String {
            switch self {
            case .preset: "Preset"
            case .width: "Width"
            case .height: "Height"
            case .percent: "Percentage"
            }
        }
    }

    @State private var mode = Mode.preset
    @State private var preset = 1080
    @State private var width = 1280
    @State private var height = 720
    @State private var percent = 50.0
    @State private var noEnlarge = true

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Resize", verb: "Resizing", noun: "videos") {
            Picker("Resize by", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            switch mode {
            case .preset:
                Picker("Size", selection: $preset) {
                    Text("4K (2160p)").tag(2160)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("480p").tag(480)
                    Text("360p").tag(360)
                }
                Text("Applies to the shorter side, so vertical videos get the same quality as horizontal ones.")
                    .font(.callout).foregroundStyle(.secondary)
            case .width:
                LabeledContent("Width") {
                    HStack {
                        TextField("Width", value: $width, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("px, height follows the aspect ratio").foregroundStyle(.secondary)
                    }
                }
            case .height:
                LabeledContent("Height") {
                    HStack {
                        TextField("Height", value: $height, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("px, width follows the aspect ratio").foregroundStyle(.secondary)
                    }
                }
            case .percent:
                LabeledContent("Scale") {
                    HStack {
                        Slider(value: $percent, in: 10...200, step: 5).frame(maxWidth: 260)
                        Text("\(Int(percent))%").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                }
            }
            if mode != .percent {
                Toggle("Don't enlarge videos that are already smaller", isOn: $noEnlarge)
            }
        } each: { [mode, preset, width, height, percent, noEnlarge] input, context, progress in
            let info = try await FFmpeg.probe(input)
            guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
            let container = VideoEncoding.outputExtension(for: input)
            let output = context.output(for: input, suffix: "resized", extension: container)
            let filter = ResizeVideoView.scaleFilter(mode: mode, preset: preset, width: width, height: height,
                                                     percent: percent, noEnlarge: noEnlarge)
            let args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-vf", filter]
                + VideoEncoding.h264(crf: 18)
                + VideoEncoding.audio(info, container: container)
                + VideoEncoding.containerFlags(container) + [output.path]
            try await FFmpeg.run(args, duration: info.duration, progress: progress)
        }
    }

    nonisolated static func scaleFilter(mode: Mode, preset: Int, width: Int, height: Int, percent: Double, noEnlarge: Bool) -> String {
        let scale: String
        switch mode {
        case .preset:
            let p = noEnlarge ? "min(iw,\(preset))" : "\(preset)"
            let q = noEnlarge ? "min(ih,\(preset))" : "\(preset)"
            scale = "scale='if(gte(iw,ih),-2,\(p))':'if(gte(iw,ih),\(q),-2)'"
        case .width:
            let w = VideoEncoding.even(Double(max(width, 2)))
            scale = noEnlarge ? "scale='min(iw,\(w))':-2" : "scale=\(w):-2"
        case .height:
            let h = VideoEncoding.even(Double(max(height, 2)))
            scale = noEnlarge ? "scale=-2:'min(ih,\(h))'" : "scale=-2:\(h)"
        case .percent:
            let factor = VideoEncoding.format(percent / 100)
            scale = "scale='trunc(iw*\(factor)/2)*2':'trunc(ih*\(factor)/2)*2'"
        }
        return scale + ":flags=lanczos,setsar=1"
    }
}
