import AppKit

/// Toolbox's menu bar icon. A click opens the launcher, so it works without the keyboard shortcut;
/// clicking the menu bar leaves Finder in front, so the launcher still picks up its selection.
/// Right-click (or ⌃-click) shows a menu.
@MainActor
final class MenuBarIcon: NSObject {
    static let shared = MenuBarIcon()

    private var item: NSStatusItem?

    /// Shows or removes the icon to match Settings.
    func update() {
        if AppSettings.showsMenuBarIcon {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Toolbox")
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = "Toolbox"
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            LauncherController.shared.toggle()
        }
    }

    private func showMenu() {
        guard let item else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Launcher", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Toolbox Window", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "File Wheel for Finder Selection", action: #selector(openFileWheel), keyEquivalent: "").target = self
        menu.addItem(withTitle: Teleprompter.shared.isShowing ? "Hide Teleprompter" : "Show Teleprompter",
                     action: #selector(toggleTeleprompter), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let updater = Updater.shared
        menu.addItem(withTitle: updater.hasUpdate ? "Update to Toolbox \(updater.update?.version.description ?? "")…" : "Check for Updates…",
                     action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Toolbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        // Attach the menu just for this click, so a plain click keeps opening the launcher.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openLauncher() { LauncherController.shared.show() }
    @objc private func openWindow() { LauncherController.shared.openMainWindow() }
    @objc private func openFileWheel() { DragWheel.shared.showForFinderSelection() }
    @objc private func toggleTeleprompter() { Teleprompter.shared.toggle() }
    @objc private func openSettings() { LauncherController.shared.openSettings() }
    @objc private func checkForUpdates() { UpdateWindowController.shared.show(check: !Updater.shared.hasUpdate) }
}
