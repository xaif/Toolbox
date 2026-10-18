import AppKit

/// Decides where results go and publishes them atomically.
///
/// Every job writes into a private staging folder on the destination volume. Only when the
/// whole batch succeeds is the staging folder moved into place as a new dated folder,
/// e.g. `~/Downloads/Toolbox/Compress Video 2026-10-18 at 15.32.07`. Originals are never touched.
@MainActor
enum OutputManager {
    static var downloadsBase: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Toolbox", isDirectory: true)
    }

    /// Resolves the base folder for a new job. Returns nil if the user cancelled the folder prompt.
    static func resolveBaseFolder(jobTitle: String) -> URL? {
        switch AppSettings.outputMode {
        case .downloads:
            return downloadsBase
        case .custom:
            return AppSettings.customOutputFolder ?? downloadsBase
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Save Here"
            panel.message = "Choose where to save the results of “\(jobTitle)”."
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// Creates an empty staging folder on the same volume as `base`, so publishing is a cheap move.
    nonisolated static func makeStagingFolder(near base: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: base, create: true)
        } catch {
            scratch = fm.temporaryDirectory.appendingPathComponent("Toolbox-\(UUID().uuidString)", isDirectory: true)
        }
        let staging = scratch.appendingPathComponent("Results", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Moves a finished staging folder into `base` under a new dated name and returns its URL.
    nonisolated static func publish(staging: URL, to base: URL, jobTitle: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "\(sanitize(jobTitle)) \(formatter.string(from: Date()))"
        var destination = base.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            destination = base.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        try fm.moveItem(at: staging, to: destination)
        try? fm.removeItem(at: staging.deletingLastPathComponent())
        return destination
    }

    nonisolated static func discard(staging: URL) {
        try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
    }

    nonisolated static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
