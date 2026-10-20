import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Drag Wheel", systemImage: "circle.hexagongrid") { DragWheelSettings() }
            Tab("Dependencies", systemImage: "shippingbox") { DependencySettings() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.outputMode) private var outputMode = OutputDestinationMode.sourceFolder.rawValue
    @AppStorage(SettingsKey.outputCustomPath) private var customPath = ""
    @AppStorage(SettingsKey.revealWhenDone) private var revealWhenDone = false
    @AppStorage(SettingsKey.hotKeyEnabled) private var hotKeyEnabled = true
    @AppStorage(SettingsKey.hotKeyAction) private var hotKeyAction = HotKeyAction.launcher.rawValue
    @AppStorage(SettingsKey.launcherUsesFinderSelection) private var useFinderSelection = true
    @AppStorage(SettingsKey.launcherRunsTools) private var runTools = true
    @AppStorage(SettingsKey.showsMenuBarIcon) private var showsMenuBarIcon = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    private var hotKeys: HotKeyManager { HotKeyManager.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Open Toolbox at login", isOn: Binding(get: { launchAtLogin }, set: {
                    LaunchAtLogin.set($0)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }))
                LabeledContent("Permissions") {
                    Button("Review Permissions…") { OnboardingController.shared.show(page: .permissions) }
                }
            }
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
                }
                Toggle("Show Toolbox in the menu bar (click it to open the launcher)", isOn: $showsMenuBarIcon)
                Toggle("Suggest tools for the files selected in Finder", isOn: $useFinderSelection)
                Toggle("Run tools like Compress on the selected files right away (otherwise show their options first)", isOn: $runTools)
                    .disabled(!useFinderSelection)
            } header: {
                Text("Quick launcher")
            } footer: {
                Text("Press the shortcut, or click the menu bar icon, in any app to search tools. When you open it from Finder, Toolbox offers tools for the selected files and hands them over. Tools like Compress or Convert run right away in the background with the options you last used, and the results are shown in Finder. Press ⇥ to see a tool's options in the launcher first, or ⇧↩ to open the tool instead. macOS asks once for permission to read the Finder selection.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if toolHotKeys.isEmpty {
                    Text("No tool hotkeys yet").foregroundStyle(.secondary)
                }
                ForEach(toolHotKeys, id: \.tool.id) { tool, shortcut in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if hotKeys.failedToolIDs.contains(tool.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("macOS couldn't use this hotkey. Another app may already use it.")
                            }
                            Text(shortcut.displayString).font(.body.monospaced())
                            Button { hotKeys.setShortcut(nil, for: tool.id) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove Hotkey")
                        }
                    } label: {
                        Label { Text(tool.name) } icon: { ToolIcon(tool: tool, size: 20) }
                    }
                }
            } header: {
                Text("Tool hotkeys")
            } footer: {
                Text("Open a tool from any app with its own hotkey. Like the launcher, it takes the files selected in Finder. To add one, highlight the tool in the quick launcher, press ⌘K and choose Set Hotkey.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var toolHotKeys: [(tool: Tool, shortcut: HotKeyShortcut)] {
        hotKeys.toolShortcuts
            .compactMap { id, shortcut in ToolRegistry.tool(id).map { (tool: $0, shortcut: shortcut) } }
            .sorted { $0.tool.name.localizedStandardCompare($1.tool.name) == .orderedAscending }
    }

    private var footer: String {
        switch OutputDestinationMode(rawValue: outputMode) ?? .sourceFolder {
        case .sourceFolder: "Results are saved in the same folder as each original, e.g. clip.mov → clip-compressed.mp4. Recordings and downloads go to Downloads. Originals are never modified or replaced."
        case .downloads: "Results are saved straight into Downloads. Originals are never modified."
        case .custom: "Results are saved straight into the folder you choose. Originals are never modified."
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
    /// Set when the last combination pressed already opens a tool.
    @State private var takenBy: Tool?

    var body: some View {
        HStack(spacing: 8) {
            if let takenBy {
                Text("Opens \(takenBy.name)").foregroundStyle(.orange)
            }
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
        takenBy = nil
        HotKeyManager.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, modifiers.isEmpty { // Esc
                stopRecording()
            } else if let recorded = HotKeyShortcut(event: event) {
                if let tool = HotKeyManager.shared.tool(using: recorded) {
                    takenBy = tool
                    NSSound.beep()
                } else {
                    shortcut = recorded
                    recorded.save()
                    stopRecording()
                }
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
        takenBy = nil
        HotKeyManager.shared.isSuspended = false
    }
}
