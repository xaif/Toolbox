import SwiftUI
import UniformTypeIdentifiers

struct ConvertVideoView: View {
    let tool: Tool

    enum Format: String, CaseIterable, Identifiable {
        case mp4, mov, webm, mkv, avi, wmv
        var id: Self { self }
        var label: String {
            switch self {
            case .mp4: "MP4 (H.264)"
            case .mov: "MOV (QuickTime)"
            case .webm: "WebM (VP9)"
            case .mkv: "MKV (Matroska)"
            case .avi: "AVI (MPEG-4)"
            case .wmv: "WMV (Windows Media)"
            }
        }
        var note: String {
            switch self {
            case .mp4: "Plays everywhere: Macs, phones, browsers and social media."
            case .mov: "Best for editing in Final Cut, iMovie and other Apple apps."
            case .webm: "Open format for the web. Encoding is slower."
            case .mkv: "Flexible container that holds almost any codec."
            case .avi: "For older players and devices."
            case .wmv: "For Windows Media players and legacy systems."
            }
        }
    }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Convert", noun: "videos", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("video.convert.format") private var format = Format.mp4
        @AppStorage("video.convert.remux") private var remux = true

        var body: some View {
            OptionPicker("Format", selection: $format, choices: Format.allCases.map { OptionChoice($0, $0.label) })
            OptionNote(format.note)
            OptionToggle("Copy streams without re-encoding when the codecs allow it (fast, lossless)", isOn: $remux)
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Converting") { [format, remux] input, context, progress in
                let info = try await FFmpeg.probe(input)
                guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
                let container = format.rawValue
                let output = context.output(for: input, extension: container)
                try await FFmpeg.run(ConvertVideoView.arguments(input: input, output: output, info: info, format: format, remux: remux),
                                     duration: info.duration, progress: progress)
            }
        }
    }

    nonisolated static func arguments(input: URL, output: URL, info: MediaInfo, format: Format, remux: Bool) -> [String] {
        let container = format.rawValue
        var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a?"]

        if remux, VideoEncoding.isCompatible(video: info.videoCodec, with: container) {
            args += ["-c:v", "copy"]
            if info.videoCodec == "hevc", ["mp4", "mov"].contains(container) { args += ["-tag:v", "hvc1"] }
        } else {
            switch format {
            case .mp4, .mov, .mkv:
                args += VideoEncoding.h264(crf: 20)
            case .webm:
                args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                         "-deadline", "good", "-cpu-used", "2", "-pix_fmt", "yuv420p"]
            case .avi:
                args += ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "3", "-pix_fmt", "yuv420p"]
            case .wmv:
                args += ["-c:v", "wmv2", "-q:v", "3", "-pix_fmt", "yuv420p"]
            }
        }

        if !info.hasAudio {
            args += ["-an"]
        } else if remux, VideoEncoding.isCompatible(audio: info.audioCodec, with: container) {
            args += ["-c:a", "copy"]
        } else {
            switch format {
            case .webm: args += ["-c:a", "libopus", "-b:a", "128k"]
            case .avi: args += ["-c:a", "libmp3lame", "-q:a", "2"]
            case .wmv: args += ["-c:a", "wmav2", "-b:a", "192k"]
            default: args += ["-c:a", "aac", "-b:a", "192k"]
            }
        }
        return args + VideoEncoding.containerFlags(container) + [output.path]
    }
}
