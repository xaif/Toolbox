import SwiftUI
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers

/// Audio files PDF to Audio writes.
enum SpeechAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, mp3, wav, aiff

    var id: Self { self }

    var label: String {
        switch self {
        case .m4a: "M4A"
        case .mp3: "MP3"
        case .wav: "WAV"
        case .aiff: "AIFF"
        }
    }

    var fileExtension: String { self == .aiff ? "aif" : rawValue }
}

struct PDFToAudioView: View {
    let tool: Tool
    @State private var pages = ""

    var body: some View {
        BatchToolView(tool: tool, accepts: AIDocumentText.types, actionTitle: "Create Audio", noun: "documents",
                      job: { Settings().job(pages: pages) }) {
            Settings()
            LabeledContent("PDF pages") {
                TextField("All pages, or e.g. 1-3, 5", text: $pages)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            HStack(spacing: 10) {
                SpeechPreviewButton()
                Button("Get More Voices…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("Speech is generated on your Mac with the system voices. Enhanced and Premium voices sound the most natural; download them in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Scanned pages are read with OCR.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    /// The page range is per document, so it's only on this page; the launcher reads every page.
    struct Settings: ToolSettings {
        @AppStorage("ai.pdf-to-audio.voice") private var voiceID = ""
        @AppStorage("ai.pdf-to-audio.rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
        @AppStorage("ai.pdf-to-audio.pitch") private var pitch = 1.0
        @AppStorage("ai.pdf-to-audio.format") private var format = SpeechAudioFormat.m4a
        @AppStorage("ai.pdf-to-audio.skipFurniture") private var skipFurniture = true

        var body: some View {
            OptionPicker("Voice", selection: $voiceID, choices: voiceChoices)
            OptionSlider("Speed", value: $rate, in: 0.3...0.7, step: 0.025, presets: [0.4, 0.5, 0.6]) { value in
                abs(value - 0.5) < 0.001 ? "Normal" : "\(Int((value / 0.5 * 100).rounded()))%"
            }
            OptionSlider("Pitch", value: $pitch, in: 0.75...1.5, step: 0.05) { String(format: "%.2f×", $0) }
            OptionPicker("Format", selection: $format, style: .segmented,
                         choices: SpeechAudioFormat.allCases.map { OptionChoice($0, $0.label) })
            if format == .mp3, !Dependencies.shared.isAvailable(.ffmpeg) {
                OptionNote("MP3 needs FFmpeg. Install it in Settings → Tools, or choose M4A.")
            }
            OptionToggle("Skip running headers, footers and page numbers", isOn: $skipFurniture)
        }

        private var voiceChoices: [OptionChoice<String>] {
            var choices = [OptionChoice("", "Automatic (best voice for the document's language)")]
            var language: String?
            for voice in SpeechVoices.available() {
                choices.append(OptionChoice(voice.identifier, SpeechVoices.label(voice), dividerBefore: voice.language != language))
                language = voice.language
            }
            if !voiceID.isEmpty, !choices.contains(where: { $0.value == voiceID }) {
                choices.append(OptionChoice(voiceID, "Unavailable voice", dividerBefore: true))
            }
            return choices
        }

        func job(for tool: Tool) -> ToolJob? { job(pages: "") }

        /// `pages` is a range like "1-3, 5" applied to PDFs; empty reads every page.
        func job(pages: String) -> ToolJob? {
            if format == .mp3, !Dependencies.shared.isAvailable(.ffmpeg) { return nil }
            let voice = SpeechSettings(voiceID: voiceID, rate: Float(rate), pitch: Float(pitch))
            let format = format, skip = skipFurniture
            let range = pages.trimmingCharacters(in: .whitespaces)
            return .each(verb: "Reading") { input, context, progress in
                var indices: [Int]?
                if !range.isEmpty, input.pathExtension.lowercased() == "pdf" {
                    let document = try PDFOps.open(input)
                    indices = try PDFOps.indices(range, pageCount: document.pageCount)
                }
                context.setStatus("Reading \(input.lastPathComponent)")
                let document = try await AIDocumentText.load(input, pages: indices) { fraction, _ in progress(fraction * 0.1) }
                let output = context.output(for: input, extension: format.fileExtension)
                if format == .mp3 {
                    let scratch = try context.makeScratchFolder()
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let wav = scratch.appendingPathComponent("speech.wav")
                    let duration = try await SpeechRenderer.render(document, skipFurniture: skip, voice: voice, format: .wav, to: wav) {
                        progress(0.1 + $0 * 0.8)
                    }
                    try await FFmpeg.run(["-i", wav.path, "-c:a", "libmp3lame", "-b:a", "96k", output.path], duration: duration) {
                        progress(0.9 + $0 * 0.1)
                    }
                } else {
                    _ = try await SpeechRenderer.render(document, skipFurniture: skip, voice: voice, format: format, to: output) {
                        progress(0.1 + $0 * 0.9)
                    }
                }
            }
        }
    }
}

/// A voice and how it speaks. An empty `voiceID` picks the best voice for the text's language.
struct SpeechSettings: Sendable {
    var voiceID = ""
    var rate = AVSpeechUtteranceDefaultSpeechRate
    var pitch: Float = 1
}

/// Turns documents into speech files.
enum SpeechRenderer {
    /// Speaks `document` into `url` (M4A, WAV or AIFF) and returns the audio's duration in seconds.
    static func render(_ document: AIDocumentText, skipFurniture: Bool, voice settings: SpeechSettings,
                       format: SpeechAudioFormat, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let paragraphs = SpeechScript.paragraphs(from: document.pages, skipFurniture: skipFurniture && document.isPaged)
            .flatMap { AISummarizer.split($0, limit: 2500) }
        guard !paragraphs.isEmpty else { throw ToolError.failed("There's no text to read.") }
        let voiceID = settings.voiceID.isEmpty ? SpeechVoices.best(for: document.fullText)?.identifier : settings.voiceID
        let writer = await SpeechAudioWriter(url: url, format: format)
        let total = Double(paragraphs.reduce(0) { $0 + $1.count })
        var done = 0.0
        for paragraph in paragraphs {
            try Task.checkCancellation()
            try await writer.speak(paragraph, voiceID: voiceID, rate: settings.rate, pitch: settings.pitch)
            try writer.appendSilence(seconds: 0.35)
            done += Double(paragraph.count)
            progress(done / total)
        }
        return try writer.finish()
    }
}

/// Writes synthesized speech into one audio file, one utterance after another.
final class SpeechAudioWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let url: URL
    private let format: SpeechAudioFormat
    private let synthesizer = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var frames: AVAudioFramePosition = 0
    private let lock = NSLock()
    /// The utterance being written, resumed once when its last buffer arrives or it's cancelled.
    private var pending: CheckedContinuation<Void, Error>?
    /// Callbacks for earlier utterances can arrive late; only this one's count.
    private var pendingUtterance: AVSpeechUtterance?

    @MainActor
    init(url: URL, format: SpeechAudioFormat) {
        self.url = url
        self.format = format
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text` into the file. Synthesis runs on the main thread, where the synthesizer delivers its buffers.
    func speak(_ text: String, voiceID: String?, rate: Float, pitch: Float) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { pending = continuation }
                DispatchQueue.main.async { [self] in
                    let utterance = AVSpeechUtterance(string: text)
                    if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
                    utterance.rate = rate
                    utterance.pitchMultiplier = pitch
                    lock.withLock { pendingUtterance = utterance }
                    var received = false
                    synthesizer.write(utterance) { [self] buffer in
                        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                        received = true
                        if pcm.frameLength == 0 { resume(nil, for: utterance); return }
                        do { try append(pcm) } catch {
                            resume(error, for: utterance)
                            synthesizer.stopSpeaking(at: .immediate)
                        }
                    }
                    // A voice that's missing or still downloading never calls back.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                        if !received { resume(ToolError.failed("The voice didn't produce any audio. Choose another voice."), for: utterance) }
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { [self] in
                synthesizer.stopSpeaking(at: .immediate)
                resume(CancellationError())
            }
        }
    }

    /// Adds a pause, e.g. between paragraphs.
    func appendSilence(seconds: Double) throws {
        try lock.withLock {
            guard let file else { return }
            let format = file.processingFormat
            let count = AVAudioFrameCount(format.sampleRate * seconds)
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            buffer.frameLength = count
            // New buffers are zero-filled, which is silence.
            try file.write(from: buffer)
            frames += AVAudioFramePosition(count)
        }
    }

    /// Closes the file and returns its duration in seconds.
    func finish() throws -> Double {
        try lock.withLock {
            guard let file else { throw ToolError.failed("No speech was generated.") }
            let duration = Double(frames) / file.processingFormat.sampleRate
            file.close()
            self.file = nil
            return duration
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resume(nil, for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resume(CancellationError(), for: utterance)
    }

    /// Resumes the waiting `speak` call once. With `utterance`, only if it's still the one being written.
    private func resume(_ error: Error?, for utterance: AVSpeechUtterance? = nil) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if let utterance, utterance !== pendingUtterance { return nil }
            defer { pending = nil; pendingUtterance = nil }
            return pending
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    private func append(_ buffer: AVAudioPCMBuffer) throws {
        try lock.withLock {
            if file == nil { file = try makeFile(for: buffer.format) }
            guard let file else { return }
            if buffer.format == file.processingFormat {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                return
            }
            // A voice in another format: convert to the file's.
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: file.processingFormat) }
            guard let converter else { throw ToolError.failed("Couldn't convert the speech audio.") }
            let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            try file.write(from: output)
            frames += AVAudioFramePosition(output.frameLength)
        }
    }

    private func makeFile(for format: AVAudioFormat) throws -> AVAudioFile {
        var settings: [String: Any] = [AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount]
        switch self.format {
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = format.channelCount > 1 ? 96_000 : 64_000
        case .wav, .mp3, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = self.format == .aiff
        }
        try? FileManager.default.removeItem(at: url)
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }
}

/// Prepares extracted text for reading aloud.
enum SpeechScript {
    /// Paragraphs to read, with lines rejoined. With `skipFurniture`, lines repeated at the top or bottom of
    /// most pages (running headers and footers) and page numbers are left out.
    static func paragraphs(from pages: [AIDocumentPage], skipFurniture: Bool) -> [String] {
        var pageLines = pages.map { page in
            page.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if skipFurniture {
            var counts: [String: Int] = [:]
            for lines in pageLines {
                for key in Set(edges(of: lines).map { lines[$0] }.map(key)) { counts[key, default: 0] += 1 }
            }
            let threshold = max(3, Int((Double(pages.count) * 0.4).rounded(.up)))
            pageLines = pageLines.map { lines in
                let remove = Set(edges(of: lines).filter {
                    isPageNumber(lines[$0]) || (lines[$0].count <= 100 && (counts[key(lines[$0])] ?? 0) >= threshold)
                })
                return lines.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
            }
        }
        return pageLines.flatMap(join)
    }

    /// Whether a line is only a page number, like "12", "Page 3 of 10", "- 4 -" or "iv".
    static func isPageNumber(_ line: String) -> Bool {
        line.range(of: #"^(page|p\.|seite|página|pagina|pág\.)?\s*[-–—]?\s*(\d{1,4}|[ivxlcdm]{1,7})\s*[-–—]?\s*((of|/|von|de|sur)\s*\d{1,4})?$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first two and last two lines, where headers and footers sit.
    private static func edges(of lines: [String]) -> [Int] {
        Array(Set([0, 1, lines.count - 2, lines.count - 1].filter { $0 >= 0 && $0 < lines.count })).sorted()
    }

    /// Lines that differ only in their numbers (like "Chapter 2 · 14") count as the same header.
    private static func key(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Rejoins lines a PDF wrapped, undoing hyphenation, and splits paragraphs where a sentence ends on
    /// a short line, before a list item, or at the end of a long line (which was a paragraph already).
    private static func join(_ lines: [String]) -> [String] {
        let lengths = lines.map(\.count).filter { $0 > 20 }.sorted()
        let typical = lengths.isEmpty ? 60 : Double(lengths[lengths.count / 2])
        var paragraphs: [String] = []
        var current = ""
        var previousLength = 0
        for line in lines {
            if current.isEmpty { current = line; previousLength = line.count; continue }
            let endsSentence = current.range(of: #"[.!?:;。！？][\"'”’)\]]*$"#, options: .regularExpression) != nil
            let startsItem = line.range(of: #"^([•▪●◦‣*–-]|\d{1,3}[.)])\s"#, options: .regularExpression) != nil
            if startsItem || (endsSentence && (Double(previousLength) < typical * 0.85 || previousLength > 150)) {
                paragraphs.append(current)
                current = line
            } else if current.hasSuffix("-"), let first = line.first, first.isLowercase {
                current = String(current.dropLast()) + line
            } else {
                current += " " + line
            }
            previousLength = line.count
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }
}

/// The installed voices.
enum SpeechVoices {
    /// Voices worth offering, grouped by language (the user's first), best quality first. Novelty and
    /// Personal Voices are left out.
    static func available() -> [AVSpeechSynthesisVoice] {
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                let aPreferred = a.language.hasPrefix(preferred), bPreferred = b.language.hasPrefix(preferred)
                if aPreferred != bPreferred { return aPreferred }
                if a.language != b.language { return languageName(a.language) < languageName(b.language) }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
        return "\(voice.name) — \(languageName(voice.language))\(quality)"
    }

    /// The best installed voice for the language `text` is written in, preferring the user's region.
    static func best(for text: String) -> AVSpeechSynthesisVoice? {
        let language = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(5000)))?.rawValue
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let code = String(language.prefix(while: { $0 != "-" }))
        let region = Locale.current.region?.identifier ?? ""
        let candidates = available().filter { $0.language.hasPrefix(code) }
        return candidates.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            let aRegion = a.language.hasSuffix(region), bRegion = b.language.hasSuffix(region)
            if aRegion != bRegion { return !aRegion }
            return isDefault(a) == false && isDefault(b)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// The system's own voice for its language beats the novelty-ish Eloquence voices at the same quality.
    private static func isDefault(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier == AVSpeechSynthesisVoice(language: voice.language)?.identifier
    }

    private static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Speaks a sample sentence with the saved voice, rate and pitch.
private struct SpeechPreviewButton: View {
    @AppStorage("ai.pdf-to-audio.voice") private var voiceID = ""
    @AppStorage("ai.pdf-to-audio.rate") private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("ai.pdf-to-audio.pitch") private var pitch = 1.0
    @State private var player = SpeechPreviewPlayer()

    var body: some View {
        Button {
            if player.isSpeaking { player.stop() } else { player.play(voiceID: voiceID, rate: Float(rate), pitch: Float(pitch)) }
        } label: {
            Label(player.isSpeaking ? "Stop Preview" : "Preview Voice", systemImage: player.isSpeaking ? "stop.fill" : "play.fill")
        }
    }
}

@MainActor
@Observable
private final class SpeechPreviewPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(voiceID: String, rate: Float, pitch: Float) {
        let voice = voiceID.isEmpty ? SpeechVoices.best(for: "") : AVSpeechSynthesisVoice(identifier: voiceID)
        let utterance = AVSpeechUtterance(string: "Here's how your documents will sound with this voice.")
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
}
