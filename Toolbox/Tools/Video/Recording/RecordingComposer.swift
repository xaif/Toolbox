import AVFoundation
import AppKit
import QuartzCore

// Pure AVFoundation editing pipeline for screen recordings: joins recorded segments, trims,
// applies smooth auto-zoom on clicks and burns in captions. Has no dependencies on the rest of
// the app so it can be exercised from a command-line harness.

/// A mouse click during recording. `time` is on the joined recording's timeline (seconds);
/// `x`/`y` are normalized to the captured area with a top-left origin.
struct RecordingClick: Hashable, Sendable {
    var time: Double
    var x: Double
    var y: Double
}

/// A caption to burn into the exported video. Times are on the joined recording's timeline.
struct RecordingCaption: Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct RecordingZoomSettings: Hashable, Sendable {
    var enabled = true
    /// Magnification while zoomed in.
    var scale = 1.8
    /// Seconds to ease in; the zoom completes as the click happens.
    var easeIn = 0.6
    /// Seconds to stay zoomed after the last click of a group.
    var hold = 1.6
    /// Seconds to ease back out to the full frame.
    var easeOut = 0.7
    /// Seconds used to pan between consecutive clicks while zoomed.
    var pan = 0.5
}

enum RecordingExportResolution: String, CaseIterable, Identifiable, Sendable {
    case original, p1080

    var id: String { rawValue }
    var label: String { self == .original ? "Original" : "1080p" }
}

/// A zoom state at a point in time: magnification and the normalized point to keep centered.
struct RecordingZoomKeyframe: Hashable, Sendable {
    var time: Double
    var scale: Double
    var x: Double
    var y: Double
}

enum RecordingComposer {
    // MARK: Composition

