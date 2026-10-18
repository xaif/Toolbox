import SwiftUI
import Speech
import PDFKit
import UniformTypeIdentifiers

// MARK: - Last-result previews

/// The most recent text a tool produced, shown under the tool after a run.
struct AIPreview: Equatable {
    var title: String
    var text: String
}

/// Keeps each AI tool's last preview alive while the user navigates around.
@MainActor
@Observable
final class AIPreviewStore {
    static let shared = AIPreviewStore()
    private(set) var previews: [String: AIPreview] = [:]

    func preview(for toolID: String) -> AIPreview? { previews[toolID] }

    func set(_ toolID: String, title: String, text: String) {
        previews[toolID] = AIPreview(title: title, text: text)
    }

    func clear(_ toolID: String) { previews[toolID] = nil }
}

/// Read-only, selectable text with a word count and a Copy button.
struct AITextPreview: View {
    let title: String
    let text: String
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat = 320

    var body: some View {
        ToolSection(title) {
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            HStack {
                Text(AIText.countDescription(text)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                AICopyButton(text: text)
            }
        }
    }
}

struct AICopyButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            AIText.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}

/// Multi-line editor with a placeholder, used for pasted input.
struct AITextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 160

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight, maxHeight: 360)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A banner for states like "model unavailable" or "permission needed".
struct AINotice<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .orange
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { actions }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}

extension AINotice where Actions == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color = .orange) {
        self.init(symbol: symbol, title: title, message: message, tint: tint, actions: { EmptyView() })
    }
}

// MARK: - Text helpers

enum AIText {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    static func countDescription(_ text: String) -> String {
        let words = wordCount(text)
        return "\(words.formatted()) word\(words == 1 ? "" : "s") · \(text.count.formatted()) characters"
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// File types whose text we can read for Summarize/Translate.
    static let documentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .rtf, .rtfd, .html, .pdf, .xml, .json]
        for ext in ["md", "markdown", "docx", "doc", "odt", "srt", "vtt", "webarchive"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    /// Whether a file's type conforms to any of `types`. Safe to call from any context.
    static func conforms(_ url: URL, to types: [UTType]) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    static func isSubtitleFile(_ url: URL) -> Bool {
        ["srt", "vtt"].contains(url.pathExtension.lowercased())
    }

    static func isMedia(_ url: URL) -> Bool {
        AIText.conforms(url, to: [.audio, .movie, .video, .audiovisualContent])
    }

    /// Extracts readable text from a document. Audio and video are transcribed on device.
    static func extract(from url: URL, transcribeMediaIn locale: Locale? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if isMedia(url) {
            var resolved = locale
            if resolved == nil { resolved = await Transcriber.defaultLocale() }
            guard let resolved else {
                throw ToolError.unsupported("Your language isn't supported for transcription.")
            }
            let transcript = try await Transcriber.transcribe(url, locale: resolved, progress: progress)
            return AITranscriptFormat.paragraphs(transcript)
        }
        if ext == "pdf" || AIText.conforms(url, to: [.pdf]) {
            guard let document = PDFDocument(url: url) else { throw ToolError.unreadableInput(url) }
            if document.isLocked { throw ToolError.failed("“\(url.lastPathComponent)” is password protected.") }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    pages.append(text)
                }
            }
            let text = pages.joined(separator: "\n\n")
            guard !text.isEmpty else {
                throw ToolError.failed("“\(url.lastPathComponent)” has no text layer. Run Extract Text on it first.")
            }
            return text
        }
        if isSubtitleFile(url) {
            return try Subtitles.load(from: url).map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        }
        let attributedTypes = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"]
        if attributedTypes.contains(ext) || AIText.conforms(url, to: [.rtf, .rtfd, .html]) {
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return attributed.string
        }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw ToolError.unreadableInput(url)
    }
}

