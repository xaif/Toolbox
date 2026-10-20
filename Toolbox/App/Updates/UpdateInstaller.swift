import CryptoKit
import Foundation

/// Downloads an update's DMG, checks it, copies the new Toolbox next to the running one, and hands over
/// to a small script that swaps the two once Toolbox quits and then opens the new version. If anything
/// fails before the swap, the installed app is left as it was.
enum UpdateInstaller {
    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Why Toolbox can't replace itself at `app`, or nil when it can.
    static func problem(installingAt app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running Toolbox from a temporary, read-only copy. Move Toolbox to your Applications folder, open it from there, then update."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Toolbox is running from a read-only disk, like its DMG. Drag it to your Applications folder, open it from there, then update."
        }
        let folder = app.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            return "Toolbox can't make changes in \(folder.path). Download the update and drag it to Applications yourself."
        }
        return nil
    }

    // MARK: - Download

    /// Downloads `url` into `folder`, reporting progress from 0 to 1. Cancelling the task stops it.
    static func download(_ url: URL, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent.isEmpty ? "Toolbox.dmg" : url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Checks the download against the size and SHA-256 digest GitHub reported for it.
    static func verify(_ file: URL, size: Int64?, digest: String?) throws {
        let actual = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        if let size, size > 0, actual != size {
            throw InstallError(message: "The download is incomplete. Try again.")
        }
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return }
        let expected = digest.dropFirst("sha256:".count).lowercased()
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw InstallError(message: "Couldn't read the download.") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == expected else {
            throw InstallError(message: "The download doesn't match the release on GitHub, so it wasn't installed. Try again.")
        }
    }

    // MARK: - Staging

    /// Opens the DMG, checks the Toolbox inside (same app, the expected version, intact signature, runs
    /// on this Mac) and copies it next to `installedApp` under a hidden name. Returns the copy.
    static func stage(dmg: URL, version: AppVersion, bundleID: String, nextTo installedApp: URL) async throws -> URL {
        let mountRoot = dmg.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let volume = try await mount(dmg, under: mountRoot)
        do {
            let staged = try await copyApp(from: volume, version: version, bundleID: bundleID, nextTo: installedApp)
            await detach(volume)
            return staged
        } catch {
            await detach(volume)
            throw error
        }
    }

    private static func copyApp(from volume: URL, version: AppVersion, bundleID: String, nextTo installedApp: URL) async throws -> URL {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        let apps = candidates.filter {
            $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
        guard let app = apps.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }), let bundle = Bundle(url: app) else {
            throw InstallError(message: "The update doesn't contain Toolbox.")
        }
        let found = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
        guard found == version else {
            throw InstallError(message: "The download contains Toolbox \(found?.description ?? "of an unknown version") instead of \(version).")
        }
        if let minimum = (bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String).flatMap(AppVersion.init) {
            let system = ProcessInfo.processInfo.operatingSystemVersion
            let running = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")!
            if running < minimum {
                throw InstallError(message: "Toolbox \(version) needs macOS \(minimum) or later.")
            }
        }
        let check = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else {
            throw InstallError(message: "The new Toolbox's code signature is damaged, so it wasn't installed.")
        }

        let staged = installedApp.deletingLastPathComponent()
            .appendingPathComponent(".\(installedApp.deletingPathExtension().lastPathComponent)-\(version)-update.app")
        try? FileManager.default.removeItem(at: staged)
        do {
            try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [app.path, staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw InstallError(message: "Couldn't copy the new Toolbox next to the current one. \(error.localizedDescription)")
        }
        return staged
    }

    private static func mount(_ dmg: URL, under folder: URL) async throws -> URL {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: [
                "attach", "-nobrowse", "-noautoopen", "-readonly", "-mountrandom", folder.path, "-plist", dmg.path,
            ])
        } catch {
            throw InstallError(message: "Couldn't open the downloaded DMG. \(error.localizedDescription)")
        }
        let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw InstallError(message: "Couldn't open the downloaded DMG.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func detach(_ volume: URL) async {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        if (try? await ProcessRunner.run(hdiutil, arguments: ["detach", volume.path, "-quiet"]))?.status != 0 {
            _ = try? await ProcessRunner.run(hdiutil, arguments: ["detach", volume.path, "-force", "-quiet"])
        }
    }

    // MARK: - Swapping

    /// Waits for process `$1` to quit, puts `$3` where `$2` is (keeping `$2` until that worked), and opens it
    /// when `$4` is 1. Gives up, leaving everything as it was, if the app is still running after a minute.
    static let swapScript = #"""
    #!/bin/sh
    pid="$1"; target="$2"; staged="$3"; relaunch="$4"
    backup="$(dirname "$target")/.$(basename "$target" .app)-previous-$$.app"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 600 ]; then rm -rf "$staged"; exit 1; fi
      sleep 0.1
    done
    if ! mv "$target" "$backup"; then
      rm -rf "$staged"
      [ "$relaunch" = 1 ] && open "$target"
      exit 1
    fi
    if mv "$staged" "$target"; then
      rm -rf "$backup"
    else
      mv "$backup" "$target"
      rm -rf "$staged"
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null
    [ "$relaunch" = 1 ] && open "$target"
    exit 0
    """#

    /// Starts the swap in the background. It outlives Toolbox, which should quit right after.
    @discardableResult
    static func startSwap(replacing target: URL, with staged: URL, after pid: Int32, relaunch: Bool, scriptFolder: URL) throws -> Process {
        try FileManager.default.createDirectory(at: scriptFolder, withIntermediateDirectories: true)
        let script = scriptFolder.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), target.path, staged.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

/// Moves the finished download into place and reports progress, at most once per percent.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var lastPercent = -1
    private let lock = NSLock()

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress(Double(percent) / 100)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateInstaller.InstallError(message: "The download failed (HTTP \(http.statusCode)).")))
            return
        }
        // The file at `location` is deleted when this returns, so move it now.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) } else { finish(.failure(error)) }
    }
}
