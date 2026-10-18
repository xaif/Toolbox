import SwiftUI
import ScreenCaptureKit
import AVFoundation

/// The screen recording studio: set up → record → edit and export.
struct RecordScreenView: View {
    let tool: Tool
    @State private var studio = RecordingStudio.shared
    @State private var runner: JobRunner

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        Group {
            switch studio.phase {
            case .editing:
                if let editor = studio.editor {
                    RecordingEditorView(tool: tool, studio: studio, editor: editor, runner: runner)
                }
            case .recording, .finishing:
                RecordingInProgressView(tool: tool, studio: studio)
            case .setup, .preparing, .countdown:
                RecordingSetupView(tool: tool, studio: studio)
            }
        }
        .onAppear { studio.setupScreenVisibilityChanged(visible: true) }
        .onDisappear { studio.setupScreenVisibilityChanged(visible: false) }
    }
}

// MARK: - Setup

private struct RecordingSetupView: View {
    let tool: Tool
    @Bindable var studio: RecordingStudio

    private var busy: Bool { studio.phase != .setup }

    var body: some View {
        ToolPage(tool: tool) {
            if !studio.hasScreenAccess {
                RecordingPermissionCard(studio: studio)
            }
            if let message = studio.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button { studio.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            ToolSection("What to record") {
                Picker("Source", selection: $studio.source) {
                    ForEach(RecordingSourceKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch studio.source {
                case .display: RecordingDisplayPicker(studio: studio)
                case .window: RecordingWindowPicker(studio: studio)
                case .area: RecordingAreaPicker(studio: studio)
                }
            }
            .disabled(busy || !studio.hasScreenAccess)

            ToolSection("Audio") {
                Toggle("Microphone", isOn: $studio.recordMicrophone)
                if studio.recordMicrophone, studio.microphones.count > 1 {
                    Picker("Input", selection: $studio.microphoneID) {
                        Text("System default").tag(String?.none)
                        ForEach(studio.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                }
                Toggle("System audio (sound from apps)", isOn: $studio.recordSystemAudio)
            }
            .disabled(busy)

            ToolSection("Camera", footnote: studio.cameraEnabled ? "Drag the bubble anywhere on screen. It's recorded where you leave it." : nil) {
                Toggle("Show camera bubble", isOn: $studio.cameraEnabled)
                if studio.cameraEnabled {
                    if studio.cameras.count > 1 {
                        Picker("Camera", selection: $studio.cameraID) {
                            Text("System default").tag(String?.none)
                            ForEach(studio.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        }
                    }
                    Picker("Size", selection: $studio.cameraSize) {
                        ForEach(RecordingCameraSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .disabled(busy)

            ToolSection("Options") {
                Toggle("Show cursor", isOn: $studio.showCursor)
                Toggle("Highlight clicks", isOn: $studio.highlightClicks)
                Picker("Resolution", selection: $studio.quality) {
                    ForEach(RecordingQuality.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $studio.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("3-second countdown", isOn: $studio.useCountdown)
            }
            .disabled(busy)
        } footer: {
            HStack {
                switch studio.phase {
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Getting ready…").foregroundStyle(.secondary)
                case .countdown(let number):
                    Text("Recording starts in \(number)…").foregroundStyle(.secondary)
                default:
                    Text("This window hides while you record. Stop from the floating bar or the menu bar.")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    Task { await studio.startRecording() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!studio.canStart)
            }
            .frame(minHeight: 32)
        }
        .task {
            studio.refreshDevices()
            await studio.refreshContent()
        }
    }
}

private struct RecordingPermissionCard: View {
    let studio: RecordingStudio

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow screen recording").font(.headline)
                Text("macOS needs your permission before Toolbox can record the screen. Turn on Toolbox in System Settings › Privacy & Security › Screen & System Audio Recording. You may need to quit and reopen Toolbox afterwards.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow Access…") { studio.requestScreenAccess() }
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings") { studio.openScreenRecordingSettings() }
                    Button("Check Again") { Task { await studio.refreshContent() } }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct RecordingDisplayPicker: View {
    @Bindable var studio: RecordingStudio

    var body: some View {
        if studio.displays.isEmpty {
            RecordingEmptySources(loading: studio.isLoadingContent, text: "No displays found.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                ForEach(studio.displays, id: \.displayID) { display in
                    RecordingSourceCard(
                        image: studio.thumbnails[display.displayID],
                        title: NSScreen.recordingScreen(for: display.displayID)?.localizedName ?? "Display",
                        subtitle: "\(display.width) × \(display.height)",
                        icon: nil,
                        selected: studio.selectedDisplayID == display.displayID
                    ) { studio.selectedDisplayID = display.displayID }
                    .task { await studio.loadThumbnail(display: display) }
                }
            }
        }
    }
}

private struct RecordingWindowPicker: View {
    @Bindable var studio: RecordingStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(studio.windows.count) windows").foregroundStyle(.secondary)
                Spacer()
                Button { Task { await studio.refreshContent() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if studio.windows.isEmpty {
                RecordingEmptySources(loading: studio.isLoadingContent, text: "No windows found. Open the app you want to record.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(studio.windows, id: \.windowID) { window in
                        RecordingSourceCard(
                            image: studio.thumbnails[window.windowID],
                            title: window.title ?? "Untitled",
                            subtitle: window.owningApplication?.applicationName ?? "",
                            icon: window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon },
                            selected: studio.selectedWindowID == window.windowID
                        ) { studio.selectedWindowID = window.windowID }
                        .task { await studio.loadThumbnail(window: window) }
                    }
                }
            }
        }
    }
}

private struct RecordingAreaPicker: View {
    @Bindable var studio: RecordingStudio

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                if let area = studio.area {
                    Text("\(Int(area.width)) × \(Int(area.height)) points").font(.headline)
                    Text(NSScreen.recordingScreen(for: studio.areaDisplayID)?.localizedName ?? "Display")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No area selected").font(.headline)
                    Text("Drag a rectangle on the screen you want to record.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(studio.area == nil ? "Select Area…" : "Change Area…") {
                Task { await studio.selectArea() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

private struct RecordingSourceCard: View {
    let image: NSImage?
    let title: String
    let subtitle: String
    let icon: NSImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 110)
                HStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(.primary)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct RecordingEmptySources: View {
    let loading: Bool
    let text: String

    var body: some View {
        HStack {
            if loading { ProgressView().controlSize(.small) }
            Text(loading ? "Looking for screens and windows…" : text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Recording in progress

private struct RecordingInProgressView: View {
    let tool: Tool
    let studio: RecordingStudio

    var body: some View {
        ToolPage(tool: tool) {
            VStack(spacing: 18) {
                if studio.phase == .finishing {
                    ProgressView()
                    Text("Finishing recording…").font(.title3)
                } else {
                    Image(systemName: studio.isPaused ? "pause.circle.fill" : "record.circle")
                        .font(.system(size: 54))
                        .foregroundStyle(studio.isPaused ? .orange : .red)
                        .symbolEffect(.pulse, isActive: !studio.isPaused)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(TimeFormat.string(studio.elapsed))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    Text(studio.isPaused ? "Paused" : "Recording").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(studio.isPaused ? "Resume" : "Pause") { Task { await studio.togglePause() } }
                        Button("Stop & Edit") { Task { await studio.stopRecording() } }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        Button("Discard", role: .destructive) { Task { await studio.discardRecording() } }
                    }
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }
}
