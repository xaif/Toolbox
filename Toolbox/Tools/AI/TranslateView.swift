import SwiftUI
import Translation
import NaturalLanguage
import UniformTypeIdentifiers

/// Offline translation with Apple's Translation framework.
///
/// Translating uses `TranslationSession(installedSource:target:)`, which works anywhere (including
/// background jobs) once a language pair is installed. Downloading a pair needs the system UI, so the
/// view triggers it through SwiftUI's `.translationTask` and `prepareTranslation()`.
enum AITranslator {
    static func supportedLanguages() async -> [Locale.Language] {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return languages
            .filter { seen.insert($0.maximalIdentifier).inserted }
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    static func displayName(for language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    static func shortCode(for language: Locale.Language) -> String {
        language.minimalIdentifier
    }

    /// Dominant language of a text, or nil if unclear.
    static func detectLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    static func isSameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && (a.script == nil || b.script == nil || a.script == b.script)
    }

    static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// Translates lines, keeping blank lines and lines without letters untouched.
    static func translate(lines: [String], from source: Locale.Language, to target: Locale.Language,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
        var output = lines
        let indices = lines.indices.filter { index in
            lines[index].unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        guard !indices.isEmpty else { return output }
        let batchSize = 40
        var done = 0
        for start in stride(from: 0, to: indices.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(indices[start..<min(start + batchSize, indices.count)])
            let requests = batch.map { TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0)) }
            let responses: [TranslationSession.Response]
            do {
                responses = try await session.translations(from: requests)
            } catch {
                throw friendly(error, source: source, target: target)
            }
            for (offset, response) in responses.enumerated() {
                let index = response.clientIdentifier.flatMap(Int.init) ?? batch[offset]
                output[index] = response.targetText
            }
            done += batch.count
            progress?(Double(done) / Double(indices.count))
        }
        return output
    }

    static func translate(text: String, from source: Locale.Language, to target: Locale.Language,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return try await translate(lines: lines, from: source, to: target, progress: progress).joined(separator: "\n")
    }

    /// Resolves the source language (detecting it when nil) and checks the pair is installed.
    static func resolveSource(_ source: Locale.Language?, for text: String, target: Locale.Language) async throws -> Locale.Language {
        guard let resolved = source ?? detectLanguage(of: text) else {
            throw ToolError.failed("Couldn't detect the language. Choose it in the From menu.")
        }
        if isSameLanguage(resolved, target) {
            throw ToolError.failed("The text is already in \(displayName(for: target)).")
        }
        switch await status(from: resolved, to: target) {
        case .installed:
            return resolved
        case .supported:
            throw ToolError.failed("\(displayName(for: resolved)) → \(displayName(for: target)) needs a one-time download. Choose \(displayName(for: resolved)) in the From menu and click Download.")
        case .unsupported:
            throw ToolError.unsupported("Translating \(displayName(for: resolved)) to \(displayName(for: target)) isn't supported.")
        @unknown default:
            throw ToolError.unsupported("This language pair isn't available.")
        }
    }

    /// Translates a document and writes the result next to the other outputs.
    static func translate(file url: URL, from source: Locale.Language?, to target: Locale.Language,
                          context: JobContext, progress: @escaping @Sendable (Double) -> Void) async throws {
        let code = shortCode(for: target)
        if AIText.isSubtitleFile(url) {
            let cues = try Subtitles.load(from: url)
            let lines = cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            let resolved = try await resolveSource(source, for: lines.joined(separator: " "), target: target)
            let translated = try await translate(lines: lines, from: resolved, to: target, progress: progress)
            let output = zip(cues, translated).map { cue, text in
                SubtitleCue(start: cue.start, end: cue.end, text: Subtitles.wrap(text))
            }
            let format: SubtitleFormat = url.pathExtension.lowercased() == "vtt" ? .vtt : .srt
            try AIText.write(Subtitles.serialize(output, as: format),
                             to: context.output(for: url, suffix: code, extension: format.fileExtension))
            return
        }
        let text = try await AIText.extract(from: url)
        let resolved = try await resolveSource(source, for: text, target: target)
        let translated = try await translate(text: text, from: resolved, to: target, progress: progress)
        let keepsExtension = ["txt", "md", "markdown", "text"].contains(url.pathExtension.lowercased())
        try AIText.write(translated, to: context.output(for: url, suffix: code, extension: keepsExtension ? url.pathExtension : "txt"))
    }

