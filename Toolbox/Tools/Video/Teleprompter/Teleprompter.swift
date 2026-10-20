import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// The teleprompter on screen: which script it shows, where it has scrolled to, and everything that
/// moves it (your voice, the keyboard, the trackpad, the phone remote). One for the app, so it keeps
/// running while you use other tools or other apps.
@MainActor
@Observable
final class Teleprompter {
    static let shared = Teleprompter()

    let settings = TeleprompterSettings.shared
    let remote = TeleprompterRemote()

    // MARK: What's showing

    private(set) var isShowing = false
    private(set) var scriptID: UUID?
    private(set) var title = ""
    private(set) var cues: [TeleprompterCue] = []
    private(set) var words = 0

    // MARK: Playback

    /// You pressed play. The text still waits during the countdown, while you hover and, when it
    /// follows your voice, while you're quiet.
    private(set) var isPlaying = false
    /// How far the script has scrolled, in points from the top.
    private(set) var offset: CGFloat = 0
    /// Seconds left before the text starts moving.
    private(set) var countdown: Int?
    private(set) var isHovering = false
    private(set) var isSpeaking = false
    /// 0…1, smoothed, for the voice beam.
    private(set) var voiceLevel: Double = 0
    /// Why the prompter can't listen. It scrolls steadily instead.
    private(set) var voiceProblem: String?
    /// Reached the end of the script.
    private(set) var isFinished = false
    /// Where you were before jumping to a cue. Go back there with `returnToSavedPlace()`.
    private(set) var savedOffset: CGFloat?
    /// The cue being read.
    private(set) var currentCue = 0
    /// Shortcuts macOS refused, usually because another app uses them.
    private(set) var unavailableShortcuts: [String] = []

    /// The laid-out script's height and where each cue starts, measured by the overlay.
    private(set) var contentHeight: CGFloat = 0
    @ObservationIgnored private var cueStarts: [CGFloat] = []
    /// The cues `cueStarts` were measured for.
    @ObservationIgnored private var measuredCues: [TeleprompterCue] = []

    @ObservationIgnored private var panel: TeleprompterPanel?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private let frameTarget = TeleprompterFrameTarget()
    @ObservationIgnored private var lastFrame: CFTimeInterval?
    @ObservationIgnored private var velocity: CGFloat = 0
    /// Set while easing to a cue or another jump target.
    @ObservationIgnored private var scrollTarget: CGFloat?
    @ObservationIgnored private var lastSpeech: CFTimeInterval = -10
    @ObservationIgnored private var countdownEnd: CFTimeInterval?
    @ObservationIgnored private let voice = TeleprompterVoiceMonitor()
    @ObservationIgnored private var playbackHotKeys: [GlobalHotKey] = []
    @ObservationIgnored private var showHotKey: GlobalHotKey?
    @ObservationIgnored private var lastRemoteUpdate: CFTimeInterval = 0

    private init() {
        frameTarget.onFrame = { [weak self] in self?.frame() }
        voice.onInterruption = { [weak self] in
            Task { @MainActor in self?.restartListening() }
        }
    }

    var lineHeight: CGFloat { settings.fontSize * (1.2 + settings.lineSpacing) }
    /// The last line stops at the reading line.
    var maxOffset: CGFloat { max(0, contentHeight - lineHeight) }
    var progress: Double { maxOffset > 0 ? Double(min(offset / maxOffset, 1)) : 0 }
    var listensToVoice: Bool { settings.scrollMode == .voice && voiceProblem == nil }
    /// Reading time left at the chosen speed.
    var secondsLeft: Int { Int((Double(words) * (1 - progress) / settings.wordsPerMinute * 60).rounded()) }

    /// Whether the text is moving on its own right now.
    var isMoving: Bool {
        isPlaying && countdown == nil && !(settings.hoverToPause && isHovering) && (!listensToVoice || isSpeaking)
    }

    /// Speed in points per second: the chosen words per minute over the laid-out text.
    private var pointsPerSecond: CGFloat {
        guard words > 0, contentHeight > 0 else { return 0 }
        return CGFloat(settings.wordsPerMinute / 60) * contentHeight / CGFloat(words)
    }

    // MARK: - Showing

