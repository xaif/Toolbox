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

    struct Action: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let keys: [String]
        let perform: @MainActor () -> Void
    }

    var query = "" {
        didSet {
            highlighted = 0
            actionsOpen = false
        }
    }
    var highlighted = 0
    private(set) var actionsOpen = false
    var actionHighlighted = 0
    private(set) var finderFiles: [URL] = []
    private(set) var isLoadingFinder = false
    private(set) var focusRequest = 0
    /// How many of the Finder files each tool accepts, computed once per selection.
    private var acceptedCounts: [String: Int] = [:]
    @ObservationIgnored private var finderTask: Task<Void, Never>?

    private var favorites: Favorites { Favorites.shared }

    func reset() {
        cancelFinderLookup()
        query = ""
        highlighted = 0
        actionsOpen = false
        finderFiles = []
        acceptedCounts = [:]
    }

    func requestFocus() { focusRequest += 1 }

    // MARK: Finder selection

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

    // MARK: Results

    var sections: [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            var results = ToolRegistry.search(trimmed)
            if !acceptedCounts.isEmpty {
                // Stable partition: tools that take the selected files come first.
                results = results.filter { acceptedCounts[$0.id] != nil } + results.filter { acceptedCounts[$0.id] == nil }
            }
            return results.isEmpty ? [] : [Section(title: "Results", tools: results)]
        }

        var sections: [Section] = []
        var shown = Set<String>()
        func add(_ title: String, _ tools: [Tool]) {
            let fresh = tools.filter { !shown.contains($0.id) }
            guard !fresh.isEmpty else { return }
            sections.append(Section(title: title, tools: fresh))
            shown.formUnion(fresh.map(\.id))
        }

        if !acceptedCounts.isEmpty {
            let favoriteIDs = Set(favorites.ids)
            let forFiles = ToolRegistry.all
                .filter { acceptedCounts[$0.id] != nil && $0.id != "files.batch-rename" }
                .sorted { favoriteIDs.contains($0.id) && !favoriteIDs.contains($1.id) }
                + ToolRegistry.all.filter { $0.id == "files.batch-rename" }
            let count = finderFiles.count
            add("For \(count) Selected \(count == 1 ? "File" : "Files")", forFiles)
        }
        add("Favorites", favorites.tools)
        if acceptedCounts.isEmpty {
            let recent = AppSettings.recentToolIDs.compactMap(ToolRegistry.tool)
            let candidates = (recent + ToolRegistry.suggestions).filter { !shown.contains($0.id) }
            var unique: [Tool] = []
            for tool in candidates where !unique.contains(tool) { unique.append(tool) }
            add("Suggestions", Array(unique.prefix(5)))
        }
        for category in ToolCategory.allCases {
            add(category.name, ToolRegistry.tools(in: category))
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

    // MARK: Favorites

    func toggleFavoriteOfHighlighted() {
        guard let tool = highlightedTool else { return }
        favorites.toggle(tool.id)
        keepHighlight(on: tool)
    }

    func moveHighlightedFavorite(by offset: Int) {
        guard let tool = highlightedTool, favorites.contains(tool.id) else { return }
        favorites.move(tool.id, by: offset)
        keepHighlight(on: tool)
    }

    private func keepHighlight(on tool: Tool) {
        if let index = flatTools.firstIndex(of: tool) { highlighted = index }
    }

    // MARK: Actions (⌘K)

    func toggleActions() {
        guard highlightedTool != nil else { return }
        actionsOpen.toggle()
        actionHighlighted = 0
    }

    func closeActions() { actionsOpen = false }

    func moveAction(_ delta: Int) {
        let count = actions.count
        guard count > 0 else { return }
        actionHighlighted = min(max(actionHighlighted + delta, 0), count - 1)
    }

    func performAction(at index: Int) {
        let list = actions
        guard list.indices.contains(index) else { return }
        actionsOpen = false
        list[index].perform()
    }

    var actions: [Action] {
        guard let tool = highlightedTool else { return [] }
        let launcher = LauncherController.shared
        var list = [Action(id: "open", title: "Open \(tool.name)", symbol: "arrow.up.forward.app", keys: ["↩"]) {
            launcher.open(tool)
        }]
        if acceptedCount(for: tool) > 0 {
            list.append(Action(id: "open-empty", title: "Open Without Selected Files", symbol: "doc", keys: ["⌥", "↩"]) {
                launcher.open(tool, withFiles: false)
            })
        }
        let isFavorite = favorites.contains(tool.id)
        list.append(Action(id: "favorite", title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           symbol: isFavorite ? "star.slash" : "star", keys: ["⌘", "⇧", "F"]) { [weak self] in
            self?.toggleFavoriteOfHighlighted()
        })
        if isFavorite {
            list.append(Action(id: "up", title: "Move Up in Favorites", symbol: "arrow.up", keys: ["⌘", "⌥", "↑"]) { [weak self] in
                self?.moveHighlightedFavorite(by: -1)
            })
            list.append(Action(id: "down", title: "Move Down in Favorites", symbol: "arrow.down", keys: ["⌘", "⌥", "↓"]) { [weak self] in
                self?.moveHighlightedFavorite(by: 1)
            })
        }
        list.append(Action(id: "window", title: "Open Toolbox Window", symbol: "macwindow", keys: ["⌘", "↩"]) {
            launcher.openMainWindow()
        })
        list.append(Action(id: "settings", title: "Toolbox Settings…", symbol: "gearshape", keys: ["⌘", ","]) {
            launcher.openSettings()
        })
        return list
    }
}

