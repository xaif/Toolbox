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
            Section("Shortcut") {
                Toggle("Open Toolbox from any app with ⌃⌥Space", isOn: $hotKeyEnabled)
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
