import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

enum ExtendedMediaTools {
    static let video: [Tool] = [
        tool("video.split", "Split Video", "Split", .video, "film", "Choose split points and save every section as a separate clip."),
        tool("video.snapshots", "Video Snapshots", "Snapshots", .video, "camera", "Scrub a video and export full resolution PNG frames."),
        tool("video.redact", "Redact Video", "Redact", .video, "eye.slash", "Cover a sensitive area for all or part of a video."),
    ]
    static let audio: [Tool] = [
        tool("audio.compress", "Compress Audio", "Compress", .audio, "arrow.down.right.and.arrow.up.left", "Compress by quality, target file size or percentage."),
        tool("audio.normalize", "Normalize Audio", "Normalize", .audio, "waveform", "Normalize loudness to a chosen LUFS level."),
        tool("audio.channels", "Convert Audio Channels", "Channels", .audio, "hifispeaker.2", "Convert recordings to mono or stereo."),
        tool("audio.visualize", "Audio Visualizer", "Visualize", .audio, "waveform.path", "Make a waveform MP4 or a video with a static background image."),
        tool("audio.bleep", "Bleep Audio", "Bleep", .audio, "waveform.badge.minus", "Replace sensitive speech in selected time ranges with a bleep."),
    ]
    private static func tool(_ id: String, _ name: String, _ short: String, _ category: ToolCategory, _ symbol: String, _ summary: String) -> Tool {
        Tool(id: id, name: name, shortName: short, category: category, symbol: symbol, summary: summary,
             keywords: [short.lowercased(), "edit", "media"], requirements: [.ffmpeg], input: category == .video ? .videos : .audios) { ExtendedMediaView(tool: $0) }
    }
}

struct MediaEditOptions: Sendable {
    var times = "", ranges = ""
    var rect = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
    var blur = false
    var start = 0.0, end = 0.0
    var channels = 1
    var loudness = -16.0
    var frequency = 1000
    var format = AudioOutputFormat.mp3
    var bitrate = 128
    var compression = "bitrate"
    var targetMB = 10.0, reduction = 50.0
    var shape = "landscape"
    var background: URL?
}