    /// Opens the prompter with `script` from the top, or switches the open prompter to it.
    func show(_ script: TeleprompterScript) {
        let switching = scriptID != script.id
        load(script)
        if isShowing {
            if switching { restart() }
            return
        }
        isShowing = true
        offset = 0
        savedOffset = nil
        isFinished = false
        velocity = 0
        scrollTarget = nil
        currentCue = 0
        makePanel()
        startListening()
        updateHotKeys()
        play()
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        isPlaying = false
        countdown = nil
        countdownEnd = nil
        isHovering = false
        displayLink?.invalidate()
        displayLink = nil
        lastFrame = nil
        panel?.orderOut(nil)
        panel = nil
        stopListening()
        updateHotKeys()
        updateRemote(force: true)
    }

    /// Shows the selected script, or hides the prompter. ⌃⌥⌘T from any app.
    func toggle() {
        if isShowing {
            hide()
        } else if let script = TeleprompterLibrary.shared.selected ?? TeleprompterLibrary.shared.scripts.first {
            show(script)
        }
    }

    /// Picks up edits to the script on screen, keeping your place.
    func scriptChanged(_ script: TeleprompterScript) {
        guard isShowing, script.id == scriptID else { return }
        load(script)
    }

    /// Takes `script`'s text and cues, without opening the prompter.
    func load(_ script: TeleprompterScript) {
        scriptID = script.id
        title = script.displayTitle
        let parsed = TeleprompterParser.cues(in: script.text)
        if parsed != cues { cues = parsed }
        words = parsed.reduce(0) { $0 + $1.words }
        updateRemote(force: true)
    }

    /// The overlay measured the script, after it first appears or its text, size or width changed.
    func layoutChanged(_ layout: TeleprompterLayout) {
        let height = layout.height
        let starts = cues.indices.map { layout.cueStarts[$0] ?? 0 }
        if contentHeight > 1, height > 1, scrollTarget == nil {
            if measuredCues != cues {
                // The text was edited: stay at the same spot in the cue you're reading.
                if cueStarts.indices.contains(currentCue), starts.indices.contains(currentCue) {
                    offset += starts[currentCue] - cueStarts[currentCue]
                }
            } else if abs(height - contentHeight) > 0.5 {
                // The same text at a new size or width: keep your place as it reflows.
                offset *= height / contentHeight
                savedOffset = savedOffset.map { $0 * height / contentHeight }
            }
        }
        measuredCues = cues
        if height != contentHeight { contentHeight = height }
        cueStarts = starts
        setOffset(offset)
    }

    // MARK: - Playback

    func play() {
        guard isShowing else { return }
        if isFinished || (maxOffset > 0 && offset >= maxOffset - 0.5) {
            isFinished = false
            setOffset(0)
            savedOffset = nil
        }
        isPlaying = true
        if offset < 1, settings.countdown > 0 {
            countdownEnd = CACurrentMediaTime() + Double(settings.countdown)
            countdown = settings.countdown
        }
        updateRemote(force: true)
    }

    func pause() {
        isPlaying = false
        countdown = nil
        countdownEnd = nil
        updateRemote(force: true)
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    /// Back to the top, with the countdown.
    func restart() {
        scrollTarget = nil
        velocity = 0
        savedOffset = nil
        isFinished = false
        setOffset(0)
        pause()
        play()
    }

    /// Scrolls by `points`; positive moves on through the script.
    func scroll(by points: CGFloat) {
        scrollTarget = nil
        if points < 0 { isFinished = false }
        setOffset(offset + points)
        updateRemote()
    }

    /// Scrolls by whole lines at the current text size.
    func nudge(lines: Double) {
        scroll(by: CGFloat(lines) * lineHeight)
    }

    func changeSpeed(by delta: Double) {
        let value = ((settings.wordsPerMinute + delta) / 10).rounded() * 10
        settings.wordsPerMinute = min(max(value, TeleprompterSettings.speeds.lowerBound), TeleprompterSettings.speeds.upperBound)
        updateRemote(force: true)
    }

    // MARK: - Cues

    /// Jumps to a cue, remembering where you were so you can go back.
    func jump(toCue index: Int) {
        guard cueStarts.indices.contains(index) else { return }
        if savedOffset == nil { savedOffset = scrollTarget ?? offset }
        move(to: cueStarts[index])
    }

    func nextCue() {
        let position = scrollTarget ?? offset
        if let next = cueStarts.firstIndex(where: { $0 > position + 1 }) { move(to: cueStarts[next]) }
    }

    /// The start of this cue, or the cue before when you're already at its start.
    func previousCue() {
        let position = scrollTarget ?? offset
        if let previous = cueStarts.lastIndex(where: { $0 < position - lineHeight * 0.5 }) {
            move(to: cueStarts[previous])
        } else {
            move(to: 0)
        }
    }

    /// Goes back to where you were before jumping to a cue.
    func returnToSavedPlace() {
        guard let savedOffset else { return }
        self.savedOffset = nil
        move(to: savedOffset)
    }

    private func move(to target: CGFloat) {
        let target = min(max(target, 0), maxOffset)
        isFinished = false
        velocity = 0
        // Without frames to ease over (the prompter is closed), or with Reduce Motion, go straight there.
        if displayLink == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollTarget = nil
            setOffset(target)
        } else {
            scrollTarget = target
        }
        updateRemote(force: true)
    }

