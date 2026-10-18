import SwiftUI

enum AudioTools {
    static let all: [Tool] = [
        Tool(id: "audio.record", name: "Record Audio", category: .audio, symbol: "mic",
             summary: "Record your voice or any microphone.",
             keywords: ["microphone", "voice memo", "podcast", "record"]) { PlaceholderToolView(tool: $0) },
        Tool(id: "audio.trim", name: "Trim Audio", shortName: "Trim", category: .audio, symbol: "scissors",
             summary: "Cut the start and end off a recording.",
             keywords: ["cut", "shorten", "clip"], requirements: [.ffmpeg]) { PlaceholderToolView(tool: $0) },
        Tool(id: "audio.cleanup", name: "Clean Up Audio", shortName: "Clean Up", category: .audio, symbol: "wand.and.stars",
             summary: "Remove background noise and even out volume.",
             keywords: ["noise", "denoise", "hiss", "normalize", "enhance", "ai"], requirements: [.ffmpeg]) { PlaceholderToolView(tool: $0) },
        Tool(id: "audio.extract", name: "Extract Audio", category: .audio, symbol: "waveform.badge.plus",
             summary: "Save the soundtrack of a video as an audio file.",
             keywords: ["rip", "mp3 from video", "soundtrack"], requirements: [.ffmpeg]) { PlaceholderToolView(tool: $0) },
        Tool(id: "audio.convert", name: "Convert Audio", shortName: "Convert", category: .audio, symbol: "arrow.triangle.2.circlepath",
             summary: "Change format to MP3, M4A, WAV, FLAC and more.",
             keywords: ["mp3", "m4a", "aac", "wav", "flac", "ogg", "format"], requirements: [.ffmpeg]) { PlaceholderToolView(tool: $0) },
    ]
}
