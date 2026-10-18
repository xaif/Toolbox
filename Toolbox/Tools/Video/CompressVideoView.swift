import SwiftUI
import UniformTypeIdentifiers

/// Reference implementation of a per-file FFmpeg tool. Other tools follow the same shape:
/// `@State` options → `BatchToolView` → work closure that probes, builds arguments and runs FFmpeg.
struct CompressVideoView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case quality, targetSize
        var id: Self { self }
        var label: String { self == .quality ? "Quality" : "Target size" }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case high, balanced, small
        var id: Self { self }
        var label: String {
            switch self {
            case .high: "High quality"
            case .balanced: "Balanced"
            case .small: "Smallest file"
            }
        }
        /// CRF for libx264/libx265 (lower = better).
        var crf: Int {
            switch self {
            case .high: 23
            case .balanced: 28
            case .small: 33
            }
        }
        /// -q:v for VideoToolbox (higher = better).
        var hardwareQuality: Int {
            switch self {
            case .high: 65
            case .balanced: 52
            case .small: 40
            }
        }
    }

    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: Self { self }
        var label: String { self == .h264 ? "H.264 (most compatible)" : "HEVC (smaller)" }
    }

    @State private var mode = Mode.quality
    @State private var quality = Quality.balanced
    @State private var targetMB = 25.0
    @State private var codec = Codec.h264
    @State private var maxHeight = 0
    @State private var hardware = false
    @State private var keepAudio = true

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Compress", verb: "Compressing", noun: "videos") {
            Picker("Compress by", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if mode == .quality {
                Picker("Quality", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0) }
                }
            } else {
                LabeledContent("Target size per video") {
                    HStack {
                        TextField("MB", value: $targetMB, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        Text("MB").foregroundStyle(.secondary)
                        Stepper("", value: $targetMB, in: 1...10_000, step: 5).labelsHidden()
                    }
                }
            }
            Picker("Codec", selection: $codec) {
                ForEach(Codec.allCases) { Text($0.label).tag($0) }
            }
            Picker("Max resolution", selection: $maxHeight) {
                Text("Keep original").tag(0)
                Text("1080p").tag(1080)
                Text("720p").tag(720)
                Text("480p").tag(480)
            }
            Toggle("Keep audio", isOn: $keepAudio)
            Toggle("Faster encoding with the Apple hardware encoder (files are a bit larger)", isOn: $hardware)
        } each: { [mode, quality, targetMB, codec, maxHeight, hardware, keepAudio] input, context, progress in
            let info = try await FFmpeg.probe(input)
            guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
            let output = context.output(for: input, suffix: "compressed", extension: "mp4")

            var args = ["-i", input.path, "-map", "0:v:0"]
            if keepAudio && info.hasAudio { args += ["-map", "0:a:0?"] }

            if maxHeight > 0 {
                // Limit the short side so portrait videos are treated like landscape ones.
                args += ["-vf", "scale='if(gte(iw,ih),-2,min(iw,\(maxHeight)))':'if(gte(iw,ih),min(ih,\(maxHeight)),-2)'"]
            }

            switch (codec, hardware) {
            case (.h264, false): args += ["-c:v", "libx264", "-preset", "medium"]
            case (.hevc, false): args += ["-c:v", "libx265", "-preset", "medium", "-x265-params", "log-level=error"]
            case (.h264, true): args += ["-c:v", "h264_videotoolbox"]
            case (.hevc, true): args += ["-c:v", "hevc_videotoolbox"]
            }
            if codec == .hevc { args += ["-tag:v", "hvc1"] }

            let audioKbps = 128
            if mode == .targetSize, info.duration > 0 {
                let totalKbps = targetMB * 8192 / info.duration
                let videoKbps = max(Int(totalKbps * 0.97) - (keepAudio && info.hasAudio ? audioKbps : 0), 100)
                args += ["-b:v", "\(videoKbps)k", "-maxrate", "\(Int(Double(videoKbps) * 1.5))k", "-bufsize", "\(videoKbps * 2)k"]
            } else if hardware {
                args += ["-q:v", "\(quality.hardwareQuality)"]
            } else {
                args += ["-crf", "\(quality.crf + (codec == .hevc ? 2 : 0))"]
            }

            args += ["-pix_fmt", "yuv420p"]
            if keepAudio && info.hasAudio { args += ["-c:a", "aac", "-b:a", "\(audioKbps)k"] } else { args += ["-an"] }
            args += ["-movflags", "+faststart", output.path]

            try await FFmpeg.run(args, duration: info.duration, progress: progress)
        }
    }
}