    private func setOffset(_ value: CGFloat) {
        let clamped = min(max(value, 0), maxOffset)
        if clamped != offset { offset = clamped }
        let reading = offset + lineHeight * 0.5
        let cue = cueStarts.lastIndex(where: { $0 <= reading }) ?? 0
        if cue != currentCue { currentCue = cue }
    }

    // MARK: - Remote commands

    /// Runs a command from the phone remote.
    func perform(_ command: TeleprompterRemoteCommand) {
        switch command.action {
        case "toggle": togglePlay()
        case "play": play()
        case "pause": pause()
        case "faster": changeSpeed(by: 10)
        case "slower": changeSpeed(by: -10)
        case "scroll": nudge(lines: min(max(command.lines ?? 0, -40), 40))
        case "cue": if let index = command.index { jump(toCue: index) }
        case "next": nextCue()
        case "previous": previousCue()
        case "back": returnToSavedPlace()
        case "restart": restart()
        case "show": if !isShowing { toggle() }
        case "hide": hide()
        default: break
        }
        updateRemote(force: true)
    }

    func updateRemote(force: Bool = false) {
        guard remote.isRunning else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastRemoteUpdate > 0.2 else { return }
        lastRemoteUpdate = now
        let title = isShowing ? title : TeleprompterLibrary.shared.selected?.displayTitle ?? ""
        remote.publish(TeleprompterRemoteState(
            showing: isShowing, playing: isPlaying, moving: isMoving, title: title, cues: isShowing ? cues.map(\.label) : [],
            cue: currentCue, progress: (progress * 1000).rounded() / 1000, wpm: Int(settings.wordsPerMinute),
            canGoBack: savedOffset != nil, countdown: countdown, listening: isShowing && listensToVoice,
            speaking: isSpeaking, secondsLeft: secondsLeft, finished: isFinished))
    }

