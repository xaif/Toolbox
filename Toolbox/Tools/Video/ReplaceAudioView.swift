import SwiftUI
import UniformTypeIdentifiers

struct ReplaceAudioView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case replace, mix
        var id: Self { self }
        var label: String { self == .replace ? "Replace original audio" : "Mix with original audio" }
    }

    enum Length: String, CaseIterable, Identifiable {
        case video, shortest
        var id: Self { self }
        var label: String { self == .video ? "Match the video" : "Stop at whichever ends first" }
    }

    @State private var runner: JobRunner
    @State private var audio: URL?
    @State private var mode = Mode.replace
    @State private var length = Length.video
    @State private var loopAudio = false
    @State private var newVolume = 1.0
    @State private var originalVolume = 0.3

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            Group {
                FileListInput(files: $runner.inputs, accepts: UTType.videoInputs, allowsMultiple: false, title: "Video", noun: "a video")
                VideoSingleFilePicker(title: "New audio", file: $audio, accepts: UTType.mediaInputs, noun: "an audio file")
                ToolSection("Options") {
                    Picker("Audio", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    volumeSlider("New audio volume", value: $newVolume, range: 0...2)
                    if mode == .mix {
                        volumeSlider("Original audio volume", value: $originalVolume, range: 0...2)
                    }
                    Picker("Length", selection: $length) {
                        ForEach(Length.allCases) { Text($0.label).tag($0) }
                    }
                    if length == .video {
                        Toggle("Loop the new audio if it's shorter than the video", isOn: $loopAudio)
                    }
                }
            }
            .disabled(runner.isRunning)
        } footer: {
            JobBar(runner: runner, actionTitle: "Replace Audio", canRun: !runner.inputs.isEmpty && audio != nil,
                   hint: "Add a video and an audio file.", action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
        .onChange(of: audio) { if !runner.isRunning { runner.reset() } }
    }

    private func volumeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05).frame(maxWidth: 240)
                Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func start() {
        guard let video = runner.inputs.first, let audio else { return }
        let options = Options(mode: mode, length: length, loopAudio: loopAudio, newVolume: newVolume, originalVolume: originalVolume)
        runner.start(title: tool.name) { context in
            context.setStatus("Replacing audio in \(video.lastPathComponent)")
            let videoInfo = try await FFmpeg.probe(video)
            let audioInfo = try await FFmpeg.probe(audio)
            guard videoInfo.hasVideo else { throw ToolError.failed("“\(video.lastPathComponent)” has no video.") }
            guard audioInfo.hasAudio else { throw ToolError.failed("“\(audio.lastPathComponent)” has no audio.") }
            let args = ReplaceAudioView.arguments(video: video, audio: audio, videoInfo: videoInfo,
                                                  audioInfo: audioInfo, options: options) { ext in
                context.output(for: video, suffix: "new-audio", extension: ext)
            }
            let expected = options.length == .video ? videoInfo.duration : min(videoInfo.duration, audioInfo.duration)
            try await FFmpeg.run(args, duration: expected) { context.setProgress($0) }
        }
    }

    struct Options {
        var mode: Mode
        var length: Length
        var loopAudio: Bool
        var newVolume: Double
        var originalVolume: Double
    }

    /// Builds the FFmpeg arguments. `makeOutput` receives the chosen container extension.
    nonisolated static func arguments(video: URL, audio: URL, videoInfo: MediaInfo, audioInfo: MediaInfo, options: Options,
                          makeOutput: (String) -> URL) -> [String] {
        let ext = video.pathExtension.lowercased()
        let container = ["mp4", "mov", "m4v", "mkv"].contains(ext) ? ext : "mp4"
        let output = makeOutput(container)

        var args = ["-i", video.path]
        let loop = options.length == .video && options.loopAudio
        if loop { args += ["-stream_loop", "-1"] }
        args += ["-i", audio.path, "-map", "0:v:0"]

        let newVol = VideoEncoding.format(options.newVolume)
        if options.mode == .mix, videoInfo.hasAudio {
            let origVol = VideoEncoding.format(options.originalVolume)
            // duration=first follows the video's own audio; -t below enforces the final length.
            let duration = options.length == .shortest ? "shortest" : "first"
            args += ["-filter_complex",
                     "[0:a:0]volume=\(origVol)[a0];[1:a:0]volume=\(newVol)[a1];"
                     + "[a0][a1]amix=inputs=2:duration=\(duration):dropout_transition=0:normalize=0[a]",
                     "-map", "[a]"]
        } else {
            args += ["-map", "1:a:0"]
            if abs(options.newVolume - 1) > 0.001 { args += ["-filter:a", "volume=\(newVol)"] }
        }

        if VideoEncoding.isCompatible(video: videoInfo.videoCodec, with: container) {
            args += ["-c:v", "copy"]
            if videoInfo.videoCodec == "hevc", container != "mkv" { args += ["-tag:v", "hvc1"] }
        } else {
            args += VideoEncoding.h264(crf: 20)
        }
        args += ["-c:a", "aac", "-b:a", "192k"]

        switch options.length {
        case .video: args += ["-t", FFmpeg.timestamp(videoInfo.duration)]
        case .shortest: args += ["-shortest"]
        }
        args += VideoEncoding.containerFlags(container) + [output.path]
        return args
    }
}