    static func friendly(_ error: Error, source: Locale.Language, target: Locale.Language) -> Error {
        if TranslationError.notInstalled ~= error {
            return ToolError.failed("\(displayName(for: source)) → \(displayName(for: target)) isn't downloaded yet. Click Download first.")
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            return ToolError.unsupported("Translating \(displayName(for: source)) to \(displayName(for: target)) isn't supported.")
        }
        return error
    }
}

struct TranslateView: View {
    let tool: Tool

    enum Mode: String, CaseIterable, Identifiable {
        case text, files
        var id: Self { self }
        var label: String { self == .text ? "Text" : "Files" }
    }

    private enum PendingAction { case text, files }

    @State private var textRunner: JobRunner
    @State private var fileRunner: JobRunner
    @State private var previews = AIPreviewStore.shared
    @State private var languages: [Locale.Language] = []
    @State private var pairStatus: LanguageAvailability.Status?
    @State private var input = ""
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var pending: PendingAction?
    @AppStorage("ai.translate.mode") private var mode = Mode.text.rawValue
    @AppStorage("ai.translate.source") private var sourceID = ""
    @AppStorage("ai.translate.target") private var targetID = ""

    init(tool: Tool) {
        self.tool = tool
        _textRunner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _fileRunner = State(initialValue: JobCenter.shared.runner(for: tool.id + ".files"))
    }

    private var currentMode: Mode { Mode(rawValue: mode) ?? .text }
    private var runner: JobRunner { currentMode == .text ? textRunner : fileRunner }
    private var source: Locale.Language? { sourceID.isEmpty ? nil : Locale.Language(identifier: sourceID) }
    private var target: Locale.Language? { targetID.isEmpty ? nil : Locale.Language(identifier: targetID) }
    private var output: String { previews.preview(for: tool.id)?.text ?? "" }
    private var busy: Bool { textRunner.isRunning || fileRunner.isRunning || downloading }

    private var canRun: Bool {
        guard target != nil, pairStatus != .unsupported, !busy else { return false }
        return currentMode == .text ? !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !fileRunner.inputs.isEmpty
    }

