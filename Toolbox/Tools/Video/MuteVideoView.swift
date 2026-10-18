import SwiftUI
import UniformTypeIdentifiers

struct MuteVideoView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.videoInputs, actionTitle: "Mute", verb: "Muting", noun: "videos") {
            Text("The video is copied as-is without re-encoding, so quality is unchanged and it's fast.")
                .foregroundStyle(.secondary)
        } each: { input, context, progress in
            let info = try await FFmpeg.probe(input)
            guard info.hasVideo else { throw ToolError.failed("No video stream found.") }
            let output = context.output(for: input, suffix: "muted")
            try await FFmpeg.run(MuteVideoView.arguments(input: input, output: output),
                                 duration: info.duration, progress: progress)
        }
    }

    nonisolated static func arguments(input: URL, output: URL) -> [String] {
        // Keep video and subtitle streams; drop audio and data tracks (which MP4 often can't hold).
        ["-i", input.path, "-map", "0:v", "-map", "0:s?", "-c", "copy", "-an", "-dn"]
            + VideoEncoding.containerFlags(output.pathExtension.lowercased()) + [output.path]
    }
}
