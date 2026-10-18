import AppKit
@preconcurrency import AVFoundation
import SwiftUI

// Floating windows used while recording: camera bubble, control bar, countdown, area picker and border.

extension NSScreen {
    var recordingDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func recordingScreen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        screens.first { $0.recordingDisplayID == displayID } ?? main
    }

    static var recordingScreenUnderMouse: NSScreen? {
        screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? main
    }

    /// Converts a rect in this screen's top-left-origin point space (ScreenCaptureKit's sourceRect)
    /// to global Cocoa coordinates.
    func recordingCocoaRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Camera bubble

/// A round, draggable, always-on-top camera preview. Screen recordings capture it like any window.
@MainActor
final class RecordingCameraBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDeviceID: String?
    private let sessionQueue = DispatchQueue(label: "toolbox.recording.camera")

    var isVisible: Bool { panel?.isVisible == true }
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show(deviceID: String?, diameter: CGFloat) {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device else { return }

        if panel == nil { makePanel(diameter: diameter) }
        resize(to: diameter)
        if currentDeviceID != device.uniqueID || session == nil {
            startSession(with: device)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        let session = session
        sessionQueue.async { session?.stopRunning() }
        self.session = nil
        currentDeviceID = nil
    }

    private func makePanel(diameter: CGFloat) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: screen.minX + 40, y: screen.minY + 40, width: diameter, height: diameter)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = RecordingDraggableView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
    }

    private func resize(to diameter: CGFloat) {
        guard let panel, let view = panel.contentView else { return }
        var frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = CGSize(width: diameter, height: diameter)
        frame.origin = CGPoint(x: center.x - diameter / 2, y: center.y - diameter / 2)
        panel.setFrame(frame, display: true)
        view.layer?.cornerRadius = diameter / 2
        view.layer?.borderWidth = max(diameter * 0.015, 2)
        previewLayer?.frame = view.bounds
    }

    private func startSession(with device: AVCaptureDevice) {
        if let old = session { sessionQueue.async { old.stopRunning() } }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        self.session = session
        currentDeviceID = device.uniqueID

        previewLayer?.removeFromSuperlayer()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let view = panel?.contentView {
            layer.frame = view.bounds
            view.layer?.addSublayer(layer)
        }
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        previewLayer = layer
        sessionQueue.async { session.startRunning() }
    }
}

private final class RecordingDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
}

// MARK: - Floating control bar

/// The small panel shown while recording: elapsed time, pause, stop and discard.
@MainActor
final class RecordingControlPanel {
    private var panel: NSPanel?

    func show(studio: RecordingStudio, on screen: NSScreen?, avoiding area: CGRect?) {
        let hosting = NSHostingView(rootView: RecordingControlBar(studio: studio))
        hosting.frame.size = hosting.fittingSize
        let size = hosting.fittingSize
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12)
        // Keep the bar out of a selected area when possible.
        if let area, area.intersects(CGRect(origin: origin, size: size)) {
            let below = area.minY - size.height - 12
            origin.y = below > visible.minY ? below : min(area.maxY + 12, visible.maxY - size.height)
        }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct RecordingControlBar: View {
    let studio: RecordingStudio
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(studio.isPaused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(pulse && !studio.isPaused ? 0.35 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(TimeFormat.string(studio.elapsed))
                    .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(minWidth: 52, alignment: .leading)
            }
            Divider().frame(height: 18)
            Button { Task { await studio.togglePause() } } label: {
                Image(systemName: studio.isPaused ? "play.fill" : "pause.fill")
            }
            .help(studio.isPaused ? "Resume" : "Pause")
            Button { Task { await studio.stopRecording() } } label: {
                Image(systemName: "stop.fill").foregroundStyle(.red)
            }
            .help("Stop and edit")
            Button { Task { await studio.discardRecording() } } label: {
                Image(systemName: "trash")
            }
            .help("Discard recording")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .padding(4)
        .disabled(studio.phase != .recording)
    }
}

// MARK: - Countdown

@MainActor
final class RecordingCountdownWindow {
    private var panel: NSPanel?
    private var hosting: NSHostingView<RecordingCountdownView>?

    func show(_ number: Int, on screen: NSScreen?) {
        let size = CGSize(width: 180, height: 180)
        if panel == nil {
            let frame = (screen ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let panel = NSPanel(contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                                    width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: RecordingCountdownView(number: number))
            panel.contentView = hosting
            self.hosting = hosting
            self.panel = panel
        }
        hosting?.rootView = RecordingCountdownView(number: number)
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

struct RecordingCountdownView: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 96, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 160, height: 160)
            .background(Circle().fill(.black.opacity(0.6)))
            .contentTransition(.numericText(countsDown: true))
    }
}

// MARK: - Area selection

/// Full-screen overlay where the user drags out the area to record.
@MainActor
enum RecordingAreaSelector {
    /// Keeps the overlay alive while it's on screen.
    private static var current: NSWindow?

    /// Returns the selected rect in the screen's top-left-origin point space, or nil if cancelled.
    static func select(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let window = RecordingAreaWindow(screen: screen) { rect in
                current = nil
                continuation.resume(returning: rect)
            }
            current = window
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private final class RecordingAreaWindow: NSWindow {
    private var completion: ((CGRect?) -> Void)?

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        let view = RecordingAreaView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect) }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ viewRect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        let height = frame.height
        orderOut(nil)
        completion(viewRect.map { rect in
            CGRect(x: rect.minX.rounded(), y: (height - rect.maxY).rounded(),
                   width: rect.width.rounded(), height: rect.height.rounded())
        })
    }
}

private final class RecordingAreaView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let rect = selection, rect.width >= 40, rect.height >= 40 {
            onFinish?(rect)
        } else {
            start = nil
            current = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: rect.minX, y: max(rect.minY - size.height - 10, 4), width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attributes)
        } else {
            let text = "Drag to select the area to record · Esc to cancel" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            let box = CGRect(x: bounds.midX - size.width / 2 - 18, y: bounds.midY - size.height / 2 - 10,
                             width: size.width + 36, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            text.draw(at: CGPoint(x: box.minX + 18, y: box.minY + 10), withAttributes: attributes)
        }
    }
}

// MARK: - Area border

/// A dashed outline around the recorded area. Toolbox's windows are excluded from the capture.
@MainActor
final class RecordingAreaBorder {
    private var window: NSWindow?

    func show(around cocoaRect: CGRect) {
        let frame = cocoaRect.insetBy(dx: -4, dy: -4)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = RecordingBorderView(frame: CGRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}
