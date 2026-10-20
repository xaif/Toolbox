import SwiftUI

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @State private var dependencies = Dependencies.shared

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        Window("Toolbox", id: "main") {
            MainView()
                .environment(model)
                .environment(dependencies)
                .frame(minWidth: 880, minHeight: 580)
        }
        .defaultSize(width: 1120, height: 740)
        // Unit tests launch the app as their host; keep it off screen.
        .defaultLaunchBehavior(AppDelegate.isTesting ? .suppressed : .automatic)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(dependencies)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var defaultsObserver: NSObjectProtocol?

    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon or focus stealing while tests run.
        if Self.isTesting { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        MainActor.assumeIsolated {
            HotKeyManager.shared.update()
            MenuBarIcon.shared.update()
            DragWheel.shared.update()
            // After the main window opens, so the welcome window lands in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { OnboardingController.shared.showIfNeeded() }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugShowLauncher") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LauncherController.shared.show() }
            }
            // `-debugQuickRun image.compress -debugInputs /a.png,/b.png` runs a quick action a few seconds
            // after launch, as if picked in the launcher.
            if let id = UserDefaults.standard.string(forKey: "debugQuickRun"), let tool = ToolRegistry.tool(id) {
                let inputs = (UserDefaults.standard.string(forKey: "debugInputs") ?? "")
                    .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { QuickRun.perform(tool, on: inputs, run: true) }
            }
            #endif
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                HotKeyManager.shared.update()
                MenuBarIcon.shared.update()
                DragWheel.shared.update()
            }
        }
    }

    /// Keep running after the window closes so the global shortcut can bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in AppModel.shared.summon() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { JobCenter.shared.activeCount }
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A job is still running." : "\(running) jobs are still running."
        alert.informativeText = "If you quit now, unfinished results are discarded. Your original files aren't affected."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Permissions…") { OnboardingController.shared.show(page: .permissions) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Find a Tool…") { model.focusSearch() }
                .keyboardShortcut("k")
            Button("Home") { model.open(.home) }
                .keyboardShortcut("0")
            Button("Show Quick Launcher") { LauncherController.shared.show() }
            Button("File Wheel for Finder Selection") { DragWheel.shared.showForFinderSelection() }
        }
        CommandGroup(before: .sidebar) {
            ForEach(FeaturedCollection.allCases) { collection in
                Button(collection.title) { model.open(collection.destination) }
                    .keyboardShortcut(collection.shortcut)
            }
            Menu("Categories") {
                ForEach(ToolCategory.allCases) { category in
                    Button(category.name) { model.open(.category(category)) }
                }
            }
            Divider()
        }
    }
}
