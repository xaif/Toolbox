import Foundation

/// Where finished results are published.
enum OutputDestinationMode: String, CaseIterable, Identifiable {
    /// A new dated folder inside ~/Downloads/Toolbox.
    case downloads
    /// A new dated folder inside a folder the user picked in Settings.
    case custom
    /// Ask for a folder every time a job starts.
    case ask

    var id: String { rawValue }

    var label: String {
        switch self {
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
    static func customExecutablePath(_ dependency: ExternalDependency) -> String {
        "dependency.\(dependency.rawValue).path"
    }
}

enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            SettingsKey.outputMode: OutputDestinationMode.downloads.rawValue,
            SettingsKey.revealWhenDone: false,
            SettingsKey.hotKeyEnabled: true,
        ])
    }

    static var outputMode: OutputDestinationMode {
        OutputDestinationMode(rawValue: defaults.string(forKey: SettingsKey.outputMode) ?? "") ?? .downloads
    }

    static var customOutputFolder: URL? {
        guard let path = defaults.string(forKey: SettingsKey.outputCustomPath), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var revealWhenDone: Bool { defaults.bool(forKey: SettingsKey.revealWhenDone) }
    static var hotKeyEnabled: Bool { defaults.bool(forKey: SettingsKey.hotKeyEnabled) }

    static func customExecutable(for dependency: ExternalDependency) -> URL? {
        guard let path = defaults.string(forKey: SettingsKey.customExecutablePath(dependency)), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func setCustomExecutable(_ url: URL?, for dependency: ExternalDependency) {
        defaults.set(url?.path, forKey: SettingsKey.customExecutablePath(dependency))
    }
}
