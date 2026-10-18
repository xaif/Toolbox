import SwiftUI
import UniformTypeIdentifiers

struct MergeVideosView: View {
    let tool: Tool

    enum Size: Int, CaseIterable, Identifiable {
        case first = 0, p1080 = 1080, p720 = 720
        var id: Self { self }
        var label: String {
            switch self {
            case .first: "Match the first clip"
            case .p1080: "1080p"
            case .p720: "720p"
            }
        }
    }

    @State private var size = Size.first

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, reorderable: true, minimumFiles: 2,
                      actionTitle: "Merge", noun: "videos") {
            Picker("Output size", selection: $size) {
                ForEach(Size.allCases) { Text($0.label).tag($0) }
            }
            Text("Drag clips to set their order. Clips with a different shape are letterboxed, never stretched.")
                .font(.callout).foregroundStyle(.secondary)
        } all: { [size] inputs, context in
            context.setStatus("Reading clips…")
            var infos: [MediaInfo] = []
            for input in inputs {
                let info = try await FFmpeg.probe(input)
                guard info.hasVideo else { throw ToolError.failed("“\(input.lastPathComponent)” has no video.") }
                infos.append(info)
            }
            let first = infos[0]
            let firstSize = first.displaySize
            let (width, height) = MergeVideosView.outputSize(first: firstSize, target: size.rawValue)
            let fps = first.frameRate > 1 ? min(first.frameRate, 60) : 30
            let total = infos.reduce(0) { $0 + $1.duration }

            let name = inputs[0].deletingPathExtension().lastPathComponent + " merged"
            let output = context.output(named: name, extension: "mp4")
            let args = MergeVideosView.arguments(inputs: inputs, infos: infos, width: width, height: height,
                                                 fps: fps, output: output)
            context.setStatus("Merging \(inputs.count) clips…")
            try await FFmpeg.run(args, duration: total) { context.setProgress($0) }
        }
    }

    nonisolated static func outputSize(first: CGSize, target: Int) -> (Int, Int) {
        guard target > 0, first.width > 0, first.height > 0 else {
            return (VideoEncoding.even(first.width), VideoEncoding.even(first.height))
        }
        let shortSide = min(first.width, first.height)
        let scale = Double(target) / shortSide
        return (VideoEncoding.even(first.width * scale), VideoEncoding.even(first.height * scale))
    }

    nonisolated static func arguments(inputs: [URL], infos: [MediaInfo], width: Int, height: Int, fps: Double, output: URL) -> [String] {
        var args: [String] = []
        for input in inputs { args += ["-i", input.path] }

        // Clips without audio get a silent track so the concat filter sees matching streams.
        var silentIndex: [Int: Int] = [:]
        var nextInput = inputs.count
        for (index, info) in infos.enumerated() where !info.hasAudio {
            args += ["-f", "lavfi", "-t", FFmpeg.timestamp(max(info.duration, 0.1)),
                     "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
            silentIndex[index] = nextInput
            nextInput += 1
        }

        let rate = VideoEncoding.format(fps)
        var graph: [String] = []
        var concatInputs = ""
        for index in inputs.indices {
            graph.append("[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(rate),format=yuv420p[v\(index)]")
            let audioSource = silentIndex[index].map { "[\($0):a]" } ?? "[\(index):a:0]"
            graph.append("\(audioSource)aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]")
            concatInputs += "[v\(index)][a\(index)]"
        }
        graph.append("\(concatInputs)concat=n=\(inputs.count):v=1:a=1[v][a]")

        args += ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]", "-map", "[a]"]
        args += VideoEncoding.h264(crf: 20) + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path]
        return args
    }
}
