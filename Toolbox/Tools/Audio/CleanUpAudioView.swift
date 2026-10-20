import SwiftUI
import UniformTypeIdentifiers

/// Noise removal and level evening with FFmpeg's FFT denoiser, de-clicker, de-esser and loudness normalizer.
///
/// The denoiser adapts to each file: a quick analysis pass measures the background noise floor
/// (the quietest moments) and the overall level, and the FFT denoiser's threshold is set from those.
struct CleanUpAudioView: View {
    let tool: Tool

    enum Strength: String, CaseIterable, Identifiable {
        case light, medium, strong
        var id: Self { self }
        var label: String { rawValue.capitalized }
        /// afftdn noise reduction in dB.
        var reduction: Int {
            switch self {
            case .light: 12
            case .medium: 24
            case .strong: 40
            }
        }
        /// How far above the measured noise floor the denoiser threshold sits, in dB.
        var margin: Double {
            switch self {
            case .light: 10
            case .medium: 18
            case .strong: 25
            }
        }
        /// Threshold used when the file couldn't be analyzed.
        var fallbackFloor: Int {
            switch self {
            case .light: -45
            case .medium: -38
            case .strong: -30
            }
        }
    }

    /// Background noise floor and overall loudness of a recording, in dBFS.
    struct NoiseProfile: Equatable {
        var floor: Double
        var level: Double
    }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.mediaInputs, actionTitle: "Clean Up", noun: "recordings", job: { Settings().job(for: tool) }) {
            Settings()
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("audio.cleanup.strength") private var strength = Strength.medium
        @AppStorage("audio.cleanup.removeRumble") private var removeRumble = true
        @AppStorage("audio.cleanup.removeClicks") private var removeClicks = false
        @AppStorage("audio.cleanup.deEss") private var deEss = false
        @AppStorage("audio.cleanup.normalize") private var normalize = true

        var body: some View {
            OptionPicker("Noise reduction", selection: $strength, style: .segmented,
                         choices: Strength.allCases.map { OptionChoice($0, $0.label) })
            OptionToggle("Remove low rumble and hum (below 80 Hz)", isOn: $removeRumble)
            OptionToggle("Remove clicks and pops", isOn: $removeClicks)
            OptionToggle("Soften harsh “s” sounds", isOn: $deEss)
            OptionToggle("Even out loudness (−16 LUFS, good for podcasts and video)", isOn: $normalize)
            OptionNote("Each file is analyzed first so noise removal matches its background noise. Works on audio files and on the soundtrack of videos; video is copied without re-encoding.")
        }

        func job(for tool: Tool) -> ToolJob? {
            .each(verb: "Cleaning") { [strength, removeRumble, removeClicks, deEss, normalize] input, context, progress in
                let info = try await FFmpeg.probe(input)
                guard info.hasAudio else { throw ToolError.failed("No audio found.") }

                let noise = await CleanUpAudioView.measureNoise(input)
                progress(0.1)
                let filters = CleanUpAudioView.filterChain(strength: strength, removeRumble: removeRumble, removeClicks: removeClicks,
                                                           deEss: deEss, normalize: normalize, noise: noise,
                                                           sampleRate: await AudioProbe.sampleRate(of: input))
                let ext = input.pathExtension.lowercased()
                var args = ["-i", input.path]
                let output: URL

                if info.hasVideo {
                    // Keep the picture untouched; re-encode only the processed audio in a codec the container accepts.
                    let container = ["mp4", "m4v", "mov", "mkv", "webm"].contains(ext) ? ext : "mp4"
                    output = context.output(for: input, suffix: "cleaned", extension: container)
                    args += ["-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-af", filters]
                    args += container == "webm" ? ["-c:a", "libopus", "-b:a", "160k"] : ["-c:a", "aac", "-b:a", "192k"]
                    if container != "mkv" && container != "webm" { args += ["-movflags", "+faststart"] }
                } else {
                    let format = AudioOutputFormat.matching(extension: ext) ?? .m4a
                    output = context.output(for: input, suffix: "cleaned", extension: format.fileExtension)
                    args += ["-map", "0:a:0", "-af", filters] + format.highQualityArguments
                }
                args += ["-map_metadata", "0", output.path]
                try await FFmpeg.run(args, duration: info.duration) { progress(0.1 + 0.9 * $0) }
            }
        }
    }

    /// Measures the quietest 50 ms window (≈ background noise) and the overall RMS level.
    nonisolated static func measureNoise(_ url: URL) async -> NoiseProfile? {
        guard let ffmpeg = Dependencies.locate(.ffmpeg),
              let result = try? await ProcessRunner.run(ffmpeg, arguments: [
                  "-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0",
                  "-af", "astats=measure_perchannel=none:measure_overall=RMS_level+RMS_trough", "-f", "null", "-",
              ]) else { return nil }
        func value(_ label: String) -> Double? {
            // FFmpeg spells the trough statistic "RMS through" in some versions.
            let line = result.stderr.split(separator: "\n").last { $0.contains(label) }
            return line.flatMap { Double($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        }
        guard let level = value("RMS level dB"), let floor = value("RMS through dB") ?? value("RMS trough dB"),
              level.isFinite else { return nil }
        // Digital silence reports -inf; treat it as very quiet.
        return NoiseProfile(floor: floor.isFinite ? floor : -90, level: level)
    }

    /// The afftdn threshold: above the noise floor by the strength's margin, but never above the
    /// overall level, so the voice itself isn't treated as noise. Clamped to afftdn's -80…-20 range.
    nonisolated static func noiseFloor(for strength: Strength, noise: NoiseProfile?) -> Int {
        guard let noise else { return strength.fallbackFloor }
        let threshold = min(noise.floor + strength.margin, noise.level - 3)
        return Int(min(max(threshold, -80), -20).rounded())
    }

    nonisolated static func filterChain(strength: Strength, removeRumble: Bool, removeClicks: Bool, deEss: Bool,
                                        normalize: Bool, noise: NoiseProfile?, sampleRate: Int?) -> String {
        var filters: [String] = []
        if removeRumble { filters.append("highpass=f=80") }
        if removeClicks { filters.append("adeclick") }
        filters.append("afftdn=nr=\(strength.reduction):nf=\(noiseFloor(for: strength, noise: noise))")
        if deEss { filters.append("deesser=i=0.4") }
        if normalize {
            filters.append("loudnorm=I=-16:TP=-1.5:LRA=11")
            // loudnorm upsamples to 192 kHz internally; restore the original rate.
            filters.append("aresample=\(sampleRate ?? 48_000)")
        }
        return filters.joined(separator: ",")
    }
}
