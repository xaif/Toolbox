import SwiftUI
import UniformTypeIdentifiers

/// Reference implementation of a per-file FFmpeg tool. Other tools follow the same shape: a nested
/// `Settings` view holds the `@AppStorage` options and builds the job (probe, build arguments, run FFmpeg);
/// the page shows it in a `BatchToolView`, and the launcher shows the same form and runs the same job.
struct CompressVideoView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case quality, targetSize, percentage
        var id: Self { self }
        var label: String { switch self { case .quality: "Quality"; case .targetSize: "Target size"; case .percentage: "Percentage" } }
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

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Compress", noun: "videos", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("video.compress.mode") private var mode = Mode.quality
        @AppStorage("video.compress.quality") private var quality = Quality.balanced
        @AppStorage("video.compress.targetMB") private var targetMB = 25.0
        @AppStorage("video.compress.reduction") private var reduction = 50.0
        @AppStorage("video.compress.codec") private var codec = Codec.h264
        @AppStorage("video.compress.maxHeight") private var maxHeight = 0
        @AppStorage("video.compress.hardware") private var hardware = false
        @AppStorage("video.compress.keepAudio") private var keepAudio = true

        var body: some View {
            OptionPicker("Compress by", selection: $mode, style: .segmented, choices: Mode.allCases.map { OptionChoice($0, $0.label) })

            if mode == .quality {
                OptionPicker("Quality", selection: $quality, choices: Quality.allCases.map { OptionChoice($0, $0.label) })
            } else if mode == .percentage {
                OptionSlider("Reduce by", value: $reduction, in: 1...95, step: 1) { "\(Int($0))%" }
            } else {
                OptionNumberField("Target size per video", value: $targetMB, format: .number.precision(.fractionLength(0...1)),
                                  unit: "MB", in: 1...10_000, step: 5, width: 70)
            }
            OptionPicker("Codec", selection: $codec, choices: Codec.allCases.map { OptionChoice($0, $0.label) })
            OptionPicker("Max resolution", selection: $maxHeight, choices: [
                OptionChoice(0, "Keep original"),
                OptionChoice(1080, "1080p"),
                OptionChoice(720, "720p"),
                OptionChoice(480, "480p"),
            ])
            OptionToggle("Keep audio", isOn: $keepAudio)
            OptionToggle("Faster encoding with the Apple hardware encoder (files are a bit larger)", isOn: $hardware)
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Compressing") { [mode, quality, targetMB, reduction, codec, maxHeight, hardware, keepAudio] input, context, progress in
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
                if mode != .quality, info.duration > 0 {
                    let bytes = mode == .percentage ? Double(PDFOps.fileSize(input))*(1-reduction/100) : targetMB*1_000_000
                    let totalKbps = bytes * 8 / 1000 / info.duration
                    guard totalKbps > Double(keepAudio && info.hasAudio ? audioKbps+100 : 100) else { throw ToolError.failed("This target is too small for the video's duration. Choose a larger size.") }
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
}
