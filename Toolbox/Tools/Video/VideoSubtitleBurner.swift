import AVFoundation
import AppKit
import QuartzCore

/// Burns captions into a video with AVFoundation and Core Animation.
/// (Homebrew's FFmpeg ships without libass, so its `subtitles` filter isn't available.)
enum VideoSubtitleBurner {
    struct Style: Sendable, Equatable {
        enum Size: String, CaseIterable, Identifiable, Sendable {
            case small, medium, large
            var id: Self { self }
            var label: String { rawValue.capitalized }
            /// Font size as a fraction of the video's shorter side.
            var factor: CGFloat {
                switch self {
                case .small: 0.045
                case .medium: 0.058
                case .large: 0.075
                }
            }
        }

        enum Position: String, CaseIterable, Identifiable, Sendable {
            case bottom, top
            var id: Self { self }
            var label: String { rawValue.capitalized }
        }

        var size = Size.medium
        var position = Position.bottom
        var background = true
    }

    /// Exports `input` (which AVFoundation must be able to read) to an MP4 at `output` with captions drawn on top.
    static func burn(
        _ input: URL,
        cues: [SubtitleCue],
        style: Style,
        to output: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError.failed("No video stream found.")
        }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)

        // Apply the track's rotation so portrait phone videos stay upright.
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(rotated.width).rounded(), height: abs(rotated.height).rounded())
        let upright = transform.concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))

        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layerConfiguration.setTransform(upright, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfiguration)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        for cue in cues where cue.end > cue.start {
            parent.addSublayer(captionLayer(for: cue, style: style, renderSize: renderSize))
        }
        let animationTool = AVVideoCompositionCoreAnimationTool(configuration: .init(
            postProcessingAsVideoLayer: videoLayer, containingLayer: parent))

        let fps = frameRate > 0 ? Double(frameRate) : 30
        let composition = AVVideoComposition(configuration: .init(
            animationTool: animationTool,
            frameDuration: CMTimeMakeWithSeconds(1 / fps, preferredTimescale: 60_000),
            instructions: [instruction],
            renderSize: renderSize))

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ToolError.failed("Couldn't start the video export.")
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state { progress?(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await session.export(to: output, as: .mp4)
        } onCancel: {
            session.cancelExport()
        }
        progress?(1)
    }

    /// One caption: a rounded box (optional) with centered text, visible only during the cue.
    static func captionLayer(for cue: SubtitleCue, style: Style, renderSize: CGSize) -> CALayer {
        let fontSize = (min(renderSize.width, renderSize.height) * style.size.factor).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        if !style.background {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
            shadow.shadowBlurRadius = max(fontSize * 0.12, 2)
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        let text = NSAttributedString(string: cue.text, attributes: attributes)
        let maxWidth = renderSize.width * 0.86
        let measured = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: min(ceil(measured.width) + 2, maxWidth), height: ceil(measured.height) + 2)
        let padding = CGSize(width: fontSize * 0.45, height: fontSize * 0.22)
        let box = CGSize(width: ceil(textSize.width + padding.width * 2), height: ceil(textSize.height + padding.height * 2))
        let margin = renderSize.height * 0.06
        // Core Animation's origin is bottom-left on macOS.
        let y = style.position == .bottom ? margin : renderSize.height - margin - box.height

        // CATextLayer doesn't draw during offscreen export, so the caption is pre-rendered into a bitmap.
        let container = CALayer()
        container.frame = CGRect(x: ((renderSize.width - box.width) / 2).rounded(), y: y.rounded(), width: box.width, height: box.height)
        container.contents = renderCaption(text, textSize: textSize, box: box, padding: padding,
                                           cornerRadius: style.background ? fontSize * 0.28 : nil)
        container.contentsGravity = .resize

        // Hidden by default; an animation holds opacity at 1 for exactly the cue's time range.
        container.opacity = 0
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        show.beginTime = cue.start > 0 ? cue.start : AVCoreAnimationBeginTimeAtZero
        show.duration = max(cue.end - max(cue.start, 0), 0.05)
        show.isRemovedOnCompletion = false
        show.fillMode = .removed
        container.add(show, forKey: "show")
        return container
    }

    /// Draws the optional rounded background and the centered text into an image of size `box`.
    private static func renderCaption(_ text: NSAttributedString, textSize: CGSize, box: CGSize,
                                      padding: CGSize, cornerRadius: CGFloat?) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let cornerRadius {
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: box), cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil))
            context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            context.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(with: CGRect(x: padding.width, y: padding.height, width: textSize.width, height: textSize.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
