import SwiftUI
import UniformTypeIdentifiers

struct VideoToGIFView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var range: ClosedRange<Double> = 0...1
    @State private var duration: Double = 0
    @State private var fps = 15
    @State private var width = 480
    @State private var loops = true

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var length: Double { range.upperBound - range.lowerBound }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.videoInputs, allowsMultiple: false, title: "Video", noun: "a video")
                .disabled(runner.isRunning)
            if let input = runner.inputs.first {
                VideoTrimEditor(url: input, range: $range, duration: $duration, maximumLength: 8)
                    .disabled(runner.isRunning)
                ToolSection("GIF", footnote: length > 15 ? "Long GIFs get very large. Try a shorter clip, a lower frame rate or a smaller width." : nil) {
                    Picker("Frame rate", selection: $fps) {
                        Text("10 fps").tag(10)
                        Text("15 fps").tag(15)
                        Text("24 fps").tag(24)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("Width", selection: $width) {
                        Text("320 px").tag(320)
                        Text("480 px").tag(480)
                        Text("640 px").tag(640)
                        Text("800 px").tag(800)
                        Text("Original").tag(0)
                    }
                    Toggle("Loop forever", isOn: $loops)
                }
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Make GIF", canRun: !runner.inputs.isEmpty && duration > 0 && length > 0.05,
                   hint: "Add a video to get started.", action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func start() {
        guard let input = runner.inputs.first else { return }
        let (range, fps, width, loops) = (range, fps, width, loops)
        runner.start(title: tool.name) { context in
            context.setStatus("Making GIF from \(input.lastPathComponent)")
            let output = context.output(for: input, extension: "gif")
            let args = VideoToGIFView.arguments(input: input, output: output, start: range.lowerBound,
                                                length: range.upperBound - range.lowerBound, fps: fps, width: width, loops: loops)
            try await FFmpeg.run(args, duration: range.upperBound - range.lowerBound) { context.setProgress($0) }
        }
    }

    /// Palette generation and use in one pass: `palettegen` reads the whole clip to build an optimal
    /// 256-color palette, then `paletteuse` dithers each frame against it.
    nonisolated static func arguments(input: URL, output: URL, start: Double, length: Double, fps: Int, width: Int, loops: Bool) -> [String] {
        let scale = width > 0 ? "scale='min(\(width),iw)':-2:flags=lanczos" : "scale=iw:-2:flags=lanczos"
        let graph = "fps=\(fps),\(scale),split[s0][s1];[s0]palettegen=max_colors=256:stats_mode=full[p];"
            + "[s1][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle"
        return ["-ss", FFmpeg.timestamp(start), "-t", FFmpeg.timestamp(length), "-i", input.path,
                "-filter_complex", graph, "-loop", loops ? "0" : "-1", output.path]
    }
}
