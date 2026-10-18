import SwiftUI
import AVFoundation
import Speech

/// Live microphone transcription with SpeechAnalyzer. Finalized text is shown in the primary
/// color and the in-progress guess in secondary, the way system dictation does it.
@MainActor
@Observable
final class AIDictationEngine {
    static let shared = AIDictationEngine()

    enum State: Equatable {
        case idle
        case preparing(String)
        case listening
        case stopping
        case permissionDenied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Editable once listening stops.
    var finalizedText = ""
    private(set) var volatileText = ""
    /// Smoothed input level, 0...1.
    private(set) var level: Double = 0
    private(set) var startedAt: Date?

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    var isListening: Bool { state == .listening }
    var isBusy: Bool {
        switch state {
        case .preparing, .listening, .stopping: true
        default: false
        }
    }

    func toggle(locale: Locale) {
        if isBusy { Task { await stop() } } else { Task { await start(locale: locale) } }
    }

    func clear() {
        finalizedText = ""
        volatileText = ""
    }

    func start(locale: Locale) async {
        guard !isBusy else { return }
        guard await Self.requestMicrophoneAccess() else {
            state = .permissionDenied
            return
        }
        do {
            state = .preparing("Getting the language model ready…")
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw ToolError.unsupported("\(Transcriber.displayName(for: locale)) isn't supported for dictation.")
            }
            try await Transcriber.prepareModel(for: supported)

            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw ToolError.failed("The speech engine didn't offer a compatible audio format.")
            }
            try await analyzer.prepareToAnalyze(in: analyzerFormat)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
            inputContinuation = continuation
            self.analyzer = analyzer

            if !finalizedText.isEmpty, !finalizedText.hasSuffix(" "), !finalizedText.hasSuffix("\n") {
                finalizedText += " "
            }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard let self else { return }
                        if result.isFinal {
                            self.finalizedText += text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                    }
                } catch {
                    self?.fail(error.localizedDescription)
                }
            }

            try await analyzer.start(inputSequence: stream)
            try startAudio(feeding: continuation, format: analyzerFormat)
            startedAt = Date()
            state = .listening
        } catch {
            await tearDown()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard isBusy else { return }
        state = .stopping
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        if !volatileText.isEmpty {
            finalizedText += volatileText
            volatileText = ""
        }
        analyzer = nil
        resultsTask = nil
        level = 0
        startedAt = nil
        state = .idle
    }

    private func fail(_ message: String) {
        guard isBusy else { return }
        Task {
            await tearDown()
            state = .failed(message)
        }
    }

    private func tearDown() async {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        level = 0
        startedAt = nil
    }

    // MARK: Audio

    private func startAudio(feeding continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw ToolError.failed("No microphone was found.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw ToolError.failed("Couldn't convert microphone audio for the speech engine.")
        }
        let tap = Self.makeTap(converter: converter, outputFormat: format, continuation: continuation) { [weak self] level in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.level = self.level * 0.6 + level * 0.4
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap)
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopAudio() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    /// Built outside the main actor: the tap runs on a real-time audio thread.
    nonisolated static func makeTap(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Double) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            onLevel(rmsLevel(of: buffer))
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    nonisolated private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        let frames = Int(buffer.frameLength)
        for index in 0..<frames { sum += data[index] * data[index] }
        let rms = sqrt(sum / Float(frames))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 55) / 50, 0), 1))
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

struct DictationView: View {
    let tool: Tool

    @State private var engine = AIDictationEngine.shared
    @State private var saver: JobRunner
    @AppStorage("ai.dictation.locale") private var localeID = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tool: Tool) {
        self.tool = tool
        _saver = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var fullText: String { engine.finalizedText + engine.volatileText }

    var body: some View {
        ToolPage(tool: tool, runner: saver) {
            notices
            ToolSection("Language") {
                AISpeechLanguagePicker(identifier: $localeID)
                    .disabled(engine.isBusy)
                if !localeID.isEmpty, !engine.isBusy {
                    AISpeechModelStatus(identifier: localeID)
                }
            }
            ToolSection(engine.isListening ? "Listening…" : "Text") {
                transcriptArea
            }
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var notices: some View {
        switch engine.state {
        case .permissionDenied:
            AINotice(symbol: "mic.slash", title: "Microphone access is off",
                     message: "Allow Toolbox to use the microphone in System Settings › Privacy & Security › Microphone, then try again.") {
                Button("Open Privacy Settings") { AISystemSettings.openMicrophonePrivacy() }
            }
        case .failed(let message):
            AINotice(symbol: "exclamationmark.triangle", title: "Dictation stopped", message: message)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if engine.isBusy {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if fullText.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary)
                        } else {
                            Text(liveText)
                        }
                    }
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(minHeight: 260, maxHeight: 420)
                .onChange(of: fullText) {
                    if reduceMotion { proxy.scrollTo("end") } else { withAnimation { proxy.scrollTo("end") } }
                }
            }
        } else {
            AITextEditor(text: $engine.finalizedText,
                         placeholder: "Press Start Dictation and speak. Your words appear here as you talk, and you can edit them afterwards.",
                         minHeight: 260)
                .font(.title3)
        }
        HStack {
            Text(AIText.countDescription(fullText)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { engine.clear() }
                .disabled(fullText.isEmpty || engine.isBusy)
            AICopyButton(text: fullText)
            Button("Save as Text") { save() }
                .disabled(fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isBusy || saver.isRunning)
        }
    }

    private var placeholder: String {
        if case .preparing(let message) = engine.state { return message }
        return "Start speaking…"
    }

    private var liveText: AttributedString {
        var finalized = AttributedString(engine.finalizedText)
        finalized.foregroundColor = .primary
        var volatile = AttributedString(engine.volatileText)
        volatile.foregroundColor = .secondary
        return finalized + volatile
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                AILevelMeter(level: engine.level, active: engine.isListening)
                switch engine.state {
                case .listening:
                    if let started = engine.startedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.body.monospacedDigit())
                    }
                case .preparing(let message):
                    ProgressView().controlSize(.small)
                    Text(message).foregroundStyle(.secondary)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Finishing…").foregroundStyle(.secondary)
                default:
                    saveStatus
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                engine.toggle(locale: Locale(identifier: localeID))
            } label: {
                Label(engine.isBusy ? "Stop" : "Start Dictation", systemImage: engine.isBusy ? "stop.fill" : "mic.fill")
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isBusy ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(localeID.isEmpty || engine.state == .stopping || !Transcriber.isAvailable)
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch saver.phase {
        case .running:
            ProgressView().controlSize(.small)
            Text("Saving…").foregroundStyle(.secondary)
        case .succeeded:
            if let folder = saver.outputFolder {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved to \(folder.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(saver.outputs.isEmpty ? [folder] : saver.outputs)
                }
                .buttonStyle(.link)
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(2)
        default:
            Text("Speech is recognized on your Mac. Nothing is uploaded.").foregroundStyle(.tertiary)
        }
    }

    private func save() {
        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "Dictation \(formatter.string(from: Date()))"
        saver.start(title: tool.name) { context in
            try AIText.write(text, to: context.output(named: name, extension: "txt"))
        }
    }
}

/// Five bars that light up with the microphone level.
struct AILevelMeter: View {
    let level: Double
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5) { index in
                let threshold = Double(index) / 5
                Capsule()
                    .fill(active && level > threshold ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(6 + index * 3))
            }
        }
        .frame(height: 20)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
