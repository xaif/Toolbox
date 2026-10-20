import AppKit

extension SettingsKey {
    static let updatesAutomatic = "updates.automatic"
    static let updatesLastChecked = "updates.lastChecked"
    static let updatesSkippedVersion = "updates.skippedVersion"
    static let updatesLastLaunchedVersion = "updates.lastLaunchedVersion"
}

/// Finds new versions of Toolbox on GitHub and installs them. Checks by itself once soon after launch and
/// then every few hours (unless turned off in Settings); the home screen, the launcher and the menus show
/// when an update is waiting.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        /// The installed version is the newest.
        case upToDate
        /// `update` is waiting to be installed.
        case available
        /// 0…1.
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The newest version above this one, from the last check.
    private(set) var update: AppUpdate?
    /// What's new in the installed version, shown when it's up to date.
    private(set) var installedNotes: ReleaseNotes?
    private(set) var lastChecked = UserDefaults.standard.object(forKey: SettingsKey.updatesLastChecked) as? Date
    /// A version you chose to skip; it isn't advertised until a newer one comes out.
    private(set) var skippedVersion = UserDefaults.standard.string(forKey: SettingsKey.updatesSkippedVersion)
    /// "Later" hides the home screen banner until Toolbox next opens.
    private(set) var isDismissed = false

    let currentVersion = AppVersion.current

    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    /// How long automatic checks wait before checking again.
    static let interval: TimeInterval = 6 * 60 * 60

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return UserDefaults.standard.bool(forKey: SettingsKey.updatesAutomatic) }
        set { withMutation(keyPath: \.checksAutomatically) { UserDefaults.standard.set(newValue, forKey: SettingsKey.updatesAutomatic) } }
    }

    /// An update is waiting and you haven't skipped it.
    var hasUpdate: Bool {
        guard let update else { return false }
        return update.version.description != skippedVersion
    }

    /// The banner on the home screen and the row in the launcher.
    var showsBanner: Bool { hasUpdate && !isDismissed && !isInstalling }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .installing: true
        default: false
        }
    }

    var isChecking: Bool { phase == .checking }

    // MARK: - Checking

    /// Starts automatic checks: shortly after launch, then whenever the last one is old enough.
    func start() {
        refreshIconAfterUpdate()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Updater.shared.checkIfDue() }
    }

    private func checkIfDue() {
        guard checksAutomatically, !isChecking, !isInstalling else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval, phase != .idle { return }
        check(userInitiated: false)
    }

    /// Looks for a newer version. Checks you start show their errors; automatic ones stay quiet.
    func check(userInitiated: Bool = true) {
        guard !isChecking, !isInstalling else { return }
        let previous = phase
        phase = .checking
        checkTask = Task {
            do {
                let releases = try await UpdateFeed.fetch()
                let found = UpdateFeed.update(from: releases, current: currentVersion)
                installedNotes = UpdateFeed.notes(for: currentVersion, in: releases)
                if found?.version != update?.version { isDismissed = false }
                update = found
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: SettingsKey.updatesLastChecked)
                // Checking again on purpose brings a skipped version back.
                if userInitiated, let found, found.version.description == skippedVersion { setSkippedVersion(nil) }
                phase = found == nil ? .upToDate : .available
            } catch {
                phase = userInitiated ? .failed(error.localizedDescription) : previous == .checking ? .idle : previous
            }
        }
    }

    /// On the first launch of a new version, makes Finder and the Dock show its icon. Versions up to 0.2.0
    /// swapped the app in without refreshing LaunchServices (and didn't note their version), so a changed icon
    /// could stay stale until a restart.
    private func refreshIconAfterUpdate() {
        let defaults = UserDefaults.standard
        let version = currentVersion.description
        let previous = defaults.string(forKey: SettingsKey.updatesLastLaunchedVersion)
        defaults.set(version, forKey: SettingsKey.updatesLastLaunchedVersion)
        NSApp.applicationIconImage = AppInfo.icon
        guard previous != version else { return }
        let app = Bundle.main.bundleURL
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: app.path)
        LSRegisterURL(app as CFURL, true)
    }

    // MARK: - Choices

    func skipThisVersion() {
        guard let update else { return }
        setSkippedVersion(update.version.description)
    }

    func remindLater() {
        isDismissed = true
    }

    private func setSkippedVersion(_ version: String?) {
        skippedVersion = version
        UserDefaults.standard.set(version, forKey: SettingsKey.updatesSkippedVersion)
    }

    // MARK: - Installing

    /// Downloads and installs `update`, then quits and opens the new version.
    func install() {
        guard let update, !isInstalling else { return }
        let running = JobCenter.shared.activeCount
        guard running == 0 else {
            phase = .failed(running == 1
                ? "A job is still running. Wait for it to finish, or cancel it, then install the update."
                : "\(running) jobs are still running. Wait for them to finish, or cancel them, then install the update.")
            return
        }
        let app = Bundle.main.bundleURL
        if let problem = UpdateInstaller.problem(installingAt: app) {
            phase = .failed(problem)
            return
        }
        phase = .downloading(0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxUpdate-\(UUID().uuidString)", isDirectory: true)
        installTask = Task {
            do {
                let dmg = try await UpdateInstaller.download(update.downloadURL, into: folder) { fraction in
                    Task { @MainActor in
                        if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(fraction) }
                    }
                }
                try Task.checkCancellation()
                phase = .installing
                try UpdateInstaller.verify(dmg, size: update.downloadSize, digest: update.digest)
                let staged = try await UpdateInstaller.stage(dmg: dmg, version: update.version,
                                                             bundleID: Bundle.main.bundleIdentifier ?? "", nextTo: app)
                try Task.checkCancellation()
                try UpdateInstaller.startSwap(replacing: app, with: staged, after: ProcessInfo.processInfo.processIdentifier,
                                              relaunch: true, scriptFolder: folder)
                NSApp.terminate(nil)
            } catch is CancellationError {
                phase = .available
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        if isInstalling { phase = update == nil ? .idle : .available }
    }

    /// The release page, for installing by hand when the update can't install itself.
    func openReleasePage() {
        NSWorkspace.shared.open(update?.pageURL ?? URL(string: "https://github.com/xaif/Toolbox/releases/latest")!)
    }
}
