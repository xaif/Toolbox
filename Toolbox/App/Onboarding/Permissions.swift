import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// The macOS privacy permissions Toolbox uses, and what each one is for.
enum AppPermission: String, CaseIterable, Identifiable {
    case screenRecording, microphone, camera, finder, files, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .finder: "Finder Selection"
        case .files: "Desktop, Documents & Downloads"
        case .accessibility: "Accessibility"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "Record a display, window or area in the Screen Recording Studio."
        case .microphone: "Record audio, narrate screen recordings and dictate text."
        case .camera: "Add your webcam to recordings and scan documents to PDF."
        case .finder: "Lets the launcher and tool hotkeys work on the files you've selected in Finder."
        case .files: "Open files from these folders and save results next to them without asking each time."
        case .accessibility: "Lets the File Wheel follow your keyboard while you drag files in other apps."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        case .finder: "filemenu.and.selection"
        case .files: "folder.fill"
        case .accessibility: "accessibility"
        }
    }

    var tint: Color {
        switch self {
        case .screenRecording: ToolCategory.video.tint
        case .microphone: ToolCategory.audio.tint
        case .camera: ToolCategory.image.tint
        case .finder: ToolCategory.files.tint
        case .files: ToolCategory.business.tint
        case .accessibility: ToolCategory.ai.tint
        }
    }

    var isOptional: Bool { self == .accessibility }

    /// macOS has no prompt for these: the app has to be added to a list in System Settings, which the
    /// guide lets people do by dragging Toolbox in.
    var isGrantedByDragging: Bool { self == .screenRecording || self == .accessibility }

    /// `tccutil`'s name for the permissions granted by adding the app in System Settings.
    var tccService: String? {
        switch self {
        case .screenRecording: "ScreenCapture"
        case .accessibility: "Accessibility"
        default: nil
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .finder: "Privacy_Automation"
        case .files: "Privacy_FilesAndFolders"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// What the guide over System Settings asks for.
    var guideInstruction: String {
        let app = AppInfo.name
        return switch self {
        case .screenRecording: "Drag \(app) into the Screen & System Audio Recording list"
        case .accessibility: "Drag \(app) into the Accessibility list"
        case .microphone: "Switch on \(app) in the Microphone list"
        case .camera: "Switch on \(app) in the Camera list"
        case .finder: "Under \(app), switch on Finder"
        case .files: "Under \(app), switch on Desktop, Documents and Downloads"
        }
    }

    var guideHint: String {
        isGrantedByDragging
            ? "macOS asks for your password or Touch ID to confirm."
            : "This closes by itself once it's on."
    }

    /// Shown by the guide once the permission comes through.
    var grantedMessage: String {
        let app = AppInfo.name
        return switch self {
        case .screenRecording: "\(app) can now record your screen"
        case .microphone: "\(app) can now use the microphone"
        case .camera: "\(app) can now use the camera"
        case .finder: "\(app) can now read your Finder selection"
        case .files: "\(app) can now open and save files in these folders"
        case .accessibility: "The File Wheel can now follow your keyboard"
        }
    }
}

enum PermissionState: Equatable {
    case granted, denied, notDetermined
}

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Toolbox"
}

