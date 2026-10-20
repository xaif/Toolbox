import SwiftUI

/// State for the quick launcher. Reset every time the panel opens.
@MainActor
@Observable
final class LauncherModel {
    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }

        init(title: String, tools: [Tool]) {
            self.title = title
            entries = tools.map(Entry.tool)
        }

        init(title: String, commands: [Command]) {
            self.title = title
            entries = commands.map(Entry.command)
        }
    }

    /// Something the launcher does for Toolbox itself rather than a tool, like Check for Updates.
    struct Command: Identifiable, Equatable {
        let id: String
        let title: String
        var subtitle: String?
        /// What ↩ does, shown in the action bar.
        let actionTitle: String
        /// Searched along with the title.
        var keywords: [String] = []
        let perform: @MainActor () -> Void

        static func == (lhs: Command, rhs: Command) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
        }
    }

    /// A row in the results.
    enum Entry: Identifiable, Equatable {
        case tool(Tool)
        case command(Command)

        var id: String {
            switch self {
            case .tool(let tool): "tool:\(tool.id)"
            case .command(let command): "command:\(command.id)"
            }
        }

        var tool: Tool? {
            if case .tool(let tool) = self { tool } else { nil }
        }

        var command: Command? {
            if case .command(let command) = self { command } else { nil }
        }
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
    /// Pointer hover changes selection without moving the list under the pointer.
    private(set) var selectionScrollRequest = 0
    private(set) var actionsOpen = false
    var actionHighlighted = 0
    var actionQuery = "" {
        didSet { if actionQuery != oldValue { actionHighlighted = 0 } }
    }
    private(set) var finderFiles: [URL] = []
    private(set) var isLoadingFinder = false
    private(set) var focusRequest = 0
    /// The tool whose hotkey is being recorded (⌘K › Set Hotkey).
    private(set) var hotKeyTool: Tool?
    /// Modifiers held down while recording, shown until a key completes the combination.
    private(set) var heldModifiers: [String] = []
    /// Why the last combination pressed while recording can't be used.
    private(set) var hotKeyProblem: String?
    /// The tool whose options are shown in place of the results (⇥, or ↩ on a tool that asks first).
    private(set) var optionsTool: Tool?
    /// Moves through and changes `optionsTool`'s options from the keyboard.
    let optionsForm = OptionsNavigator()
    /// How many of the Finder files each tool accepts, computed once per selection.
    private var acceptedCounts: [String: Int] = [:]
    @ObservationIgnored private var finderTask: Task<Void, Never>?
    @ObservationIgnored private var hotKeyMonitor: Any?

    private var favorites: Favorites { Favorites.shared }

    func reset() {
        cancelFinderLookup()
        stopRecordingHotKey()
        query = ""
        highlighted = 0
        actionsOpen = false
        optionsTool = nil
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

    /// Whether `tool` can run on the selected files from the launcher, perhaps after showing its options.
    func canQuickRun(_ tool: Tool) -> Bool {
        guard let action = tool.quickAction else { return false }
        return acceptedCount(for: tool) >= action.minimumFiles && QuickRun.isAvailable(tool)
    }

    /// Whether ↩ shows `tool`'s options first instead of running it: the tool asks for them (a size, an
    /// angle), its saved options are incomplete, or running right away is turned off in Settings.
    func asksFirst(_ tool: Tool) -> Bool {
        canQuickRun(tool) && (tool.quickAction?.asksFirst == true || !AppSettings.launcherRunsTools || !QuickRun.isReady(tool))
    }

    /// What ↩ does for `tool`, e.g. "Compress 3 Files", "Resize 3 Files…" (options first) or "Open Tool".
    func primaryTitle(for tool: Tool?) -> String {
        guard let tool, canQuickRun(tool), let verb = tool.quickAction?.verb else { return "Open Tool" }
        let count = acceptedCount(for: tool)
        let title = "\(verb) \(count) \(count == 1 ? "File" : "Files")"
        return optionsTool == nil && asksFirst(tool) ? title + "…" : title
    }

    // MARK: Options (⇥)

    func showOptions(for tool: Tool) {
        guard canQuickRun(tool) else { return }
        actionsOpen = false
        optionsForm.reset(submit: { modifiers in
            if modifiers.contains(.shift) {
                LauncherController.shared.open(tool, run: false)
            } else {
                LauncherController.shared.run(tool)
            }
        }, cancel: { [weak self] in
            self?.closeOptions()
        })
        optionsTool = tool
    }

    func closeOptions() {
        optionsTool = nil
        requestFocus()
    }

    // MARK: Results

    var sections: [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            var results = ToolRegistry.search(trimmed)
            if !acceptedCounts.isEmpty {
                // Stable partition: tools that take the selected files come first.
                results = results.filter { acceptedCounts[$0.id] != nil } + results.filter { acceptedCounts[$0.id] == nil }
            }
            var sections: [Section] = []
            let commands = commands(matching: trimmed)
            if !commands.isEmpty { sections.append(Section(title: "Toolbox", commands: commands)) }
            if !results.isEmpty { sections.append(Section(title: "Results", tools: results)) }
            return sections
        }

        var sections: [Section] = []
        // Like Raycast, a waiting update sits at the top until it's installed, skipped or put off.
        if acceptedCounts.isEmpty, Updater.shared.showsBanner, let update = Updater.shared.update {
            sections.append(Section(title: "Update Available", commands: [updateCommand(update)]))
        }
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

    var flatEntries: [Entry] { sections.flatMap(\.entries) }

    func move(_ delta: Int) {
        let count = flatEntries.count
        guard count > 0 else { return }
        let next = min(max(highlighted + delta, 0), count - 1)
        guard next != highlighted else { return }
        highlighted = next
        selectionScrollRequest += 1
    }

    var highlightedEntry: Entry? {
        let entries = flatEntries
        return entries.indices.contains(highlighted) ? entries[highlighted] : nil
    }

    var highlightedTool: Tool? { highlightedEntry?.tool }
    var highlightedCommand: Command? { highlightedEntry?.command }

    // MARK: Commands

    /// Toolbox's own commands, found by searching.
    private var commands: [Command] {
        let updater = Updater.shared
        var list: [Command] = []
        if updater.hasUpdate, let update = updater.update { list.append(updateCommand(update)) }
        list.append(Command(id: "check-for-updates", title: "Check for Updates", subtitle: "Toolbox \(updater.currentVersion)",
                            actionTitle: "Check Now",
                            keywords: ["update", "upgrade", "version", "new", "changelog", "release", "toolbox"]) {
            UpdateWindowController.shared.show(check: true)
        })
        return list
    }

    private func updateCommand(_ update: AppUpdate) -> Command {
        Command(id: "install-update", title: "Update to Toolbox \(update.version)", subtitle: "See what's new",
                actionTitle: "See What's New",
                keywords: ["update", "upgrade", "install", "version", "new", "changelog", "release"]) {
            UpdateWindowController.shared.show()
        }
    }

    /// Commands whose title or keywords start with every word typed.
    private func commands(matching query: String) -> [Command] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return commands.filter { command in
            let tokens = (command.title.lowercased().split(separator: " ") + command.keywords.map { Substring($0) })
            return words.allSatisfy { word in tokens.contains { $0.hasPrefix(word) } }
        }
    }

    // MARK: Favorites

    func toggleFavoriteOfHighlighted() {
        if let tool = highlightedTool { toggleFavorite(tool) }
    }

    func moveHighlightedFavorite(by offset: Int) {
        if let tool = highlightedTool { moveFavorite(tool, by: offset) }
    }

    func toggleFavorite(_ tool: Tool) {
        favorites.toggle(tool.id)
        keepHighlight(on: tool)
    }

    func moveFavorite(_ tool: Tool, by offset: Int) {
        guard favorites.contains(tool.id) else { return }
        favorites.move(tool.id, by: offset)
        keepHighlight(on: tool)
    }

    private func keepHighlight(on tool: Tool) {
        if let index = flatEntries.firstIndex(of: .tool(tool)) {
            highlighted = index
            selectionScrollRequest += 1
        }
    }

    // MARK: Actions (⌘K)

    func toggleActions() {
        guard highlightedTool != nil || optionsTool != nil else { return }
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

    /// The ⌘K actions: for the tool whose options are shown, otherwise for the highlighted tool.
    var actions: [Action] {
        if let tool = optionsTool { return optionsActions(for: tool) }
        return highlightedTool.map(actions(for:)) ?? []
    }

    /// Actions in the options view. Everything also has a button, so it works without the keyboard.
    private func optionsActions(for tool: Tool) -> [Action] {
        let launcher = LauncherController.shared
        return [
            Action(id: "run", title: primaryTitle(for: tool), symbol: "play", keys: ["↩"], group: 0) {
                launcher.run(tool)
            },
            Action(id: "open", title: "Open in Toolbox Window", symbol: "macwindow", keys: ["⇧", "↩"], group: 0) {
                launcher.open(tool, run: false)
            },
            Action(id: "back", title: "Back to All Tools", symbol: "chevron.left", keys: ["esc"], group: 1) { [weak self] in
                self?.closeOptions()
            },
        ]
    }

    /// The actions for `tool`'s row: the ⌘K panel, its … button and its right-click menu.
    func actions(for tool: Tool) -> [Action] {
        let launcher = LauncherController.shared
        var list: [Action] = []
        if canQuickRun(tool) {
            list.append(Action(id: "run", title: primaryTitle(for: tool), symbol: "play", keys: ["↩"], group: 0) {
                launcher.activate(tool)
            })
            list.append(Action(id: "options", title: "Show Options", symbol: "slider.horizontal.3", keys: ["⇥"], group: 0) { [weak self] in
                self?.showOptions(for: tool)
            })
            list.append(Action(id: "open", title: "Open Tool", symbol: "arrow.up.forward.app", keys: ["⇧", "↩"], group: 0) {
                launcher.open(tool, run: false)
            })
        } else {
            list.append(Action(id: "open", title: "Open", symbol: "arrow.up.forward.app", keys: ["↩"], group: 0) {
                launcher.open(tool)
            })
        }
        if acceptedCount(for: tool) > 0 {
            list.append(Action(id: "open-empty", title: "Open Without Selected Files", symbol: "doc", keys: ["⌥", "↩"], group: 0) {
                launcher.open(tool, withFiles: false)
            })
        }
        let isFavorite = favorites.contains(tool.id)
        list.append(Action(id: "favorite", title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                           symbol: isFavorite ? "star.slash" : "star", keys: ["⇧", "⌘", "F"], group: 1) { [weak self] in
            self?.toggleFavorite(tool)
        })
        if isFavorite {
            list.append(Action(id: "up", title: "Move Favorite Up", symbol: "arrow.up", keys: ["⌥", "⌘", "↑"], group: 1) { [weak self] in
                self?.moveFavorite(tool, by: -1)
            })
            list.append(Action(id: "down", title: "Move Favorite Down", symbol: "arrow.down", keys: ["⌥", "⌘", "↓"], group: 1) { [weak self] in
                self?.moveFavorite(tool, by: 1)
            })
        }
        let hasHotKey = HotKeyManager.shared.toolShortcuts[tool.id] != nil
        list.append(Action(id: "hotkey", title: hasHotKey ? "Change Hotkey…" : "Set Hotkey…", symbol: "keyboard",
                           keys: [], group: 2) { [weak self] in
            self?.startRecordingHotKey(for: tool)
        })
        if hasHotKey {
            list.append(Action(id: "remove-hotkey", title: "Remove Hotkey", symbol: "minus.circle", keys: [], group: 2) {
                HotKeyManager.shared.setShortcut(nil, for: tool.id)
            })
        }
        // Results saved next to the originals (or wherever the user picks) have no one folder to show.
        if let folder = OutputManager.fixedFolder {
            list.append(Action(id: "results", title: "Show Results Folder", symbol: "folder", keys: [], group: 3) {
                launcher.hide()
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            })
        }
        list.append(Action(id: "window", title: "Open Toolbox Window", symbol: "macwindow", keys: ["⌘", "↩"], group: 3) {
            launcher.openMainWindow()
        })
        list.append(Action(id: "settings", title: "Toolbox Settings…", symbol: "gearshape", keys: ["⌘", ","], group: 3) {
            launcher.openSettings()
        })
        return list
    }

    // MARK: Hotkey (⌘K › Set Hotkey)

    var isRecordingHotKey: Bool { hotKeyTool != nil }

    /// Listens for the next key combination and makes it `tool`'s global hotkey.
    func startRecordingHotKey(for tool: Tool) {
        stopRecordingHotKey()
        actionsOpen = false
        hotKeyTool = tool
        // Release Toolbox's own hotkeys so pressing one reaches the recorder instead of firing.
        HotKeyManager.shared.isSuspended = true
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                heldModifiers = HotKeyShortcut.modifierSymbols(HotKeyShortcut.carbonModifiers(event.modifierFlags))
                return event
            }
            record(event)
            return nil
        }
    }

    func stopRecordingHotKey() {
        if let hotKeyMonitor { NSEvent.removeMonitor(hotKeyMonitor) }
        hotKeyMonitor = nil
        guard hotKeyTool != nil else { return }
        hotKeyTool = nil
        heldModifiers = []
        hotKeyProblem = nil
        HotKeyManager.shared.isSuspended = false
    }

    func removeRecordingHotKey() {
        guard let tool = hotKeyTool else { return }
        HotKeyManager.shared.setShortcut(nil, for: tool.id)
        stopRecordingHotKey()
    }

    private func record(_ event: NSEvent) {
        guard let tool = hotKeyTool else { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 53 { // Esc
            stopRecordingHotKey()
        } else if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // ⌫, ⌦
            removeRecordingHotKey()
        } else if let shortcut = HotKeyShortcut(event: event) {
            if let problem = problem(with: shortcut, for: tool) {
                hotKeyProblem = problem
                NSSound.beep()
            } else {
                HotKeyManager.shared.setShortcut(shortcut, for: tool.id)
                stopRecordingHotKey()
            }
        } else {
            hotKeyProblem = "Include ⌘, ⌥ or ⌃ in the hotkey."
            NSSound.beep()
        }
    }

    /// Why `shortcut` can't open `tool`, or nil if it can.
    private func problem(with shortcut: HotKeyShortcut, for tool: Tool) -> String? {
        let keys = shortcut.displayString
        if AppSettings.hotKeyEnabled, shortcut == .current {
            return "\(keys) is Toolbox's global shortcut."
        }
        if let other = HotKeyManager.shared.tool(using: shortcut), other != tool {
            return "\(keys) already opens \(other.name)."
        }
        // Toolbox's own hotkeys are released while recording, so this only catches other apps.
        if !GlobalHotKey.isAvailable(shortcut) {
            return "Another app already uses \(keys)."
        }
        return nil
    }
}

