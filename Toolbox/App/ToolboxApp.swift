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
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(dependencies)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            HotKeyManager.shared.update()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugShowLauncher") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { LauncherController.shared.show() }
            }
            #endif
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HotKeyManager.shared.update() }
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
        CommandGroup(replacing: .newItem) {
            Button("Find a Tool…") { model.focusSearch() }
                .keyboardShortcut("k")
            Button("Home") { model.open(.home) }
                .keyboardShortcut("0")
            Button("Show Quick Launcher") { LauncherController.shared.show() }
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