/// Tracks and requests Toolbox's privacy permissions. While something is watching (onboarding, the System
/// Settings guide), it re-checks every second so changes made in System Settings show up right away.
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    private(set) var states: [AppPermission: PermissionState] = [:]
    private(set) var requesting: Set<AppPermission> = []
    /// Permissions whose System Settings page was opened from Toolbox in this session and are still off.
    private(set) var openedInSettings: Set<AppPermission> = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var isCheckingSlowly = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    private static let filesRequestedKey = "permissions.filesRequested"

    private init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
    }

    func state(_ permission: AppPermission) -> PermissionState { states[permission] ?? .notDetermined }

    var grantedCount: Int { AppPermission.allCases.filter { state($0) == .granted }.count }

    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        update(.screenRecording, CGPreflightScreenCaptureAccess() ? .granted : .notDetermined)
        update(.accessibility, AXIsProcessTrusted() ? .granted : .notDetermined)
        update(.microphone, Self.state(of: AVCaptureDevice.authorizationStatus(for: .audio)))
        update(.camera, Self.state(of: AVCaptureDevice.authorizationStatus(for: .video)))
        // These two talk to other processes, so they're checked off the main thread.
        guard !isCheckingSlowly else { return }
        isCheckingSlowly = true
        let filesRequested = UserDefaults.standard.bool(forKey: Self.filesRequestedKey)
        Task.detached {
            let finder = Self.finderState(askingIfNeeded: false)
            // Reading these folders makes macOS ask, so only check once we've asked on purpose.
            let files: PermissionState = filesRequested ? (Self.canReadUserFolders() ? .granted : .denied) : .notDetermined
            await MainActor.run {
                let center = PermissionCenter.shared
                center.update(.finder, finder)
                center.update(.files, files)
                center.isCheckingSlowly = false
            }
        }
    }

    /// Asks for a permission: shows macOS's prompt when there is one, otherwise opens System Settings with
    /// the guide on top of it.
    func request(_ permission: AppPermission) {
        guard state(permission) != .granted, !requesting.contains(permission) else { return }
        if permission.isGrantedByDragging || state(permission) == .denied {
            openedInSettings.insert(permission)
            guard let service = permission.tccService else {
                PermissionGuide.shared.show(for: permission)
                return
            }
            // A copy of Toolbox signed differently (an older build, another install) leaves an entry that
            // can be switched on but never matches this app, and dragging Toolbox in doesn't replace it.
            // Clearing Toolbox's own entry first means the drag always adds one that works.
            requesting.insert(permission)
            Task.detached {
                Self.resetSystemEntry(service)
                await MainActor.run {
                    PermissionCenter.shared.requesting.remove(permission)
                    PermissionGuide.shared.show(for: permission)
                }
            }
            return
        }
        requesting.insert(permission)
        switch permission {
        case .microphone, .camera:
            AVCaptureDevice.requestAccess(for: permission == .microphone ? .audio : .video) { _ in
                Task { @MainActor in PermissionCenter.shared.finishRequest(permission) }
            }
        case .finder:
            Task.detached {
                _ = Self.finderState(askingIfNeeded: true)
                await PermissionCenter.shared.finishRequest(permission)
            }
        case .files:
            UserDefaults.standard.set(true, forKey: Self.filesRequestedKey)
            Task.detached {
                _ = Self.canReadUserFolders()
                await PermissionCenter.shared.finishRequest(permission)
            }
        case .screenRecording, .accessibility:
            break
        }
    }

    private func finishRequest(_ permission: AppPermission) {
        requesting.remove(permission)
        refresh()
    }

    private func update(_ permission: AppPermission, _ state: PermissionState) {
        if state == .granted { openedInSettings.remove(permission) }
        guard states[permission] != state else { return }
        states[permission] = state
    }

    private static func state(of status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    /// Whether Toolbox may send Apple Events to Finder, which is how it reads the Finder selection.
    /// Asking blocks until the person answers macOS's prompt.
    nonisolated private static func finderState(askingIfNeeded ask: Bool) -> PermissionState {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let target = finder.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case 0: return .granted
        case -1743: return .denied // errAEEventNotPermitted
        default: return .notDetermined // -1744 needs consent; -600 Finder isn't running
        }
    }

    /// Removes Toolbox from one privacy list in System Settings. Only touches Toolbox's own entry.
    nonisolated private static func resetSystemEntry(_ service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", service, bundleID]
        tccutil.standardOutput = FileHandle.nullDevice
        tccutil.standardError = FileHandle.nullDevice
        guard (try? tccutil.run()) != nil else { return }
        tccutil.waitUntilExit()
    }

    /// Lists Desktop, Documents and Downloads. The first time, macOS asks once per folder; afterwards this
    /// just reports whether all three are allowed.
    nonisolated private static func canReadUserFolders() -> Bool {
        let manager = FileManager.default
        let folders: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        var allowed = true
        for folder in folders {
            guard let url = manager.urls(for: folder, in: .userDomainMask).first else { continue }
            if (try? manager.contentsOfDirectory(atPath: url.path)) == nil { allowed = false }
        }
        return allowed
    }
}

/// Opens Toolbox when you log in, through the system's Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Couldn't change the login item: \(error.localizedDescription)")
        }
    }
}

enum AppRelauncher {
    /// Quits and opens Toolbox again. macOS applies some permissions, like Screen Recording, only after a relaunch.
    @MainActor
    static func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to exit, then opens the app bundle passed as $0.
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                            Bundle.main.bundlePath]
        guard (try? waiter.run()) != nil else { return }
        NSApp.terminate(nil)
        // Still running: quitting was cancelled, e.g. to let a job finish.
        waiter.terminate()
    }
}
