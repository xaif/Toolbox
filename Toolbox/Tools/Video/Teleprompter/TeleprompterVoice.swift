import AVFoundation
import AudioToolbox
import CoreAudio

/// Listens to the microphone so the prompter can scroll while you speak. Nothing is recorded or saved:
/// it only keeps the loudness of the latest buffer. The tap runs on an audio thread, so this class is
/// deliberately not main-actor isolated; the prompter reads `decibels` on each frame.
final class TeleprompterVoiceMonitor: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var latest: Float = -100
    private var running = false
    private var configurationObserver: NSObjectProtocol?

    /// Called on the main queue when the input device changes or disappears mid-session.
    var onInterruption: (@Sendable () -> Void)?

    /// Loudness of the latest buffer in dBFS (−100 when silent or stopped).
    var decibels: Float { lock.withLock { latest } }
    var isRunning: Bool { lock.withLock { running } }

    func start(deviceID: AudioDeviceID?) throws {
        stop()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ToolError.failed("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.measure(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.withLock { running = true }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onInterruption?() }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard isRunning, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        lock.withLock {
            running = false
            latest = -100
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<frames { sum += samples[index] * samples[index] }
        let rms = (sum / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        lock.withLock { latest = decibels }
    }
}

/// Measures background noise for a couple of seconds and suggests a sensitivity just above it.
@MainActor
enum TeleprompterCalibration {
    static func measureNoise(deviceID: AudioDeviceID?, seconds: Double = 2.5) async throws -> Float {
        let monitor = TeleprompterVoiceMonitor()
        try monitor.start(deviceID: deviceID)
        defer { monitor.stop() }
        var readings: [Float] = []
        let end = Date().addingTimeInterval(seconds)
        // Skip the first moment, while the input settles.
        try await Task.sleep(for: .milliseconds(300))
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            readings.append(monitor.decibels)
        }
        guard !readings.isEmpty else { return -60 }
        // The loud end of the background, ignoring a stray click or two.
        let sorted = readings.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }
}