enum MediaEditOps {
    static func time(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let value = text.contains(":") ? Subtitles.parseTimestamp(text) : Double(text)
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    static func times(_ raw: String, duration: Double) throws -> [Double] {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { time(String($0)) }
        guard values.count == parts.count, !values.isEmpty, values.allSatisfy({ $0 < duration }) else {
            throw ToolError.failed("Enter comma-separated times within the file, e.g. 5, 00:15, 30.5.")
        }
        return Array(Set(values)).sorted()
    }
    static func ranges(_ raw: String, duration: Double) throws -> [ClosedRange<Double>] {
        try raw.split(separator: ",", omittingEmptySubsequences: false).map { part in
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = time(String(bounds[0])), let end = time(String(bounds[1])), start < end, end <= duration else {
                throw ToolError.failed("Enter ranges within the file, e.g. 1-2.5, 00:10-00:12.")
            }
            return start...end
        }
    }
    static func job(id: String, options: MediaEditOptions) -> ToolJob {
        .each(verb: "Processing") { input, context, progress in
            let info = try await FFmpeg.probe(input)
            guard info.duration > 0 else { throw ToolError.failed("Couldn't read this file's duration.") }
            switch id {
            case "video.split":
                let split = try times(options.times, duration: info.duration).filter { $0 > 0 }
                guard !split.isEmpty else { throw ToolError.failed("Add a split point after the start of the video.") }
                let points = [0.0] + split + [info.duration]
                let folder = try context.outputFolder(named: input.deletingPathExtension().lastPathComponent + "-clips", nextTo: input)
                for index in 0..<(points.count-1) {
                    try Task.checkCancellation()
                    let length = points[index+1]-points[index]
                    let output = folder.appendingPathComponent(String(format: "Clip %03d.mp4", index+1))
                    try await FFmpeg.run(["-ss", FFmpeg.timestamp(points[index]), "-i", input.path, "-t", FFmpeg.timestamp(length), "-map", "0:v:0", "-map", "0:a?"] + VideoEncoding.h264(crf: 18) + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path], duration: length)
                    progress(Double(index+1)/Double(points.count-1))
                }
            case "video.snapshots":
                let snapshots = try times(options.times, duration: info.duration)
                let folder = try context.outputFolder(named: input.deletingPathExtension().lastPathComponent + "-frames", nextTo: input)
                for (index, time) in snapshots.enumerated() {
                    try Task.checkCancellation()
                    try await FFmpeg.run(["-ss", FFmpeg.timestamp(time), "-i", input.path, "-frames:v", "1", folder.appendingPathComponent(String(format: "Frame %03d.png", index+1)).path])
                    progress(Double(index+1)/Double(snapshots.count))
                }
            case "video.redact":
                let rect = options.rect
                guard rect.width > 0.005, rect.height > 0.005, options.start >= 0, options.start < info.duration,
                      options.end == 0 || (options.end > options.start && options.end <= info.duration) else { throw ToolError.failed("Choose a region and a time range inside the video.") }
                let w = max(2, Int(info.displaySize.width*rect.width)/2*2), h = max(2, Int(info.displaySize.height*rect.height)/2*2)
                let x = max(0, Int(info.displaySize.width*rect.minX)/2*2), y = max(0, Int(info.displaySize.height*rect.minY)/2*2)
                let enabled = "between(t,\(FFmpeg.timestamp(options.start)),\(FFmpeg.timestamp(options.end == 0 ? info.duration : options.end)))"
                let filter: String
                if options.blur {
                    filter = "[0:v]split[base][area];[area]crop=\(w):\(h):\(x):\(y),boxblur=\(max(1,min(w,h)/10)):3[blur];[base][blur]overlay=\(x):\(y):enable='\(enabled)'[v]"
                } else { filter = "[0:v]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill:enable='\(enabled)'[v]" }
                let output = context.output(for: input, suffix: "redacted", extension: "mp4")
                try await FFmpeg.run(["-i", input.path, "-filter_complex", filter, "-map", "[v]", "-map", "0:a?"] + VideoEncoding.h264(crf: 18) + VideoEncoding.audio(info, container: "mp4") + ["-movflags", "+faststart", output.path], duration: info.duration, progress: progress)
            case "audio.visualize":
                let size = options.shape == "portrait" ? "720x1280" : options.shape == "square" ? "1080x1080" : "1280x720"
                let output = context.output(for: input, suffix: "visualizer", extension: "mp4")
                var args: [String]
                if let background = options.background {
                    let dimensions = size.components(separatedBy: "x")
                    args = ["-loop", "1", "-i", background.path, "-i", input.path, "-vf", "scale=\(dimensions[0]):\(dimensions[1]):force_original_aspect_ratio=increase,crop=\(dimensions[0]):\(dimensions[1])", "-map", "0:v", "-map", "1:a:0", "-t", FFmpeg.timestamp(info.duration)]
                } else {
                    args = ["-i", input.path, "-filter_complex", "[0:a]showwaves=s=\(size):mode=cline:colors=0xff8800:rate=30,format=yuv420p[v]", "-map", "[v]", "-map", "0:a:0"]
                }
                try await FFmpeg.run(args + VideoEncoding.h264(crf: 20) + ["-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", output.path], duration: info.duration, progress: progress)
            default:
                guard info.hasAudio else { throw ToolError.failed("No audio track found.") }
                let output = context.output(for: input, suffix: String(id.split(separator: ".").last ?? "edited"), extension: options.format.fileExtension)
                var args = ["-i", input.path]
                if id == "audio.bleep" {
                    let intervals = try ranges(options.ranges, duration: info.duration)
                    let expression = intervals.map { "between(t,\(FFmpeg.timestamp($0.lowerBound)),\(FFmpeg.timestamp($0.upperBound)))" }.joined(separator: "+")
                    let filter = "[0:a:0]volume=0:enable='\(expression)'[clean];sine=frequency=\(options.frequency):sample_rate=48000:duration=\(FFmpeg.timestamp(info.duration)),volume=0:enable='not(\(expression))'[tone];[clean][tone]amix=inputs=2:duration=first:normalize=0[a]"
                    args += ["-filter_complex", filter, "-map", "[a]"]
                } else {
                    args += ["-map", "0:a:0", "-vn"]
                    if id == "audio.normalize" { args += ["-af", "loudnorm=I=\(options.loudness):TP=-1.5:LRA=11"] }
                    if id == "audio.channels" { args += ["-ac", String(options.channels)] }
                }
                var bitrate = options.bitrate
                if id == "audio.compress", options.compression != "bitrate" {
                    let bytes = options.compression == "target" ? options.targetMB*1_000_000 : Double(PDFOps.fileSize(input))*(1-options.reduction/100)
                    bitrate = Int(bytes*8/info.duration/1000*0.96)
                    guard bitrate >= 16 else { throw ToolError.failed("The target is too small for this recording. Increase the target size.") }
                    bitrate = min(320, bitrate)
                }
                try await FFmpeg.run(args + options.format.codecArguments(bitrate: bitrate) + [output.path], duration: info.duration, progress: progress)
            }
        }
    }
}

