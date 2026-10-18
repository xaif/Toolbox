import AppKit
import SwiftUI

/// The floating quick launcher: a Raycast-style search panel that appears over any app.
/// It's a non-activating panel, so the app you were in stays active until you pick a tool.
@MainActor
final class LauncherController: NSObject, NSWindowDelegate {
    static let shared = LauncherController()

    let model = LauncherModel()
    private var panel: LauncherPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        model.reset()
        let panel = self.panel ?? makePanel()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        model.requestFocus()
        // The shadow is derived from the transparent window's contents, so refresh it once they're drawn.
        DispatchQueue.main.async { panel.invalidateShadow() }
        if AppSettings.launcherUsesFinderSelection, frontmost?.bundleIdentifier == "com.apple.finder" {
            model.loadFinderSelection()
        }
        #if DEBUG
        if let paths = UserDefaults.standard.string(forKey: "debugLauncherFiles") {
            model.useFiles(paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        }
        #endif
    }

    func hide() {
        panel?.orderOut(nil)
        model.cancelFinderLookup()
    }

    /// Opens a tool in the main window, handing over the Finder selection unless `withFiles` is false.
    func open(_ tool: Tool, withFiles: Bool = true) {
        let files = withFiles ? model.finderFiles : []
        hide()
        AppModel.shared.openTool(tool, with: files)
    }

    func openMainWindow() {
        hide()
        AppModel.shared.summon()
    }

    func openSettings() {
        hide()
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Command-key shortcuts, handled before the main menu sees them.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), flags) {
        case (40, .command): // ⌘K
            model.toggleActions()
        case (36, .command), (76, .command): // ⌘↩
            openMainWindow()
        case (3, [.command, .shift]): // ⌘⇧F
            model.toggleFavoriteOfHighlighted()
        case (126, [.command, .option]): // ⌘⌥↑
            model.moveHighlightedFavorite(by: -1)
        case (125, [.command, .option]): // ⌘⌥↓
            model.moveHighlightedFavorite(by: 1)
        case (43, .command): // ⌘,
            openSettings()
        case (13, .command): // ⌘W
            hide()
        default:
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Private

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel()
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: LauncherPanel.size)
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Centers the panel horizontally in the upper part of the screen with the mouse pointer.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = LauncherPanel.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - visible.height * 0.14 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// Borderless, transparent, floating panel. The rounded glass shape is drawn by `LauncherView`.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)
    static let cornerRadius: CGFloat = 26

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ LauncherController.shared.handleKeyEquivalent(event) }) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { LauncherController.shared.hide() }
    }
}
