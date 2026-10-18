import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Dependencies", systemImage: "shippingbox") { DependencySettings() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.outputMode) private var outputMode = OutputDestinationMode.downloads.rawValue
    @AppStorage(SettingsKey.outputCustomPath) private var customPath = ""
    @AppStorage(SettingsKey.revealWhenDone) private var revealWhenDone = false
    @AppStorage(SettingsKey.hotKeyEnabled) private var hotKeyEnabled = true
    @AppStorage(SettingsKey.hotKeyAction) private var hotKeyAction = HotKeyAction.launcher.rawValue
    @AppStorage(SettingsKey.launcherUsesFinderSelection) private var useFinderSelection = true
    private var hotKeys: HotKeyManager { HotKeyManager.shared }

    var body: some View {
        Form {
            Section {
                Picker("Save results to", selection: $outputMode) {
                    ForEach(OutputDestinationMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if outputMode == OutputDestinationMode.custom.rawValue {
                    LabeledContent("Folder") {
                        HStack {
                            Text(customPath.isEmpty ? "None chosen" : (customPath as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(customPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }
                Toggle("Show results in Finder when a job finishes", isOn: $revealWhenDone)
            } header: {
                Text("Output")
            } footer: {
                Text(footer).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Global shortcut", isOn: $hotKeyEnabled)
                if hotKeyEnabled {
                    LabeledContent("Shortcut") { ShortcutRecorder() }
                    if hotKeys.registrationFailed {
                        Label("macOS couldn't use this shortcut. Another app may already use it. Try a different one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Picker("Opens", selection: $hotKeyAction) {
                        ForEach(HotKeyAction.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Suggest tools for the files selected in Finder", isOn: $useFinderSelection)
                        .disabled(hotKeyAction != HotKeyAction.launcher.rawValue)
                }
            } header: {
                Text("Quick launcher")
            } footer: {
                Text("Press the shortcut in any app to search tools. When you open it from Finder, Toolbox offers tools for the selected files and hands them over. macOS asks once for permission to read the Finder selection.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: String {
        switch OutputDestinationMode(rawValue: outputMode) ?? .downloads {
        case .downloads: "Each job creates a new dated folder in Downloads › Toolbox. Originals are never modified."
        case .custom: "Each job creates a new dated folder inside the folder you choose."
        case .ask: "You'll pick a folder each time you start a job."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
    }
}

private struct DependencySettings: View {
    @Environment(Dependencies.self) private var dependencies

    var body: some View {
        Form {
            ForEach(ExternalDependency.allCases) { dependency in
                Section(dependency.displayName) {
                    if let url = dependencies.locations[dependency] {
                        LabeledContent("Installed") {
                            HStack {
                                Text(url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()]) } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if AppSettings.customExecutable(for: dependency) != nil {
                            Button("Use Default Location") { dependencies.setCustomExecutable(nil, for: dependency) }
                        }
                    } else {
                        DependencyCard(dependency: dependency)
                            .listRowInsets(EdgeInsets())
                    }
                    Text(dependency.purpose).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Check Again") { dependencies.refresh() }
            } footer: {
                Text("Image, PDF, text recognition and transcription tools don't need anything extra.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { dependencies.refresh() }
    }
}

/// Click, then press a key combination to set the global shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @State private var shortcut = HotKeyShortcut.current
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Type a shortcut…" : shortcut.displayString)
                    .font(.body.monospaced())
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if !isRecording, shortcut != .default {
                Button("Reset") {
                    shortcut = .default
                    shortcut.save()
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        HotKeyManager.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, modifiers.isEmpty { // Esc
                stopRecording()
            } else if let recorded = HotKeyShortcut(event: event) {
                shortcut = recorded
                recorded.save()
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyManager.shared.isSuspended = false
    }
}
