import Foundation

/// Basic facts about a media file, read with ffprobe (or AVFoundation as a fallback).
struct MediaInfo {
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    /// Clockwise rotation from container metadata (0, 90, 180, 270).
    var rotation: Int = 0
    var frameRate: Double = 0
    var hasVideo = false
    var hasAudio = false
    var videoCodec: String?
    var audioCodec: String?
    var bitRate: Int = 0

    /// Display size after applying rotation.
    var displaySize: CGSize {
        rotation % 180 == 0
            ? CGSize(width: width, height: height)
            : CGSize(width: height, height: width)
    }
}

enum FFmpeg {
    /// Runs ffmpeg with the given arguments (inputs, filters and output).
    /// - Parameters:
    ///   - duration: Expected output duration in seconds, used to compute progress.
    ///   - progress: Called with 0...1 as encoding advances.
    static func run(
        _ arguments: [String],
        duration: Double? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let ffmpeg = try Dependencies.require(.ffmpeg)
        let base = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        let total = duration ?? 0
        try await ProcessRunner.runChecked(ffmpeg, arguments: base + arguments, onStdoutLine: { line in
            guard total > 0, let progress else { return }
            // -progress emits key=value lines; out_time_us is the encoded position in microseconds.
            if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) {
                progress(min(max(micros / 1_000_000 / total, 0), 1))
            } else if line == "progress=end" {
                progress(1)
            }
        })
    }

    /// Reads duration, dimensions and stream info.
    static func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = Dependencies.locateFFprobe() else { throw ToolError.missingDependency(.ffmpeg) }
        let result = try await ProcessRunner.runChecked(ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.unreadableInput(url)
        }
        var info = MediaInfo()
        if let format = json["format"] as? [String: Any] {
            info.duration = Double(format["duration"] as? String ?? "") ?? 0
            info.bitRate = Int(format["bit_rate"] as? String ?? "") ?? 0
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            if type == "video", !info.hasVideo {
                // Skip attached cover art, which ffprobe reports as a video stream.
                if let disposition = stream["disposition"] as? [String: Any], (disposition["attached_pic"] as? Int) == 1 { continue }
                info.hasVideo = true
                info.width = stream["width"] as? Int ?? 0
                info.height = stream["height"] as? Int ?? 0
                info.videoCodec = stream["codec_name"] as? String
                info.frameRate = parseRate(stream["avg_frame_rate"] as? String) ?? parseRate(stream["r_frame_rate"] as? String) ?? 0
                if let tags = stream["tags"] as? [String: Any], let rotate = Int(tags["rotate"] as? String ?? "") {
                    info.rotation = rotate
                }
                for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
                    if let rotation = side["rotation"] as? Int { info.rotation = -rotation }
                    else if let rotation = side["rotation"] as? Double { info.rotation = -Int(rotation) }
                }
                info.rotation = ((info.rotation % 360) + 360) % 360
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            } else if type == "audio", !info.hasAudio {
                info.hasAudio = true
                info.audioCodec = stream["codec_name"] as? String
                if info.duration == 0 { info.duration = Double(stream["duration"] as? String ?? "") ?? 0 }
            }
        }
        return info
    }

    private static func parseRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return parts.first }
        let value = parts[0] / parts[1]
        return value > 0 ? value : nil
    }

    /// Formats seconds for ffmpeg's -ss/-to/-t options.
    static func timestamp(_ seconds: Double) -> String {
        String(format: "%.3f", max(seconds, 0))
    }
}
