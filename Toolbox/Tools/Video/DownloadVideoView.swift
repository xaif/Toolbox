import SwiftUI

struct DownloadVideoView: View {
    let tool: Tool

    enum Quality: String, CaseIterable, Identifiable {
        case best, p1080, p720, audio
        var id: Self { self }
        var label: String {
            switch self {
            case .best: "Best available"
            case .p1080: "Up to 1080p"
            case .p720: "Up to 720p"
            case .audio: "Audio only (MP3)"
            }
        }
    }

    @State private var runner: JobRunner
    @State private var text = ""
    @State private var quality = Quality.best
    @State private var compatible = true
    @State private var playlists = false
    @State private var updating = false
    @State private var updateMessage: String?

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var urls: [String] { Self.parseURLs(text) }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Links").font(.headline)
                        if !urls.isEmpty {
                            Text("\(urls.count)").font(.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer()
                        Button("Paste") {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                text = text.isEmpty ? pasted : text + "\n" + pasted
                            }
                        }
                    }
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 110, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Paste one or more video links, one per line")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
                }

                ToolSection("Options", footnote: "Only download videos you have the right to save. Downloads are fetched directly by yt-dlp on your Mac.") {
                    Picker("Quality", selection: $quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    if quality != .audio {
                        Toggle("Prefer formats that play in QuickTime (H.264)", isOn: $compatible)
                    }
                    Toggle("Download whole playlists", isOn: $playlists)
                    HStack(spacing: 8) {
                        Button("Update yt-dlp", action: updateYtDlp)
                            .disabled(updating || Dependencies.homebrewURL == nil)
                        if updating { ProgressView().controlSize(.small) }
                        Text(updateMessage ?? "Sites change often. If downloads fail, update yt-dlp first.")
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .disabled(runner.isRunning)
        } footer: {
            JobBar(runner: runner, actionTitle: "Download", canRun: !urls.isEmpty, hint: "Paste a link to get started.", action: start)
        }
    }

    nonisolated static func parseURLs(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .filter { seen.insert($0).inserted }
    }

    private func start() {
        let urls = urls
        let options = Options(quality: quality, compatible: compatible, playlists: playlists)
        runner.start(title: tool.name) { context in
            guard let folder = context.stagingFolder else { return }
            let ytdlp = try Dependencies.require(.ytdlp)
            let ffmpeg = try Dependencies.require(.ffmpeg)
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let base = Double(index) / Double(urls.count)
                let share = 1 / Double(urls.count)
                let prefix = urls.count > 1 ? "\(index + 1) of \(urls.count): " : ""
                context.setStatus(prefix + "Fetching \(url)")
                context.setProgress(base)
                let tracker = DownloadProgressTracker()
                try await ProcessRunner.runChecked(
                    ytdlp,
                    arguments: DownloadVideoView.arguments(url: url, folder: folder, ffmpeg: ffmpeg, options: options),
                    onStdoutLine: { line in
                        if let update = tracker.handle(line) {
                            if let status = update.status { context.setStatus(prefix + status) }
                            if let fraction = update.fraction { context.setProgress(base + fraction * share) }
                        }
                    })
            }
            // yt-dlp leaves nothing else behind on success, but be safe about partial files.
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in leftovers where ["part", "ytdl", "temp"].contains(file.pathExtension) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Runs `brew upgrade yt-dlp`. Outdated yt-dlp is the usual cause of failed downloads.
    private func updateYtDlp() {
        guard let brew = Dependencies.homebrewURL else { return }
        updating = true
        updateMessage = "Updating yt-dlp…"
        Task {
            do {
                try await ProcessRunner.runChecked(brew, arguments: ["upgrade", "yt-dlp"])
                let version = try? await ProcessRunner.run(try Dependencies.require(.ytdlp), arguments: ["--version"])
                let number = version?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                updateMessage = number.isEmpty ? "yt-dlp is up to date." : "yt-dlp is up to date (\(number))."
            } catch {
                updateMessage = "Couldn't update: \(error.localizedDescription)"
            }
            Dependencies.shared.refresh()
            updating = false
        }
    }

    struct Options {
        var quality: Quality
        var compatible: Bool
        var playlists: Bool
    }

    nonisolated static let progressPrefix = "TBXPROGRESS"

    nonisolated static func arguments(url: String, folder: URL, ffmpeg: URL, options: Options) -> [String] {
        var args = [
            "--ignore-config", "--newline", "--no-color", "--no-mtime", "--no-update",
            "--ffmpeg-location", ffmpeg.path,
            "-P", folder.path,
            "-o", "%(title).150B [%(id)s].%(ext)s",
            "--progress-template", "download:\(progressPrefix) %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s",
            options.playlists ? "--yes-playlist" : "--no-playlist",
        ]
        switch options.quality {
        case .audio:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .best, .p1080, .p720:
            let limit = options.quality == .p1080 ? "[height<=1080]" : options.quality == .p720 ? "[height<=720]" : ""
            args += ["-f", "bv*\(limit)+ba/b\(limit)/b"]
            if options.compatible { args += ["-S", "vcodec:h264,res,acodec:m4a"] }
            args += ["--merge-output-format", "mp4"]
        }
        return args + ["--", url]
    }
}

/// Parses yt-dlp's output into progress and status updates. A video often arrives as separate
/// video and audio parts that each report 0–100%; yt-dlp announces the parts up front
/// ("Downloading 1 format(s): 137+140"), so progress is spread across them.
final class DownloadProgressTracker: @unchecked Sendable {
    struct Update {
        var fraction: Double?
        var status: String?
    }

    private let lock = NSLock()
    private var expectedParts = 1
    private var part = 0
    private var currentName = ""

    func handle(_ line: String) -> Update? {
        lock.lock(); defer { lock.unlock() }
        if line.hasPrefix(DownloadVideoView.progressPrefix) {
            let fields = line.split(separator: " ").dropFirst().map { Double($0) }
            guard fields.count == 3, let downloaded = fields[0] else { return nil }
            guard let total = fields[1] ?? fields[2], total > 0 else { return nil }
            let fraction = min(downloaded / total, 1)
            let parts = max(part, 1)
            let expected = max(parts, expectedParts)
            let overall = (Double(parts - 1) + fraction) / Double(expected)
            let percent = Int(fraction * 100)
            return Update(fraction: min(overall, 0.97), status: "Downloading \(currentName) (\(percent)%)")
        }
        if line.hasPrefix("[info]"), let range = line.range(of: "format(s): ") {
            // A new item (also once per playlist entry): reset the part counter.
            expectedParts = max(line[range.upperBound...].split(separator: "+").count, 1)
            part = 0
            return Update(fraction: 0, status: nil)
        }
        if line.hasPrefix("[download] Destination:") {
            part += 1
            currentName = URL(fileURLWithPath: String(line.dropFirst("[download] Destination:".count))
                .trimmingCharacters(in: .whitespaces)).lastPathComponent
            return Update(fraction: nil, status: "Downloading \(currentName)")
        }
        if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoRemuxer]") {
            return Update(fraction: 0.98, status: "Merging video and audio…")
        }
        if line.hasPrefix("[ExtractAudio]") {
            return Update(fraction: 0.98, status: "Converting to MP3…")
        }
        if line.contains("has already been downloaded") {
            return Update(fraction: 1, status: "Already downloaded")
        }
        return nil
    }
}
