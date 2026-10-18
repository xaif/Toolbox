import SwiftUI
import UniformTypeIdentifiers

/// Batch speech-to-text for audio and video files, with TXT, SRT and VTT outputs.
struct TranscribeView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var previews = AIPreviewStore.shared
    @AppStorage("ai.transcribe.locale") private var localeID = ""
    @AppStorage("ai.transcribe.txt") private var writeText = true
    @AppStorage("ai.transcribe.srt") private var writeSRT = true
    @AppStorage("ai.transcribe.vtt") private var writeVTT = false
    @AppStorage("ai.transcribe.timestamps") private var textTimestamps = false

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var formats: [SubtitleFormat] {
        var formats: [SubtitleFormat] = []
        if writeText { formats.append(.txt) }
        if writeSRT { formats.append(.srt) }
        if writeVTT { formats.append(.vtt) }
        return formats
    }

    private var canRun: Bool { !runner.inputs.isEmpty && !formats.isEmpty && !localeID.isEmpty && Transcriber.isAvailable }

    private var hint: String {
        if !Transcriber.isAvailable { return "On-device transcription isn't available on this Mac." }
        if runner.inputs.isEmpty { return "Add audio or video files to get started." }
        if formats.isEmpty { return "Choose at least one output format." }
        return "Choose a language."
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            if !Transcriber.isAvailable {
                AINotice(symbol: "waveform.slash", title: "Transcription isn't available",
                         message: "This Mac doesn't support Apple's on-device speech recognition.")
            }
            FileListInput(files: $runner.inputs, accepts: UTType.mediaInputs, noun: "audio or video files")
                .disabled(runner.isRunning)

            ToolSection("Options", footnote: "Speech is recognized on your Mac. Audio is never uploaded.") {
                AISpeechLanguagePicker(identifier: $localeID)
                if !localeID.isEmpty {
                    AISpeechModelStatus(identifier: localeID)
                }
                Divider()
                LabeledContent("Save as") {
                    HStack(spacing: 16) {
                        Toggle("Text (.txt)", isOn: $writeText)
                        Toggle("Subtitles (.srt)", isOn: $writeSRT)
                        Toggle("WebVTT (.vtt)", isOn: $writeVTT)
                    }
                    .toggleStyle(.checkbox)
                }
                if writeText {
                    Toggle("Add timestamps to the text file", isOn: $textTimestamps)
                }
            }
            .disabled(runner.isRunning)

            if let preview = previews.preview(for: tool.id) {
                AITextPreview(title: "Transcript · \(preview.title)", text: preview.text)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Transcribe", canRun: canRun, hint: hint, action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func start() {
        let inputs = runner.inputs
        let locale = Locale(identifier: localeID)
        let formats = formats
        let timestamps = textTimestamps
        let toolID = tool.id
        runner.start(title: tool.name) { context in
            try await context.forEach(inputs, verb: "Transcribing") { input, progress in
                let transcript = try await Transcriber.transcribe(input, locale: locale, progress: progress)
                guard !transcript.phrases.isEmpty else { throw ToolError.failed("No speech was detected.") }
                for format in formats {
                    let url = context.output(for: input, extension: format.fileExtension)
                    let content = format == .txt
                        ? AITranscriptFormat.paragraphs(transcript, timestamps: timestamps)
                        : Subtitles.serialize(transcript.cues, as: format)
                    try AIText.write(content, to: url)
                }
                let text = AITranscriptFormat.paragraphs(transcript)
                await MainActor.run {
                    AIPreviewStore.shared.set(toolID, title: input.lastPathComponent, text: text)
                }
            }
        }
    }
}