    // MARK: - Each frame

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - (lastFrame ?? now), 0), 0.1))
        lastFrame = now

        if let panel {
            let hovering = panel.frame.contains(NSEvent.mouseLocation)
            if hovering != isHovering { isHovering = hovering }
        }
        if let end = countdownEnd {
            let left = Int((end - now).rounded(.up))
            if left <= 0 {
                countdownEnd = nil
                countdown = nil
                updateRemote(force: true)
            } else if left != countdown {
                countdown = left
                updateRemote(force: true)
            }
        }
        if voice.isRunning {
            let decibels = voice.decibels
            if decibels > settings.speechThreshold { lastSpeech = now }
            // Stay "speaking" through the short gaps between words.
            let speaking = now - lastSpeech < 0.7
            if speaking != isSpeaking { isSpeaking = speaking }
            let level = Double(min(max((decibels + 60) / 50, 0), 1))
            let rate = Double(dt) * (level > voiceLevel ? 18 : 5)
            let smoothed = voiceLevel + (level - voiceLevel) * min(rate, 1)
            if abs(smoothed - voiceLevel) > 0.004 { voiceLevel = smoothed }
        }

        if let target = scrollTarget {
            let step = (target - offset) * min(dt * 9, 1)
            if abs(target - offset) < 0.75 {
                scrollTarget = nil
                setOffset(target)
            } else {
                setOffset(offset + step)
            }
        } else {
            // Ease in and out instead of jumping between moving and still.
            let target = isMoving ? pointsPerSecond : 0
            velocity += (target - velocity) * min(dt * 5, 1)
            if target == 0, velocity < 0.5 { velocity = 0 }
            if velocity > 0 { setOffset(offset + velocity * dt) }
        }

        if isPlaying, countdown == nil, maxOffset > 0, offset >= maxOffset - 0.5 {
            isPlaying = false
            isFinished = true
            velocity = 0
            updateRemote(force: true)
        }
        updateRemote()
    }

    // MARK: - Window

    private func makePanel() {
        panel?.orderOut(nil)
        let panel = TeleprompterPanel(mode: settings.display)
        panel.contentView = NSHostingView(rootView: TeleprompterOverlay(prompter: self))
        panel.onScroll = { [weak self] points in self?.scroll(by: points) }
        panel.onFrameChange = { [weak self] frame in
            guard self?.settings.display == .floating else { return }
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "teleprompter.floatingFrame")
        }
        self.panel = panel
        layoutPanel()
        panel.orderFrontRegardless()

        displayLink?.invalidate()
        if let view = panel.contentView {
            let link = view.displayLink(target: frameTarget, selector: #selector(TeleprompterFrameTarget.step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Re-creates the window for another display mode, or moves and resizes it for new settings.
    /// `screenChanged` moves a floating window to the chosen display.
    func displaySettingsChanged(screenChanged: Bool = false) {
        guard isShowing, let panel else { return }
        if panel.mode != settings.display {
            makePanel()
        } else {
            if screenChanged { panel.isPlaced = false }
            layoutPanel()
        }
    }

    private func layoutPanel() {
        guard let panel else { return }
        let screen = Self.screen(for: settings.screenID)
        switch settings.display {
        case .notch:
            let full = screen.frame
            let width = min(CGFloat(settings.notchWidth), full.width)
            let height = min(CGFloat(settings.notchHeight), full.height / 2)
            panel.setFrame(CGRect(x: full.midX - width / 2, y: full.maxY - height, width: width, height: height), display: true)
        case .floating:
            // After that, the window stays where you put it.
            guard !panel.isPlaced else { return }
            panel.isPlaced = true
            let saved = UserDefaults.standard.string(forKey: "teleprompter.floatingFrame").map(NSRectFromString)
            let screens = settings.screenID == 0 ? NSScreen.screens : [screen]
            if let saved, saved.width >= 200, saved.height >= 80, screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                panel.setFrame(saved, display: true)
            } else {
                let visible = screen.visibleFrame
                let size = CGSize(width: min(620, visible.width - 40), height: 280)
                panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24,
                                      width: size.width, height: size.height), display: true)
            }
        }
    }

    /// The display for `id`; 0 picks the one with a camera notch, then the main display.
    static func screen(for id: Int) -> NSScreen {
        if id != 0, let screen = NSScreen.screens.first(where: { $0.recordingDisplayID == CGDirectDisplayID(id) }) { return screen }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Height of the camera notch on the prompter's display; 0 when it has none.
    var notchHeight: CGFloat {
        Self.screen(for: settings.screenID).safeAreaInsets.top
    }

    /// Width of the camera notch on the prompter's display; 0 when it has none.
    var cameraNotchWidth: CGFloat {
        let screen = Self.screen(for: settings.screenID)
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - left.width - right.width)
    }

    func dragWindow(resizing: Bool) {
        panel?.drag(resizing: resizing)
    }

    func endWindowDrag() {
        panel?.endDrag()
    }

    // MARK: - Microphone

    /// Starts or stops listening to match the scroll mode.
    func scrollModeChanged() {
        guard isShowing else { return }
        if settings.scrollMode == .voice { startListening() } else { stopListening() }
        updateRemote(force: true)
    }

    func microphoneChanged() {
        guard isShowing, settings.scrollMode == .voice else { return }
        restartListening()
    }

    private func startListening() {
        guard settings.scrollMode == .voice, !voice.isRunning else { return }
        voiceProblem = nil
        Task {
            guard await Self.microphoneAllowed() else {
                voiceProblem = "Microphone access is off, so the text scrolls steadily. Allow it in System Settings › Privacy & Security › Microphone."
                return
            }
            guard isShowing, settings.scrollMode == .voice else { return }
            do {
                let id = settings.microphoneID
                try voice.start(deviceID: id == 0 ? nil : AudioDeviceID(id))
                voiceProblem = nil
            } catch {
                voiceProblem = "Couldn't listen to the microphone, so the text scrolls steadily. \(error.localizedDescription)"
            }
        }
    }

    private func stopListening() {
        voice.stop()
        isSpeaking = false
        voiceLevel = 0
        voiceProblem = nil
    }

    private func restartListening() {
        voice.stop()
        startListening()
    }

    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    // MARK: - Shortcuts

    struct Shortcut: Identifiable {
        let id: String
        let keyCode: Int
        let key: String
        let label: String
        let action: @MainActor (Teleprompter) -> Void

        static let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var display: String { "⌃⌥⌘" + key }
    }

    /// Show or hide the prompter. Registered while global shortcuts are on.
    static let showShortcut = Shortcut(id: "show", keyCode: kVK_ANSI_T, key: "T", label: "Show or hide the teleprompter") { $0.toggle() }

    /// Registered only while the prompter is on screen.
    static let playbackShortcuts: [Shortcut] = [
        Shortcut(id: "play", keyCode: kVK_Space, key: "Space", label: "Play or pause") { $0.togglePlay() },
        Shortcut(id: "back", keyCode: kVK_UpArrow, key: "↑", label: "Scroll back") { $0.nudge(lines: -2) },
        Shortcut(id: "forward", keyCode: kVK_DownArrow, key: "↓", label: "Scroll forward") { $0.nudge(lines: 2) },
        Shortcut(id: "faster", keyCode: kVK_ANSI_Equal, key: "=", label: "Faster") { $0.changeSpeed(by: 10) },
        Shortcut(id: "slower", keyCode: kVK_ANSI_Minus, key: "−", label: "Slower") { $0.changeSpeed(by: -10) },
        Shortcut(id: "next", keyCode: kVK_ANSI_RightBracket, key: "]", label: "Next cue") { $0.nextCue() },
        Shortcut(id: "previous", keyCode: kVK_ANSI_LeftBracket, key: "[", label: "Previous cue") { $0.previousCue() },
        Shortcut(id: "return", keyCode: kVK_ANSI_B, key: "B", label: "Back to where you left off") { $0.returnToSavedPlace() },
        Shortcut(id: "restart", keyCode: kVK_ANSI_R, key: "R", label: "Start over") { $0.restart() },
    ]

    /// Registers the shortcuts that fit the current state. Called at launch and when settings change.
    func updateHotKeys() {
        let enabled = settings.globalShortcuts && !AppDelegate.isTesting
        if enabled, showHotKey == nil {
            showHotKey = Self.register(Self.showShortcut)
        } else if !enabled {
            showHotKey = nil
        }
        if enabled, isShowing {
            if playbackHotKeys.isEmpty { playbackHotKeys = Self.playbackShortcuts.map(Self.register) }
        } else {
            playbackHotKeys = []
        }
        let all = [(Self.showShortcut, showHotKey)] + zip(Self.playbackShortcuts, playbackHotKeys).map { ($0, Optional($1)) }
        let failed = all.compactMap { shortcut, hotKey in hotKey?.isRegistered == false ? shortcut.display : nil }
        if failed != unavailableShortcuts { unavailableShortcuts = failed }
    }

    private static func register(_ shortcut: Shortcut) -> GlobalHotKey {
        GlobalHotKey(HotKeyShortcut(keyCode: UInt32(shortcut.keyCode), modifiers: Shortcut.modifiers)) {
            Task { @MainActor in shortcut.action(Teleprompter.shared) }
        }
    }
}

/// Measurements of the laid-out script, in its own coordinates.
struct TeleprompterLayout: Equatable {
    var height: CGFloat = 0
    var cueStarts: [Int: CGFloat] = [:]
}

/// Receives display-link callbacks, which need an Objective-C target.
final class TeleprompterFrameTarget: NSObject {
    var onFrame: (@MainActor () -> Void)?

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated { onFrame?() }
    }
}
