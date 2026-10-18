import AppKit
import SwiftUI

/// The floating quick launcher: a Spotlight/Raycast-style search panel that appears over any app.
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

    func open(_ tool: Tool) {
        let files = model.finderFiles
        hide()
        AppModel.shared.openTool(tool, with: files)
    }

    func openMainWindow() {
        hide()
        AppModel.shared.summon()
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
                             y: visible.maxY - visible.height * 0.22 - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 680, height: 440)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
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

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { LauncherController.shared.hide() }
    }
}
