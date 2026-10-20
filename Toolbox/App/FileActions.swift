import AppKit
import SwiftUI

enum FileAction: String, CaseIterable, Identifiable {
    case airDrop, float, copy, move, copyPath, terminal
    var id: Self { self }
    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }
    var symbol: String {
        switch self {
        case .airDrop: "airplayaudio"
        case .float: "pin.fill"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "doc.text"
        case .terminal: "terminal"
        }
    }
}

@MainActor
enum FileActions {
    static func perform(_ action: FileAction, files: [URL], anchor: NSView? = nil) {
        let files = files.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(files as [NSURL])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        case .float: FloatingShelf.shared.show(files)
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else { showError("AirDrop isn't available on this Mac."); return }
            service.perform(withItems: files)
        case .terminal:
            let folders = Array(Set(files.map { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
            })).sorted { $0.path < $1.path }
            let bundle = UserDefaults.standard.string(forKey: "files.terminal") == "iterm" ? "com.googlecode.iterm2" : "com.apple.Terminal"
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { showError("The selected terminal app isn't installed."); return }
            NSWorkspace.shared.open(folders, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case .move: move(files)
        }
    }

    private static func move(_ files: [URL]) {
        NSApp.activate()
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
        picker.prompt = "Move Here"; picker.message = "Choose a destination for the original files."
        guard picker.runModal() == .OK, let destination = picker.url else { return }
        let fm = FileManager.default
        var moved: [(URL, URL)] = []
        do {
            let selected = Set(files.map { $0.standardizedFileURL })
            let roots = files.filter { input in
                !selected.contains(where: { other in other != input && input.standardizedFileURL.path.hasPrefix(other.standardizedFileURL.path + "/") })
            }
            for input in roots {
                let source = input.resolvingSymlinksInPath()
                let dest = destination.resolvingSymlinksInPath()
                guard dest != source, !dest.path.hasPrefix(source.path + "/") else { throw ToolError.failed("A folder can't be moved into itself.") }
                if input.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL { continue }
                let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let ext = isFolder ? "" : input.pathExtension
                let name = OutputManager.uniqueName(isFolder ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent, extension: ext) {
                    fm.fileExists(atPath: destination.appendingPathComponent($0).path)
                }
                let output = destination.appendingPathComponent(name)
                try fm.moveItem(at: input, to: output)
                moved.append((input, output))
            }
            if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved.map(\.1)) }
        } catch {
            var rollbackFailures: [String] = []
            for (source, target) in moved.reversed() {
                do { try fm.moveItem(at: target, to: source) } catch { rollbackFailures.append(target.path) }
            }
            showError(error.localizedDescription + (rollbackFailures.isEmpty ? "" : "\nSome files remain at:\n" + rollbackFailures.joined(separator: "\n")))
        }
    }
    static func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "File action couldn't finish"; alert.informativeText = message
        alert.runModal()
    }
}

@MainActor @Observable
final class FloatingShelf {
    static let shared = FloatingShelf()
    var files: [URL] = []
    private var panel: NSPanel?
    func show(_ newFiles: [URL]) {
        for file in newFiles where !files.contains(file) { files.append(file) }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Floating Files"; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: FloatingShelfView(shelf: self))
            panel.minSize = NSSize(width: 240, height: 180)
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
    func pin(right: Bool) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: right ? frame.maxX - panel.frame.width : frame.minX, y: min(max(panel.frame.minY, frame.minY), frame.maxY-panel.frame.height)))
    }
}

private struct FloatingShelfView: View {
    @Bindable var shelf: FloatingShelf
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drag files into any app").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu { Button("Pin Left") { shelf.pin(right: false) }; Button("Pin Right") { shelf.pin(right: true) } } label: { Image(systemName: "pin") }
                Button { shelf.files.removeAll() } label: { Image(systemName: "trash") }.help("Clear shelf")
            }.padding(10)
            List {
                ForEach(shelf.files, id: \.self) { file in
                    HStack {
                        FileThumbnail(url: file)
                        Text(file.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button { shelf.files.removeAll { $0 == file } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .onDrag { NSItemProvider(object: file as NSURL) }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("Copy Path") { FileActions.perform(.copyPath, files: [file]) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in shelf.show(urls); return true }
    }
}

struct FileActionsView: View {
    let tool: Tool
    @State private var runner: JobRunner
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    private var files: [URL] { runner.inputs }
    var body: some View {
        ToolPage(tool: tool) {
            Button("Choose Files or Folders…") {
                let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.allowsMultipleSelection = true
                if picker.runModal() == .OK { runner.inputs = picker.urls }
            }
            ForEach(files, id: \.self) { Text($0.lastPathComponent) }
            LazyVGrid(columns: [.init(.adaptive(minimum: 140))]) {
                ForEach(FileAction.allCases) { action in
                    Button { FileActions.perform(action, files: files) } label: {
                        Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity).padding(12)
                    }.disabled(files.isEmpty)
                }
            }
            Text("Drop a mixed selection, including folders. Float keeps a reusable shelf above other apps. Move asks where to put the originals.")
                .foregroundStyle(.secondary)
        }
        .dropDestination(for: URL.self) { urls, _ in runner.inputs = urls; return true }
    }
}