    /// Joins segment files end to end. Returns the composition and its video track.
    static func makeComposition(segments: [URL]) async throws -> (AVMutableComposition, AVMutableCompositionTrack, CGSize) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingComposerError.failed("Couldn't create a video track.")
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        var naturalSize = CGSize.zero

        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0, let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if naturalSize == .zero {
                let (size, transform) = try await sourceVideo.load(.naturalSize, .preferredTransform)
                videoTrack.preferredTransform = transform
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                naturalSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
            for (index, track) in sourceAudio.enumerated() {
                if index >= audioTracks.count,
                   let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    audioTracks.append(added)
                }
                guard index < audioTracks.count else { continue }
                let trackRange = try await track.load(.timeRange)
                let clipped = CMTimeRangeGetIntersection(trackRange, otherRange: range)
                if clipped.duration.seconds > 0 {
                    try audioTracks[index].insertTimeRange(clipped, of: track, at: cursor + clipped.start)
                }
            }
            cursor = cursor + duration
        }
        guard naturalSize != .zero else { throw RecordingComposerError.failed("The recording is empty.") }
        return (composition, videoTrack, naturalSize)
    }

    // MARK: Zoom

    /// Turns clicks into zoom keyframes. Clicks close together form one group that stays zoomed
    /// and pans from click to click; isolated clicks zoom in, hold, then zoom out.
    static func zoomKeyframes(clicks: [RecordingClick], duration: Double, settings: RecordingZoomSettings) -> [RecordingZoomKeyframe] {
        guard settings.enabled, settings.scale > 1.01, duration > 0 else { return [] }
        let sorted = clicks.filter { $0.time >= 0 && $0.time <= duration }.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return [] }

        // Group clicks that happen before the previous zoom would have finished zooming out.
        var groups: [[RecordingClick]] = []
        for click in sorted {
            if let last = groups.last?.last, click.time - last.time <= settings.hold + settings.easeOut + settings.easeIn {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var frames: [RecordingZoomKeyframe] = []
        func add(_ time: Double, _ scale: Double, _ x: Double, _ y: Double) {
            let t = min(max(time, 0), duration)
            if let last = frames.last, t <= last.time + 0.001 {
                // Same instant (or clamped earlier): the newest state wins.
                frames[frames.count - 1] = RecordingZoomKeyframe(time: last.time, scale: scale, x: x, y: y)
                return
            }
            frames.append(RecordingZoomKeyframe(time: t, scale: scale, x: x, y: y))
        }

        for group in groups {
            let first = group[0]
            let start = max(first.time - settings.easeIn, frames.last?.time ?? 0)
            add(start, 1, first.x, first.y)
            add(first.time, settings.scale, first.x, first.y)
            for (previous, click) in zip(group, group.dropFirst()) {
                let panStart = max(click.time - settings.pan, previous.time)
                add(panStart, settings.scale, previous.x, previous.y)
                add(click.time, settings.scale, click.x, click.y)
            }
            let last = group[group.count - 1]
            add(last.time + settings.hold, settings.scale, last.x, last.y)
            add(last.time + settings.hold + settings.easeOut, 1, last.x, last.y)
        }
        return frames
    }

    /// Transform that shows the zoomed region of a `source`-sized frame scaled into `render`.
    static func zoomTransform(scale: Double, x: Double, y: Double, source: CGSize, render: CGSize) -> CGAffineTransform {
        let base = render.width / source.width
        let zoom = CGFloat(max(scale, 1))
        let visible = CGSize(width: source.width / zoom, height: source.height / zoom)
        let originX = min(max(CGFloat(x) * source.width - visible.width / 2, 0), source.width - visible.width)
        let originY = min(max(CGFloat(y) * source.height - visible.height / 2, 0), source.height - visible.height)
        let factor = zoom * base
        return CGAffineTransform(a: factor, b: 0, c: 0, d: factor, tx: -factor * originX, ty: -factor * originY)
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: Video composition

    /// Builds the video composition for preview or export.
    /// - Parameters:
    ///   - captions: Burned in with Core Animation. Only valid for export, not AVPlayer playback.
    static func videoComposition(
        videoTrack: AVCompositionTrack,
        duration: Double,
        sourceSize: CGSize,
        renderSize: CGSize,
        frameRate: Double = 60,
        keyframes: [RecordingZoomKeyframe],
        captions: [RecordingCaption] = []
    ) -> AVVideoComposition {
        let timescale: CMTimeScale = 600
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

        var layer = AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
        let preferred = videoTrack.preferredTransform
        func transform(_ scale: Double, _ x: Double, _ y: Double) -> CGAffineTransform {
            preferred.concatenating(zoomTransform(scale: scale, x: x, y: y, source: sourceSize, render: renderSize))
        }

        layer.setTransform(transform(1, 0.5, 0.5), at: .zero)
        for (from, to) in zip(keyframes, keyframes.dropFirst()) {
            let span = to.time - from.time
            guard span > 0.001 else { continue }
            if from.scale == to.scale && from.x == to.x && from.y == to.y {
                layer.setTransform(transform(from.scale, from.x, from.y), at: time(from.time))
                continue
            }
            // Linear ramps between eased sub-steps approximate an ease-in-out curve.
            let steps = max(Int(span / 0.05), 4)
            for step in 0..<steps {
                let f0 = ease(Double(step) / Double(steps))
                let f1 = ease(Double(step + 1) / Double(steps))
                func state(_ f: Double) -> CGAffineTransform {
                    transform(from.scale + (to.scale - from.scale) * f,
                              from.x + (to.x - from.x) * f,
                              from.y + (to.y - from.y) * f)
                }
                let start = from.time + span * Double(step) / Double(steps)
                let end = from.time + span * Double(step + 1) / Double(steps)
                layer.addTransformRamp(.init(timeRange: CMTimeRange(start: time(start), end: time(end)),
                                             start: state(f0), end: state(f1)))
            }
        }
        if let last = keyframes.last {
            layer.setTransform(transform(last.scale, last.x, last.y), at: time(last.time))
        }

        let instruction = AVVideoCompositionInstruction(configuration: .init(
            backgroundColor: CGColor(gray: 0, alpha: 1),
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: time(duration))))

        var configuration = AVVideoComposition.Configuration(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 1))),
            instructions: [instruction],
            renderSize: renderSize)
        if !captions.isEmpty {
            configuration.animationTool = captionTool(captions: captions, renderSize: renderSize)
        }
        return AVVideoComposition(configuration: configuration)
    }

    /// Core Animation layers that show each caption at the bottom of the frame during its time range.
    static func captionTool(captions: [RecordingCaption], renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let fontSize = max(renderSize.height * 0.042, 14)
        for caption in captions where caption.end > caption.start {
            guard let image = captionImage(caption.text, fontSize: fontSize, maxWidth: renderSize.width * 0.8) else { continue }
            // Layer geometry here has a bottom-left origin.
            let box = CALayer()
            box.frame = CGRect(x: ((renderSize.width - CGFloat(image.width)) / 2).rounded(),
                               y: (renderSize.height * 0.06).rounded(),
                               width: CGFloat(image.width), height: CGFloat(image.height))
            box.contents = image
            box.opacity = 0

            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + caption.start
            show.duration = caption.end - caption.start
            show.isRemovedOnCompletion = true
            show.fillMode = .removed
            box.add(show, forKey: "show")
            parent.addSublayer(box)
        }
        return AVVideoCompositionCoreAnimationTool(configuration: .init(postProcessingAsVideoLayer: video, containingLayer: parent))
    }

    /// Renders a caption (rounded translucent box with centered white text) using Core Text.
    /// Pre-rendering avoids CATextLayer, whose contents never get drawn when the layer tree is
    /// built off the main thread.
    static func captionImage(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeMutableBytes(of: &alignment) { bytes -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let paddingX = (fontSize * 0.6).rounded()
        let paddingY = (fontSize * 0.3).rounded()
        let textSize = CGSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height) + 2)
        let width = Int(textSize.width + paddingX * 2)
        let height = Int(textSize.height + paddingY * 2)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: fontSize * 0.35, cornerHeight: fontSize * 0.35, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.68))
        context.fillPath()
        let textRect = CGRect(x: paddingX, y: paddingY, width: textSize.width, height: textSize.height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    // MARK: Export

    static func renderSize(for source: CGSize, resolution: RecordingExportResolution) -> CGSize {
        var size = source
        if resolution == .p1080 {
            let scale = min(1, 1920 / max(source.width, source.height), 1080 / min(source.width, source.height))
            size = CGSize(width: source.width * scale, height: source.height * scale)
        }
        return CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    /// Joins, trims, zooms, captions and encodes a recording.
    static func export(
        segments: [URL],
        clicks: [RecordingClick],
        trim: ClosedRange<Double>?,
        zoom: RecordingZoomSettings,
        captions: [RecordingCaption],
        resolution: RecordingExportResolution,
        fileType: AVFileType,
        to output: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let (composition, videoTrack, sourceSize) = try await makeComposition(segments: segments)
        let fullDuration = try await composition.load(.duration).seconds

        // Trim by removing the tail first, then the head, and shift clicks/captions accordingly.
        var offset = 0.0
        if let trim {
            let lower = min(max(trim.lowerBound, 0), fullDuration)
            let upper = min(max(trim.upperBound, lower), fullDuration)
            if upper < fullDuration - 0.01 {
                composition.removeTimeRange(CMTimeRange(start: CMTime(seconds: upper, preferredTimescale: 600),
                                                        end: CMTime(seconds: fullDuration, preferredTimescale: 600)))
            }
            if lower > 0.01 {
                composition.removeTimeRange(CMTimeRange(start: .zero, end: CMTime(seconds: lower, preferredTimescale: 600)))
                offset = lower
            }
        }
        let duration = try await composition.load(.duration).seconds
        guard duration > 0.05 else { throw RecordingComposerError.failed("The trimmed recording is empty.") }

        let shiftedClicks = clicks.map { RecordingClick(time: $0.time - offset, x: $0.x, y: $0.y) }
        let shiftedCaptions = captions.compactMap { caption -> RecordingCaption? in
            let start = max(caption.start - offset, 0)
            let end = min(caption.end - offset, duration)
            return end > start + 0.05 ? RecordingCaption(start: start, end: end, text: caption.text) : nil
        }
        let render = renderSize(for: sourceSize, resolution: resolution)
        let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let keyframes = zoomKeyframes(clicks: shiftedClicks, duration: duration, settings: zoom)
        let videoComposition = videoComposition(
            videoTrack: videoTrack, duration: duration, sourceSize: sourceSize, renderSize: render,
            frameRate: frameRate > 1 ? min(frameRate, 60) : 30, keyframes: keyframes, captions: shiftedCaptions)

        let preset = max(render.width, render.height) > 4096 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RecordingComposerError.failed("Couldn't start the export.")
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let report) = state { progress?(report.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: fileType)
        progress?(1)
    }

    /// Writes the composition's audio to an .m4a file, e.g. for transcription.
    static func exportAudio(segments: [URL], to output: URL) async throws {
        let (composition, _, _) = try await makeComposition(segments: segments)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw RecordingComposerError.failed("This recording has no audio to caption.")
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingComposerError.failed("Couldn't read the recording's audio.")
        }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .m4a)
    }
}

enum RecordingComposerError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
