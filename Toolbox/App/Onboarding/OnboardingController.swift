import AppKit
import SwiftUI

extension SettingsKey {
    static let onboardingCompleted = "onboarding.completed"
    /// The page to come back to if Toolbox relaunches mid-onboarding, e.g. after Screen Recording is allowed.
    static let onboardingPage = "onboarding.page"
}

/// The welcome window: shown on first launch, and again from Settings to review permissions.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let shared = OnboardingController()
    static let size = NSSize(width: 720, height: 610)

    private let model = OnboardingModel()
    private var window: NSWindow?

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: SettingsKey.onboardingCompleted) }

    func showIfNeeded() {
        guard !Self.isCompleted else { return }
        show()
    }

    func show(page: OnboardingPage? = nil) {
        if let page { model.jump(to: page) }
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            window.center()
            PermissionCenter.shared.startWatching()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the window back in front of System Settings once a permission has been granted there.
    func bringForwardIfOpen() {
        guard let window, window.isVisible else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted)
        UserDefaults.standard.removeObject(forKey: SettingsKey.onboardingPage)
        window?.close()
        AppModel.shared.bringMainWindowForward()
    }

    // MARK: NSWindowDelegate

    /// Closing the window counts as done. Settings can bring it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        UserDefaults.standard.set(true, forKey: SettingsKey.onboardingCompleted)
        UserDefaults.standard.removeObject(forKey: SettingsKey.onboardingPage)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        PermissionCenter.shared.stopWatching()
        PermissionGuide.shared.close()
    }

    // MARK: Private

    private func makeWindow() -> NSWindow {
        let root = OnboardingView(model: model, onFinish: { OnboardingController.shared.finish() })
            .environment(Dependencies.shared)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(Self.size)
        window.identifier = NSUserInterfaceItemIdentifier("onboarding")
        window.title = "Welcome to \(AppInfo.name)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        self.window = window
        return window
    }
}
