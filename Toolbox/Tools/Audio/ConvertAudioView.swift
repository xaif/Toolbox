import SwiftUI
import UniformTypeIdentifiers

struct ConvertAudioView: View {
    let tool: Tool

    @State private var format = AudioOutputFormat.mp3
    @State private var bitrate = 192
    @State private var sampleRate = 0
    @State private var channels = 0

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.audioInputs, actionTitle: "Convert", verb: "Converting", noun: "audio files") {
            Picker("Format", selection: $format) {
                ForEach(AudioOutputFormat.allCases) { Text($0.label).tag($0) }
            }
            if format.isLossy {
                Picker("Bitrate", selection: $bitrate) {
                    ForEach(AudioOutputFormat.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            Picker("Sample rate", selection: $sampleRate) {
                Text("Keep original").tag(0)
                Text("44.1 kHz").tag(44_100)
                Text("48 kHz").tag(48_000)
                if !format.isLossy { Text("96 kHz").tag(96_000) }
            }
            Picker("Channels", selection: $channels) {
                Text("Keep original").tag(0)
                Text("Stereo").tag(2)
                Text("Mono").tag(1)
            }
        } each: { [format, bitrate, sampleRate, channels] input, context, progress in
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

    @State private var format = Format.original
    @State private var bitrate = 192

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Extract", verb: "Extracting", noun: "videos") {
            Picker("Format", selection: $format) {
                ForEach(Format.allCases) { Text($0.label).tag($0) }
            }
            if let output = format.outputFormat, output.isLossy {
                Picker("Bitrate", selection: $bitrate) {
                    ForEach(AudioOutputFormat.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            if format == .original {
                Text("Copies the soundtrack exactly as it is stored in the video. The file type depends on the video's audio codec.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } each: { [format, bitrate] input, context, progress in
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
