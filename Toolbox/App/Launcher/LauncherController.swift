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
        // `-debugLauncherOptions image.compress` opens straight to that tool's options.
        if let id = UserDefaults.standard.string(forKey: "debugLauncherOptions"), let tool = ToolRegistry.tool(id) {
            model.showOptions(for: tool)
        }
        #endif
    }

    func hide() {
        panel?.orderOut(nil)
        model.cancelFinderLookup()
        model.stopRecordingHotKey()
    }

    /// Picks `tool` (↩ or a click): runs it on the selected files, shows its options first when it asks
    /// for them, or opens it.
    func activate(_ tool: Tool) {
        if model.asksFirst(tool) { model.showOptions(for: tool) } else { open(tool) }
    }

    /// Picks `tool` for `files` from outside the launcher (its hotkey): runs it, or opens the launcher on
    /// its options when it asks for them first.
    func activate(_ tool: Tool, files: [URL]) {
        model.useFiles(files)
        guard model.asksFirst(tool) else {
            QuickRun.perform(tool, on: files, run: true)
            return
        }
        show()
        model.cancelFinderLookup()
        model.useFiles(files)
        model.showOptions(for: tool)
    }

    /// Opens a tool in the main window, handing over the Finder selection unless `withFiles` is false.
    /// Tools with a quick action instead run on those files in the background, unless `run` is false.
    func open(_ tool: Tool, withFiles: Bool = true, run: Bool = true) {
        let files = withFiles ? model.finderFiles : []
        hide()
        QuickRun.perform(tool, on: files, run: run)
    }

    /// Runs `tool` on the selected files with the options shown in the launcher.
    func run(_ tool: Tool) {
        guard QuickRun.isReady(tool) else { return }
        let files = model.finderFiles
        hide()
        if !QuickRun.start(tool, on: files) { AppModel.shared.openTool(tool, with: files) }
    }

    /// Runs one of Toolbox's own commands, like Check for Updates.
    func perform(_ command: LauncherModel.Command) {
        hide()
        command.perform()
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
        panel.contentView = makeGlassView()
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Liquid Glass, like Spotlight's: it refracts whatever is behind the panel, adapts to light and dark
    /// backgrounds, and turns frosted with Reduce Transparency.
    private func makeGlassView() -> NSGlassEffectView {
        let bounds = NSRect(origin: .zero, size: LauncherPanel.size)
        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.cornerRadius = LauncherPanel.cornerRadius
        glass.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        return glass
    }

    /// Centers the panel horizontally in the upper part of the screen with the mouse pointer.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(width: min(LauncherPanel.size.width, visible.width - 32),
                          height: min(LauncherPanel.size.height, visible.height - 32))
        // Keep the search field at the reference launcher's upper-screen position. Results scroll
        // inside the panel; their count never changes its position or pushes the footer offscreen.
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: max(visible.minY + 16, visible.maxY - visible.height * 0.11 - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// Borderless, transparent, floating panel whose content is a rounded glass view.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 750, height: 475)
    /// Controls in the panel's corners sit `inset` from its edges with a corner radius of
    /// `cornerRadius - inset`, so their curves are concentric with the panel's.
    static let cornerRadius: CGFloat = 28
    static let inset: CGFloat = 9
    static let controlHeight: CGFloat = 38

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
        MainActor.assumeIsolated {
            let launcher = LauncherController.shared
            if launcher.model.optionsTool != nil { launcher.model.closeOptions() } else { launcher.hide() }
        }
    }
}
