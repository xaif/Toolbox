import AppKit

/// Owns the global shortcut: registers it from Settings and routes presses to the launcher or the window.
@MainActor
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// True when macOS refused the shortcut, usually because another app already uses it.
    private(set) var registrationFailed = false

    /// Set while the Settings recorder is listening, so pressing the current shortcut can be recorded.
    var isSuspended = false {
        didSet { update() }
    }

    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var registered: HotKeyShortcut?

    func update() {
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
}
