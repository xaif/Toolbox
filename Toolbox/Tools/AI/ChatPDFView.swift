import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// The document and conversation in Chat with PDF. Shared, so the chat survives navigating away.
@MainActor
@Observable
final class ChatPDFModel {
    static let shared = ChatPDFModel()

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var failed = false
    }

    private(set) var url: URL?
    private(set) var document: AIDocumentText?
    private(set) var pdf: PDFDocument?
    private(set) var index: ChatIndex?
    private(set) var messages: [Message] = []
    private(set) var loadStatus: String?
    private(set) var loadProgress = 0.0
    private(set) var loadError: String?
    private(set) var isAnswering = false
    /// The page the preview should show. A new id shows the same page again.
    private(set) var pageRequest: (page: Int, id: UUID)?
    /// The part shown beside the chat for documents without pages.
    var shownPart: Int?
    private var finished: Set<UUID> = []
    private var loadTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    /// Identifies the answer in progress, so a stopped one finishing late doesn't end a newer one.
    private var answerToken: UUID?

    var isReady: Bool { index != nil }

    /// Answered questions, oldest first.
    var turns: [ChatTurn] {
        zip(messages, messages.dropFirst()).compactMap { question, answer in
            guard question.role == .user, answer.role == .assistant, !answer.failed, !answer.text.isEmpty else { return nil }
            return ChatTurn(question: question.text, answer: answer.text)
        }
    }

    func load(_ newURL: URL?) {
        guard newURL != url else { return }
        loadTask?.cancel()
        clearChat()
        url = newURL
        document = nil; pdf = nil; index = nil; messages = []; loadError = nil; shownPart = nil; pageRequest = nil
        guard let newURL else { loadStatus = nil; return }
        loadStatus = "Reading \(newURL.lastPathComponent)…"
        loadProgress = 0
        loadTask = Task {
            do {
                let document = try await AIDocumentText.load(newURL) { fraction, status in
                    Task { @MainActor in
                        guard self.url == newURL, self.index == nil else { return }
                        self.loadProgress = fraction
                        if !status.isEmpty { self.loadStatus = status }
                    }
                }
                guard url == newURL else { return }
                loadStatus = "Indexing…"
                let index = await Task.detached(priority: .userInitiated) { ChatIndex(chunks: ChatIndex.chunks(document)) }.value
                guard url == newURL, !Task.isCancelled else { return }
                self.document = document
                self.pdf = document.isPaged ? PDFDocument(url: newURL) : nil
                self.index = index
            } catch {
                guard url == newURL else { return }
                if !(error is CancellationError) { loadError = error.localizedDescription }
            }
            if url == newURL { loadStatus = nil }
        }
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let document, let index, !isAnswering else { return }
        let history = turns
        messages.append(Message(role: .user, text: question))
        let answer = Message(role: .assistant, text: "")
        messages.append(answer)
        isAnswering = true
        let token = UUID()
        answerToken = token
        answerTask = Task {
            do {
                let result = try await ChatAnswerer.answer(question, document: document, index: index, history: history) { partial in
                    Task { @MainActor in self.update(answer.id, text: partial) }
                }
                update(answer.id, text: result.isEmpty ? "The model didn't answer. Try rephrasing the question." : result, final: true)
            } catch is CancellationError {
                let current = messages.first { $0.id == answer.id }?.text ?? ""
                update(answer.id, text: current.isEmpty ? "Stopped." : current, final: true)
            } catch {
                update(answer.id, text: error.localizedDescription, failed: true, final: true)
            }
            if answerToken == token { isAnswering = false }
        }
    }

    func stop() {
        answerTask?.cancel()
        answerTask = nil
    }

    func clearChat() {
        stop()
        answerToken = nil
        messages = []
        isAnswering = false
    }

    /// Shows a cited page in the preview, or the cited part for documents without pages.
    func show(page: Int) {
        guard let document, document.pages.contains(where: { $0.number == page }) else { return }
        if document.isPaged { pageRequest = (page, UUID()) } else { shownPart = page }
    }

    /// The conversation as Markdown, for copying and saving.
    var markdown: String {
        var text = "# Chat with “\(document?.name ?? url?.lastPathComponent ?? "Document")”\n\n"
        for message in messages where !message.text.isEmpty {
            text += message.role == .user ? "**Question:** \(message.text)\n\n" : "\(message.text)\n\n---\n\n"
        }
        return text
    }

    private func update(_ id: UUID, text: String, failed: Bool = false, final: Bool = false) {
        guard !finished.contains(id), let position = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[position].text = text
        messages[position].failed = failed
        if final { finished.insert(id) }
    }
}

