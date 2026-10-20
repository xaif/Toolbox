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

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Resize", noun: "videos",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("video.resize.mode") private var mode = Mode.preset
        @AppStorage("video.resize.preset") private var preset = 1080
        @AppStorage("video.resize.width") private var width = 1280
        @AppStorage("video.resize.height") private var height = 720
        @AppStorage("video.resize.percent") private var percent = 50.0
        @AppStorage("video.resize.noEnlarge") private var noEnlarge = true

        var body: some View {
            OptionPicker("Resize by", selection: $mode, style: .segmented, choices: Mode.allCases.map { OptionChoice($0, $0.label) })

            switch mode {
            case .preset:
                OptionPicker("Size", selection: $preset, choices: [
                    OptionChoice(2160, "4K (2160p)"),
                    OptionChoice(1080, "1080p"),
                    OptionChoice(720, "720p"),
                    OptionChoice(480, "480p"),
                    OptionChoice(360, "360p"),
                ])
                OptionNote("Applies to the shorter side, so vertical videos get the same quality as horizontal ones.")
            case .width:
                OptionNumberField("Width", value: $width, format: .number, unit: "px, height follows the aspect ratio")
            case .height:
                OptionNumberField("Height", value: $height, format: .number, unit: "px, width follows the aspect ratio")
            case .percent:
                OptionSlider("Scale", value: $percent, in: 10...200, step: 5) { "\(Int($0))%" }
            }
            if mode != .percent {
                OptionToggle("Don't enlarge videos that are already smaller", isOn: $noEnlarge)
            }
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Resizing") { [mode, preset, width, height, percent, noEnlarge] input, context, progress in
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
