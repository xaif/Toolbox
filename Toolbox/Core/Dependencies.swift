import Foundation
import Observation

/// Finds and installs external programs (FFmpeg, yt-dlp).
/// Nothing is bundled: we use the user's own copy or install one through Homebrew.
@MainActor
@Observable
final class Dependencies {
    static let shared = Dependencies()

    enum InstallState: Equatable {
        case idle
        case installing
        case failed(String)
    }

    private(set) var locations: [ExternalDependency: URL] = [:]
    private(set) var installStates: [ExternalDependency: InstallState] = [:]
    private(set) var installLog: [ExternalDependency: [String]] = [:]

    private init() {
        refresh()
    }

    func refresh() {
        var found: [ExternalDependency: URL] = [:]
        for dependency in ExternalDependency.allCases {
            if let url = Self.locate(dependency) { found[dependency] = url }
        }
        locations = found
    }

    func isAvailable(_ dependency: ExternalDependency) -> Bool { locations[dependency] != nil }

    func installState(_ dependency: ExternalDependency) -> InstallState { installStates[dependency] ?? .idle }

    func log(for dependency: ExternalDependency) -> [String] { installLog[dependency] ?? [] }

    func setCustomExecutable(_ url: URL?, for dependency: ExternalDependency) {
        AppSettings.setCustomExecutable(url, for: dependency)
        refresh()
    }

    static var homebrewURL: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Installs a dependency with `brew install`, streaming output into `installLog`.
    func install(_ dependency: ExternalDependency) {
        guard installState(dependency) != .installing else { return }
        guard let brew = Self.homebrewURL else {
            installStates[dependency] = .failed("Homebrew isn't installed. Install it from brew.sh, or choose an existing \(dependency.displayName) binary.")
            return
        }
        installStates[dependency] = .installing
        installLog[dependency] = ["$ brew install \(dependency.brewFormula)"]
        Task {
            do {
                try await ProcessRunner.runChecked(
                    brew,
                    arguments: ["install", dependency.brewFormula],
                    onStdoutLine: { line in Task { @MainActor in self.appendLog(line, for: dependency) } },
                    onStderrLine: { line in Task { @MainActor in self.appendLog(line, for: dependency) } }
                )
                refresh()
                installStates[dependency] = isAvailable(dependency)
                    ? .idle
                    : .failed("Homebrew finished, but \(dependency.displayName) wasn't found.")
            } catch {
                installStates[dependency] = .failed(error.localizedDescription)
            }
        }
    }

    private func appendLog(_ line: String, for dependency: ExternalDependency) {
        var lines = installLog[dependency] ?? []
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        installLog[dependency] = lines
    }

    /// Resolves the executable for a dependency or throws a user-facing error.
    nonisolated static func require(_ dependency: ExternalDependency) throws -> URL {
        guard let url = locate(dependency) else { throw ToolError.missingDependency(dependency) }
        return url
    }

    nonisolated static func locate(_ dependency: ExternalDependency) -> URL? {
        locate(executable: dependency.executableName, custom: AppSettings.customExecutable(for: dependency))
    }

    /// `ffprobe` ships next to `ffmpeg`; prefer the sibling of whichever ffmpeg we use.
    nonisolated static func locateFFprobe() -> URL? {
        if let ffmpeg = locate(.ffmpeg) {
            let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return locate(executable: "ffprobe", custom: nil)
    }

    nonisolated private static func locate(executable: String, custom: URL?) -> URL? {
        let fm = FileManager.default
        if let custom, fm.isExecutableFile(atPath: custom.path) { return custom }
        for directory in ProcessRunner.searchPath {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