// MARK: - View

/// Fills for content on the launcher's glass, tuned to read over light and dark backgrounds.
struct LauncherPalette {
    let scheme: ColorScheme
    var isDark: Bool { scheme == .dark }

    /// Smokes the glass in dark mode: over bright windows, regular glass alone turns mid-gray and washes
    /// out light text.
    var smoke: Color { isDark ? Color.black.opacity(0.3) : .clear }
    /// The selected row, and the backgrounds of small buttons.
    var highlight: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07) }
    /// Grouped content sitting on the glass, like the options form.
    var card: Color { isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.5) }
    var cardRim: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }
}

struct LauncherView: View {
    private enum Field { case search, actions, options }

    /// The ⌘K actions and the hotkey recorder sit in the bottom-trailing corner, concentric with the panel.
    private static let popoverRadius = LauncherPanel.cornerRadius - LauncherPanel.inset
    /// How far up from the bottom content has to sit to be clear of the floating controls.
    private static let controlsClearance = LauncherPanel.inset * 2 + LauncherPanel.controlHeight + 6

    @Bindable var model: LauncherModel
    @FocusState private var focus: Field?
    @State private var lastPointerLocation: NSPoint?
    /// Bumped when saved settings change, so the options pane re-checks whether the tool can run.
    @State private var settingsRevision = 0
    @Namespace private var glassNamespace
    @Environment(\.colorScheme) private var colorScheme

