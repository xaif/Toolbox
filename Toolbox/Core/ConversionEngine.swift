import AppKit
import PDFKit
import Vision
import CoreText
import ImageIO

enum ConversionEngine {
    /// - Parameter reflowHTML: PDF → HTML keeps only the text instead of each page's layout.
    static func job(target: String, fixedEPUB: Bool = false, reflowHTML: Bool = false) -> ToolJob {
        .each(verb: "Converting") { input, context, progress in
            guard ConversionCatalog.targets(for: input).contains(target) else {
                throw ToolError.unsupported("\(input.lastPathComponent) can't be converted to \(target.uppercased()).")
            }
            switch ConversionCatalog.family(of: input) {
            case .image: try await image(input, target: target, context: context)
            case .audio, .video: try await media(input, target: target, context: context, progress: progress)
            case .subtitle:
                let cues = try Subtitles.load(from: input)
                guard let format = SubtitleFormat(rawValue: target) else { throw ToolError.unsupported(target) }
                try Subtitles.serialize(cues, as: format).write(to: context.output(for: input, extension: target), atomically: true, encoding: .utf8)
            case .archive: try await ArchiveEngine.convert(input, target: target, context: context)
            case .pdf: try await DocumentConverter.pdf(input, target: target, fixedEPUB: fixedEPUB, reflowHTML: reflowHTML, context: context)
            case .document, .ebook, .slides, .spreadsheet: try await DocumentConverter.convert(input, target: target, context: context)
            case nil: throw ToolError.unsupported("Unrecognized file format.")
            }
            progress(1)
        }
    }

    static func image(_ input: URL, target: String, context: JobContext) async throws {
        let scratch = try context.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        var readable = input
        if (try? ImageIOHelpers.source(for: input)) == nil {
            let decoded = scratch.appendingPathComponent("decoded.png")
            if input.pathExtension.lowercased() == "svg" {
                try await MainActor.run {
                    guard let image = NSImage(contentsOf: input),
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ToolError.unreadableInput(input) }
                    let rendered = try ImageIOHelpers.resize(cgImage, width: Int(image.size.width), height: Int(image.size.height))
                    guard let data = PDFOps.encode(rendered, as: .png, quality: 1, dpi: nil) else { throw ToolError.unreadableInput(input) }
                    try data.write(to: decoded)
                }
            } else {
                try await FFmpeg.run(["-i", input.path, "-frames:v", "1", decoded.path])
            }
            readable = decoded
        }
        let output = context.output(for: input, extension: target)
        if target == "pdf" {
            var layout = PDFImageLayout(); layout.pageSize = .fit
            try PDFOps.imagesToPDF([readable], layout: layout, to: output)
        } else if let format = ImageFormat.allCases.first(where: { $0.fileExtension == target }), ImageFormat.writable.contains(format) {
            try ImageIOHelpers.reencode(readable, to: output, format: format, quality: 0.9)
        } else if target == "webp" || target == "avif" {
            let png = scratch.appendingPathComponent("encode.png")
            try ImageIOHelpers.reencode(readable, to: png, format: .png)
            if target == "webp" {
                try await ProcessRunner.runChecked(Dependencies.require(.webp), arguments: ["-q", "90", png.path, "-o", output.path])
            } else {
                try await ProcessRunner.runChecked(Dependencies.require(.avif), arguments: ["--qcolor", "85", "--speed", "6", png.path, output.path])
            }
        } else { throw ToolError.unsupported("This Mac can't write \(target.uppercased()).") }
    }

    static func media(_ input: URL, target: String, context: JobContext, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await FFmpeg.probe(input)
        let output = context.output(for: input, extension: target)
        if let audio = AudioOutputFormat(rawValue: target) {
            guard info.hasAudio else { throw ToolError.failed("This file has no audio track.") }
            try await FFmpeg.run(["-i", input.path, "-map", "0:a:0", "-vn"] + audio.codecArguments(bitrate: 192) + [output.path], duration: info.duration, progress: progress)
        } else if target == "gif" {
            try await FFmpeg.run(["-i", input.path, "-filter_complex", "[0:v]fps=15,scale='min(960,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0", output.path], duration: info.duration, progress: progress)
        } else if let format = ConvertVideoView.Format(rawValue: target) {
            try await FFmpeg.run(ConvertVideoView.arguments(input: input, output: output, info: info, format: format, remux: true), duration: info.duration, progress: progress)
        } else { throw ToolError.unsupported(target) }
    }
}