/// Plain-text layouts for transcripts.
enum AITranscriptFormat {
    /// Phrases grouped into paragraphs at pauses longer than `pause` seconds.
    static func paragraphs(_ transcript: Transcript, timestamps: Bool = false, pause: Double = 1.8) -> String {
        var paragraphs: [(start: Double, text: String)] = []
        var current: [String] = []
        var currentStart = 0.0
        var lastEnd = -Double.infinity
        for phrase in transcript.phrases {
            if !current.isEmpty, phrase.start - lastEnd > pause || current.joined(separator: " ").count > 600 {
                paragraphs.append((currentStart, current.joined(separator: " ")))
                current.removeAll()
            }
            if current.isEmpty { currentStart = phrase.start }
            current.append(phrase.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lastEnd = phrase.end
        }
        if !current.isEmpty { paragraphs.append((currentStart, current.joined(separator: " "))) }
        return paragraphs.map { paragraph in
            timestamps ? "[\(Subtitles.timestamp(paragraph.start, separator: ".").prefix(8))] \(paragraph.text)" : paragraph.text
        }.joined(separator: "\n\n") + "\n"
    }
}

// MARK: - Speech languages

/// Loads the on-device speech languages once and shares them between Transcribe, Dictation and Summarize.
@MainActor
@Observable
final class AISpeechLocales {
    static let shared = AISpeechLocales()
    private(set) var locales: [Locale] = []
    private(set) var defaultIdentifier: String?
    private(set) var isLoaded = false

    func load() async {
        guard !isLoaded else { return }
        locales = await Transcriber.supportedLocales()
        defaultIdentifier = await Transcriber.defaultLocale()?.identifier
        isLoaded = true
    }

    /// Resolves a stored identifier to a supported locale identifier, falling back to the default.
    func resolve(_ identifier: String) -> String {
        if locales.contains(where: { $0.identifier == identifier }) { return identifier }
        return defaultIdentifier ?? locales.first?.identifier ?? identifier
    }
}

/// Language picker for on-device speech recognition.
struct AISpeechLanguagePicker: View {
    @Binding var identifier: String
    @State private var store = AISpeechLocales.shared

    var body: some View {
        Group {
            if store.isLoaded {
                if store.locales.isEmpty {
                    LabeledContent("Language") {
                        Text("No on-device speech languages are available on this Mac.").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Language", selection: $identifier) {
                        ForEach(store.locales, id: \.identifier) { locale in
                            Text(Transcriber.displayName(for: locale)).tag(locale.identifier)
                        }
                    }
                }
            } else {
                LabeledContent("Language") { ProgressView().controlSize(.small) }
            }
        }
        .task {
            await store.load()
            let resolved = store.resolve(identifier)
            if resolved != identifier { identifier = resolved }
        }
    }
}

/// Shows whether the speech model for a language is installed, and downloads it on request.
struct AISpeechModelStatus: View {
    let identifier: String

    @State private var status: AssetInventory.Status?
    @State private var downloadProgress: Double?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            if let downloadProgress {
                ProgressView(value: downloadProgress).frame(width: 140)
                Text("Downloading language model… \(Int(downloadProgress * 100))%").foregroundStyle(.secondary)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary)
            } else {
                switch status {
                case .installed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Language model installed. Works offline.").foregroundStyle(.secondary)
                case .supported:
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                    Text("Needs a one-time download of the language model.").foregroundStyle(.secondary)
                    Button("Download Now", action: download)
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("The language model is downloading…").foregroundStyle(.secondary)
                case .unsupported:
                    Image(systemName: "xmark.circle").foregroundStyle(.orange)
                    Text("This language isn't supported on this Mac.").foregroundStyle(.secondary)
                case nil:
                    ProgressView().controlSize(.small)
                @unknown default:
                    EmptyView()
                }
            }
        }
        .font(.callout)
        .task(id: identifier) { await refresh() }
    }

    private func refresh() async {
        guard !identifier.isEmpty else { return }
        error = nil
        let module = SpeechTranscriber(locale: Locale(identifier: identifier), preset: .transcription)
        status = await AssetInventory.status(forModules: [module])
        if status == .downloading {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { await refresh() }
        }
    }

    private func download() {
        let locale = Locale(identifier: identifier)
        downloadProgress = 0
        Task {
            do {
                try await Transcriber.prepareModel(for: locale) { fraction in
                    Task { @MainActor in if downloadProgress != nil { downloadProgress = fraction } }
                }
                downloadProgress = nil
                await refresh()
            } catch {
                downloadProgress = nil
                self.error = error.localizedDescription
            }
        }
    }
}

enum AISystemSettings {
    static func openMicrophonePrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAppleIntelligence() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.siri",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