// MARK: - View

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool
    @State private var mouseMovedSinceOpen = false
    @Environment(\.colorScheme) private var colorScheme

    private let shape = RoundedRectangle(cornerRadius: LauncherPanel.cornerRadius, style: .circular)

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                searchBar
                results
            }
            footer
            if model.actionsOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeActions() }
                actionsCard
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .padding(.bottom, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.actionsOpen)
        .frame(width: LauncherPanel.size.width, height: LauncherPanel.size.height)
        .background {
            ZStack {
                LauncherBackground(cornerRadius: LauncherPanel.cornerRadius)
                // A light veil gives the frosted, Raycast-like tone over dark content.
                colorScheme == .dark ? Color.black.opacity(0.10) : Color.white.opacity(0.28)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45), lineWidth: 1))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) {
            searchFocused = true
            mouseMovedSinceOpen = false
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 13) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search for tools…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($searchFocused)
                .onKeyPress(.downArrow) {
                    model.actionsOpen ? model.moveAction(1) : model.move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.actionsOpen ? model.moveAction(-1) : model.move(-1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if model.actionsOpen {
                        model.performAction(at: model.actionHighlighted)
                    } else if press.modifiers.contains(.command) {
                        LauncherController.shared.openMainWindow()
                    } else if let tool = model.highlightedTool {
                        LauncherController.shared.open(tool, withFiles: !press.modifiers.contains(.option))
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.actionsOpen { model.closeActions() }
                    else if !model.query.isEmpty { model.query = "" }
                    else { LauncherController.shared.hide() }
                    return .handled
                }
            Spacer(minLength: 0)
            if model.isLoadingFinder {
                ProgressView().controlSize(.small)
            } else if !model.finderFiles.isEmpty {
                finderChip
            } else {
                HStack(spacing: 6) {
                    Text("Toolbox Window").foregroundStyle(.secondary)
                    KeyCap("⌘")
                    KeyCap("↩")
                }
                .font(.system(size: 13))
                .onTapGesture { LauncherController.shared.openMainWindow() }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
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
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
        .fixedSize()
        .help("Selected in Finder. The tool you open gets these files.")
    }

    private var chipTitle: String {
        guard model.finderFiles.count == 1 else { return "\(model.finderFiles.count) files" }
        let name = model.finderFiles[0].lastPathComponent
        return name.count > 26 ? "\(name.prefix(12))…\(name.suffix(12))" : name
    }

    // MARK: Results

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

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.flatTools.isEmpty {
                        Text("No tools match “\(model.query)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title, let isFirst):
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, isFirst ? 2 : 14)
                                .padding(.bottom, 6)
                        case .tool(let tool, let index):
                            LauncherRow(tool: tool, isHighlighted: index == model.highlighted,
                                        fileCount: model.acceptedCount(for: tool))
                                .id(row.id)
                                .onTapGesture { LauncherController.shared.open(tool) }
                                .onContinuousHover { phase in
                                    // Ignore the hover the pointer is already resting on when the panel opens.
                                    if case .active = phase, !model.actionsOpen {
                                        if mouseMovedSinceOpen { model.highlighted = index } else { mouseMovedSinceOpen = true }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 60) // room to scroll the last row above the floating footer
            }
            .scrollIndicators(.never)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                }
            }
            .onChange(of: model.highlighted) {
                if let tool = model.highlightedTool { proxy.scrollTo("tool:\(tool.id)") }
            }
            .onChange(of: model.query) { proxy.scrollTo(rows.first?.id, anchor: .top) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Menu {
                Button("Open Toolbox Window") { LauncherController.shared.openMainWindow() }
                Button("Toolbox Settings…") { LauncherController.shared.openSettings() }
                Divider()
                Button("Quit Toolbox") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.regular, in: Circle())

            Spacer()

            HStack(spacing: 12) {
                Button { if let tool = model.highlightedTool { LauncherController.shared.open(tool) } } label: {
                    HStack(spacing: 7) {
                        Text("Open Tool").fontWeight(.medium)
                        KeyCap("↩")
                    }
                }
                .buttonStyle(.plain)
                Rectangle().fill(.separator).frame(width: 1, height: 16)
                Button { model.toggleActions() } label: {
                    HStack(spacing: 7) {
                        Text("Actions").foregroundStyle(.secondary)
                        KeyCap("⌘")
                        KeyCap("K")
                    }
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(10)
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let tool = model.highlightedTool {
                Text(tool.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 10) {
                    Image(systemName: action.symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(action.title)
                    Spacer(minLength: 12)
                    HStack(spacing: 3) { ForEach(action.keys, id: \.self) { KeyCap($0) } }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(index == model.actionHighlighted ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.performAction(at: index) }
                .onHover { if $0 { model.actionHighlighted = index } }
            }
        }
        .padding(6)
        .frame(width: 330)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

private struct LauncherRow: View {
    let tool: Tool
    let isHighlighted: Bool
    let fileCount: Int

    var body: some View {
        HStack(spacing: 11) {
            ToolIcon(tool: tool, size: 22)
            Text(tool.name)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Text(tool.category.name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if fileCount > 0 {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Tool")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(isHighlighted ? Color.primary.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A small keyboard key, like the hints in Raycast's footer.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
    }
}

/// Behind-window blur with rounded corners that stays vibrant even though the app isn't active.
private struct LauncherBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded-rect mask; the vibrancy layer ignores SwiftUI clipping.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