    private var palette: LauncherPalette { LauncherPalette(scheme: colorScheme) }
    private let shape = RoundedRectangle(cornerRadius: LauncherPanel.cornerRadius, style: .continuous)

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let tool = model.optionsTool {
                    optionsHeader(tool)
                    optionsPane(tool)
                } else {
                    searchBar
                    results
                }
            }
            if model.actionsOpen || model.isRecordingHotKey {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.closeActions()
                        model.stopRecordingHotKey()
                    }
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.smoke)
        .clipShape(shape)
        .onAppear {
            updateFocus()
            lastPointerLocation = NSEvent.mouseLocation
        }
        .onChange(of: model.focusRequest) {
            updateFocus()
            lastPointerLocation = NSEvent.mouseLocation
        }
        .onChange(of: model.actionsOpen) { updateFocus() }
        .onChange(of: model.isRecordingHotKey) { updateFocus() }
        .onChange(of: model.optionsTool) { updateFocus() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settingsRevision += 1
        }
    }

    /// The hotkey recorder reads keys itself, so no field keeps focus while it's open.
    private func updateFocus() {
        if model.isRecordingHotKey {
            focus = nil
        } else if model.actionsOpen {
            // The actions field is added in this same update, and focus set before it exists is dropped,
            // leaving ↑↓ moving the results behind the panel.
            DispatchQueue.main.async { if model.actionsOpen { focus = .actions } }
        } else if model.optionsTool != nil {
            // A focused text option takes the keyboard back itself.
            if model.optionsForm.isEditingText { model.optionsForm.restoreTextFocus() } else { focus = .options }
        } else {
            focus = .search
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 11) {
            // Sized like the rows' tool icons, so the query lines up with their names.
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            TextField("Search tools — try “compress”, “pdf” or “gif”", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($focus, equals: .search)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        LauncherController.shared.openMainWindow()
                    } else if let command = model.highlightedCommand {
                        LauncherController.shared.perform(command)
                    } else if let tool = model.highlightedTool {
                        if press.modifiers.isDisjoint(with: [.option, .shift]) {
                            LauncherController.shared.activate(tool)
                        } else {
                            LauncherController.shared.open(tool, withFiles: !press.modifiers.contains(.option),
                                                           run: !press.modifiers.contains(.shift))
                        }
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let tool = model.highlightedTool, model.canQuickRun(tool) else { return .ignored }
                    model.showOptions(for: tool)
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
        .frame(height: 60)
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
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
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
        /// `section` is the title of the section the row is in.
        case tool(Tool, index: Int, section: String)
        case command(LauncherModel.Command, index: Int)

        var id: String {
            switch self {
            case .header(let title, _): "header:\(title)"
            case .tool(let tool, _, _): LauncherModel.Entry.tool(tool).id
            case .command(let command, _): LauncherModel.Entry.command(command).id
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var index = 0
        for (sectionIndex, section) in model.sections.enumerated() {
            rows.append(.header(section.title, isFirst: sectionIndex == 0))
            for entry in section.entries {
                switch entry {
                case .tool(let tool): rows.append(.tool(tool, index: index, section: section.title))
                case .command(let command): rows.append(.command(command, index: index))
                }
                index += 1
            }
        }
        return rows
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.flatEntries.isEmpty {
                        ContentUnavailableView.search(text: model.query)
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title, let isFirst):
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 11)
                                .padding(.top, isFirst ? 2 : 14)
                                .padding(.bottom, 6)
                                .id(row.id)
                        case .command(let command, let index):
                            LauncherCommandRow(command: command, isHighlighted: index == model.highlighted,
                                               highlight: palette.highlight)
                                .id(row.id)
                                .onTapGesture { LauncherController.shared.perform(command) }
                                .onContinuousHover { phase in
                                    if case .active = phase, !model.actionsOpen, !model.isRecordingHotKey {
                                        let location = NSEvent.mouseLocation
                                        if let previous = lastPointerLocation, location != previous {
                                            model.highlighted = index
                                        }
                                        lastPointerLocation = location
                                    }
                                }
                        case .tool(let tool, let index, let section):
                            // Within a category's own section its name would only repeat the header.
                            LauncherRow(tool: tool, isHighlighted: index == model.highlighted,
                                        subtitle: section == tool.category.name ? nil : tool.category.name,
                                        fileCount: model.acceptedCount(for: tool),
                                        hotKey: HotKeyManager.shared.toolShortcuts[tool.id]?.keyCaps ?? [],
                                        highlight: palette.highlight,
                                        showOptions: model.canQuickRun(tool) ? { model.showOptions(for: tool) } : nil,
                                        showActions: {
                                            model.highlighted = index
                                            model.toggleActions()
                                        })
                                .id(row.id)
                                .onTapGesture { LauncherController.shared.activate(tool) }
                                .contextMenu { contextMenu(for: tool) }
                                .onContinuousHover { phase in
                                    // Layout changes and scrolling can emit hover updates with a stationary
                                    // pointer. Only a real pointer move should change the selected row.
                                    if case .active = phase, !model.actionsOpen, !model.isRecordingHotKey {
                                        let location = NSEvent.mouseLocation
                                        if let previous = lastPointerLocation, location != previous {
                                            model.highlighted = index
                                        }
                                        lastPointerLocation = location
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, LauncherPanel.inset)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            // The floating controls cover the bottom of the list. As safe area, it still lets rows scroll
            // under them, but moving the selection scrolls it to rest above them instead of beneath.
            .safeAreaPadding(.bottom, Self.controlsClearance)
            .mask {
                // Rows dissolve into the glass as they pass under the floating controls, and are gone by
                // the middle of them so the controls' glass doesn't pick up their colors.
                let gone = LauncherPanel.inset + LauncherPanel.controlHeight / 2
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.controlsClearance - gone)
                    Color.clear.frame(height: gone)
                }
            }
            .onChange(of: model.selectionScrollRequest) {
                // Keep the first section's header visible when the top row is selected.
                if model.highlighted == 0 { proxy.scrollTo(rows.first?.id, anchor: .top) }
                else if let entry = model.highlightedEntry { proxy.scrollTo(entry.id) }
            }
            .onChange(of: model.query) { proxy.scrollTo(rows.first?.id, anchor: .top) }
            .onChange(of: model.focusRequest) { proxy.scrollTo(rows.first?.id, anchor: .top) }
            .onChange(of: model.finderFiles) { proxy.scrollTo(rows.first?.id, anchor: .top) }
        }
    }

    // MARK: Floating controls

    /// The menu button and the action bar float over the results as Liquid Glass. ⌘K grows the action bar
    /// into the actions panel and shrinks it back, the way glass controls morph into what they open.
    private var controls: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom) {
                menuButton
                Spacer(minLength: 0)
                Group {
                    if let tool = model.hotKeyTool {
                        hotKeyRecorder(for: tool)
                            .glassEffect(.regular, in: .rect(cornerRadius: Self.popoverRadius))
                    } else if model.actionsOpen {
                        actionsPanel
                            .glassEffect(.regular, in: .rect(cornerRadius: Self.popoverRadius))
                    } else if model.optionsTool != nil || model.highlightedEntry != nil {
                        actionBar
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .glassEffectID("actions", in: glassNamespace)
            }
            .padding(LauncherPanel.inset)
        }
        .animation(Self.morph, value: model.actionsOpen)
        .animation(Self.morph, value: model.isRecordingHotKey)
    }

    /// A quick spring with a hint of overshoot, like the system's glass morphs.
    private static let morph = Animation.spring(response: 0.34, dampingFraction: 0.86)

    private var menuButton: some View {
        Menu {
            Button("Open Toolbox Window") { LauncherController.shared.openMainWindow() }
            Button("Toolbox Settings…") { LauncherController.shared.openSettings() }
            Button(Updater.shared.hasUpdate ? "Update to Toolbox \(Updater.shared.update?.version.description ?? "")…" : "Check for Updates…") {
                LauncherController.shared.hide()
                UpdateWindowController.shared.show(check: !Updater.shared.hasUpdate)
            }
            Divider()
            Button("Quit Toolbox") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "equal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: LauncherPanel.controlHeight, height: LauncherPanel.controlHeight)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
    }

    /// Raycast's action bar: the primary action, Options (when the tool has them) and Actions. Every
    /// part is a button, so the launcher works with the mouse alone.
    @ViewBuilder
    private var actionBar: some View {
        if model.optionsTool == nil, let command = model.highlightedCommand {
            Button { LauncherController.shared.perform(command) } label: {
                HStack(spacing: 7) {
                    Text(command.actionTitle).fontWeight(.medium)
                    KeyCap("↩")
                }
            }
            .buttonStyle(BarButtonStyle(highlight: palette.highlight))
            .font(.system(size: 13))
            .padding(.horizontal, BarButtonStyle.inset)
            .frame(height: LauncherPanel.controlHeight)
        } else {
            toolActionBar
        }
    }

    private var toolActionBar: some View {
        let optionsTool = model.optionsTool
        let tool = optionsTool ?? model.highlightedTool
        let ready = optionsTool.map(isReady) ?? true
        return HStack(spacing: 2) {
            Button {
                if let optionsTool { LauncherController.shared.run(optionsTool) }
                else if let tool { LauncherController.shared.activate(tool) }
            } label: {
                HStack(spacing: 7) {
                    Text(model.primaryTitle(for: tool)).fontWeight(.medium)
                    KeyCap("↩")
                }
            }
            .disabled(!ready)
            if optionsTool == nil, let tool, model.canQuickRun(tool) {
                barDivider
                Button { model.showOptions(for: tool) } label: {
                    HStack(spacing: 7) {
                        Text("Options").foregroundStyle(.secondary)
                        KeyCap("⇥")
                    }
                }
            }
            barDivider
            Button { model.toggleActions() } label: {
                HStack(spacing: 7) {
                    Text("Actions").foregroundStyle(.secondary)
                    KeyCap("⌘")
                    KeyCap("K")
                }
            }
        }
        .buttonStyle(BarButtonStyle(highlight: palette.highlight))
        .font(.system(size: 13))
        .padding(.horizontal, BarButtonStyle.inset)
        .frame(height: LauncherPanel.controlHeight)
    }

    private var barDivider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 16)
    }

    /// Whether `tool` can run with its saved options. Reads `settingsRevision` to refresh as they change.
    private func isReady(_ tool: Tool) -> Bool {
        _ = settingsRevision
        return QuickRun.isReady(tool)
    }

    /// A row's right-click menu: the same actions as ⌘K, grouped the same way.
    @ViewBuilder
    private func contextMenu(for tool: Tool) -> some View {
        let actions = model.actions(for: tool)
        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            if index > 0, actions[index - 1].group != action.group { Divider() }
            Button { action.perform() } label: { Label(action.title, systemImage: action.symbol) }
        }
    }

    // MARK: Options (⇥)

    private func optionsHeader(_ tool: Tool) -> some View {
        HStack(spacing: 12) {
            Button { model.closeOptions() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(palette.highlight, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Back to all tools")
            ToolIcon(tool: tool, size: 24)
            Text(tool.name)
                .font(.system(size: 18))
            Spacer(minLength: 0)
            if !model.finderFiles.isEmpty { finderChip }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    /// The tool's saved options, the same form as on its page in the Toolbox window, laid out as rows to
    /// move through with ↑↓ and change with ←→, space or typing.
    private func optionsPane(_ tool: Tool) -> some View {
        let form = model.optionsForm
        let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Options")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    Group {
                        if let options = tool.quickAction?.makeOptions {
                            KeyboardOptionsForm(navigator: form) { options() }
                                .padding(6)
                        } else {
                            Text("\(tool.name) has no options.")
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.card, in: card)
                    .overlay(card.strokeBorder(palette.cardRim))
                    Group {
                        if tool.quickAction?.combinesFiles == true {
                            Text("Files are combined in name order. To choose the order, open the tool (⇧↩).")
                        }
                        Text("Options are saved for next time, here and in the Toolbox window.")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, Self.controlsClearance) // room above the floating controls
            }
            .onChange(of: form.focusedID) {
                if let id = form.focusedID { proxy.scrollTo(id) }
                // Text options take the keyboard themselves; the rest are driven from here.
                if !form.isEditingText { focus = .options }
            }
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($focus, equals: .options)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { form.handle($0) }
    }

    // MARK: Actions (⌘K)

    private var actionsPanel: some View {
        let actions = model.visibleActions
        return VStack(alignment: .leading, spacing: 0) {
            if let tool = model.optionsTool ?? model.highlightedTool {
                Text(tool.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
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
                        Divider().padding(.horizontal, 10).padding(.vertical, 5)
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
                .padding(.horizontal, 16)
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
    }

    // MARK: Hotkey recorder (⌘K › Set Hotkey)

    private func hotKeyRecorder(for tool: Tool) -> some View {
        let current = HotKeyManager.shared.toolShortcuts[tool.id]
        let keys = model.heldModifiers.isEmpty ? current?.keyCaps ?? [] : model.heldModifiers
        let prompt = current == nil ? "Press a key combination" : "Press a new key combination"
        let well = RoundedRectangle(cornerRadius: Self.popoverRadius - 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Hotkey for \(tool.name)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    if keys.isEmpty {
                        Image(systemName: "keyboard")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(keys, id: \.self) { KeyCap($0, large: true) }
                }
                .frame(height: 30)
                Text(model.hotKeyProblem ?? prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(model.hotKeyProblem == nil ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(palette.highlight.opacity(0.5), in: well)
            .overlay(well.strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 16) {
                Button { model.stopRecordingHotKey() } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyCap("esc")
                    }
                }
                if current != nil {
                    Button { model.removeRecordingHotKey() } label: {
                        HStack(spacing: 6) {
                            Text("Remove Hotkey")
                            KeyCap("⌫")
                        }
                    }
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .frame(width: 350)
    }

    private func actionRow(_ action: LauncherModel.Action, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(action.title)
            Spacer(minLength: 12)
            HStack(spacing: 3) { ForEach(action.keys, id: \.self) { KeyCap($0) } }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isHighlighted ? palette.highlight : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A row for one of Toolbox's own commands, with the app icon, like Raycast's own commands.
private struct LauncherCommandRow: View {
    let command: LauncherModel.Command
    let isHighlighted: Bool
    let highlight: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: AppInfo.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .padding(-1)
            Text(command.title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("Command")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(isHighlighted ? highlight : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct LauncherRow: View {
    let tool: Tool
    let isHighlighted: Bool
    /// Shown after the name in sections that mix categories.
    let subtitle: String?
    let fileCount: Int
    let hotKey: [String]
    let highlight: Color
    /// Shows the tool's options in the launcher. Nil when it can't run on the selected files.
    let showOptions: (() -> Void)?
    /// Opens the actions panel for this row.
    let showActions: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            ToolIcon(tool: tool, size: 22)
            Text(tool.name)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if fileCount > 0 {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if !hotKey.isEmpty {
                HStack(spacing: 3) { ForEach(hotKey, id: \.self) { KeyCap($0) } }
            }
            // Like Raycast, hovering a row reveals its actions as buttons.
            if isHovered {
                HStack(spacing: 4) {
                    if let showOptions {
                        rowButton("slider.horizontal.3", help: "Options", action: showOptions)
                    }
                    rowButton("ellipsis", help: "Actions", action: showActions)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 40)
        .background(isHighlighted ? highlight : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(highlight, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A button in the floating action bar. A capsule, concentric with the bar's, lights up under the pointer
/// and deepens while pressed.
private struct BarButtonStyle: ButtonStyle {
    /// The gap between the bar's edge and its buttons.
    static let inset: CGFloat = 5
    let highlight: Color

    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration, highlight: highlight)
    }

    private struct BarButton: View {
        let configuration: Configuration
        let highlight: Color
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .frame(height: LauncherPanel.controlHeight - BarButtonStyle.inset * 2)
                .background(highlight.opacity(configuration.isPressed ? 1 : isHovered ? 0.6 : 0), in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { isHovered = $0 && isEnabled }
        }
    }
}

/// A small keyboard key, like the hints in Raycast's footer. `large` is for the hotkey recorder.
struct KeyCap: View {
    let key: String
    let large: Bool
    init(_ key: String, large: Bool = false) {
        self.key = key
        self.large = large
    }

    var body: some View {
        let side: CGFloat = large ? 28 : 18
        let radius: CGFloat = large ? 7 : 5
        Text(key)
            .font(.system(size: large ? 15 : 11, weight: .medium))
            .foregroundStyle(large ? .primary : .secondary)
            .frame(minWidth: side, minHeight: side)
            .padding(.horizontal, key.count > 1 ? (large ? 7 : 4) : 0)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Behind-window blur with rounded corners that stays vibrant even though the app isn't active.
struct LauncherBackground: NSViewRepresentable {
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
