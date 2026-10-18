import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Encoding helpers shared by the video tools.
enum VideoEncoding {
    /// Containers we can write without changing the user's chosen format.
    static let editableContainers: Set<String> = ["mp4", "mov", "m4v"]

    /// Keeps the input's container when it's MP4/MOV/M4V, otherwise falls back to MP4.
    static func outputExtension(for input: URL, keeping allowed: Set<String> = editableContainers) -> String {
        let ext = input.pathExtension.lowercased()
        return allowed.contains(ext) ? ext : "mp4"
    }

    /// High-quality H.264 settings that play everywhere.
    static func h264(crf: Int = 20, preset: String = "medium") -> [String] {
        ["-c:v", "libx264", "-preset", preset, "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
    }

    /// Copies the audio when the codec fits the container, otherwise re-encodes to AAC (or Opus for WebM).
    static func audio(_ info: MediaInfo, container: String, bitrate: String = "192k") -> [String] {
        guard info.hasAudio else { return ["-an"] }
        if isCompatible(audio: info.audioCodec, with: container) { return ["-c:a", "copy"] }
        return container == "webm" ? ["-c:a", "libopus", "-b:a", "128k"] : ["-c:a", "aac", "-b:a", bitrate]
    }

    /// `-movflags +faststart` for MP4-family outputs so they start playing before fully downloaded.
    static func containerFlags(_ container: String) -> [String] {
        ["mp4", "mov", "m4v"].contains(container) ? ["-movflags", "+faststart"] : []
    }

    static func isCompatible(video codec: String?, with container: String) -> Bool {
        guard let codec else { return false }
        switch container {
        case "mp4", "m4v": return ["h264", "hevc", "av1", "mpeg4", "vp9"].contains(codec)
        case "mov": return ["h264", "hevc", "prores", "mpeg4", "mjpeg"].contains(codec)
        case "webm": return ["vp8", "vp9", "av1"].contains(codec)
        case "mkv": return true
        case "avi": return ["mpeg4", "h264", "mjpeg", "msmpeg4v3", "msmpeg4v2"].contains(codec)
        default: return false
        }
    }

    static func isCompatible(audio codec: String?, with container: String) -> Bool {
        guard let codec else { return false }
        switch container {
        case "mp4", "m4v": return ["aac", "mp3", "alac", "ac3", "eac3", "opus", "flac"].contains(codec)
        case "mov": return ["aac", "mp3", "alac", "ac3", "pcm_s16le", "pcm_s24le", "pcm_f32le"].contains(codec)
        case "webm": return ["opus", "vorbis"].contains(codec)
        case "mkv": return true
        case "avi": return ["mp3", "ac3", "pcm_s16le"].contains(codec)
        default: return false
        }
    }

    /// `atempo` only accepts 0.5…2.0, so larger changes are chained, e.g. 4× → `atempo=2,atempo=2`.
    static func atempoChain(_ speed: Double) -> String {
        var remaining = speed
        var factors: [Double] = []
        while remaining > 2.0 { factors.append(2.0); remaining /= 2.0 }
        while remaining < 0.5 { factors.append(0.5); remaining /= 0.5 }
        factors.append(remaining)
        return factors.map { "atempo=\(format($0))" }.joined(separator: ",")
    }

    /// Compact decimal for filter arguments ("2", "0.75", "1.333333").
    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Rounds down to an even number (H.264 with yuv420p requires even dimensions).
    static func even(_ value: Double) -> Int {
        max(2, Int(value) / 2 * 2)
    }

    /// True when AVFoundation can decode the file (needed for previews and native processing).
    static func isPlayableByAVFoundation(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        return true
    }

    /// Returns a URL AVFoundation can read: the input itself, or an H.264 MP4 transcode in `folder`.
    static func avFoundationReadable(_ input: URL, in folder: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if await isPlayableByAVFoundation(input) { return input }
        let info = try await FFmpeg.probe(input)
        let output = folder.appendingPathComponent("source.mp4")
        var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?"] + h264(crf: 17, preset: "fast")
        args += info.hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
        try await FFmpeg.run(args + [output.path], duration: info.duration, progress: progress)
        return output
    }
}

/// Grabs a single frame for previews. Uses AVFoundation, falling back to FFmpeg for other formats.
enum VideoFrameGrabber {
    static func frame(of url: URL, at seconds: Double = 0, maxSize: CGFloat = 1280) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
            return result.image
        }
        guard Dependencies.locate(.ffmpeg) != nil else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await FFmpeg.run(["-ss", FFmpeg.timestamp(seconds), "-i", url.path, "-frames:v", "1",
                                  "-vf", "scale='min(\(Int(maxSize)),iw)':-2", temp.path])
        } catch {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(temp as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Shows a still frame from a video with an optional overlay (crop guides, caption sample…).
struct VideoFramePreview<Overlay: View>: View {
    let url: URL?
    var time: Double = 0
    var height: CGFloat = 260
    @ViewBuilder var overlay: (CGSize) -> Overlay

    @State private var image: CGImage?
    @State private var loading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.85))
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { overlay($0.size) } }
                    .aspectRatio(size, contentMode: .fit)
                    .padding(8)
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Text("Preview unavailable").foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .task(id: "\(url?.path ?? "")-\(time)") {
            guard let url else { image = nil; return }
            loading = true
            image = await VideoFrameGrabber.frame(of: url, at: time)
            loading = false
        }
    }
}

