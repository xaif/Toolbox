import AppKit

/// Owns the global shortcuts: registers them from Settings and routes presses to the launcher, the window
/// or a tool.
@MainActor
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// True when macOS refused the shortcut, usually because another app already uses it.
    private(set) var registrationFailed = false

    /// Hotkeys that open a tool directly, keyed by tool ID. Set from the launcher's ⌘K actions.
    private(set) var toolShortcuts: [String: HotKeyShortcut] {
        didSet {
            UserDefaults.standard.set(toolShortcuts.mapValues { ["keyCode": Int($0.keyCode), "modifiers": Int($0.modifiers)] },
                                      forKey: SettingsKey.toolHotKeys)
            update()
        }
    }

    /// Tools whose hotkey macOS refused.
    private(set) var failedToolIDs: Set<String> = []

    /// Set while a recorder is listening, so pressing a shortcut that's in use can be recorded.
    var isSuspended = false {
        didSet { update() }
    }

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var registered: HotKeyShortcut?
    @ObservationIgnored private var toolHotKeys: [String: GlobalHotKey] = [:]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: SettingsKey.toolHotKeys) as? [String: [String: Int]] ?? [:]
        toolShortcuts = stored.compactMapValues { value in
            guard let keyCode = value["keyCode"], let modifiers = value["modifiers"] else { return nil }
            return HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        }
    }

    func update() {
        updateMainHotKey()
        updateToolHotKeys()
    }

    func setShortcut(_ shortcut: HotKeyShortcut?, for toolID: String) {
        toolShortcuts[toolID] = shortcut
    }

    /// The tool that `shortcut` opens, if any.
    func tool(using shortcut: HotKeyShortcut) -> Tool? {
        toolShortcuts.first { $0.value == shortcut }.flatMap { ToolRegistry.tool($0.key) }
    }

    private func updateMainHotKey() {
        guard AppSettings.hotKeyEnabled, !isSuspended else {
            hotKey = nil
            registered = nil
            registrationFailed = false
            return
        }
        let shortcut = HotKeyShortcut.current
        guard shortcut != registered else { return }
        hotKey = nil
        let newHotKey = GlobalHotKey(shortcut) { Task { @MainActor in HotKeyManager.shared.fire() } }
        registrationFailed = !newHotKey.isRegistered
        hotKey = newHotKey
        registered = shortcut
    }

    private func updateToolHotKeys() {
        let wanted = isSuspended ? [:] : toolShortcuts.filter { ToolRegistry.tool($0.key) != nil }
        for (id, hotKey) in toolHotKeys where wanted[id] != hotKey.shortcut {
            toolHotKeys[id] = nil
        }
        for (id, shortcut) in wanted where toolHotKeys[id] == nil {
            toolHotKeys[id] = GlobalHotKey(shortcut) { Task { @MainActor in HotKeyManager.shared.fire(toolID: id) } }
        }
        let failed = Set(toolHotKeys.filter { !$0.value.isRegistered }.keys)
        if failed != failedToolIDs { failedToolIDs = failed }
    }

    private func fire() {
        if UserDefaults.standard.string(forKey: SettingsKey.hotKeyAction) == HotKeyAction.window.rawValue {
            if NSApp.isActive, NSApp.keyWindow?.identifier?.rawValue == "main" {
                NSApp.hide(nil)
            } else {
                AppModel.shared.summon()
            }
        } else {
            LauncherController.shared.toggle()
        }
    }

    /// Opens a tool from its own hotkey. Like picking it in the launcher, it takes the files selected
    /// in Finder and runs tools with a quick action on them, or shows their options first.
    private func fire(toolID: String) {
        guard let tool = ToolRegistry.tool(toolID) else { return }
        let fromFinder = AppSettings.launcherUsesFinderSelection
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        LauncherController.shared.hide()
        Task {
            let files = fromFinder ? await FinderSelection.fetch() : []
            LauncherController.shared.activate(tool, files: files)
        }
    }
}
