import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// Write scripts and set up the teleprompter: where it shows, how it scrolls, how text looks, the
/// microphone, the phone remote and the shortcuts.
struct TeleprompterView: View {
    let tool: Tool

    @State private var library = TeleprompterLibrary.shared
    @State private var prompter = Teleprompter.shared
    @State private var importing = false
    @State private var importError: String?
    @State private var microphones: [AudioInputDevice] = []
    @State private var calibrating = false
    @State private var calibrationNote: String?

    private var settings: TeleprompterSettings { prompter.settings }

    var body: some View {
        @Bindable var settings = settings
        ToolPage(tool: tool) {
            notices
            ToolSection("Script", footnote: "Start a line with # to make a cue you can jump to. [Notes in square brackets] are dimmed and not counted. Lines starting with - become bullet points.") {
                HStack(alignment: .top, spacing: 12) {
                    scriptList
                    editor
                }
            }
            ToolSection("Where it shows", footnote: "Hidden when you share your screen, record it or take screenshots. It shows on every Space and over full-screen apps.") {
                OptionPicker("Show", selection: $settings.display, style: .segmented,
                             choices: TeleprompterDisplayMode.allCases.map { OptionChoice($0, $0.label, symbol: $0.symbol) })
                Picker("Display", selection: $settings.screenID) {
                    Text("Automatic (the one with the camera)").tag(0)
                    Divider()
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(Int(screen.recordingDisplayID ?? 0))
                    }
                }
                .fixedSize()
                if settings.display == .notch {
                    OptionSlider("Width", value: $settings.notchWidth, in: 300...900, step: 10) { "\(Int($0)) pt" }
                    OptionSlider("Height", value: $settings.notchHeight, in: 100...420, step: 10) { "\(Int($0)) pt" }
                } else {
                    OptionSlider("Background", value: $settings.floatingOpacity, in: 0.4...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                    OptionNote("Drag the top of the window to move it and the corner to resize it.")
                }
            }
            ToolSection("Scrolling") {
                OptionPicker("Scrolling", selection: $settings.scrollMode, style: .segmented,
                             choices: TeleprompterScrollMode.allCases.map { OptionChoice($0, $0.label) })
                OptionNote(settings.scrollMode == .voice
                           ? "The text moves while you speak and waits when you stop."
                           : "The text moves at a steady pace until you pause it.")
                OptionSlider("Words per minute", value: $settings.wordsPerMinute, in: TeleprompterSettings.speeds, step: 10,
                             presets: [110, 140, 170]) { "\(Int($0))" }
                Picker("Countdown", selection: $settings.countdown) {
                    Text("Off").tag(0)
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .fixedSize()
                OptionToggle("Pause while the pointer is over the prompter", isOn: $settings.hoverToPause)
                OptionNote("Scroll with the trackpad any time to move through the script yourself.")
            }
            ToolSection("Text") {
                OptionSlider("Size", value: $settings.fontSize, in: TeleprompterSettings.fontSizes, step: 1) { "\(Int($0)) pt" }
                LabeledContent("Color") { colorSwatches }
                OptionPicker("Font", selection: $settings.font, choices: TeleprompterFont.allCases.map { OptionChoice($0, $0.label) })
                    .fixedSize()
                OptionSlider("Line spacing", value: $settings.lineSpacing, in: 0...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                OptionPicker("Alignment", selection: $settings.alignment, style: .segmented,
                             choices: TeleprompterAlignment.allCases.map { OptionChoice($0, $0.label) })
                OptionToggle("Mirror the text, for a teleprompter with beam-splitter glass", isOn: $settings.mirrored)
            }
            if settings.scrollMode == .voice {
                microphoneSection
            }
            remoteSection
            shortcutsSection
        } footer: {
            footer
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importScripts(urls) }
        }
        .onAppear { microphones = AudioInputDevices.all() }
        .onChange(of: settings.display) { prompter.displaySettingsChanged() }
        .onChange(of: settings.notchWidth) { prompter.displaySettingsChanged() }
        .onChange(of: settings.notchHeight) { prompter.displaySettingsChanged() }
        .onChange(of: settings.screenID) { prompter.displaySettingsChanged(screenChanged: true) }
        .onChange(of: settings.scrollMode) { prompter.scrollModeChanged() }
        .onChange(of: settings.microphoneID) { prompter.microphoneChanged() }
        .onChange(of: settings.globalShortcuts) { prompter.updateHotKeys() }
        .onChange(of: library.selectedID) {
            if prompter.isShowing, let script = library.selected { prompter.show(script) }
        }
        .onDisappear { library.saveNow() }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let problem = prompter.voiceProblem {
            AINotice(symbol: "mic.slash", title: "Not listening", message: problem) {
                Button("Open Privacy Settings") { AISystemSettings.openMicrophonePrivacy() }
            }
        }
        if let importError {
            AINotice(symbol: "exclamationmark.triangle", title: "Couldn't import", message: importError) {
                Button("OK") { self.importError = nil }
            }
        }
    }

    // MARK: - Scripts

    private var scriptList: some View {
        @Bindable var library = library
        return VStack(spacing: 0) {
            List(selection: $library.selectedID) {
                ForEach(library.scripts) { script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.displayTitle).lineLimit(1)
                        Text(script.modified, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Duplicate") { library.duplicate(script.id) }
                        Button("Delete", role: .destructive) { library.delete(script.id) }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 2) {
                Button { library.add() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("New script")
                Button { if let id = library.selectedID { library.delete(id) } } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                    .help("Delete script")
                    .disabled(library.selectedID == nil)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 22, height: 20) }
                    .help("Import text, Markdown or RTF files as scripts")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: 210, height: 380)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }

    @ViewBuilder
    private var editor: some View {
        if let script = library.selected {
            let cues = TeleprompterParser.cues(in: script.text)
            let words = cues.reduce(0) { $0 + $1.words }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: binding(for: script.id, \.title), prompt: Text("Untitled Script"))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Divider()
                TextEditor(text: binding(for: script.id, \.text))
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if script.text.isEmpty {
                            Text("Type or paste your script. Start a line with # to begin a cue.")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                Divider()
                HStack {
                    Text(summary(words: words, cues: cues.filter { $0.title != nil }.count))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Cue") { addCue(to: script) }
                        .controlSize(.small)
                        .help("Adds a # heading at the end of the script")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 380, maxHeight: 380)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        } else {
            ContentUnavailableView {
                Label("No Script", systemImage: "text.alignleft")
            } description: {
                Text("Write a script, or import one from a text file.")
            } actions: {
                Button("New Script") { library.add() }
            }
            .frame(maxWidth: .infinity, minHeight: 380)
        }
    }

    private func binding(for id: UUID, _ keyPath: WritableKeyPath<TeleprompterScript, String>) -> Binding<String> {
        Binding {
            library.script(id)?[keyPath: keyPath] ?? ""
        } set: { value in
            guard var script = library.script(id) else { return }
            script[keyPath: keyPath] = value
            library.update(id, title: script.title, text: script.text)
            prompter.scriptChanged(script)
        }
    }

    private func summary(words: Int, cues: Int) -> String {
        let minutes = Double(words) / settings.wordsPerMinute
        let time = minutes < 1 ? "under a minute" : "about \(Int(minutes.rounded())) min"
        var parts = ["\(words) \(words == 1 ? "word" : "words")", "\(time) at \(Int(settings.wordsPerMinute)) wpm"]
        if cues > 0 { parts.append("\(cues) \(cues == 1 ? "cue" : "cues")") }
        return parts.joined(separator: " · ")
    }

    private func addCue(to script: TeleprompterScript) {
        let text = script.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = TeleprompterParser.cues(in: text).filter { $0.title != nil }.count + 1
        let updated = (text.isEmpty ? "" : text + "\n\n") + "# Cue \(number)\n"
        library.update(script.id, text: updated)
        if let script = library.script(script.id) { prompter.scriptChanged(script) }
    }

    private static let importTypes: [UTType] = [.plainText, .rtf, .rtfd, .html, UTType("net.daringfireball.markdown"), UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    private func importScripts(_ urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension)
            let text: String?
            if let type, type.conforms(to: .plainText) {
                text = try? String(contentsOf: url, encoding: .utf8)
            } else {
                text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                failed.append(url.lastPathComponent)
                continue
            }
            library.add(title: url.deletingPathExtension().lastPathComponent, text: text)
        }
        importError = failed.isEmpty ? nil : "No text found in \(ListFormatter.localizedString(byJoining: failed))."
    }

    // MARK: - Text color

    private var colorSwatches: some View {
        @Bindable var settings = settings
        return HStack(spacing: 6) {
            ForEach(TeleprompterSettings.textColors, id: \.self) { hex in
                Button { settings.textColor = hex } label: {
                    Circle()
                        .fill(Color(cgColor: WhiteboardRenderer.cgColor(hex)))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
                        .frame(width: 20, height: 20)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: settings.textColor == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(hex)
            }
            ColorPicker("Custom color", selection: Binding {
                settings.color
            } set: { color in
                if let hex = Self.hex(color) { settings.textColor = hex }
            }, supportsOpacity: false)
            .labelsHidden()
            .help("Custom color")
        }
    }

    private static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let value = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value[0], value[1], value[2])
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        @Bindable var settings = settings
        return ToolSection("Microphone", footnote: "Loud background noise can sound like speech to the prompter; headphones help. Nothing is recorded.") {
            Picker("Input", selection: $settings.microphoneID) {
                Text("System default").tag(0)
                if !microphones.isEmpty { Divider() }
                ForEach(microphones) { device in
                    Text(device.name).tag(Int(device.id))
                }
            }
            .fixedSize()
            OptionSlider("Sensitivity", value: $settings.sensitivity, in: 0.05...1, step: 0.01,
                         minimumLabel: "Less", maximumLabel: "More") { "\(Int(($0 * 100).rounded()))%" }
            if prompter.isShowing, prompter.listensToVoice {
                LabeledContent("Level") { TeleprompterLevelMeter(prompter: prompter) }
            }
            HStack {
                Button(calibrating ? "Listening…" : "Calibrate…") { Task { await calibrate() } }
                    .disabled(calibrating)
                Text(calibrationNote ?? "Stay quiet for a few seconds and Toolbox sets the sensitivity just above the background noise.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func calibrate() async {
        calibrating = true
        calibrationNote = "Stay quiet…"
        defer { calibrating = false }
        guard await Teleprompter.microphoneAllowed() else {
            calibrationNote = "Microphone access is off. Allow it in System Settings › Privacy & Security › Microphone."
            return
        }
        do {
            let id = settings.microphoneID
            let noise = try await TeleprompterCalibration.measureNoise(deviceID: id == 0 ? nil : AudioDeviceID(id))
            settings.sensitivity = TeleprompterSettings.sensitivity(forNoise: noise)
            calibrationNote = "Background noise is about \(Int(noise.rounded())) dB, so sensitivity is now \(Int((settings.sensitivity * 100).rounded()))%."
        } catch {
            calibrationNote = "Couldn't listen: \(error.localizedDescription)"
        }
    }

    // MARK: - Remote

    private var remoteSection: some View {
        let remote = prompter.remote
        return ToolSection("Phone remote", footnote: "Your phone connects straight to this Mac over your network. Nothing goes through the internet.") {
            if remote.isRunning, let url = remote.url {
                HStack(alignment: .center, spacing: 14) {
                    if let qr = remote.qrCode {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .padding(5)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityLabel("QR code for the remote")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Scan the code with your phone's camera, or open this link in any browser on the same Wi-Fi:")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(url.absoluteString).font(.body.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Copy Link") { AIText.copy(url.absoluteString) }
                            Button("Stop Remote") { remote.stop() }
                        }
                        .controlSize(.small)
                        Label(remote.connected == 0 ? "No phone connected yet" : remote.connected == 1 ? "1 phone connected" : "\(remote.connected) phones connected",
                              systemImage: remote.connected == 0 ? "iphone.slash" : "iphone")
                            .font(.callout)
                            .foregroundStyle(remote.connected == 0 ? .secondary : .primary)
                    }
                }
            } else {
                HStack {
                    Button(remote.isStarting ? "Starting…" : "Start Remote") { Task { await remote.start() } }
                        .disabled(remote.isStarting)
                    Text("Play, pause, scroll with a dial, change speed and jump between cues from your phone.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = remote.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        @Bindable var settings = settings
        return ToolSection("Keyboard shortcuts") {
            OptionToggle("Use these shortcuts in any app", isOn: $settings.globalShortcuts)
            if settings.globalShortcuts {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach([Teleprompter.showShortcut] + Teleprompter.playbackShortcuts) { shortcut in
                        GridRow {
                            Text(shortcut.display)
                                .font(.body.monospaced())
                                .foregroundStyle(prompter.unavailableShortcuts.contains(shortcut.display) ? .orange : .primary)
                            Text(shortcut.label).foregroundStyle(.secondary)
                        }
                    }
                }
                OptionNote("⌃⌥⌘T works any time. The others work while the prompter is showing, so they don't get in the way of other apps.")
                if !prompter.unavailableShortcuts.isEmpty {
                    Label("Another app already uses \(ListFormatter.localizedString(byJoining: prompter.unavailableShortcuts)).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if prompter.isShowing {
                    Label("Showing “\(prompter.title)”", systemImage: "text.viewfinder")
                } else if settings.globalShortcuts {
                    Text("Press ⌃⌥⌘T in any app to show or hide the prompter.")
                } else {
                    Text("Your scripts stay on this Mac.")
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Record Screen…") { AppModel.shared.open(.tool("video.record-screen")) }
                .help("Recordings leave the prompter out, so you can read while you record")
            if prompter.isShowing {
                Button("Close Prompter") { prompter.hide() }
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button { if let script = library.selected { prompter.show(script) } } label: {
                    Text("Start Prompter").frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(library.selected?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
        .frame(minHeight: 32)
    }
}

/// The live microphone level, with a mark where speech starts counting.
private struct TeleprompterLevelMeter: View {
    let prompter: Teleprompter

    var body: some View {
        let threshold = Double(min(max((prompter.settings.speechThreshold + 60) / 50, 0), 1))
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(prompter.isSpeaking ? Color.green : Color.secondary)
                        .frame(width: proxy.size.width * prompter.voiceLevel)
                    Rectangle().fill(.primary).frame(width: 2)
                        .offset(x: proxy.size.width * threshold - 1)
                }
            }
            .frame(width: 260, height: 8)
            Text(prompter.isSpeaking ? "Speaking" : "Quiet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .help("Speech louder than the mark scrolls the text")
    }
}
