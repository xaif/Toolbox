import SwiftUI

struct MetadataView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @State private var tags: [String: String] = [:]
    @State private var edits: [String: String] = [:]
    @State private var touched: Set<String> = []
    @State private var removesAll = false
    @State private var readError: String?
    private let editable = ["Title", "Author", "Artist", "Album", "Copyright", "Comment", "Description", "Make", "Model", "DateTimeOriginal", "GPSLatitude", "GPSLongitude"]
    init(tool: Tool) { self.tool = tool; _runner = State(initialValue: JobCenter.shared.runner(for: tool.id)) }
    var body: some View {
        BatchToolView(tool: tool, accepts: [.data], actionTitle: removesAll ? "Remove Metadata" : "Save Copy", noun: "files") {
            Toggle("Remove embedded metadata", isOn: $removesAll)
            if !removesAll {
                ForEach(editable, id: \.self) { key in
                    TextField(key, text: Binding(get: { edits[key] ?? "" }, set: { edits[key] = $0; touched.insert(key) }))
                }
                Text("Only changed fields are written. Clear a field to remove its tag. Edits apply to every selected file; unsupported tags depend on the format.").font(.caption).foregroundStyle(.secondary)
            }
            if let readError { Text(readError).foregroundStyle(.orange) }
            if !tags.isEmpty {
                DisclosureGroup("All metadata in the first file") {
                    ForEach(tags.keys.sorted(), id: \.self) { key in
                        LabeledContent(key) { Text(tags[key] ?? "").textSelection(.enabled).lineLimit(4) }
                    }
                }
            }
        } each: { [edits, removesAll, touched] input, context, progress in
            let executable = try Dependencies.require(.exiftool)
            let output = context.output(for: input, suffix: removesAll ? "no-metadata" : "metadata")
            try FileManager.default.copyItem(at: input.resolvingSymlinksInPath(), to: output)
            var arguments = ["-overwrite_original"]
            if removesAll { arguments += ["-all=", "-tagsFromFile", input.path, "-Orientation", "-ICC_Profile"] }
            else {
                for key in touched.sorted() { arguments.append("-\(key)=\(edits[key] ?? "")") }
                guard arguments.count > 1 else { throw ToolError.failed("Change a field or choose Remove Metadata.") }
            }
            try await ProcessRunner.runChecked(executable, arguments: arguments + [output.path])
            progress(1)
        }
        .task(id: runner.inputs.first) {
            tags = [:]; edits = [:]; touched = []; readError = nil
            guard let input = runner.inputs.first else { return }
            do {
                let result = try await ProcessRunner.runChecked(Dependencies.require(.exiftool), arguments: ["-j", "-s", input.path])
                let rows = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]
                tags = (rows?.first ?? [:]).mapValues { String(describing: $0) }
                edits = Dictionary(uniqueKeysWithValues: editable.map { ($0, tags[$0] ?? "") })
            } catch { readError = error.localizedDescription }
        }
    }
}
