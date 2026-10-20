import AppKit

/// Decides where results go and publishes them atomically.
///
/// Every job writes into a private staging folder. Only when the whole batch succeeds are the results
/// moved into place, straight into the destination folder with no folder per job. By default that's
/// next to each original, e.g. `~/Desktop/clip.mov` → `~/Desktop/clip-compressed.mp4`. Existing files,
/// originals included, are never replaced: a clashing name gets a number, e.g. `clip-compressed 2.mp4`.
@MainActor
enum OutputManager {
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The folder all results go to, or nil when it depends on the job (next to the originals, or ask).
    static var fixedFolder: URL? {
        switch AppSettings.outputMode {
        case .downloads: downloadsFolder
        case .custom: AppSettings.customOutputFolder ?? downloadsFolder
        case .sourceFolder, .ask: nil
        }
    }

    /// Where results go, for job bars that are ready to run.
    static var destinationNote: String {
        switch AppSettings.outputMode {
        case .sourceFolder: "Originals stay untouched. Results are saved next to them."
        case .downloads, .custom: "Originals stay untouched. Results go to \((fixedFolder ?? downloadsFolder).lastPathComponent)."
        case .ask: "Originals stay untouched. You'll choose where results go."
        }
    }

    /// Resolves where a new job's results go. Returns nil if the user cancelled the folder prompt.
    static func resolveDestination(jobTitle: String, inputs: [URL]) -> OutputDestination? {
        switch AppSettings.outputMode {
        case .sourceFolder:
            return OutputDestination(folder: downloadsFolder, besideSources: true)
        case .downloads, .custom:
            return OutputDestination(folder: fixedFolder ?? downloadsFolder, besideSources: false)
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = inputs.first?.deletingLastPathComponent()
            panel.prompt = "Save Here"
            panel.message = "Choose where to save the results of “\(jobTitle)”."
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return OutputDestination(folder: url, besideSources: false)
        }
    }

    /// Creates an empty staging folder on the same volume as `folder`, so publishing is a cheap move.
    nonisolated static func makeStagingFolder(near folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        } catch {
            scratch = fm.temporaryDirectory.appendingPathComponent("Toolbox-\(UUID().uuidString)", isDirectory: true)
        }
        let staging = scratch.appendingPathComponent("Results", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Moves everything in each staging folder into its destination folder and returns the published URLs.
    /// Never replaces an existing file. If a move fails, the results moved so far are removed again.
    nonisolated static func publish(_ staged: [(staging: URL, destination: URL)]) throws -> [URL] {
        let fm = FileManager.default
        var published: [URL] = []
        do {
            for (staging, destination) in staged {
                let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
                guard !items.isEmpty else { continue }
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for item in items {
                    let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    let ext = isFolder ? "" : item.pathExtension
                    let base = isFolder ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
                    let name = uniqueName(base, extension: ext) {
                        fm.fileExists(atPath: destination.appendingPathComponent($0).path)
                    }
                    let target = destination.appendingPathComponent(name, isDirectory: isFolder)
                    // Fails rather than replaces if something appeared under that name meanwhile.
                    try fm.moveItem(at: item, to: target)
                    published.append(target)
                }
            }
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
        return published
    }

    nonisolated static func discard(staging: URL) {
        try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
    }

    /// The first of `name.ext`, `name 2.ext`, `name 3.ext`… that isn't taken.
    nonisolated static func uniqueName(_ name: String, extension ext: String, isTaken: (String) -> Bool) -> String {
        var candidate = ext.isEmpty ? name : "\(name).\(ext)"
        var counter = 2
        while isTaken(candidate) {
            candidate = ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    nonisolated static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// Where one job's results go, decided when it starts.
struct OutputDestination: Sendable {
    /// Where results go, unless `besideSources` puts them next to the file they're made from.
    let folder: URL
    let besideSources: Bool

    /// The folder for a result made from `source`, or for one not made from a particular file if nil.
    func folder(for source: URL?) -> URL {
        var result = folder
        if besideSources, let source, source.isFileURL {
            let parent = source.deletingLastPathComponent()
            // Files in temporary folders (like screen recording takes) would be lost, and some folders are read-only.
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            if !(parent.resolvingSymlinksInPath().path + "/").hasPrefix(temp),
               FileManager.default.isWritableFile(atPath: parent.path) {
                result = parent
            }
        }
        // One spelling per folder, so results headed to the same folder share a staging folder.
        return URL(fileURLWithPath: result.standardizedFileURL.path, isDirectory: true)
    }
}
