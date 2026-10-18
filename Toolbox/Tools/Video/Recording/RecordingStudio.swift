import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

enum RecordingSourceKind: String, CaseIterable, Identifiable {
    case display, window, area
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        case .area: "Area"
        }
    }
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable {
    case retina, p1080, p720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .retina: "Full resolution"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
    /// Longest/shortest side limits in pixels; nil keeps native resolution.
    var limits: (long: CGFloat, short: CGFloat)? {
        switch self {
        case .retina: nil
        case .p1080: (1920, 1080)
        case .p720: (1280, 720)
        }
    }
}

enum RecordingCameraSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var diameter: CGFloat {
        switch self {
        case .small: 150
        case .medium: 210
        case .large: 290
        }
    }
}

/// A finished recording waiting in the editor.
struct RecordingTake {
    let folder: URL
    let segments: [URL]
    let clicks: [RecordingClick]
    let duration: Double
    let size: CGSize
    let date: Date

    var baseName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(formatter.string(from: date))"
    }
}

/// App-wide recording state. A singleton so a recording keeps going while the user browses other tools.
@MainActor
@Observable
final class RecordingStudio {
    static let shared = RecordingStudio()

    enum Phase: Equatable {
        case setup, preparing, countdown(Int), recording, finishing, editing
    }

    private(set) var phase: Phase = .setup
    var errorMessage: String?

    // MARK: Options

    var source: RecordingSourceKind = .display
    var selectedDisplayID: CGDirectDisplayID?
    var selectedWindowID: CGWindowID?
    /// Selected area in its display's top-left-origin point space.
    var area: CGRect?
    var areaDisplayID: CGDirectDisplayID?
    var recordMicrophone = true
    var microphoneID: String?
    var recordSystemAudio = false
    var showCursor = true
    var highlightClicks = true
    var cameraEnabled = false { didSet { updateCameraBubble() } }
    var cameraID: String? { didSet { updateCameraBubble() } }
    var cameraSize = RecordingCameraSize.medium { didSet { updateCameraBubble() } }
    var quality = RecordingQuality.retina
    var frameRate = 30
    var useCountdown = true

    // MARK: Available sources

    private(set) var displays: [SCDisplay] = []
    private(set) var windows: [SCWindow] = []
    private(set) var hasScreenAccess = CGPreflightScreenCaptureAccess()
    private(set) var isLoadingContent = false
    private(set) var thumbnails: [UInt32: NSImage] = [:]
    private(set) var microphones: [AVCaptureDevice] = []
    private(set) var cameras: [AVCaptureDevice] = []

    // MARK: Recording state

