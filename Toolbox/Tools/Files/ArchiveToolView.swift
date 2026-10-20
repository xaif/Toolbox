import SwiftUI
import UniformTypeIdentifiers

struct ArchiveToolView: View {
    let tool: Tool
    @AppStorage("archive.format") private var format = "zip"
    @State private var files: [URL] = []
    @State private var runner: JobRunner
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    var body: some View {
        if tool.id == "files.extract-archive" {
            BatchToolView(tool: tool, accepts: ConversionFamily.archive.types, actionTitle: "Extract", job: { Self.extractJob }) {
                Text("Creates a folder for each archive. Originals are kept. Archives containing links or unsafe paths are rejected.").foregroundStyle(.secondary)
            }
        } else {
            ToolPage(tool: tool, runner: runner) {
                Button("Choose Files and Folders…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK { files = panel.urls }
                }
                ForEach(files, id: \.self) { Text($0.lastPathComponent) }
                Picker("Format", selection: $format) { Text("ZIP").tag("zip"); Text("TAR").tag("tar"); Text("GZIP (.tar.gz)").tag("gz") }
            } footer: {
                JobBar(runner: runner, actionTitle: "Create Archive", canRun: !files.isEmpty) {
                    runner.start(title: tool.name, inputs: files) { [files, format] context in
                        let scratch = try context.makeScratchFolder()
                        defer { try? FileManager.default.removeItem(at: scratch) }
                        let output = context.output(named: files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Archive", extension: format == "gz" ? "tar.gz" : format)
                        try await ArchiveEngine.create(from: files, format: format, to: output, scratch: scratch)
                    }
                }
            }.dropDestination(for: URL.self) { urls, _ in files = urls; return true }
        }
    }
    static var extractJob: ToolJob {
        .each(verb: "Extracting") { input, context, progress in
            let folder = try context.outputFolder(named: input.deletingPathExtension().lastPathComponent + "-extracted", nextTo: input)
            try await ArchiveEngine.extract(input, to: folder)
            progress(1)
        }
    }
}
