import AVFoundation
import CoreAudio
import AudioToolbox

/// A Core Audio device that has input channels.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let channels: Int
}

enum AudioInputDevices {
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(id: id, name: name(of: id) ?? "Unknown Device", channels: channels)
        }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

enum AudioRecordingFormat: String, CaseIterable, Identifiable {
    case m4a, wav
    var id: Self { self }
    var label: String { self == .m4a ? "M4A (AAC, smaller)" : "WAV (uncompressed)" }
    var fileExtension: String { rawValue }
}

/// Captures microphone input with AVAudioEngine and writes it to a file.
/// The tap runs on an audio thread, so this class is deliberately not main-actor isolated.
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var outputFormat: AVAudioFormat?
    private var paused = false
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000

    /// Called from the audio thread with the current level (0...1) and recorded seconds.
    var onUpdate: (@Sendable (_ level: Float, _ seconds: Double) -> Void)?

    func start(deviceID: AudioDeviceID?, url: URL, format: AudioRecordingFormat) throws {
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw ToolError.failed("No microphone input is available.")
        }
        let channels = min(hardware.channelCount, 2)
        sampleRate = hardware.sampleRate
        guard let processing = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate,
                                             channels: channels, interleaved: false) else {
            throw ToolError.failed("Unsupported microphone format.")
        }

        let file = try Self.makeFile(url: url, format: format, sampleRate: hardware.sampleRate, channels: channels)

        lock.lock()
        self.file = file
        self.outputFormat = processing
        framesWritten = 0
        paused = false
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); self.file = nil; lock.unlock()
            throw error
        }
    }

    /// Creates the output file. Buffers written to it are Float32, non-interleaved, at `sampleRate`.
    static func makeFile(url: URL, format: AudioRecordingFormat, sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFile {
        let settings: [String: Any]
        switch format {
        case .m4a:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(sampleRate, 48_000),
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func setPaused(_ value: Bool) {
        lock.lock(); paused = value; lock.unlock()
    }

    /// Stops capture and closes the file. Returns the recorded duration in seconds.
    @discardableResult
    func stop() -> Double {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil
        let seconds = Double(framesWritten) / sampleRate
        lock.unlock()
        return seconds
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData else { return }

        var peak: Float = 0
        for channel in 0..<min(Int(buffer.format.channelCount), 2) {
            let samples = source[channel]
            for i in 0..<frames { peak = max(peak, abs(samples[i])) }
        }
        // Map -60…0 dBFS onto 0…1 for the meter.
        let decibels = 20 * log10(max(peak, 0.000_001))
        let level = Float(min(max((decibels + 60) / 60, 0), 1))

        lock.lock()
        if !paused, let file, let format = outputFormat,
           let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
           let destination = copy.floatChannelData {
            copy.frameLength = AVAudioFrameCount(frames)
            let available = Int(buffer.format.channelCount)
            for channel in 0..<Int(format.channelCount) {
                memcpy(destination[channel], source[min(channel, available - 1)], frames * MemoryLayout<Float>.size)
            }
            if (try? file.write(from: copy)) != nil { framesWritten += AVAudioFramePosition(frames) }
        }
        let seconds = Double(framesWritten) / sampleRate
        lock.unlock()
        onUpdate?(level, seconds)
    }
}
