import AVFoundation
import SwiftUI

@MainActor
@Observable
final class AudioRecordModel {
    enum State: Equatable {
        case idle
        case recording
        case paused
        case finished(URL)
    }

    private(set) var state = State.idle
    private(set) var level: Float = 0
    private(set) var elapsed: Double = 0
    private(set) var permission = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var devices: [AudioInputDevice] = []
    private(set) var errorMessage: String?
    private(set) var startedAt = Date()
    private(set) var isPlaying = false
    var selectedDevice: AudioDeviceID?
    var format = AudioRecordingFormat.m4a

    let player = AVPlayer()
    private var engine: AudioCaptureEngine?
    private var endObserver: NSObjectProtocol?

    init() {
        refreshDevices()
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.isPlaying = false
                self.player.seek(to: .zero)
            }
        }
    }

    var isCapturing: Bool { state == .recording || state == .paused }

    var recordingURL: URL? {
        if case .finished(let url) = state { return url }
        return nil
    }

    func refreshDevices() {
        devices = AudioInputDevices.all()
        if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = AudioInputDevices.defaultDeviceID() ?? devices.first?.id
        }
    }

    func record() {
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.permission = AVCaptureDevice.authorizationStatus(for: .audio)
                    if granted { self.beginRecording() }
                }
            }
        default:
            permission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func beginRecording() {
        discardRecording()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
        let engine = AudioCaptureEngine()
        engine.onUpdate = { [weak self] level, seconds in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                self.level = level
                self.elapsed = seconds
            }
        }
        do {
            try engine.start(deviceID: selectedDevice, url: url, format: format)
            self.engine = engine
            pendingURL = url
            startedAt = Date()
            elapsed = 0
            state = .recording
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var pendingURL: URL?

    func togglePause() {
        guard let engine else { return }
        if state == .recording {
            engine.setPaused(true)
            state = .paused
            level = 0
        } else if state == .paused {
            engine.setPaused(false)
            state = .recording
        }
    }

    func stop() {
        guard let engine, let url = pendingURL else { return }
        elapsed = engine.stop()
        self.engine = nil
        pendingURL = nil
        level = 0
        guard elapsed > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            errorMessage = "Nothing was recorded. Check that the right microphone is selected."
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        state = .finished(url)
    }

    func togglePlayback() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func discardRecording() {
        player.pause()
        isPlaying = false
        player.replaceCurrentItem(with: nil)
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        state = .idle
        elapsed = 0
    }

    /// Name for the saved file, based on when recording started.
    var suggestedName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: startedAt))"
    }

    func shutdown() {
        if isCapturing { stop() }
        player.pause()
        isPlaying = false
    }
}

struct RecordAudioView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var model = AudioRecordModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            if model.permission == .denied || model.permission == .restricted {
                permissionCard
            } else {
                ToolSection("Input") {
                    HStack {
                        Picker("Microphone", selection: $model.selectedDevice) {
                            ForEach(model.devices) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                        Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Refresh devices")
                    }
                    Picker("Format", selection: $model.format) {
                        ForEach(AudioRecordingFormat.allCases) { Text($0.label).tag($0) }
                    }
                }
                .disabled(model.isCapturing)

                recorderPanel
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Save Recording", canRun: model.recordingURL != nil && !model.isCapturing,
                   hint: model.isCapturing ? "Stop recording to save it." : "Record something to save it.", action: save)
        }
        .onDisappear { model.shutdown() }
    }

    private var recorderPanel: some View {
        VStack(spacing: 18) {
            Text(TimeFormat.string(model.elapsed, precise: true))
                .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(model.state == .recording ? .primary : .secondary)

            AudioLevelMeter(level: model.level, active: model.state == .recording)
                .frame(height: 10)
                .frame(maxWidth: 360)

            HStack(spacing: 18) {
                switch model.state {
                case .idle:
                    recordButton
                case .recording, .paused:
                    Button(action: model.togglePause) {
                        Label(model.state == .paused ? "Resume" : "Pause",
                              systemImage: model.state == .paused ? "record.circle" : "pause.fill")
                    }
                    .controlSize(.large)
                    Button(action: model.stop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                case .finished:
                    Button(action: model.togglePlayback) {
                        Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .controlSize(.large)
                    Button(role: .destructive) {
                        model.discardRecording()
                        runner.reset()
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .controlSize(.large)
                    .disabled(runner.isRunning)
                    Button {
                        runner.reset()
                        model.record()
                    } label: {
                        Label("Record Again", systemImage: "record.circle")
                    }
                    .controlSize(.large)
                    .disabled(runner.isRunning)
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if model.state == .paused {
                Text("Paused").foregroundStyle(.secondary)
            } else if model.recordingURL != nil, runner.phase != .succeeded {
                Text("Listen back, then save it or record again.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private var recordButton: some View {
        Button(action: model.record) {
            ZStack {
                Circle().fill(Color.red).frame(width: 64, height: 64)
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 64, height: 64)
            }
            .shadow(color: .red.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help("Start recording (Space)")
        .accessibilityLabel("Record")
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Microphone access is off", systemImage: "mic.slash").font(.headline)
            Text("Toolbox needs permission to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone, then come back.")
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func save() {
        guard let source = model.recordingURL else { return }
        model.shutdown()
        let name = model.suggestedName
        let ext = source.pathExtension
        runner.start(title: tool.name) { context in
            context.setStatus("Saving \(name)")
            try FileManager.default.copyItem(at: source, to: context.output(named: name, extension: ext))
        }
    }
}

/// Horizontal level meter with green → yellow → red segments.
struct AudioLevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: geometry.size.width * CGFloat(active ? level : 0))
                    }
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
