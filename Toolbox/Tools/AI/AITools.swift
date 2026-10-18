import SwiftUI

enum AITools {
    static let all: [Tool] = [
        Tool(id: "ai.transcribe", name: "Transcribe", category: .ai, symbol: "text.bubble",
             summary: "Turn audio and video into text and subtitles, on device.",
             keywords: ["speech to text", "subtitles", "srt", "vtt", "captions", "transcript"]) { TranscribeView(tool: $0) },
        Tool(id: "ai.dictation", name: "Dictation", category: .ai, symbol: "mic.badge.plus",
             summary: "Speak and watch your words appear live.",
             keywords: ["voice typing", "speech", "live transcription", "microphone"]) { DictationView(tool: $0) },
        Tool(id: "ai.extract-text", name: "Extract Text", category: .ai, symbol: "text.viewfinder",
             summary: "Read text from images, screenshots and scanned PDFs (OCR).",
             keywords: ["ocr", "scan", "recognize", "copy text", "screenshot"]) { ExtractTextView(tool: $0) },
        Tool(id: "ai.summarize", name: "Summarize", category: .ai, symbol: "text.append",
             summary: "Get the key points of a document, transcript or text.",
             keywords: ["tldr", "summary", "key points", "apple intelligence"]) { SummarizeView(tool: $0) },
        Tool(id: "ai.translate", name: "Translate", category: .ai, symbol: "translate",
             summary: "Translate text and documents between languages, offline.",
             keywords: ["language", "translation", "srt", "subtitles"]) { TranslateView(tool: $0) },
    ]
}
