import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Holds the preview player, waveform and selected range for Trim Audio.
@MainActor
@Observable
final class AudioTrimModel {
    private(set) var url: URL?
    private(set) var duration: Double = 0
    private(set) var peaks: [Float] = []
    private(set) var isLoading = false
    private(set) var canPreview = false
    private(set) var isPlaying = false
    var playhead: Double = 0
    var range: ClosedRange<Double> = 0...1

    let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.playhead = seconds
                if self.isPlaying, seconds >= self.range.upperBound {
                    self.player.pause()
                    self.isPlaying = false
                    self.playhead = self.range.upperBound
                }
            }
        }
    }

    func load(_ url: URL?) async {
        guard url != self.url else { return }
        player.pause()
        isPlaying = false
        self.url = url
        peaks = []
        duration = 0
        canPreview = false
        guard let url else { player.replaceCurrentItem(with: nil); return }

        isLoading = true
        defer { isLoading = false }
        var length = (try? await FFmpeg.probe(url).duration) ?? 0
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        if length <= 0, let assetDuration = try? await asset.load(.duration).seconds, assetDuration.isFinite {
            length = assetDuration
        }
        guard self.url == url else { return }
        duration = max(length, 0.1)
        range = 0...duration
        playhead = 0
        canPreview = playable
        player.replaceCurrentItem(with: playable ? AVPlayerItem(asset: asset) : nil)
        let loaded = await AudioWaveformLoader.peaks(for: url)
        if self.url == url { peaks = loaded }
    }

    func togglePlay() {
        guard canPreview else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if playhead < range.lowerBound || playhead >= range.upperBound - 0.05 { seek(range.lowerBound) }
            player.play()
            isPlaying = true
        }
    }

    func seek(_ seconds: Double) {
        playhead = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        isPlaying = false
    }
}

struct TrimAudioView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var model = AudioTrimModel()
    @State private var fadeIn = false
    @State private var fadeInSeconds = 1.0
    @State private var fadeOut = false
    @State private var fadeOutSeconds = 1.0

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.audioInputs, allowsMultiple: false, title: "Audio file")
                .disabled(runner.isRunning)
            if model.url != nil {
                selectionSection
                ToolSection("Fades") {
                    HStack {
                        Toggle("Fade in", isOn: $fadeIn)
                        Stepper(value: $fadeInSeconds, in: 0.1...30, step: 0.5) {
                            Text("\(fadeInSeconds, format: .number.precision(.fractionLength(1))) s").monospacedDigit()
                        }
                        .disabled(!fadeIn)
                    }
                    HStack {
                        Toggle("Fade out", isOn: $fadeOut)
                        Stepper(value: $fadeOutSeconds, in: 0.1...30, step: 0.5) {
                            Text("\(fadeOutSeconds, format: .number.precision(.fractionLength(1))) s").monospacedDigit()
                        }
                        .disabled(!fadeOut)
                    }
                }
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Trim", canRun: model.url != nil && model.duration > 0,
                   hint: "Add an audio file to get started.", action: start)
        }
        .task(id: runner.inputs.first) {
            await model.load(runner.inputs.first)
        }
        .onChange(of: runner.inputs) { runner.reset() }
        .onDisappear { model.stop() }
    }

    private var selectionSection: some View {
        ToolSection("Selection") {
            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    AudioWaveformView(peaks: model.peaks, selection: model.range, duration: model.duration,
                                      tint: ToolCategory.audio.tint)
                    if model.peaks.isEmpty {
                        HStack(spacing: 6) {
                            if model.isLoading { ProgressView().controlSize(.small) }
                            Text(model.isLoading ? "Reading audio…" : "No waveform available")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    GeometryReader { geometry in
                        if model.duration > 0 {
                            Rectangle().fill(Color.primary)
                                .frame(width: 2)
                                .offset(x: CGFloat(model.playhead / model.duration) * geometry.size.width - 1)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .frame(height: 70)
                .overlay {
                    // Click the waveform to move the playhead.
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard model.duration > 0, geometry.size.width > 0 else { return }
                                model.seek(min(max(Double(location.x / geometry.size.width), 0), 1) * model.duration)
                            }
                    }
                }
                .padding(.horizontal, 12)

                RangeSlider(range: $model.range, bounds: 0...model.duration, playhead: model.playhead,
                            tint: ToolCategory.audio.tint) { model.seek($0) }
            }

            HStack(spacing: 14) {
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .controlSize(.large)
                .disabled(!model.canPreview)
                .help(model.canPreview ? "Play the selection" : "Preview isn't available for this format")
                Text("\(TimeFormat.string(model.playhead, precise: true)) / \(TimeFormat.string(model.duration, precise: true))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                TimeField(label: "Start", seconds: lowerBinding, range: 0...model.duration)
                TimeField(label: "End", seconds: upperBinding, range: 0...model.duration)
            }
            Text("New length: \(TimeFormat.string(model.range.upperBound - model.range.lowerBound, precise: true))")
                .font(.callout).foregroundStyle(.secondary)
        }
        .disabled(runner.isRunning)
    }

    private var lowerBinding: Binding<Double> {
        Binding(get: { model.range.lowerBound }, set: { value in
            let lower = min(value, model.range.upperBound - 0.1)
            model.range = max(lower, 0)...model.range.upperBound
            model.seek(model.range.lowerBound)
        })
    }

    private var upperBinding: Binding<Double> {
        Binding(get: { model.range.upperBound }, set: { value in
            let upper = max(value, model.range.lowerBound + 0.1)
            model.range = model.range.lowerBound...min(upper, model.duration)
        })
    }

    private func start() {
        guard let input = runner.inputs.first else { return }
        model.stop()
        let start = model.range.lowerBound
        let length = model.range.upperBound - model.range.lowerBound
        let fadeIn = fadeIn ? min(fadeInSeconds, length) : 0
        let fadeOut = fadeOut ? min(fadeOutSeconds, length) : 0
        runner.start(title: tool.name) { context in
            context.setStatus("Trimming \(input.lastPathComponent)")
            let args = TrimAudioView.arguments(input: input, output: { ext in context.output(for: input, suffix: "trimmed", extension: ext) },
                                               start: start, length: length, fadeIn: fadeIn, fadeOut: fadeOut)
            try await FFmpeg.run(args, duration: length) { context.setProgress($0) }
        }
    }

    /// FFmpeg arguments for a trim. Re-encodes in the source format so fades and exact cut points work.
    nonisolated static func arguments(input: URL, output: (String) -> URL, start: Double, length: Double,
                                      fadeIn: Double, fadeOut: Double) -> [String] {
        let format = AudioOutputFormat.matching(extension: input.pathExtension) ?? .m4a
        let destination = output(format.fileExtension)
        var args = ["-ss", FFmpeg.timestamp(start), "-i", input.path, "-t", FFmpeg.timestamp(length), "-map", "0:a:0"]
        var filters: [String] = []
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(FFmpeg.timestamp(fadeIn))") }
        if fadeOut > 0 { filters.append("afade=t=out:st=\(FFmpeg.timestamp(max(length - fadeOut, 0))):d=\(FFmpeg.timestamp(fadeOut))") }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        args += format.highQualityArguments
        args += ["-map_metadata", "0", destination.path]
        return args
    }
}
