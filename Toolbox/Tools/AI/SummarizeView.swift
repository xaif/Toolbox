import SwiftUI
import FoundationModels
import UniformTypeIdentifiers

/// Summaries with Apple's on-device foundation model. Long input is summarized in parts first
/// (map), then the notes are summarized again (reduce) until they fit the context window.
enum AISummarizer {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case keyPoints, short, detailed
        var id: Self { self }

        var label: String {
            switch self {
            case .keyPoints: "Key points"
            case .short: "Short paragraph"
            case .detailed: "Detailed"
            }
        }

        var instructions: String {
            let base = "You summarize documents faithfully. Never add facts that aren't in the text, and never comment on what the text doesn't mention."
            switch self {
            case .keyPoints:
                return base + " Respond with a bulleted list of the 3 to 7 most important points, one short sentence each."
            case .short:
                return base + " Respond with one short paragraph of 2 to 4 sentences."
            case .detailed:
                return base + " Respond with a one-sentence overview, then a few sections. Give each section a short Markdown heading (##) followed by bullet points."
            }
        }
    }

    enum Availability: Equatable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case other(String)
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable(let reason): return .other(String(describing: reason))
        }
    }

    /// Characters per chunk. The context window is shared by instructions, input and output,
    /// so input gets roughly 40% of it at ~4 characters per token.
    static var chunkCharacters: Int {
        max(1500, Int(Double(SystemLanguageModel.default.contextSize) * 1.6))
    }

    static func summarize(
        _ text: String,
        style: Style,
        onPartial: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ToolError.failed("There's no text to summarize.") }
        guard availability == .available else { throw ToolError.unsupported(message(for: availability)) }

        var material = cleaned
        var round = 0
        // Character limits are an estimate; languages with fewer characters per token can still
        // overflow, in which case we halve the limit and condense further.
        var limit = chunkCharacters
        while true {
            while material.count > limit {
                round += 1
                let chunks = split(material, limit: limit)
                var notes: [String] = []
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    progress(0.85 * Double(index) / Double(chunks.count),
                             "Reading part \(index + 1) of \(chunks.count)\(round > 1 ? " (pass \(round))" : "")…")
                    notes.append(try await condense(chunk))
                }
                material = notes.joined(separator: "\n")
            }

            progress(0.9, "Writing summary…")
            let session = LanguageModelSession(instructions: style.instructions)
            let prompt = round > 0
                ? "Summarize the whole document. These notes were taken from its consecutive parts:\n\n\(material)"
                : "Summarize this text:\n\n\(material)"
            var final = ""
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    final = tidy(snapshot.content)
                    onPartial(final)
                }
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, limit > 1000 {
                    limit /= 2
                    continue
                }
                throw friendly(error)
            }
            progress(1, "Done")
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Normalizes list markers the model sometimes doubles up ("- - ", "* ", "• ").
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^([ \t]*)(?:[-*•][ \t]+)+"#, with: "$1- ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
    }

    /// Summarizes one part of a long document into compact notes. Splits further if it doesn't fit.
    private static func condense(_ chunk: String) async throws -> String {
        let session = LanguageModelSession(instructions: "You take compact notes on part of a longer document. List its key facts, names, numbers, decisions and conclusions as short bullet points. Never add facts that aren't in the text.")
        do {
            return tidy(try await session.respond(to: "Take notes on this part:\n\n\(chunk)").content)
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error, chunk.count > 400 {
                let halves = split(chunk, limit: chunk.count / 2 + 1)
                var parts: [String] = []
                for half in halves { parts.append(try await condense(half)) }
                return parts.joined(separator: "\n")
            }
            throw friendly(error)
        }
    }

    /// Splits at paragraph, then sentence, then word boundaries so each piece is ≤ `limit` characters.
    static func split(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        func push(_ unit: String, separator: String) {
            if current.isEmpty { current = unit }
            else if current.count + separator.count + unit.count <= limit { current += separator + unit }
            else { pieces.append(current); current = unit }
        }
        for paragraph in text.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            if paragraph.count <= limit {
                push(paragraph, separator: "\n")
                continue
            }
            var sentences: [String] = []
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
            }
            for sentence in sentences {
                if sentence.count <= limit {
                    push(sentence, separator: " ")
                } else {
                    for word in sentence.split(separator: " ") { push(String(word.prefix(limit)), separator: " ") }
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func message(for availability: Availability) -> String {
        switch availability {
        case .available: ""
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence, which Summarize uses."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use Summarize."
        case .modelNotReady: "Apple Intelligence is still getting ready (the model may be downloading). Try again in a little while."
        case .other(let reason): "The on-device model isn't available (\(reason))."
        }
    }

    static func friendly(_ error: Error) -> Error {
        guard let error = error as? LanguageModelSession.GenerationError else { return error }
        switch error {
        case .exceededContextWindowSize: return ToolError.failed("The text is too long for the on-device model.")
        case .guardrailViolation: return ToolError.failed("The on-device model declined to summarize this text.")
        case .unsupportedLanguageOrLocale: return ToolError.failed("The on-device model doesn't support this language yet.")
        case .assetsUnavailable: return ToolError.failed("The on-device model isn't ready yet. Try again shortly.")
        default: return error
        }
    }
}

struct SummarizeView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var saver: JobRunner
    @State private var input = ""
    @State private var sourceURL: URL?
    @State private var loadingFile: String?
    @State private var loadError: String?
    @State private var previews = AIPreviewStore.shared
    @State private var availability = AISummarizer.availability
    @State private var dropTargeted = false
    @AppStorage("ai.summarize.style") private var style = AISummarizer.Style.keyPoints.rawValue

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _saver = State(initialValue: JobCenter.shared.runner(for: tool.id + ".save"))
    }

    private var selectedStyle: AISummarizer.Style { AISummarizer.Style(rawValue: style) ?? .keyPoints }
    private var hasInput: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var summary: String { previews.preview(for: tool.id)?.text ?? "" }

    var body: some View {
        ToolPage(tool: tool, runner: saver) {
            availabilityNotice

            ToolSection("Text", footnote: "Paste text, or drop a document, PDF, or audio/video file (it's transcribed first).") {
                AITextEditor(text: $input, placeholder: "Paste or type the text you want summarized…", minHeight: 180)
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                HStack(spacing: 8) {
                    Button("Open File…", action: chooseFile)
                    if let loadingFile {
                        ProgressView().controlSize(.small)
                        Text("Reading \(loadingFile)…").foregroundStyle(.secondary).lineLimit(1)
                    } else if let loadError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(loadError).foregroundStyle(.secondary).lineLimit(2)
                    } else if let sourceURL {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(sourceURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(AIText.countDescription(input)).font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { input = ""; sourceURL = nil; loadError = nil }
                        .disabled(input.isEmpty)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                load(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .disabled(runner.isRunning)

            ToolSection("Style") {
                Picker("Style", selection: $style) {
                    ForEach(AISummarizer.Style.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .disabled(runner.isRunning)

            if !summary.isEmpty {
                ToolSection("Summary") {
                    ScrollView {
                        Text(markdown(summary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 380)
                    HStack {
                        Text(AIText.countDescription(summary)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        AICopyButton(text: summary)
                        Button("Save as Markdown") { save() }
                            .disabled(runner.isRunning || saver.isRunning)
                    }
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Summarize",
                   canRun: hasInput && availability == .available && loadingFile == nil,
                   hint: availability == .available ? "Paste text or open a file to get started." : AISummarizer.message(for: availability),
                   action: start)
        }
        .task {
            // The model can become ready while the tool is open.
            while !Task.isCancelled, availability != .available {
                try? await Task.sleep(for: .seconds(3))
                availability = AISummarizer.availability
            }
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        switch availability {
        case .available:
            EmptyView()
        case .appleIntelligenceNotEnabled:
            AINotice(symbol: "apple.intelligence", title: "Apple Intelligence is off",
                     message: AISummarizer.message(for: availability)) {
                Button("Open System Settings") { AISystemSettings.openAppleIntelligence() }
            }
        case .modelNotReady:
            AINotice(symbol: "arrow.down.circle", title: "The model is getting ready",
                     message: AISummarizer.message(for: availability), tint: .blue)
        default:
            AINotice(symbol: "exclamationmark.triangle", title: "Summarize isn't available",
                     message: AISummarizer.message(for: availability))
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        // Inline-only parsing keeps line breaks; show "## Heading" lines as bold text.
        let display = text.replacingOccurrences(of: #"(?m)^#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)
        return (try? AttributedString(markdown: display, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AIText.documentTypes + [.audio, .movie, .video]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        loadingFile = url.lastPathComponent
        loadError = nil
        Task {
            do {
                let text = try await AIText.extract(from: url)
                input = text.trimmingCharacters(in: .whitespacesAndNewlines)
                sourceURL = url
            } catch {
                loadError = error.localizedDescription
            }
            loadingFile = nil
        }
    }

    private func start() {
        let text = input
        let style = selectedStyle
        let toolID = tool.id
        previews.clear(toolID)
        saver.reset()
        runner.start(title: tool.name, publishesFiles: false) { context in
            let result = try await AISummarizer.summarize(text, style: style, onPartial: { partial in
                Task { @MainActor in AIPreviewStore.shared.set(toolID, title: "Summary", text: partial) }
            }, progress: { fraction, status in
                context.setProgress(fraction)
                context.setStatus(status)
            })
            await MainActor.run { AIPreviewStore.shared.set(toolID, title: "Summary", text: result) }
        }
    }

    private func save() {
        let text = summary + "\n"
        let source = sourceURL
        let base = source.map { $0.deletingPathExtension().lastPathComponent + " summary" } ?? "Summary"
        saver.start(title: tool.name) { context in
            try AIText.write(text, to: context.output(named: base, extension: "md", nextTo: source))
        }
    }
}
