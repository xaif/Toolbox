import SwiftUI
import AVFoundation
import CoreText
import UniformTypeIdentifiers

/// Batch speech-to-text for audio and video files, with TXT, SRT, VTT and PDF outputs.
struct TranscribeView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var previews = AIPreviewStore.shared
    /// Bumped when saved settings change, so the button re-checks them.
    @State private var settingsRevision = 0

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    /// Why the job can't run yet, if it can't. Reads `settingsRevision` to refresh when settings change.
    private var problem: String? {
        _ = settingsRevision
        if !Transcriber.isAvailable { return "On-device transcription isn't available on this Mac." }
        if runner.inputs.isEmpty { return "Add audio or video files to get started." }
        return Settings().problem
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
                Settings()
            }
            .disabled(runner.isRunning)

            if let preview = previews.preview(for: tool.id) {
                AITextPreview(title: "Transcript · \(preview.title)", text: preview.text)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Transcribe", canRun: problem == nil, hint: problem, action: start)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settingsRevision += 1
        }
    }

    private func start() {
        guard let job = Settings().job(for: tool) else { return }
        runner.start(job, title: tool.name, inputs: runner.inputs)
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("ai.transcribe.locale") private var localeID = ""
        @AppStorage("ai.transcribe.txt") private var writeText = true
        @AppStorage("ai.transcribe.srt") private var writeSRT = true
        @AppStorage("ai.transcribe.vtt") private var writeVTT = false
        @AppStorage("ai.transcribe.timestamps") private var textTimestamps = false
        @AppStorage("ai.transcribe.pdf") private var writePDF = false

        private var formats: [SubtitleFormat] {
            var formats: [SubtitleFormat] = []
            if writeText { formats.append(.txt) }
            if writeSRT { formats.append(.srt) }
            if writeVTT { formats.append(.vtt) }
            return formats
        }

        /// What's missing before the job can run.
        var problem: String? {
            if !Transcriber.isAvailable { return "On-device transcription isn't available on this Mac." }
            if formats.isEmpty, !writePDF { return "Choose at least one output format." }
            if localeID.isEmpty { return "Choose a language." }
            return nil
        }

        var body: some View {
            AISpeechLanguagePicker(identifier: $localeID)
            if !localeID.isEmpty {
                AISpeechModelStatus(identifier: localeID)
                    .optionIndent()
            }
            Divider()
            OptionGroup("Save as") {
                OptionToggle("Text (.txt)", isOn: $writeText)
                OptionToggle("Subtitles (.srt)", isOn: $writeSRT)
                OptionToggle("WebVTT (.vtt)", isOn: $writeVTT)
                OptionToggle("PDF transcript (.pdf)", isOn: $writePDF)
            }
            if writeText {
                OptionToggle("Add timestamps to the text file", isOn: $textTimestamps)
            }
        }

        func job(for tool: Tool) -> ToolJob? {
            guard problem == nil else { return nil }
            let locale = Locale(identifier: localeID)
            let formats = formats
            let timestamps = textTimestamps
            let writePDF = writePDF
            let toolID = tool.id
            return .each(verb: "Transcribing") { input, context, progress in
                let transcript = try await Transcriber.transcribe(input, locale: locale, progress: progress)
                guard !transcript.phrases.isEmpty else { throw ToolError.failed("No speech was detected.") }
                for format in formats {
                    let url = context.output(for: input, extension: format.fileExtension)
                    let content = format == .txt
                        ? AITranscriptFormat.paragraphs(transcript, timestamps: timestamps)
                        : Subtitles.serialize(transcript.cues, as: format)
                    try AIText.write(content, to: url)
                }
                if writePDF {
                    let duration = try? await AVURLAsset(url: input).load(.duration).seconds
                    try AITranscriptPDF.write(transcript, title: input.deletingPathExtension().lastPathComponent,
                                              source: input.lastPathComponent, duration: duration,
                                              to: context.output(for: input, extension: "pdf"))
                }
                let text = AITranscriptFormat.paragraphs(transcript)
                await MainActor.run {
                    AIPreviewStore.shared.set(toolID, title: input.lastPathComponent, text: text)
                }
            }
        }
    }
}

/// Transcripts as readable PDFs: a title and details, then paragraphs marked with their start times.
enum AITranscriptPDF {
    static func write(_ transcript: Transcript, title: String, source: String, duration: Double?,
                      date: Date = Date(), to url: URL) throws {
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? transcript.phrases.last?.end ?? 0
        let gray = CGColor(gray: 0.45, alpha: 1)
        let text = NSMutableAttributedString()
        func append(_ string: String, font: NSFont, color: CGColor = CGColor(gray: 0, alpha: 1), spacing: CGFloat = 0, lineHeight: CGFloat = 1) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.lineHeightMultiple = lineHeight
            text.append(NSAttributedString(string: string, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color, .paragraphStyle: style,
            ]))
        }
        append(title + "\n", font: .systemFont(ofSize: 20, weight: .semibold), spacing: 4)
        var details = ["Transcribed from \(source)", date.formatted(date: .long, time: .omitted)]
        if length > 0 { details.append(Duration.seconds(length).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))) }
        append(details.joined(separator: " · ") + "\n", font: .systemFont(ofSize: 10), color: gray, spacing: 22)
        for paragraph in paragraphs(transcript) {
            append(timestamp(paragraph.start, long: length >= 3600) + "\n", font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium), color: gray, spacing: 2)
            append(paragraph.text + "\n", font: .systemFont(ofSize: 11), spacing: 12, lineHeight: 1.2)
        }
        try render(text, footer: title, to: url)
    }

    /// Phrases grouped at pauses longer than `pause` seconds, like the text transcript's paragraphs.
    static func paragraphs(_ transcript: Transcript, pause: Double = 1.8) -> [(start: Double, text: String)] {
        var paragraphs: [(start: Double, text: String)] = []
        var lastEnd = -Double.infinity
        for phrase in transcript.phrases {
            let words = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            if let last = paragraphs.last, phrase.start - lastEnd <= pause, last.text.count <= 600 {
                paragraphs[paragraphs.count - 1].text += " " + words
            } else {
                paragraphs.append((phrase.start, words))
            }
            lastEnd = phrase.end
        }
        return paragraphs
    }

    private static func timestamp(_ seconds: Double, long: Bool) -> String {
        let total = Int(max(seconds, 0))
        return long ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Lays `text` out on A4 (US Letter in the US) pages with "title · Page n of N" footers.
    private static func render(_ text: NSAttributedString, footer: String, to url: URL) throws {
        let size = Locale.current.region == .unitedStates ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        var bounds = CGRect(origin: .zero, size: size)
        let frameRect = bounds.insetBy(dx: 64, dy: 64)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: frameRect, transform: nil)
        var ranges: [CFRange] = []
        var offset = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw ToolError.failed("Couldn't lay out the transcript.") }
            ranges.append(visible)
            offset += visible.length
        } while offset < text.length
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, [kCGPDFContextTitle: footer] as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for (index, range) in ranges.enumerated() {
            context.beginPDFPage(nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, range, path, nil), context)
            let label = NSAttributedString(string: "\(footer) · Page \(index + 1) of \(ranges.count)", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.55, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(label)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: (size.width - width) / 2, y: 36)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