    var body: some View {
        ToolPage(tool: tool, runner: currentMode == .files ? fileRunner : nil) {
            ToolSection("Languages", footnote: "Translation runs on your Mac. Once a language is downloaded it works offline.") {
                languagePickers
                statusLine
            }
            .disabled(busy)

            Picker("Translate", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(busy)

            if currentMode == .text {
                ToolSection("Text") {
                    AITextEditor(text: $input, placeholder: "Type or paste text to translate…", minHeight: 150)
                    HStack {
                        Text(AIText.countDescription(input)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { input = ""; previews.clear(tool.id) }.disabled(input.isEmpty)
                    }
                }
                .disabled(textRunner.isRunning)
                if !output.isEmpty {
                    AITextPreview(title: previews.preview(for: tool.id)?.title ?? "Translation", text: output)
                }
            } else {
                FileListInput(files: $fileRunner.inputs, accepts: AIText.documentTypes,
                              noun: "documents or subtitles")
                    .disabled(fileRunner.isRunning)
                Text("Subtitles (.srt, .vtt) keep their timings. Text and Markdown keep their format; Word, RTF, HTML and PDF are saved as text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: currentMode == .text ? "Translate" : "Translate Files",
                   canRun: canRun, hint: hint, action: start)
        }
        .translationTask(downloadConfiguration) { session in
            await performDownload(session)
        }
        .task { await loadLanguages() }
        .task(id: "\(sourceID)>\(targetID)") { await refreshStatus() }
        .onChange(of: fileRunner.inputs) { if !fileRunner.isRunning { fileRunner.reset() } }
    }

    private var languagePickers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Picker("From", selection: $sourceID) {
                Text("Detect automatically").tag("")
                Divider()
                ForEach(languages, id: \.maximalIdentifier) { language in
                    Text(AITranslator.displayName(for: language)).tag(language.maximalIdentifier)
                }
            }
            Button {
                guard !sourceID.isEmpty else { return }
                (sourceID, targetID) = (targetID, sourceID)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help("Swap languages")
            .disabled(sourceID.isEmpty)
            Picker("To", selection: $targetID) {
                ForEach(languages, id: \.maximalIdentifier) { language in
                    Text(AITranslator.displayName(for: language)).tag(language.maximalIdentifier)
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            if languages.isEmpty {
                ProgressView().controlSize(.small)
                Text("Loading languages…").foregroundStyle(.secondary)
            } else if downloading {
                ProgressView().controlSize(.small)
                Text("Downloading languages…").foregroundStyle(.secondary)
            } else if let downloadError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(downloadError).foregroundStyle(.secondary)
            } else if source == nil {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                Text("The language is detected when you translate.").foregroundStyle(.secondary)
            } else {
                switch pairStatus {
                case .installed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready. Works offline.").foregroundStyle(.secondary)
                case .supported:
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                    Text("These languages need a one-time download.").foregroundStyle(.secondary)
                    Button("Download") { requestDownload(source: source, then: nil) }
                case .unsupported:
                    Image(systemName: "xmark.circle").foregroundStyle(.orange)
                    Text("This language pair isn't supported.").foregroundStyle(.secondary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
        .font(.callout)
    }

    private var hint: String {
        if target == nil { return "Choose a language to translate to." }
        if pairStatus == .unsupported { return "This language pair isn't supported." }
        return currentMode == .text ? "Type or paste text to translate." : "Add documents or subtitles to get started."
    }

    // MARK: Actions

    private func loadLanguages() async {
        guard languages.isEmpty else { return }
        languages = await AITranslator.supportedLanguages()
        if target == nil || !languages.contains(where: { $0.maximalIdentifier == targetID }) {
            let mine = Locale.current.language
            let match = languages.first { $0.languageCode == mine.languageCode && $0.region == mine.region }
                ?? languages.first { $0.languageCode == mine.languageCode }
            let fallback = languages.first { $0.languageCode == (mine.languageCode == .english ? .spanish : .english) }
            targetID = (match ?? fallback ?? languages.first)?.maximalIdentifier ?? ""
        }
        if !sourceID.isEmpty, !languages.contains(where: { $0.maximalIdentifier == sourceID }) { sourceID = "" }
    }

    private func refreshStatus() async {
        downloadError = nil
        guard let target else { pairStatus = nil; return }
        guard let source else { pairStatus = nil; return }
        if AITranslator.isSameLanguage(source, target) { pairStatus = .unsupported; return }
        pairStatus = await AITranslator.status(from: source, to: target)
    }

    private func requestDownload(source: Locale.Language?, then action: PendingAction?) {
        guard let target else { return }
        pending = action
        downloadError = nil
        downloading = true
        let configuration = TranslationSession.Configuration(source: source, target: target)
        if downloadConfiguration == configuration {
            downloadConfiguration?.invalidate()
        } else {
            downloadConfiguration = configuration
        }
    }

    private func performDownload(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            downloading = false
            await refreshStatus()
            if let action = pending {
                pending = nil
                run(action)
            }
        } catch {
            downloading = false
            pending = nil
            downloadError = error.localizedDescription
        }
    }

    private func start() {
        let action: PendingAction = currentMode == .text ? .text : .files
        guard let target else { return }
        Task {
            // An explicit source pair that still needs downloading: download first, then run.
            if let source, await AITranslator.status(from: source, to: target) == .supported {
                requestDownload(source: source, then: action)
                return
            }
            // Auto-detected text: detect now so a missing pair can be downloaded before translating.
            if action == .text, source == nil, let detected = AITranslator.detectLanguage(of: input),
               !AITranslator.isSameLanguage(detected, target),
               await AITranslator.status(from: detected, to: target) == .supported {
                requestDownload(source: detected, then: action)
                return
            }
            run(action)
        }
    }

    private func run(_ action: PendingAction) {
        guard let target else { return }
        let source = source
        let toolID = tool.id
        switch action {
        case .text:
            let text = input
            textRunner.start(title: tool.name, publishesFiles: false) { context in
                context.setStatus("Translating…")
                let resolved = try await AITranslator.resolveSource(source, for: text, target: target)
                let translated = try await AITranslator.translate(text: text, from: resolved, to: target) { fraction in
                    context.setProgress(fraction)
                }
                let title = "\(AITranslator.displayName(for: resolved)) → \(AITranslator.displayName(for: target))"
                await MainActor.run { AIPreviewStore.shared.set(toolID, title: title, text: translated) }
            }
        case .files:
            let inputs = fileRunner.inputs
            fileRunner.start(title: tool.name) { context in
                try await context.forEach(inputs, verb: "Translating") { input, progress in
                    try await AITranslator.translate(file: input, from: source, to: target, context: context, progress: progress)
                }
            }
        }
    }
}
