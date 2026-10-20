import Foundation

/// Where finished results are published. Results go straight into the folder, never into a subfolder per job.
enum OutputDestinationMode: String, CaseIterable, Identifiable {
    /// Next to each original file. Results that don't come from a file (recordings, downloads) go to Downloads.
    case sourceFolder
    /// ~/Downloads.
    case downloads
    /// A folder the user picked in Settings.
    case custom
    /// Ask for a folder every time a job starts.
    case ask

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sourceFolder: "Same folder as the original"
        case .downloads: "Downloads folder"
        case .custom: "Custom folder"
        case .ask: "Ask every time"
        }
    }
}

/// UserDefaults keys shared by `@AppStorage` and non-view code.
enum SettingsKey {
    static let outputMode = "output.mode"
    static let outputCustomPath = "output.customPath"
    static let revealWhenDone = "output.revealWhenDone"
    static let hotKeyEnabled = "hotkey.enabled"
    static let hotKeyCode = "hotkey.keyCode"
    static let hotKeyModifiers = "hotkey.modifiers"
    static let hotKeyAction = "hotkey.action"
    static let toolHotKeys = "hotkey.tools"
    static let launcherUsesFinderSelection = "launcher.finderSelection"
    static let launcherRunsTools = "launcher.runTools"
    static let showsMenuBarIcon = "menuBar.showIcon"
    static let recentTools = "launcher.recentTools"
    static let favoriteTools = "favorites.tools"
    static func customExecutablePath(_ dependency: ExternalDependency) -> String {
        "dependency.\(dependency.rawValue).path"
    }
}

enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.outputMode: OutputDestinationMode.sourceFolder.rawValue,
            SettingsKey.revealWhenDone: false,
            SettingsKey.hotKeyEnabled: true,
            SettingsKey.hotKeyAction: "launcher",
            SettingsKey.launcherUsesFinderSelection: true,
            SettingsKey.launcherRunsTools: true,
            SettingsKey.showsMenuBarIcon: true,
            SettingsKey.updatesAutomatic: true,
        ])
    }

    static var outputMode: OutputDestinationMode {
        OutputDestinationMode(rawValue: defaults.string(forKey: SettingsKey.outputMode) ?? "") ?? .sourceFolder
    }

    static var customOutputFolder: URL? {
        guard let path = defaults.string(forKey: SettingsKey.outputCustomPath), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var revealWhenDone: Bool { defaults.bool(forKey: SettingsKey.revealWhenDone) }
    static var hotKeyEnabled: Bool { defaults.bool(forKey: SettingsKey.hotKeyEnabled) }
    static var launcherUsesFinderSelection: Bool { defaults.bool(forKey: SettingsKey.launcherUsesFinderSelection) }
    /// Whether tools with a quick action start right away on the files picked up by the launcher.
    static var launcherRunsTools: Bool { defaults.bool(forKey: SettingsKey.launcherRunsTools) }
    static var showsMenuBarIcon: Bool { defaults.bool(forKey: SettingsKey.showsMenuBarIcon) }

    /// Most recently opened tool IDs, newest first.
    static var recentToolIDs: [String] { defaults.stringArray(forKey: SettingsKey.recentTools) ?? [] }

    static func noteToolOpened(_ id: String) {
        var recent = recentToolIDs.filter { $0 != id }
        recent.insert(id, at: 0)
        defaults.set(Array(recent.prefix(8)), forKey: SettingsKey.recentTools)
    }

    static func customExecutable(for dependency: ExternalDependency) -> URL? {
        guard let path = defaults.string(forKey: SettingsKey.customExecutablePath(dependency)), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func setCustomExecutable(_ url: URL?, for dependency: ExternalDependency) {
        defaults.set(url?.path, forKey: SettingsKey.customExecutablePath(dependency))
    }
}
