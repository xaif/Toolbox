import AVFoundation
import SwiftUI

/// Loads a downsampled peak envelope for drawing a waveform.
enum AudioWaveformLoader {
    /// Returns `bins` peak values in 0...1. Tries AVFoundation first, then decodes with FFmpeg for
    /// formats AVFoundation can't read (Ogg, Opus, WebM…).
    static func peaks(for url: URL, bins: Int = 800) async -> [Float] {
        if let peaks = try? await readPeaks(url, bins: bins) { return peaks }
        guard Dependencies.locate(.ffmpeg) != nil else { return [] }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await FFmpeg.run(["-i", url.path, "-vn", "-ac", "1", "-ar", "8000", "-c:a", "pcm_s16le", temp.path])
            return try await readPeaks(temp, bins: bins)
        } catch {
            return []
        }
    }

    private static func readPeaks(_ url: URL, bins: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError.unreadableInput(url) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ToolError.unreadableInput(url) }

        let sampleRate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ToolError.unreadableInput(url) }

        let totalSamples = max(Int(duration * sampleRate), bins)
        let samplesPerBin = max(totalSamples / bins, 1)
        var peaks = [Float](repeating: 0, count: bins)
        var sampleIndex = 0

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in samples {
                let bin = min(sampleIndex / samplesPerBin, bins - 1)
                let value = abs(sample)
                if value > peaks[bin] { peaks[bin] = value }
                sampleIndex += 1
            }
        }
        guard reader.status != .failed else { throw reader.error ?? ToolError.unreadableInput(url) }
        let maximum = peaks.max() ?? 0
        return maximum > 0 ? peaks.map { min($0 / maximum, 1) } : peaks
    }
}

/// Draws a mirrored bar waveform, highlighting the selected range.
struct AudioWaveformView: View {
    let peaks: [Float]
    var selection: ClosedRange<Double>?
    var duration: Double
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barWidth = size.width / CGFloat(peaks.count)
            let mid = size.height / 2
            for (index, peak) in peaks.enumerated() {
                let x = CGFloat(index) * barWidth
                let height = max(CGFloat(peak) * size.height * 0.95, 1)
                let rect = CGRect(x: x, y: mid - height / 2, width: max(barWidth - 0.5, 0.5), height: height)
                var inside = true
                if let selection, duration > 0 {
                    let time = Double(index) / Double(peaks.count) * duration
                    inside = selection.contains(time)
                }
                context.fill(Path(rect), with: .color(inside ? tint : Color.secondary.opacity(0.35)))
            }
        }
    }
}
