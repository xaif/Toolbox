import SwiftUI

/// State for the quick launcher. Reset every time the panel opens.
@MainActor
@Observable
final class LauncherModel {
    struct Section: Identifiable {
        let title: String
        let tools: [Tool]
        var id: String { title }
    }

    var query = "" {
        didSet { highlighted = 0 }
    }
    var highlighted = 0
    private(set) var finderFiles: [URL] = []
    private(set) var isLoadingFinder = false
    private(set) var focusRequest = 0
    /// How many of the Finder files each tool accepts, computed once per selection.
    private var acceptedCounts: [String: Int] = [:]
    @ObservationIgnored private var finderTask: Task<Void, Never>?

    func reset() {
        cancelFinderLookup()
        query = ""
        highlighted = 0
        finderFiles = []
        acceptedCounts = [:]
    }

    func requestFocus() { focusRequest += 1 }

    func loadFinderSelection() {
        isLoadingFinder = true
        finderTask = Task {
            let files = await FinderSelection.fetch()
            guard !Task.isCancelled else { return }
            useFiles(files)
            isLoadingFinder = false
        }
    }

    func cancelFinderLookup() {
        finderTask?.cancel()
        finderTask = nil
        isLoadingFinder = false
    }

    func clearFinderFiles() { useFiles([]) }

    func useFiles(_ files: [URL]) {
        finderFiles = files
        var counts: [String: Int] = [:]
        if !files.isEmpty {
            for tool in ToolRegistry.all {
                if let count = tool.input?.accepted(from: files).count, count > 0 { counts[tool.id] = count }
            }
        }
        acceptedCounts = counts
        highlighted = 0
    }

    func acceptedCount(for tool: Tool) -> Int { acceptedCounts[tool.id] ?? 0 }

    var sections: [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            var results = ToolRegistry.search(trimmed)
            if !acceptedCounts.isEmpty {
                // Stable partition: tools that take the selected files come first.
                results = results.filter { acceptedCounts[$0.id] != nil } + results.filter { acceptedCounts[$0.id] == nil }
            }
            return results.isEmpty ? [] : [Section(title: "Tools", tools: results)]
        }

        var sections: [Section] = []
        var shown = Set<String>()
        let recent = AppSettings.recentToolIDs.compactMap(ToolRegistry.tool)

        if !acceptedCounts.isEmpty {
            let recentRank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1.id, $0) })
            let forFiles = ToolRegistry.all
                .filter { acceptedCounts[$0.id] != nil && $0.id != "files.batch-rename" }
                .sorted { (recentRank[$0.id] ?? Int.max) < (recentRank[$1.id] ?? Int.max) }
                + ToolRegistry.all.filter { $0.id == "files.batch-rename" }
            let count = finderFiles.count
            sections.append(Section(title: "For \(count) selected \(count == 1 ? "file" : "files")", tools: forFiles))
            shown.formUnion(forFiles.map(\.id))
        }
        let recentRemaining = recent.filter { !shown.contains($0.id) }.prefix(5)
        if !recentRemaining.isEmpty {
            sections.append(Section(title: "Recent", tools: Array(recentRemaining)))
            shown.formUnion(recentRemaining.map(\.id))
        }
        let suggestions = ToolRegistry.suggestions.filter { !shown.contains($0.id) }
        if !suggestions.isEmpty, acceptedCounts.isEmpty {
            sections.append(Section(title: "Suggestions", tools: suggestions))
        }
        return sections
    }

    var flatTools: [Tool] { sections.flatMap(\.tools) }

    func move(_ delta: Int) {
        let count = flatTools.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    var highlightedTool: Tool? {
        let tools = flatTools
        return tools.indices.contains(highlighted) ? tools[highlighted] : nil
    }
}

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool
    @State private var mouseMovedSinceOpen = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            results
            Divider().opacity(0.6)
            footer
        }
        .background(LauncherBackground())
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) {
            searchFocused = true
            mouseMovedSinceOpen = false
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search tools…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        LauncherController.shared.openMainWindow()
                    } else if let tool = model.highlightedTool {
                        LauncherController.shared.open(tool)
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { LauncherController.shared.hide() } else { model.query = "" }
                    return .handled
                }
            if model.isLoadingFinder {
                ProgressView().controlSize(.small)
            } else if !model.finderFiles.isEmpty {
                finderChip
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var finderChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.on.doc.fill").font(.caption)
            Text(chipTitle).lineLimit(1)
            Button { model.clearFinderFiles() } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .help("Don't use the Finder selection")
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .fixedSize()
        .help("Selected in Finder. The tool you open gets these files.")
    }

    private enum Row: Identifiable {
        case header(String, isFirst: Bool)
        case tool(Tool, index: Int)

        var id: String {
            switch self {
            case .header(let title, _): "header:\(title)"
            case .tool(let tool, _): "tool:\(tool.id)"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var index = 0
        for (sectionIndex, section) in model.sections.enumerated() {
            rows.append(.header(section.title, isFirst: sectionIndex == 0))
            for tool in section.tools {
                rows.append(.tool(tool, index: index))
                index += 1
            }
        }
        return rows
    }

    private var chipTitle: String {
        guard model.finderFiles.count == 1 else { return "\(model.finderFiles.count) files" }
        let name = model.finderFiles[0].lastPathComponent
        return name.count > 26 ? "\(name.prefix(12))…\(name.suffix(12))" : name
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.flatTools.isEmpty {
                        Text("No tools match “\(model.query)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title, let isFirst):
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, isFirst ? 4 : 12)
                                .padding(.bottom, 4)
                        case .tool(let tool, let index):
                            LauncherRow(tool: tool, isHighlighted: index == model.highlighted,
                                        fileCount: model.acceptedCount(for: tool))
                                .onTapGesture { LauncherController.shared.open(tool) }
                                .onContinuousHover { phase in
                                    // Ignore the hover the pointer is already resting on when the panel opens.
                                    if case .active = phase {
                                        if mouseMovedSinceOpen { model.highlighted = index } else { mouseMovedSinceOpen = true }
                                    }
                                }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.highlighted) {
                if let tool = model.highlightedTool { proxy.scrollTo("tool:\(tool.id)") }
            }
            .onChange(of: model.query) { proxy.scrollTo(rows.first?.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
            Text("Toolbox").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            FooterHint(label: "Open", keys: ["↩"])
            FooterHint(label: "Toolbox Window", keys: ["⌘", "↩"])
            FooterHint(label: "Close", keys: ["esc"])
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

private struct LauncherRow: View {
    let tool: Tool
    let isHighlighted: Bool
    let fileCount: Int

    var body: some View {
        HStack(spacing: 11) {
            ToolIcon(tool: tool, size: 28)
            Text(tool.name).font(.system(size: 14, weight: .medium))
            Text(tool.summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if fileCount > 0 {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Text(tool.category.name)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct FooterHint: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.caption.weight(.medium))
                    .frame(minWidth: 18)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .font(.callout)
    }
}

/// Behind-window blur that stays vibrant even though the app isn't active.
private struct LauncherBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