/// Video preview with a range selector, used by Trim Video and Video to GIF.
struct VideoTrimEditor: View {
    let url: URL
    @Binding var range: ClosedRange<Double>
    @Binding var duration: Double
    var maximumLength: Double?

    @State private var player = AVPlayer()
    @State private var playhead: Double = 0
    @State private var observer: Any?
    @State private var canPreview = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if canPreview {
                    PlayerView(player: player)
                } else {
                    ZStack {
                        Color.black.opacity(0.85)
                        Text("Preview isn't available for this format. You can still pick times below.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if duration > 0 {
                RangeSlider(range: $range, bounds: 0...duration, playhead: canPreview ? playhead : nil,
                            minimumLength: min(0.1, duration)) { time in
                    seek(to: time)
                }
                HStack(spacing: 16) {
                    TimeField(label: "Start", seconds: lowerBinding, range: 0...duration)
                    TimeField(label: "End", seconds: upperBinding, range: 0...duration)
                    Spacer()
                    Text("Length \(TimeFormat.string(range.upperBound - range.lowerBound, precise: true))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if canPreview {
                    HStack {
                        Button { range = min(playhead, range.upperBound - 0.1)...range.upperBound } label: {
                            Label("Set Start", systemImage: "arrow.right.to.line")
                        }
                        Button { range = range.lowerBound...max(playhead, range.lowerBound + 0.1) } label: {
                            Label("Set End", systemImage: "arrow.left.to.line")
                        }
                        .help("Use the current playhead position")
                        Spacer()
                        Button(action: playSelection) {
                            Label("Play Selection", systemImage: "play.fill")
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { await load() }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
        }
    }

    private var lowerBinding: Binding<Double> {
        Binding(get: { range.lowerBound }, set: { range = min($0, range.upperBound - 0.1)...range.upperBound })
    }

    private var upperBinding: Binding<Double> {
        Binding(get: { range.upperBound }, set: { range = range.lowerBound...max($0, range.lowerBound + 0.1) })
    }

    private func load() async {
        loadError = nil
        duration = 0
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil

        if await VideoEncoding.isPlayableByAVFoundation(url) {
            canPreview = true
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            let seconds = (try? await item.asset.load(.duration).seconds) ?? 0
            duration = seconds.isFinite ? seconds : 0
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
                playhead = time.seconds
                if player.rate > 0, playhead >= range.upperBound {
                    player.pause()
                }
            }
        } else {
            canPreview = false
            player.replaceCurrentItem(with: nil)
            duration = (try? await FFmpeg.probe(url).duration) ?? 0
        }
        if duration <= 0 {
            loadError = "Couldn't read the length of this video."
            return
        }
        let end = maximumLength.map { min($0, duration) } ?? duration
        range = 0...end
    }

    private func seek(to time: Double) {
        guard canPreview else { return }
        player.pause()
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playSelection() {
        player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }
}

/// A one-file picker for custom tool layouts (e.g. the audio track in Replace Audio).
struct VideoSingleFilePicker: View {
    let title: String
    @Binding var file: URL?
    let accepts: [UTType]
    var noun = "file"

    var body: some View {
        FileListInput(files: Binding(get: { file.map { [$0] } ?? [] }, set: { file = $0.first }),
                      accepts: accepts, allowsMultiple: false, title: title, noun: noun)
    }
}
