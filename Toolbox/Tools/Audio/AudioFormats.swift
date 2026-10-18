import Foundation
import UniformTypeIdentifiers

/// Audio formats the audio tools can write with FFmpeg.
enum AudioOutputFormat: String, CaseIterable, Identifiable {
    case mp3, m4a, wav, aiff, flac, ogg, opus

    var id: Self { self }

    var label: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .ogg: "OGG (Opus)"
        case .opus: "Opus"
        }
    }

    var fileExtension: String {
        switch self {
        case .aiff: "aif"
        default: rawValue
        }
    }

    var isLossy: Bool {
        switch self {
        case .mp3, .m4a, .ogg, .opus: true
        case .wav, .aiff, .flac: false
        }
    }

    /// Bitrates offered for lossy formats, in kbps.
    static let bitrates = [64, 96, 128, 160, 192, 256, 320]

    /// FFmpeg codec arguments. `bitrate` (kbps) is used for lossy formats only.
    func codecArguments(bitrate: Int) -> [String] {
        switch self {
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
        case .m4a: ["-c:a", "aac", "-b:a", "\(bitrate)k", "-movflags", "+faststart"]
        case .wav: ["-c:a", "pcm_s16le"]
        case .aiff: ["-c:a", "pcm_s16be"]
        case .flac: ["-c:a", "flac"]
        case .ogg, .opus: ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"]
        }
    }

    /// Codec arguments that keep the quality of an existing file of this format.
    var highQualityArguments: [String] {
        switch self {
        case .mp3: ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: ["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]
        case .ogg, .opus: ["-c:a", "libopus", "-b:a", "192k"]
        default: codecArguments(bitrate: 0)
        }
    }

    /// The format matching a file extension, if FFmpeg can write it.
    static func matching(extension ext: String) -> AudioOutputFormat? {
        switch ext.lowercased() {
        case "mp3": .mp3
        case "m4a", "aac", "mp4", "m4b": .m4a
        case "wav", "wave": .wav
        case "aif", "aiff", "aifc": .aiff
        case "flac": .flac
        case "ogg", "oga": .ogg
        case "opus": .opus
        default: nil
        }
    }
}

enum AudioProbe {
    /// Sample rate of the first audio stream, or nil if unknown.
    static func sampleRate(of url: URL) async -> Int? {
        guard let ffprobe = Dependencies.locateFFprobe(),
              let result = try? await ProcessRunner.runChecked(ffprobe, arguments: [
                  "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate",
                  "-of", "default=nw=1:nk=1", url.path,
              ]) else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// For stream-copying an audio track: the container extension that can hold `codec` as-is.
    static func copyContainer(forCodec codec: String?) -> String {
        guard let codec else { return "mka" }
        switch codec {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "opus": return "opus"
        case "vorbis": return "ogg"
        case "flac": return "flac"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_u8": return "wav"
        case "pcm_s16be", "pcm_s24be", "pcm_s32be": return "aif"
        default: return "mka"
        }
    }
}

extension UTType {
    /// Video containers that can carry an audio track to process.
    static let audioToolVideoContainers: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "3gp", "wmv", "flv"]
}
