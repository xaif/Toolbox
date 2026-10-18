import SwiftUI
import UniformTypeIdentifiers

struct TrimVideoView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case fast, precise
        var id: Self { self }
        var label: String { self == .fast ? "Fast" : "Precise" }
        var note: String {
            self == .fast
                ? "No re-encoding: instant and lossless, but cuts land on the nearest keyframe (can be off by a second or two)."
                : "Re-encodes the clip so cuts are frame-accurate. Slower."
        }
    }

    @State private var runner: JobRunner
    @State private var range: ClosedRange<Double> = 0...1
    @State private var duration: Double = 0
    @State private var mode = Mode.precise

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.videoInputs, allowsMultiple: false, title: "Video", noun: "a video")
                .disabled(runner.isRunning)
            if let input = runner.inputs.first {
                VideoTrimEditor(url: input, range: $range, duration: $duration)
                    .disabled(runner.isRunning)
                ToolSection("Options") {
                    Picker("Cut", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text(mode.note).font(.callout).foregroundStyle(.secondary)
                }
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Trim", canRun: canRun,
                   hint: runner.inputs.isEmpty ? "Add a video to get started." : nil, action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private var canRun: Bool {
        !runner.inputs.isEmpty && duration > 0 && (range.lowerBound > 0.01 || range.upperBound < duration - 0.01)
    }

    private func start() {
        guard let input = runner.inputs.first else { return }
        let range = range
        let mode = mode
        runner.start(title: tool.name) { context in
            context.setStatus("Trimming \(input.lastPathComponent)")
            let info = try await FFmpeg.probe(input)
            let container = mode == .fast ? input.pathExtension.lowercased() : VideoEncoding.outputExtension(for: input)
            let output = context.output(for: input, suffix: "trimmed", extension: container.isEmpty ? "mp4" : container)
            let args = TrimVideoView.arguments(input: input, output: output, info: info, start: range.lowerBound,
                                               end: range.upperBound, mode: mode)
            try await FFmpeg.run(args, duration: range.upperBound - range.lowerBound) { context.setProgress($0) }
        }
    }

    nonisolated static func arguments(input: URL, output: URL, info: MediaInfo, start: Double, end: Double, mode: Mode) -> [String] {
        let length = FFmpeg.timestamp(end - start)
        var args = ["-ss", FFmpeg.timestamp(start), "-i", input.path, "-t", length]
        let container = output.pathExtension.lowercased()
        switch mode {
        case .fast:
            args += ["-map", "0:v", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        case .precise:
            args += ["-map", "0:v:0", "-map", "0:a?"] + VideoEncoding.h264(crf: 18)
            args += info.hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
        }
        return args + VideoEncoding.containerFlags(container) + [output.path]
    }
}
