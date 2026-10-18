import AVFoundation
import Observation

enum RecordingExportFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

/// State for editing a finished take: live preview (with zoom), trim, captions and export settings.
/// Lives in `RecordingStudio` so edits survive navigating to other tools.
@MainActor
@Observable
final class RecordingEditorModel {
    let take: RecordingTake
    let player = AVPlayer()

    private(set) var isReady = false
    private(set) var loadError: String?
    private(set) var currentTime: Double = 0

    var trim: ClosedRange<Double> { didSet { applyTrim() } }

    var autoZoom: Bool { didSet { rebuildPreview() } }
    var zoomScale = 1.8

    var captionsEnabled = false { didSet { if captionsEnabled, cues == nil, !transcribing { transcribe() } } }
    var locale: Locale? { didSet { if oldValue != nil, oldValue != locale { cues = nil; if captionsEnabled { transcribe() } } } }
    private(set) var locales: [Locale] = []
    private(set) var cues: [SubtitleCue]?
    private(set) var transcribing = false
    private(set) var transcriptionProgress: Double = 0
    private(set) var captionError: String?
    private(set) var transcriptionAvailable = Transcriber.isAvailable

    var format = RecordingExportFormat.mp4
    var resolution = RecordingExportResolution.original

    private var composition: AVMutableComposition?
    private var videoTrack: AVMutableCompositionTrack?
    private var sourceSize = CGSize.zero
    private var timeObserver: Any?
    private var transcriptionTask: Task<Void, Never>?

    init(take: RecordingTake) {
        self.take = take
        self.trim = 0...max(take.duration, 0.1)
        self.autoZoom = !take.clicks.isEmpty
        Task { await load() }
    }

    var zoomSettings: RecordingZoomSettings {
        RecordingZoomSettings(enabled: autoZoom, scale: zoomScale)
    }

    /// The caption showing at the current playhead, for the preview overlay.
    var activeCaption: String? {
        guard captionsEnabled, let cues else { return nil }
        return cues.first { $0.start <= currentTime && currentTime < $0.end }?.text
    }

    private func load() async {
        do {
            let (composition, track, size) = try await RecordingComposer.makeComposition(segments: take.segments)
            self.composition = composition
            self.videoTrack = track
            self.sourceSize = size
            rebuildPreview()
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds }
            }
            isReady = true
        } catch {
            loadError = error.localizedDescription
        }
        if transcriptionAvailable {
            locales = await Transcriber.supportedLocales()
            locale = await Transcriber.defaultLocale() ?? locales.first
        }
    }

    /// Rebuilds the player item so the preview reflects the zoom settings.
    func rebuildPreview() {
        guard let composition, let videoTrack else { return }
        let resume = player.currentTime()
        let wasPlaying = player.rate != 0
        let item = AVPlayerItem(asset: composition)
        if autoZoom {
            let keyframes = RecordingComposer.zoomKeyframes(clicks: take.clicks, duration: take.duration, settings: zoomSettings)
            item.videoComposition = RecordingComposer.videoComposition(
                videoTrack: videoTrack, duration: take.duration, sourceSize: sourceSize,
                renderSize: RecordingComposer.renderSize(for: sourceSize, resolution: .p1080),
                frameRate: 30, keyframes: keyframes)
        }
        player.replaceCurrentItem(with: item)
        applyTrim()
        player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    private func applyTrim() {
        guard let item = player.currentItem else { return }
        item.forwardPlaybackEndTime = CMTime(seconds: trim.upperBound, preferredTimescale: 600)
        item.reversePlaybackEndTime = CMTime(seconds: trim.lowerBound, preferredTimescale: 600)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    // MARK: Captions

    func transcribe() {
        guard let locale else {
            captionError = "Choose a language for captions."
            return
        }
        transcriptionTask?.cancel()
        transcribing = true
        transcriptionProgress = 0
        captionError = nil
        let segments = take.segments
        let audioURL = take.folder.appendingPathComponent("captions-audio.m4a")
        transcriptionTask = Task { [weak self] in
            do {
                try await RecordingComposer.exportAudio(segments: segments, to: audioURL)
                let transcript = try await Transcriber.transcribe(audioURL, locale: locale) { progress in
                    Task { @MainActor in self?.transcriptionProgress = progress }
                }
                try Task.checkCancellation()
                let cues = transcript.cues
                self?.cues = cues
                if cues.isEmpty { self?.captionError = "No speech was found in this recording." }
            } catch is CancellationError {
            } catch {
                self?.captionError = error.localizedDescription
            }
            self?.transcribing = false
        }
    }

    // MARK: Export

    var canExport: Bool { isReady && !(captionsEnabled && transcribing) }

    /// Snapshot of the current settings as a job for `JobRunner`.
    func exportJob() -> @Sendable (JobContext) async throws -> Void {
        let take = take
        let trim = trim
        let zoom = zoomSettings
        let captions = captionsEnabled ? (cues ?? []) : []
        let resolution = resolution
        let format = format
        return { context in
            let output = context.output(named: take.baseName, extension: format.rawValue)
            context.setStatus("Exporting \(output.lastPathComponent)")
            try await RecordingComposer.export(
                segments: take.segments, clicks: take.clicks, trim: trim, zoom: zoom,
                captions: captions.map { RecordingCaption(start: $0.start, end: $0.end, text: $0.text) },
                resolution: resolution, fileType: format.fileType, to: output,
                progress: { context.setProgress($0) })
            if !captions.isEmpty {
                let duration = trim.upperBound - trim.lowerBound
                let shifted = captions.compactMap { cue -> SubtitleCue? in
                    let start = max(cue.start - trim.lowerBound, 0)
                    let end = min(cue.end - trim.lowerBound, duration)
                    return end > start ? SubtitleCue(start: start, end: end, text: cue.text) : nil
                }
                let srt = context.output(named: take.baseName, extension: "srt")
                try Subtitles.serialize(shifted, as: .srt).write(to: srt, atomically: true, encoding: .utf8)
            }
        }
    }

    func tearDown() {
        transcriptionTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}