struct ExtendedMediaView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var options = MediaEditOptions()
    @State private var playhead = 0.0
    @State private var duration = 0.0
    @State private var frame: CGImage?
    @State private var player: AVPlayer?
    @State private var audioSelection = AudioTrimModel()
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    var body: some View {
        BatchToolView(tool: tool, accepts: tool.category == .video ? UTType.videoInputs : UTType.audioInputs,
                      actionTitle: tool.shortName, job: { MediaEditOps.job(id: tool.id, options: options) }) {
            if let first = runner.inputs.first {
                if tool.id == "video.redact", let frame {
                    ImageSelectionCanvas(image: frame, selection: $options.rect) { options.rect = $0 }.frame(maxHeight: 300)
                } else if tool.category == .video { VideoFramePreview(url: first, time: playhead) { _ in EmptyView() } }
                else if tool.id == "audio.bleep" {
                    AudioWaveformView(peaks: audioSelection.peaks, selection: audioSelection.range, duration: audioSelection.duration, tint: .orange).frame(height: 80)
                    RangeSlider(range: $audioSelection.range, bounds: 0...max(audioSelection.duration, 0.1), playhead: audioSelection.playhead) { audioSelection.seek($0) }
                    HStack {
                        Button(action: audioSelection.togglePlay) { Label(audioSelection.isPlaying ? "Pause" : "Preview Selection", systemImage: audioSelection.isPlaying ? "pause" : "play") }
                        Button("Add Bleep for Selection") {
                            options.ranges += (options.ranges.isEmpty ? "" : ", ") + FFmpeg.timestamp(audioSelection.range.lowerBound) + "-" + FFmpeg.timestamp(audioSelection.range.upperBound)
                        }
                    }
                } else if let player { PlayerView(player: player).frame(height: 64) }
                if tool.category == .video {
                    HStack {
                        Slider(value: $playhead, in: 0...max(duration-0.01, 0.01))
                        Text(FFmpeg.timestamp(playhead) + " s").monospacedDigit().frame(width: 80)
                        Button("−1 Frame") { playhead = max(0, playhead-1/30) }
                        Button("+1 Frame") { playhead = min(max(0,duration-0.01), playhead+1/30) }
                    }
                }
            }
            controls
        }
        .task(id: runner.inputs.first) {
            guard let input = runner.inputs.first else { frame = nil; duration = 0; return }
            duration = (try? await FFmpeg.probe(input).duration) ?? 0
            player?.pause(); player = AVPlayer(url: input)
            if tool.id == "audio.bleep" { await audioSelection.load(input) }
            playhead = 0; frame = await VideoFrameGrabber.frame(of: input)
        }
        .task(id: playhead) {
            if tool.id == "video.redact", let input = runner.inputs.first { frame = await VideoFrameGrabber.frame(of: input, at: playhead) }
        }
        .onDisappear { player?.pause(); audioSelection.stop() }
    }
    @ViewBuilder private var controls: some View {
        switch tool.id {
        case "video.split", "video.snapshots":
            TextField(tool.id == "video.split" ? "Split points" : "Snapshot times", text: $options.times, prompt: Text("5, 00:15, 30.5"))
            Button(tool.id == "video.split" ? "Add Split at Playhead" : "Add Snapshot at Playhead") {
                options.times += (options.times.isEmpty ? "" : ", ") + FFmpeg.timestamp(playhead)
            }
            Text("Times are seconds or mm:ss, separated by commas. Splits are re-encoded for accurate cut points. Snapshots retain the full video resolution.").font(.caption).foregroundStyle(.secondary)
        case "video.redact":
            Text("Drag on the frame to select a region. The region stays in the same position throughout the chosen range.")
            Toggle("Blur region", isOn: $options.blur)
            HStack { TextField("Start (seconds)", value: $options.start, format: .number); TextField("End (0 = end of video)", value: $options.end, format: .number) }
        case "audio.compress":
            Picker("Compress by", selection: $options.compression) { Text("Bitrate").tag("bitrate"); Text("Target size").tag("target"); Text("Percentage reduction").tag("percentage") }
            if options.compression == "target" { TextField("Target MB", value: $options.targetMB, format: .number) }
            if options.compression == "percentage" { HStack { Text("Reduce by \(Int(options.reduction))%"); Slider(value: $options.reduction, in: 1...95) } }
            Text("Target sizes are approximate; container overhead and encoder limits affect the result.").font(.caption).foregroundStyle(.secondary)
        case "audio.normalize":
            HStack { Text("Target loudness: \(Int(options.loudness)) LUFS"); Slider(value: $options.loudness, in: -30 ... -5, step: 1) }
        case "audio.channels":
            Picker("Channels", selection: $options.channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
            Text("Mono-to-stereo duplicates the recording in both channels.").font(.caption).foregroundStyle(.secondary)
        case "audio.visualize":
            Picker("Size", selection: $options.shape) { Text("Landscape").tag("landscape"); Text("Portrait").tag("portrait"); Text("Square").tag("square") }
            HStack {
                Button("Use Static Image…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK { options.background = panel.url } }
                if options.background != nil { Button("Use Waveform") { options.background = nil } }
            }
            if let background = options.background { Text(background.lastPathComponent) }
        case "audio.bleep":
            TextField("Bleep ranges", text: $options.ranges, prompt: Text("1-2.5, 00:10-00:12"))
            Stepper("Tone: \(options.frequency) Hz", value: $options.frequency, in: 200...2000, step: 100)
            Text("Each range replaces the original audio with a tone. Times are seconds or mm:ss.").font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
        if tool.category == .audio && tool.id != "audio.visualize" {
            Picker("Output format", selection: $options.format) { ForEach(AudioOutputFormat.allCases.filter { tool.id != "audio.compress" || $0.isLossy }) { Text($0.label).tag($0) } }
            if options.format.isLossy { Picker("Bitrate", selection: $options.bitrate) { ForEach(AudioOutputFormat.bitrates, id: \.self) { Text("\($0) kbps").tag($0) } } }
        }
    }
}
