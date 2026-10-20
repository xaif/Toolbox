import SwiftUI
import UniformTypeIdentifiers

struct ChangeSpeedView: View {
    let tool: Tool

    enum AudioMode: String, CaseIterable, Identifiable {
        case keepPitch, changePitch, remove
        var id: Self { self }
        var label: String {
            switch self {
            case .keepPitch: "Change speed, keep pitch"
            case .changePitch: "Change speed and pitch"
            case .remove: "Remove audio"
            }
        }
    }

    static let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Change Speed", noun: "videos",
                      job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("video.speed.speed") private var speed = 2.0
        @AppStorage("video.speed.audioMode") private var audioMode = AudioMode.keepPitch

        var body: some View {
            OptionSlider("Speed", value: $speed, in: 0.25...4, step: 0.05, presets: ChangeSpeedView.presets) {
                "\(VideoEncoding.format($0))×"
            }
            OptionPicker("Audio", selection: $audioMode, choices: AudioMode.allCases.map { OptionChoice($0, $0.label) })
            OptionNote(speed > 1 ? "The video will be \(VideoEncoding.format(speed))× faster." : "The video will play at \(Int(speed * 100))% speed.")
        }

        /// Nil at 1×, which would change nothing.
        func job(for tool: Tool) -> ToolJob? {
            guard abs(speed - 1) > 0.001 else { return nil }
            return .each(verb: "Processing") { [speed, audioMode] input, context, progress in
                let info = try await FFmpeg.probe(input)
                guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
                let container = VideoEncoding.outputExtension(for: input)
                let output = context.output(for: input, suffix: "\(VideoEncoding.format(speed))x", extension: container)
                try await FFmpeg.run(ChangeSpeedView.arguments(input: input, output: output, info: info, speed: speed, audioMode: audioMode),
                                     duration: info.duration / speed, progress: progress)
            }
        }
    }

    nonisolated static func arguments(input: URL, output: URL, info: MediaInfo, speed: Double, audioMode: AudioMode) -> [String] {
        var args = ["-i", input.path, "-map", "0:v:0"]
        let s = VideoEncoding.format(speed)
        args += ["-vf", "setpts=PTS/\(s)"]
        if info.hasAudio, audioMode != .remove {
            args += ["-map", "0:a:0"]
            switch audioMode {
            case .keepPitch:
                args += ["-af", VideoEncoding.atempoChain(speed)]
            case .changePitch:
                args += ["-af", "aresample=48000,asetrate=\(Int(48000 * speed)),aresample=48000"]
            case .remove:
                break
            }
            args += ["-c:a", "aac", "-b:a", "192k"]
        } else {
            args += ["-an"]
        }
        // Speed changes reshape timestamps, so the video must be re-encoded.
        return args + VideoEncoding.h264(crf: 20) + VideoEncoding.containerFlags(output.pathExtension.lowercased()) + [output.path]
    }
}