struct ChatPDFView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var saver: JobRunner
    @State private var model = ChatPDFModel.shared
    @State private var availability = AISummarizer.availability
    @State private var question = ""
    @State private var dropTargeted = false
    @FocusState private var questionFocused: Bool

    static let starters = [
        "Summarize this document",
        "What are the key points?",
        "List the important dates, names and numbers",
        "What conclusions or next steps does it give?",
    ]

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _saver = State(initialValue: JobCenter.shared.runner(for: tool.id + ".save"))
    }

    private var canAsk: Bool { availability == .available && model.isReady && !model.isAnswering }

    var body: some View {
        ToolPage(tool: tool, scrolls: false) {
            availabilityNotice
            if runner.inputs.isEmpty {
                FileListInput(files: $runner.inputs, accepts: AIDocumentText.types, allowsMultiple: false,
                              title: "Document", noun: "a PDF or document")
                Text("Ask questions in your own words. Answers come from Apple's on-device model, cite the pages they're based on, and nothing leaves your Mac. Scanned pages are read with OCR.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                documentBar
                HSplitView {
                    chat
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    sidePanel
                }
                .frame(maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { AIText.conforms($0, to: AIDocumentText.types) }) else { return false }
                    runner.inputs = [url]
                    return true
                } isTargeted: { dropTargeted = $0 }
                .overlay {
                    if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
                }
            }
        } footer: {
            composer
        }
        .onChange(of: runner.inputs, initial: true) { model.load(runner.inputs.first) }
        .task {
            // The model can become ready while the tool is open.
            while !Task.isCancelled, availability != .available {
                try? await Task.sleep(for: .seconds(3))
                availability = AISummarizer.availability
            }
        }
    }

    // MARK: - Document

    private var documentBar: some View {
        HStack(spacing: 10) {
            if let url = model.url { FileThumbnail(url: url, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.url?.lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                if let status = model.loadStatus {
                    HStack(spacing: 6) {
                        ProgressView(value: model.loadProgress).frame(width: 120).controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if let document = model.document {
                    Text(description(of: document)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if saver.phase == .succeeded, !saver.outputs.isEmpty {
                Button("Show Saved Chat") { NSWorkspace.shared.activateFileViewerSelecting(saver.outputs) }
                    .buttonStyle(.link)
            }
            AICopyButton(text: model.messages.isEmpty ? "" : model.markdown, title: "Copy Chat")
            Button("Save as Markdown", action: save)
                .disabled(model.messages.isEmpty || model.isAnswering || saver.isRunning)
            Button("Clear Chat") { model.clearChat() }
                .disabled(model.messages.isEmpty)
            Button("Change…") { runner.inputs = [] }
        }
    }

    private func description(of document: AIDocumentText) -> String {
        let count = document.pages.count
        let words = document.pages.reduce(0) { $0 + AIText.wordCount($1.text) }
        let unit = document.isPaged ? (count == 1 ? "page" : "pages") : (count == 1 ? "part" : "parts")
        return "\(count) \(unit) · \(words.formatted()) words · read on this Mac"
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let pdf = model.pdf {
            ChatPDFPreview(document: pdf, request: model.pageRequest)
                .frame(minWidth: 260, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        } else if let part = model.shownPart, let page = model.document?.pages.first(where: { $0.number == part }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Part \(part)").font(.headline)
                    Spacer()
                    Button { model.shownPart = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
                }
                ScrollView {
                    Text(page.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty, model.isReady { starters }
                    ForEach(model.messages) { message in
                        ChatBubble(message: message, isAnswering: model.isAnswering && message.id == model.messages.last?.id) {
                            model.show(page: $0)
                        }
                        .id(message.id)
                    }
                }
                .padding(14)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .onChange(of: model.messages.last?.text) {
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking").font(.headline)
            ForEach(Self.starters, id: \.self) { starter in
                Button { send(starter) } label: {
                    Label(starter, systemImage: "text.bubble")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(model.isReady ? "Ask a question about the document…" : "Add a document to start chatting",
                      text: $question, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($questionFocused)
                .onSubmit { send(question) }
                .disabled(!model.isReady || availability != .available)
            if model.isAnswering {
                Button("Stop", role: .cancel) { model.stop() }
                    .controlSize(.large)
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button { send(question) } label: { Text("Ask").frame(minWidth: 60) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canAsk || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(minHeight: 32)
    }

    private func send(_ text: String) {
        guard canAsk, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.ask(text)
        question = ""
        questionFocused = true
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        switch availability {
        case .available:
            EmptyView()
        case .appleIntelligenceNotEnabled:
            AINotice(symbol: "apple.intelligence", title: "Apple Intelligence is off",
                     message: ChatAnswerer.message(for: availability)) {
                Button("Open System Settings") { AISystemSettings.openAppleIntelligence() }
            }
        case .modelNotReady:
            AINotice(symbol: "arrow.down.circle", title: "The model is getting ready",
                     message: ChatAnswerer.message(for: availability), tint: .blue)
        default:
            AINotice(symbol: "exclamationmark.triangle", title: "Chat with PDF isn't available",
                     message: ChatAnswerer.message(for: availability))
        }
    }

    private func save() {
        let text = model.markdown
        let source = model.url
        let base = source.map { $0.deletingPathExtension().lastPathComponent + " chat" } ?? "Chat"
        saver.start(title: tool.name, inputs: source.map { [$0] } ?? []) { context in
            try AIText.write(text, to: context.output(named: base, extension: "md", nextTo: source))
        }
    }
}

/// One question or answer. Page citations in answers are links that show the page.
private struct ChatBubble: View {
    let message: ChatPDFModel.Message
    let isAnswering: Bool
    let showPage: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty, isAnswering {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the document…").foregroundStyle(.secondary)
                    }
                } else if message.failed {
                    Label(message.text, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else {
                    Text(content)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let page = ChatCitations.page(for: url) else { return .systemAction }
                            showPage(page)
                            return .handled
                        })
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(message.role == .user ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contextMenu {
                Button("Copy") { AIText.copy(message.text) }
            }
            if message.role == .assistant { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var content: AttributedString {
        guard message.role == .assistant else { return AttributedString(message.text) }
        // Inline-only parsing keeps line breaks; show "## Heading" lines as bold text.
        let display = ChatCitations.linkedMarkdown(message.text)
            .replacingOccurrences(of: #"(?m)^#{1,6}\s+(.+)$"#, with: "**$1**", options: .regularExpression)
        return (try? AttributedString(markdown: display, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
}

/// The PDF beside the chat. Shows the page of the last citation clicked.
struct ChatPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let request: (page: Int, id: UUID)?

    final class Coordinator {
        var lastRequest: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        guard let request, request.id != context.coordinator.lastRequest else { return }
        context.coordinator.lastRequest = request.id
        if let page = document.page(at: request.page - 1) { view.go(to: page) }
    }
}