    private(set) var isPaused = false
    private var startedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var pauseBegan: Date?
    private(set) var take: RecordingTake?
    private(set) var editor: RecordingEditorModel?

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let paused = pausedTotal + (pauseBegan.map { Date().timeIntervalSince($0) } ?? 0)
        return max(Date().timeIntervalSince(startedAt) - paused, 0)
    }

    private var engine: RecordingEngine?
    private var recordingFolder: URL?
    private let camera = RecordingCameraBubble()
    private let controlPanel = RecordingControlPanel()
    private let countdown = RecordingCountdownWindow()
    private let areaBorder = RecordingAreaBorder()
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private var hiddenWindows: [NSWindow] = []

    private init() {
        loadOptions()
        refreshDevices()
    }

    // MARK: Sources

    func refreshDevices() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                   mediaType: .video, position: .unspecified).devices
    }

    func requestScreenAccess() {
        hasScreenAccess = CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess()
        if hasScreenAccess { Task { await refreshContent() } }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reloads displays and windows. Requires screen recording permission.
    func refreshContent() async {
        hasScreenAccess = CGPreflightScreenCaptureAccess()
        guard hasScreenAccess else { return }
        isLoadingContent = true
        defer { isLoadingContent = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            displays = content.displays
            windows = content.windows
                .filter { window in
                    window.windowLayer == 0 && window.isOnScreen
                        && window.frame.width >= 120 && window.frame.height >= 80
                        && !(window.title ?? "").isEmpty
                        && window.owningApplication != nil
                        && window.owningApplication?.processID != pid
                }
                .sorted {
                    let a = $0.owningApplication?.applicationName ?? "", b = $1.owningApplication?.applicationName ?? ""
                    return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
            if selectedDisplayID == nil || !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                selectedDisplayID = NSScreen.main?.recordingDisplayID ?? displays.first?.displayID
            }
            if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) { selectedWindowID = nil }
        } catch {
            hasScreenAccess = false
            errorMessage = "Toolbox couldn't list your screens. \(error.localizedDescription)"
        }
    }

    /// Loads a small preview image for a display or window, cached by ID.
    func loadThumbnail(display: SCDisplay) async {
        guard thumbnails[display.displayID] == nil else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        thumbnails[display.displayID] = await capture(filter: filter, aspect: CGFloat(display.width) / CGFloat(max(display.height, 1)))
    }

    func loadThumbnail(window: SCWindow) async {
        guard thumbnails[window.windowID] == nil else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        thumbnails[window.windowID] = await capture(filter: filter, aspect: window.frame.width / max(window.frame.height, 1))
    }

    private func capture(filter: SCContentFilter, aspect: CGFloat) async -> NSImage? {
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = max(Int(480 / max(aspect, 0.1)), 2)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    func selectArea() async {
        guard let screen = NSScreen.recordingScreenUnderMouse else { return }
        let mainWindows = hideMainWindows()
        let rect = await RecordingAreaSelector.select(on: screen)
        restore(mainWindows)
        if let rect {
            area = rect
            areaDisplayID = screen.recordingDisplayID
            source = .area
        }
    }

    // MARK: Camera

    private func updateCameraBubble() {
        guard phase == .setup || phase == .preparing || phase == .recording || isCountingDown else { return }
        if cameraEnabled {
            Task {
                guard await Self.requestAccess(for: .video) else {
                    cameraEnabled = false
                    errorMessage = "Camera access is off. Turn it on in System Settings › Privacy & Security › Camera."
                    return
                }
                if cameraEnabled { camera.show(deviceID: cameraID, diameter: cameraSize.diameter) }
            }
        } else {
            camera.hide()
        }
    }

    /// Hides the camera bubble while away from the setup screen (e.g. another tool is open).
    func setupScreenVisibilityChanged(visible: Bool) {
        guard phase == .setup else { return }
        if visible { updateCameraBubble() } else { camera.hide() }
    }

    private var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    nonisolated static func requestAccess(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    // MARK: Recording

    var canStart: Bool {
        guard phase == .setup, hasScreenAccess else { return false }
        switch source {
        case .display: return !displays.isEmpty
        case .window: return selectedWindowID != nil
        case .area: return area != nil
        }
    }

    func startRecording() async {
        guard phase == .setup else { return }
        errorMessage = nil
        phase = .preparing
        saveOptions()

        if recordMicrophone, !(await Self.requestAccess(for: .audio)) {
            fail("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone, or record without the microphone.")
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            hasScreenAccess = false
            fail("Toolbox needs Screen Recording permission.")
            return
        }

        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecording-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            recordingFolder = folder

            let (filter, configuration, region, targetScreen, areaRect) = try await makeCapture()
            let large = max(configuration.width, configuration.height) > 4096
            let probe = SCRecordingOutputConfiguration()
            let codec: AVVideoCodecType = large && probe.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
            let fileType: AVFileType = probe.availableOutputFileTypes.contains(.mov) ? .mov : .mp4
            let engine = RecordingEngine(filter: filter, configuration: configuration, region: region,
                                         folder: folder, fileType: fileType, codec: codec)
            engine.onUnexpectedStop = { [weak self] _ in
                guard let self, self.phase == .recording else { return }
                Task { await self.stopRecording() }
            }
            self.engine = engine

            hiddenWindows = hideMainWindows()
            if useCountdown {
                for number in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(number)
                    countdown.show(number, on: targetScreen)
                    try await Task.sleep(for: .seconds(1))
                }
                countdown.close()
            }

            try await engine.start()
            startedAt = Date()
            pausedTotal = 0
            pauseBegan = nil
            isPaused = false
            phase = .recording
            controlPanel.show(studio: self, on: targetScreen, avoiding: areaRect)
            if let areaRect { areaBorder.show(around: areaRect) }
            showStatusItem()
        } catch {
            countdown.close()
            await engine?.stop()
            engine = nil
            restore(hiddenWindows)
            hiddenWindows = []
            cleanupFolder()
            fail(Self.describe(error))
        }
    }

    func togglePause() async {
        guard phase == .recording, let engine else { return }
        if isPaused {
            do {
                try engine.resume()
                if let pauseBegan { pausedTotal += Date().timeIntervalSince(pauseBegan) }
                pauseBegan = nil
                isPaused = false
            } catch {
                errorMessage = Self.describe(error)
            }
        } else {
            pauseBegan = Date()
            isPaused = true
            await engine.pause()
        }
        updateStatusItem()
    }

    func stopRecording() async {
        guard phase == .recording, let engine else { return }
        phase = .finishing
        tearDownRecordingUI()
        await engine.stop()
        self.engine = nil

        let segments = engine.segments
        var durations: [Double] = []
        var size = CGSize.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            durations.append((try? await asset.load(.duration).seconds) ?? 0)
            if size == .zero, let track = try? await asset.loadTracks(withMediaType: .video).first {
                size = (try? await track.load(.naturalSize)) ?? .zero
            }
        }
        let total = durations.reduce(0, +)
        restore(hiddenWindows)
        hiddenWindows = []

        guard let folder = recordingFolder, total > 0.2 else {
            cleanupFolder()
            phase = .setup
            updateCameraBubble()
            errorMessage = engine.error.map { "The recording failed: \(Self.describe($0))" } ?? "The recording was too short."
            return
        }
        let take = RecordingTake(folder: folder, segments: segments, clicks: engine.clicks(segmentDurations: durations),
                                 duration: total, size: size, date: startedAt ?? Date())
        self.take = take
        editor = RecordingEditorModel(take: take)
        recordingFolder = nil
        phase = .editing
    }

    /// Stops and throws the recording away.
    func discardRecording() async {
        guard phase == .recording, let engine else { return }
        phase = .finishing
        tearDownRecordingUI()
        await engine.stop()
        self.engine = nil
        restore(hiddenWindows)
        hiddenWindows = []
        cleanupFolder()
        phase = .setup
        updateCameraBubble()
    }

    /// Leaves the editor and deletes the take.
    func discardTake() {
        editor?.tearDown()
        editor = nil
        if let take { try? FileManager.default.removeItem(at: take.folder) }
        take = nil
        phase = .setup
        updateCameraBubble()
    }

    private func fail(_ message: String) {
        errorMessage = message
        phase = .setup
    }

    private func tearDownRecordingUI() {
        controlPanel.close()
        areaBorder.close()
        camera.hide()
        statusTimer?.invalidate()
        statusTimer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func cleanupFolder() {
        if let recordingFolder { try? FileManager.default.removeItem(at: recordingFolder) }
        recordingFolder = nil
    }

    // MARK: Capture configuration

    private func makeCapture() async throws -> (SCContentFilter, SCStreamConfiguration, RecordingEngine.Region, NSScreen?, CGRect?) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.first { $0.processID == pid }
        let bubble = camera.isVisible ? content.windows.first { $0.windowID == CGWindowID(camera.windowNumber) } : nil

        func displayFilter(_ display: SCDisplay) -> SCContentFilter {
            if let ownApp {
                return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: bubble.map { [$0] } ?? [])
            }
            return SCContentFilter(display: display, excludingWindows: [])
        }

        let filter: SCContentFilter
        var sourceRect: CGRect?
        let region: RecordingEngine.Region
        var screen: NSScreen?
        var areaRect: CGRect?

        switch source {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID }) ?? content.displays.first else {
                throw RecordingComposerError.failed("No display is available to record.")
            }
            filter = displayFilter(display)
            region = .init(rect: display.frame, windowID: nil)
            screen = NSScreen.recordingScreen(for: display.displayID)
        case .area:
            guard let area, let display = content.displays.first(where: { $0.displayID == areaDisplayID }) else {
                throw RecordingComposerError.failed("Select an area to record first.")
            }
            filter = displayFilter(display)
            sourceRect = area
            region = .init(rect: area.offsetBy(dx: display.frame.minX, dy: display.frame.minY), windowID: nil)
            screen = NSScreen.recordingScreen(for: display.displayID)
            areaRect = screen?.recordingCocoaRect(fromTopLeft: area)
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                throw RecordingComposerError.failed("That window is no longer open. Pick another one.")
            }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let display = content.displays.first { $0.frame.contains(center) } ?? content.displays.first
            screen = display.flatMap { NSScreen.recordingScreen(for: $0.displayID) }
            if let bubble, let display {
                // Include the camera bubble by capturing just these two windows on the display.
                filter = SCContentFilter(display: display, including: [window, bubble])
                let rect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    .intersection(CGRect(origin: .zero, size: display.frame.size))
                sourceRect = rect
                region = .init(rect: window.frame, windowID: nil)
            } else {
                filter = SCContentFilter(desktopIndependentWindow: window)
                region = .init(rect: window.frame, windowID: window.windowID)
            }
        }

        let configuration = SCStreamConfiguration()
        let pointSize = sourceRect?.size ?? filter.contentRect.size
        var pixels = CGSize(width: pointSize.width * CGFloat(filter.pointPixelScale),
                            height: pointSize.height * CGFloat(filter.pointPixelScale))
        if let limits = quality.limits {
            let scale = min(1, limits.long / max(pixels.width, pixels.height), limits.short / min(pixels.width, pixels.height))
            pixels = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        }
        configuration.width = max(Int((pixels.width / 2).rounded()) * 2, 2)
        configuration.height = max(Int((pixels.height / 2).rounded()) * 2, 2)
        if let sourceRect { configuration.sourceRect = sourceRect }
        // Scale into the configured size (lower resolution presets, windows that get resized).
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 6
        configuration.showsCursor = showCursor
        configuration.showMouseClicks = highlightClicks
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = recordSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = recordMicrophone
        if recordMicrophone, let microphoneID { configuration.microphoneCaptureDeviceID = microphoneID }
        return (filter, configuration, region, screen, areaRect)
    }

    // MARK: Windows and menu bar

    private func hideMainWindows() -> [NSWindow] {
        let windows = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "main" }
        windows.forEach { $0.orderOut(nil) }
        return windows
    }

    private func restore(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        NSApp.activate()
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    private func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        item.button?.contentTintColor = .systemRed
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = RecordingStatusTarget.shared
        item.button?.action = #selector(RecordingStatusTarget.stop)
        item.button?.toolTip = "Stop recording"
        statusItem = item
        updateStatusItem()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in RecordingStudio.shared.updateStatusItem() }
        }
    }

    private func updateStatusItem() {
        statusItem?.button?.title = " " + TimeFormat.string(elapsed) + (isPaused ? " (paused)" : "")
    }

    // MARK: Persistence

    private static let defaultsPrefix = "recording."

    private func saveOptions() {
        let defaults = UserDefaults.standard
        defaults.set(source.rawValue, forKey: Self.defaultsPrefix + "source")
        defaults.set(recordMicrophone, forKey: Self.defaultsPrefix + "mic")
        defaults.set(microphoneID, forKey: Self.defaultsPrefix + "micID")
        defaults.set(recordSystemAudio, forKey: Self.defaultsPrefix + "systemAudio")
        defaults.set(showCursor, forKey: Self.defaultsPrefix + "cursor")
        defaults.set(highlightClicks, forKey: Self.defaultsPrefix + "clicks")
        defaults.set(cameraID, forKey: Self.defaultsPrefix + "cameraID")
        defaults.set(cameraSize.rawValue, forKey: Self.defaultsPrefix + "cameraSize")
        defaults.set(quality.rawValue, forKey: Self.defaultsPrefix + "quality")
        defaults.set(frameRate, forKey: Self.defaultsPrefix + "fps")
        defaults.set(useCountdown, forKey: Self.defaultsPrefix + "countdown")
    }

    private func loadOptions() {
        let defaults = UserDefaults.standard
        func value<T>(_ key: String) -> T? { defaults.object(forKey: Self.defaultsPrefix + key) as? T }
        source = value("source").flatMap(RecordingSourceKind.init(rawValue:)) ?? .display
        if source == .area { source = .display } // Areas aren't remembered between launches.
        recordMicrophone = value("mic") ?? true
        microphoneID = value("micID")
        recordSystemAudio = value("systemAudio") ?? false
        showCursor = value("cursor") ?? true
        highlightClicks = value("clicks") ?? true
        cameraID = value("cameraID")
        cameraSize = value("cameraSize").flatMap(RecordingCameraSize.init(rawValue:)) ?? .medium
        quality = value("quality").flatMap(RecordingQuality.init(rawValue:)) ?? .retina
        frameRate = value("fps") ?? 30
        useCountdown = value("countdown") ?? true
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            return "Screen Recording permission was denied."
        }
        return error.localizedDescription
    }
}

/// Target for the menu bar stop button.
@MainActor
final class RecordingStatusTarget: NSObject {
    static let shared = RecordingStatusTarget()
    @objc func stop() {
        Task { await RecordingStudio.shared.stopRecording() }
    }
}
