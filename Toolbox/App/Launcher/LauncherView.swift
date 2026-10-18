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
        /// Actions with the same group are listed together, separated from other groups by a divider.
        let group: Int
        let perform: @MainActor () -> Void
    }

    /// Text fields write their value back when they lose focus, so only react to real edits.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            highlighted = 0
            actionsOpen = false
        }
    }
    var highlighted = 0
    private(set) var actionsOpen = false
    var actionHighlighted = 0
    var actionQuery = "" {
        didSet { if actionQuery != oldValue { actionHighlighted = 0 } }
    }
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
        actionQuery = ""
        actionHighlighted = 0
    }

    func closeActions() { actionsOpen = false }

    func moveAction(_ delta: Int) {
        let count = visibleActions.count
        guard count > 0 else { return }
        actionHighlighted = min(max(actionHighlighted + delta, 0), count - 1)
    }

    func performAction(at index: Int) {
        let list = visibleActions
        guard list.indices.contains(index) else { return }
        actionsOpen = false
        list[index].perform()
    }

    /// Actions matching the "Search for actions…" field.
    var visibleActions: [Action] {
        let query = actionQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var actions: [Action] {
        guard let tool = highlightedTool else { return [] }
        let launcher = LauncherController.shared
        var list = [Action(id: "open", title: "Open", symbol: "arrow.up.forward.app", keys: ["↩"], group: 0) {
            launcher.open(tool)
        }]
        if acceptedCount(for: tool) > 0 {
            list.append(Action(id: "open-empty", title: "Open Without Selected Files", symbol: "doc", keys: ["⌥", "↩"], group: 0) {
                launcher.open(tool, withFiles: false)
            })
        }
        let isFavorite = favorites.contains(tool.id)
        list.append(Action(id: "favorite", title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           symbol: isFavorite ? "star.slash" : "star", keys: ["⇧", "⌘", "F"], group: 1) { [weak self] in
            self?.toggleFavoriteOfHighlighted()
        })
        if isFavorite {
            list.append(Action(id: "up", title: "Move Favorite Up", symbol: "arrow.up", keys: ["⌥", "⌘", "↑"], group: 1) { [weak self] in
                self?.moveHighlightedFavorite(by: -1)
            })
            list.append(Action(id: "down", title: "Move Favorite Down", symbol: "arrow.down", keys: ["⌥", "⌘", "↓"], group: 1) { [weak self] in
                self?.moveHighlightedFavorite(by: 1)
            })
        }
        list.append(Action(id: "results", title: "Show Results Folder", symbol: "folder", keys: [], group: 2) {
            launcher.hide()
            let folder = AppSettings.outputMode == .custom ? (AppSettings.customOutputFolder ?? OutputManager.downloadsBase)
                                                           : OutputManager.downloadsBase
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        })
        list.append(Action(id: "window", title: "Open Toolbox Window", symbol: "macwindow", keys: ["⌘", "↩"], group: 2) {
            launcher.openMainWindow()
        })
        list.append(Action(id: "settings", title: "Toolbox Settings…", symbol: "gearshape", keys: ["⌘", ","], group: 2) {
            launcher.openSettings()
        })
        return list
    }
}

// MARK: - View

/// Colours sampled from Raycast's launcher so the panel reads the same in light and dark mode.
private struct LauncherPalette {
    let scheme: ColorScheme
    var isDark: Bool { scheme == .dark }

    /// Laid over the blur; mostly opaque so busy windows behind don't show through.
    var base: Color { isDark ? Color(white: 0.13).opacity(0.88) : Color(white: 0.952).opacity(0.86) }
    var rim: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.09) }
    var highlight: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.075) }
    var raised: Color { isDark ? Color(white: 0.20) : Color(white: 0.985) }
    var raisedRim: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.07) }
}

struct LauncherView: View {
    private enum Field { case search, actions }

