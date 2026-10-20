import SwiftUI
import UniformTypeIdentifiers

struct ConvertAudioView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.audioInputs, actionTitle: "Convert", noun: "audio files", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("audio.convert.format") private var format = AudioOutputFormat.mp3
        @AppStorage("audio.convert.bitrate") private var bitrate = 192
        @AppStorage("audio.convert.sampleRate") private var sampleRate = 0
        @AppStorage("audio.convert.channels") private var channels = 0

        var body: some View {
            OptionPicker("Format", selection: $format, choices: AudioOutputFormat.allCases.map { OptionChoice($0, $0.label) })
            if format.isLossy {
                OptionPicker("Bitrate", selection: $bitrate, choices: AudioOutputFormat.bitrates.map { OptionChoice($0, "\($0) kbps") })
            }
            OptionPicker("Sample rate", selection: $sampleRate, choices: [
                OptionChoice(0, "Keep original"),
                OptionChoice(44_100, "44.1 kHz"),
                OptionChoice(48_000, "48 kHz"),
            ] + (format.isLossy ? [] : [OptionChoice(96_000, "96 kHz")]))
            OptionPicker("Channels", selection: $channels, choices: [
                OptionChoice(0, "Keep original"),
                OptionChoice(2, "Stereo"),
                OptionChoice(1, "Mono"),
            ])
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Converting") { [format, bitrate, sampleRate, channels] input, context, progress in
                let info = try await FFmpeg.probe(input)
                guard info.hasAudio else { throw ToolError.failed("No audio found.") }
                let output = context.output(for: input, extension: format.fileExtension)
                var args = ["-i", input.path, "-map", "0:a:0"]
                args += format.codecArguments(bitrate: bitrate)
                if sampleRate > 0 { args += ["-ar", "\(sampleRate)"] }
                // Without an explicit count, FFmpeg downmixes surround to stereo for encoders that need it (MP3).
                if channels > 0 { args += ["-ac", "\(channels)"] }
                args += ["-map_metadata", "0", output.path]
                try await FFmpeg.run(args, duration: info.duration, progress: progress)
            }
        }
    }
}

struct ExtractAudioView: View {
    let tool: Tool

    enum Format: String, CaseIterable, Identifiable {
        case original, mp3, m4a, wav, flac
        var id: Self { self }
        var label: String {
            switch self {
            case .original: "Original (no quality loss)"
            case .mp3: "MP3"
            case .m4a: "M4A (AAC)"
            case .wav: "WAV"
            case .flac: "FLAC"
            }
        }
        var outputFormat: AudioOutputFormat? {
            switch self {
            case .original: nil
            case .mp3: .mp3
            case .m4a: .m4a
            case .wav: .wav
            case .flac: .flac
            }
        }
    }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Extract", noun: "videos", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("audio.extract.format") private var format = Format.original
        @AppStorage("audio.extract.bitrate") private var bitrate = 192

        var body: some View {
            OptionPicker("Format", selection: $format, choices: Format.allCases.map { OptionChoice($0, $0.label) })
            if let output = format.outputFormat, output.isLossy {
                OptionPicker("Bitrate", selection: $bitrate, choices: AudioOutputFormat.bitrates.map { OptionChoice($0, "\($0) kbps") })
            }
            if format == .original {
                OptionNote("Copies the soundtrack exactly as it is stored in the video. The file type depends on the video's audio codec.")
            }
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Extracting") { [format, bitrate] input, context, progress in
                let info = try await FFmpeg.probe(input)
                guard info.hasAudio else { throw ToolError.failed("This video has no audio track.") }
                var args = ["-i", input.path, "-map", "0:a:0", "-vn"]
                let output: URL
                if let target = format.outputFormat {
                    output = context.output(for: input, extension: target.fileExtension)
                    args += target.codecArguments(bitrate: bitrate)
                } else {
                    output = context.output(for: input, extension: AudioProbe.copyContainer(forCodec: info.audioCodec))
                    args += ["-c:a", "copy"]
                }
                args += ["-map_metadata", "0", output.path]
                try await FFmpeg.run(args, duration: info.duration, progress: progress)
            }
        }
    }
}
