import SwiftUI

enum SpeechAITools {
    static let all: [Tool] = [
        Tool(id: "ai.chat-pdf", name: "Chat with PDF", category: .ai, symbol: "bubble.left.and.text.bubble.right",
             summary: "Ask questions about a PDF or document and get answers that cite their pages, on device.",
             keywords: ["ask", "question", "chat", "pdf ai", "assistant", "q&a", "apple intelligence", "document"],
             input: ToolInput(types: AIDocumentText.types, multiple: false)) { ChatPDFView(tool: $0) },
        Tool(id: "ai.pdf-to-audio", name: "PDF to Audio", category: .ai, symbol: "headphones",
             summary: "Read PDFs and documents aloud into audio files with the system voices.",
             keywords: ["text to speech", "tts", "read aloud", "audiobook", "narrate", "voice", "speak", "m4a", "mp3"],
             input: ToolInput(types: AIDocumentText.types),
             quickAction: QuickAction("Create Audio from", settings: PDFToAudioView.Settings.self)) { PDFToAudioView(tool: $0) },
    ]
}
