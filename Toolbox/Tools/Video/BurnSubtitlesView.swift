import SwiftUI
import UniformTypeIdentifiers

struct BurnSubtitlesView: View {
    let tool: Tool

    enum Source: String, CaseIterable, Identifiable {
        case file, transcribe
        var id: Self { self }
        var label: String { self == .file ? "Subtitle file (SRT or VTT)" : "Generate with on-device transcription" }
    }

    static let subtitleTypes: [UTType] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }

    @State private var runner: JobRunner
    @State private var source = Source.file
    @State private var subtitleFile: URL?
    @State private var locales: [Locale] = []
    @State private var localeID = ""
    @State private var saveSRT = true
    @State private var style = VideoSubtitleBurner.Style()

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            Group {
                FileListInput(files: $runner.inputs, accepts: UTType.videoInputs, allowsMultiple: false, title: "Video", noun: "a video")

                ToolSection("Subtitles") {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    switch source {
                    case .file:
                        VideoSingleFilePicker(title: "Subtitle file", file: $subtitleFile, accepts: Self.subtitleTypes, noun: "an .srt or .vtt file")
                    case .transcribe:
                        if !Transcriber.isAvailable {
                            Label("On-device transcription isn't available on this Mac.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else if locales.isEmpty {
                            ProgressView().controlSize(.small)
                        } else {
                            Picker("Spoken language", selection: $localeID) {
                                ForEach(locales, id: \.identifier) { Text(Transcriber.displayName(for: $0)).tag($0.identifier) }
                            }
                            Toggle("Also save the subtitles as an .srt file", isOn: $saveSRT)
                            Text("Speech is recognized on your Mac. The language model downloads once if needed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                ToolSection("Style") {
                    Picker("Size", selection: $style.size) {
                        ForEach(VideoSubtitleBurner.Style.Size.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Picker("Position", selection: $style.position) {
                        ForEach(VideoSubtitleBurner.Style.Position.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Toggle("Dark box behind text", isOn: $style.background)
                    if let video = runner.inputs.first {
                        VideoFramePreview(url: video, time: 1) { size in
                            CaptionSample(style: style, frameSize: size)
                        }
                    }
                }
            }
            .disabled(runner.isRunning)
        } footer: {
            JobBar(runner: runner, actionTitle: "Burn In", canRun: canRun, hint: hint, action: start)
        }
        .task { await loadLocales() }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private var canRun: Bool {
        guard !runner.inputs.isEmpty else { return false }
        switch source {
        case .file: return subtitleFile != nil
        case .transcribe: return Transcriber.isAvailable && !localeID.isEmpty
        }
    }

    private var hint: String {
        runner.inputs.isEmpty ? "Add a video to get started." : "Choose a subtitle file."
    }

    private func loadLocales() async {
        guard locales.isEmpty, Transcriber.isAvailable else { return }
        let supported = await Transcriber.supportedLocales()
        let preferred = await Transcriber.defaultLocale()
        locales = supported
        if localeID.isEmpty {
            localeID = preferred?.identifier ?? supported.first?.identifier ?? ""
        }
    }

    private func start() {
        guard let video = runner.inputs.first else { return }
        let source = source
        let subtitleFile = subtitleFile
        let locale = Locale(identifier: localeID)
        let saveSRT = saveSRT
        let style = style

        runner.start(title: tool.name) { context in
            let scratch = try context.makeScratchFolder()
            var cues: [SubtitleCue]
            var done = 0.0

            switch source {
            case .file:
                guard let subtitleFile else { throw ToolError.failed("Choose a subtitle file.") }
                cues = try Subtitles.load(from: subtitleFile)
            case .transcribe:
                context.setStatus("Transcribing \(video.lastPathComponent)…")
                let transcript = try await Transcriber.transcribe(video, locale: locale) { context.setProgress($0 * 0.45) }
                cues = transcript.cues
                guard !cues.isEmpty else { throw ToolError.failed("No speech was found in the video.") }
                if saveSRT {
                    let srt = context.output(for: video, extension: SubtitleFormat.srt.fileExtension)
                    try Subtitles.serialize(cues, as: .srt).write(to: srt, atomically: true, encoding: .utf8)
                }
                done = 0.45
            }

            let start = done
            let needsTranscode = await !VideoEncoding.isPlayableByAVFoundation(video)
            if needsTranscode { context.setStatus("Preparing \(video.lastPathComponent)…") }
            let readable = try await VideoEncoding.avFoundationReadable(video, in: scratch) { p in
                context.setProgress(start + p * (1 - start) * 0.35)
            }
            let burnStart = needsTranscode ? start + (1 - start) * 0.35 : start

            context.setStatus("Burning in \(cues.count) subtitles…")
            let output = context.output(for: video, suffix: "subtitled", extension: "mp4")
            try await VideoSubtitleBurner.burn(readable, cues: cues, style: style, to: output) { p in
                context.setProgress(burnStart + p * (1 - burnStart))
            }
        }
    }
}

/// SwiftUI mock of a burned-in caption, scaled to the preview frame.
private struct CaptionSample: View {
    let style: VideoSubtitleBurner.Style
    let frameSize: CGSize

    var body: some View {
        let fontSize = max(min(frameSize.width, frameSize.height) * style.size.factor, 6)
        VStack {
            if style.position == .bottom { Spacer() }
            Text("Subtitles will look like this")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: style.background ? .clear : .black, radius: max(fontSize * 0.1, 1))
                .padding(.horizontal, fontSize * 0.45)
                .padding(.vertical, fontSize * 0.22)
                .background(style.background ? Color.black.opacity(0.62) : .clear,
                            in: RoundedRectangle(cornerRadius: fontSize * 0.28))
                .padding(frameSize.height * 0.06)
            if style.position == .top { Spacer() }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .allowsHitTesting(false)
    }
}
