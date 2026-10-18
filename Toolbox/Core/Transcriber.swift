import AVFoundation
import Speech

/// A finished on-device transcript.
struct Transcript: Sendable {
    /// One entry per recognized phrase, as returned by the recognizer.
    var phrases: [SubtitleCue]
    /// Individual words with timings.
    var words: [TimedWord]

    var text: String {
        phrases.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Caption-sized cues, good for SRT/VTT files and burned-in subtitles.
    var cues: [SubtitleCue] {
        words.isEmpty ? phrases : Subtitles.cues(from: words)
    }
}

/// On-device speech-to-text using Apple's SpeechAnalyzer. Audio never leaves the Mac.
enum Transcriber {
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Languages the on-device model supports, sorted by display name.
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /// The best supported match for the user's current language, if any.
    static func defaultLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return match }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Downloads the language model if it isn't installed yet (a one-time system download).
    static func prepareModel(for locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = progress.map { report in
            request.progress.observe(\.fractionCompleted) { item, _ in report(item.fractionCompleted) }
        }
        defer { observation?.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Transcribes any audio or video file.
    /// - Parameter progress: 0...1. The first ~5% covers audio extraction.
    static func transcribe(
        _ url: URL,
        locale: Locale,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        guard isAvailable else { throw ToolError.unsupported("On-device transcription isn't available on this Mac.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ToolError.unsupported("\(displayName(for: locale)) isn't supported for transcription.")
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let audioURL = try await AudioExtraction.pcmFile(from: url, in: scratch)
        progress?(0.05)
        try await prepareModel(for: supported)

        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let collector = Task { () throws -> Transcript in
            var transcript = Transcript(phrases: [], words: [])
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                transcript.phrases.append(SubtitleCue(start: result.range.start.seconds,
                                                      end: result.range.end.seconds, text: text))
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !word.isEmpty {
                        transcript.words.append(TimedWord(start: range.start.seconds, end: range.end.seconds, text: word))
                    }
                }
                if duration > 0 { progress?(0.05 + 0.95 * min(result.range.end.seconds / duration, 1)) }
            }
            return transcript
        }

        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        try Task.checkCancellation()
        var transcript = try await collector.value
        transcript.words = mergeWordPieces(transcript.words)
        progress?(1)
        return transcript
    }

    /// The recognizer can return punctuation or sub-word pieces as separate runs; glue them to the previous word.
    private static func mergeWordPieces(_ words: [TimedWord]) -> [TimedWord] {
        var merged: [TimedWord] = []
        for word in words {
            if let last = merged.last, let first = word.text.unicodeScalars.first,
               CharacterSet.punctuationCharacters.contains(first), word.text.count <= 2 {
                merged[merged.count - 1] = TimedWord(start: last.start, end: max(last.end, word.end), text: last.text + word.text)
            } else {
                merged.append(word)
            }
        }
        return merged
    }
}

/// Decodes the audio track of any media file into an uncompressed file the speech engine can read.
enum AudioExtraction {
    /// Returns a 16-bit PCM WAV in `folder`. Uses AVFoundation, falling back to FFmpeg for formats
    /// AVFoundation can't open (MKV, WebM, Ogg…).
    static func pcmFile(from url: URL, in folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent("audio.wav")
        do {
            try await decodeWithAVFoundation(url, to: output)
            return output
        } catch {
            guard Dependencies.locate(.ffmpeg) != nil else { throw error }
            try? FileManager.default.removeItem(at: output)
            try await FFmpeg.run(["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path])
            return output
        }
    }

    private static func decodeWithAVFoundation(_ url: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ToolError.failed("“\(url.lastPathComponent)” has no audio.")
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? ToolError.unreadableInput(url) }

        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                      into: buffer.mutableAudioBufferList)
            guard status == noErr else { continue }
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw reader.error ?? ToolError.unreadableInput(url) }
    }
}