    @Bindable var model: LauncherModel
    @FocusState private var focus: Field?
    @State private var mouseMovedSinceOpen = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: LauncherPalette { LauncherPalette(scheme: colorScheme) }
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
                actionsPanel
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.actionsOpen)
        .frame(width: LauncherPanel.size.width, height: LauncherPanel.size.height)
        .background {
            ZStack {
                LauncherBackground(cornerRadius: LauncherPanel.cornerRadius)
                palette.base
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.rim, lineWidth: 1))
        .onAppear { focus = .search }
        .onChange(of: model.focusRequest) {
            focus = .search
            mouseMovedSinceOpen = false
        }
        .onChange(of: model.actionsOpen) { focus = model.actionsOpen ? .actions : .search }
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
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        LauncherController.shared.openMainWindow()
                    } else if let tool = model.highlightedTool {
                        LauncherController.shared.open(tool, withFiles: !press.modifiers.contains(.option))
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !model.query.isEmpty { model.query = "" } else { LauncherController.shared.hide() }
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
        .background(Color.accentColor.opacity(0.13), in: Capsule())
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
                                .id(row.id)
                        case .tool(let tool, let index):
                            LauncherRow(tool: tool, isHighlighted: index == model.highlighted,
                                        fileCount: model.acceptedCount(for: tool), highlight: palette.highlight)
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
                // Keep the first section's header visible when the top row is selected.
                if model.highlighted == 0 { proxy.scrollTo(rows.first?.id, anchor: .top) }
                else if let tool = model.highlightedTool { proxy.scrollTo("tool:\(tool.id)") }
            }
            .onChange(of: model.query) { proxy.scrollTo(rows.first?.id, anchor: .top) }
            .onChange(of: model.focusRequest) { proxy.scrollTo(rows.first?.id, anchor: .top) }
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
                Image(systemName: "equal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(raisedSurface(Circle()))

            Spacer()

            if !model.actionsOpen {
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
                .background(raisedSurface(Capsule()))
            }
        }
        .padding(10)
    }

    /// The near-white floating surface used by the footer controls and the actions panel.
    private func raisedSurface<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(palette.raised.opacity(0.94))
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(palette.raisedRim))
            .shadow(color: .black.opacity(palette.isDark ? 0.3 : 0.08), radius: 8, y: 2)
    }

    // MARK: Actions (⌘K)

    private var actionsPanel: some View {
        let actions = model.visibleActions
        return VStack(alignment: .leading, spacing: 0) {
            if let tool = model.highlightedTool {
                Text(tool.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 1) {
                if actions.isEmpty {
                    Text("No matching actions")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                }
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0, actions[index - 1].group != action.group {
                        Divider().padding(.horizontal, 6).padding(.vertical, 5)
                    }
                    actionRow(action, isHighlighted: index == model.actionHighlighted)
                        .onTapGesture { model.performAction(at: index) }
                        .onHover { if $0 { model.actionHighlighted = index } }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            Divider()
            TextField("Search for actions…", text: $model.actionQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focus, equals: .actions)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .onKeyPress(.downArrow) { model.moveAction(1); return .handled }
                .onKeyPress(.upArrow) { model.moveAction(-1); return .handled }
                .onKeyPress(.return, phases: .down) { _ in
                    model.performAction(at: model.actionHighlighted)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if model.actionQuery.isEmpty { model.closeActions() } else { model.actionQuery = "" }
                    return .handled
                }
        }
        .frame(width: 350)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(palette.raisedRim))
        .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.14), radius: 18, y: 6)
    }

    private func actionRow(_ action: LauncherModel.Action, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 13))
                .frame(width: 18)
            Text(action.title)
            Spacer(minLength: 12)
            HStack(spacing: 3) { ForEach(action.keys, id: \.self) { KeyCap($0) } }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isHighlighted ? palette.highlight : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct LauncherRow: View {
    let tool: Tool
    let isHighlighted: Bool
    let fileCount: Int
    let highlight: Color

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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(isHighlighted ? highlight : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.13)))
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
