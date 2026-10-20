import AppKit
import SwiftUI

/// A small glass panel that sits on the System Settings window and tells you what to do there. For
/// Screen Recording and Accessibility it holds a Toolbox row you can drag straight into the list.
/// It follows the window, hides while another app is in front, and closes itself once the permission
/// comes through.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let width: CGFloat = 480
    /// Gap between the panel and the bottom of the System Settings window.
    private static let bottomMargin: CGFloat = 18

    private let model = PermissionGuideModel()
    private var panel: GuidePanel?
    private var hosting: GuideHostingView?
    private var timer: Timer?
    private var openedAt = Date()
    private var settingsLastSeen: Date?
    private var ticks = 0

    private(set) var permission: AppPermission?

    /// Opens System Settings at the permission's page and shows the guide over it.
    func show(for permission: AppPermission) {
        close()
        self.permission = permission
        model.permission = permission
        model.isGranted = false
        model.isDragging = false
        openedAt = Date()
        settingsLastSeen = nil
        ticks = 0
        NSWorkspace.shared.open(permission.settingsURL)
        PermissionCenter.shared.startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionGuide.shared.tick() }
        }
    }

    func close() {
        guard permission != nil else { return }
        timer?.invalidate()
        timer = nil
        permission = nil
        PermissionCenter.shared.stopWatching()
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        fade(panel, to: 0) { panel.orderOut(nil) }
    }

    // MARK: Tracking

    private func tick() {
        guard let permission else { return }
        ticks += 1
        // Screen Recording and Accessibility have no change notification, so poll a few times a second.
        if ticks % 6 == 0 { PermissionCenter.shared.refresh() }
        if !model.isGranted, PermissionCenter.shared.state(permission) == .granted {
            celebrate(permission)
        }

        guard let frame = Self.settingsWindowFrame() else {
            // Wait for System Settings to open, and close once it goes away.
            let waited = Date().timeIntervalSince(settingsLastSeen ?? openedAt)
            if waited > (settingsLastSeen == nil ? 8 : 0.6) { close() }
            else { panel.map { setVisible(false, $0) } }
            return
        }
        settingsLastSeen = Date()
        let panel = self.panel ?? makePanel()
        place(panel, over: frame)
        let settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
        setVisible(settingsInFront || model.isDragging || model.isGranted, panel)
    }

    private func celebrate(_ permission: AppPermission) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { model.isGranted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard self.permission == permission else { return }
            self.close()
            // Screen Recording asks to quit and reopen in System Settings; leave that dialog in front.
            if permission != .screenRecording { OnboardingController.shared.bringForwardIfOpen() }
        }
    }

    // MARK: Panel

    private func makePanel() -> GuidePanel {
        let bounds = NSRect(x: 0, y: 0, width: Self.width, height: 120)
        let hosting = GuideHostingView(rootView: PermissionGuideView(model: model, onClose: { PermissionGuide.shared.close() }))
        // The panel takes the height the content asks for; the content never resizes the panel itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.cornerRadius = PermissionGuideView.cornerRadius
        glass.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        let panel = GuidePanel()
        panel.contentView = glass
        panel.alphaValue = 0
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Centers the panel over the bottom of the window's content area, clear of the sidebar, like a
    /// hint attached to the list.
    private func place(_ panel: GuidePanel, over window: CGRect) {
        let sidebar = min(max(window.width * 0.3, 190), 260)
        let content = window.width > Self.width + sidebar ? window.divided(atDistance: sidebar, from: .minXEdge).remainder : window
        let width = min(Self.width, content.width - 24)
        if model.width != width { model.width = width }
        let height = max(hosting?.intrinsicContentSize.height ?? 0, 60)
        var frame = CGRect(x: content.midX - width / 2, y: window.minY + Self.bottomMargin, width: width, height: height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func setVisible(_ visible: Bool, _ panel: GuidePanel) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
            if panel.alphaValue < 1, !panel.isFading { fade(panel, to: 1) }
        } else if panel.isVisible, !panel.isFading {
            // Order it out too, so a see-through panel never catches clicks meant for System Settings.
            fade(panel, to: 0) { panel.orderOut(nil) }
        }
    }

    private func fade(_ panel: GuidePanel, to alpha: CGFloat, then completion: (() -> Void)? = nil) {
        panel.isFading = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.22 : 0.16
            panel.animator().alphaValue = alpha
        } completionHandler: {
            panel.isFading = false
            completion?()
        }
    }

    /// The frontmost-in-z-order System Settings window, in AppKit screen coordinates. Window bounds are
    /// readable without Screen Recording permission (titles aren't).
    private static func settingsWindowFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let bounds = info.lazy
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
            .first { $0.width > 320 && $0.height > 240 }
        guard let bounds, let primary = NSScreen.screens.first else { return nil }
        // Quartz puts the origin at the top left of the primary display, AppKit at its bottom left.
        return CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

@MainActor
@Observable
final class PermissionGuideModel {
    var permission: AppPermission = .screenRecording
    var width: CGFloat = 480
    var isGranted = false
    var isDragging = false
    var isHoveringRow = false
}

/// Borderless, see-through panel that floats over System Settings without taking focus from it.
private final class GuidePanel: NSPanel {
    var isFading = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// System Settings stays in front while you use the guide, so the first click has to reach its buttons.
private final class GuideHostingView: NSHostingView<PermissionGuideView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PermissionGuideView: View {
    static let cornerRadius: CGFloat = 26
    /// The drag row's corners are concentric with the panel's.
    private static let inset: CGFloat = 12

    let model: PermissionGuideModel
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: LauncherPalette { LauncherPalette(scheme: colorScheme) }
    private var permission: AppPermission { model.permission }
    private var showsDragRow: Bool { permission.isGrantedByDragging && !model.isGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                symbol
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isGranted ? permission.grantedMessage : permission.guideInstruction)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.isGranted {
                        Text(permission.guideHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(palette.highlight, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            if showsDragRow {
                AppDragRow(model: model, palette: palette)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(Self.inset)
        .padding(.bottom, showsDragRow ? 0 : 6)
        .frame(width: model.width, alignment: .leading)
        .background(palette.smoke)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var symbol: some View {
        let name = model.isGranted ? "checkmark.circle.fill" : permission.isGrantedByDragging ? "arrow.up" : "switch.2"
        let image = Image(systemName: name)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(model.isGranted ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 26, height: 26)
        if reduceMotion || model.isGranted || !permission.isGrantedByDragging {
            image
        } else {
            // Nudges upward now and then, toward the list.
            image.symbolEffect(.bounce.up.byLayer, options: .repeat(.periodic(delay: 2.5)))
        }
    }
}

/// Looks like a row in the System Settings list; dragging it drags Toolbox.app, which the list accepts.
private struct AppDragRow: View {
    static let radius = PermissionGuideView.cornerRadius - 12

    let model: PermissionGuideModel
    let palette: LauncherPalette

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Text(AppInfo.name)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(model.isHoveringRow ? palette.highlight : palette.card))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(palette.cardRim))
        .opacity(model.isDragging ? 0.45 : 1)
        .overlay { AppDragSource(model: model, preview: dragPreview) }
        .animation(.easeOut(duration: 0.12), value: model.isHoveringRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(AppInfo.name). Drag into the list in System Settings.")
    }

    /// What follows the pointer: the same row on a solid background, so it reads over any window.
    private var dragPreview: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Text(AppInfo.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.isDark ? Color.white : Color.black)
            Spacer()
        }
        .padding(.leading, 10)
        .frame(width: 220, height: 52)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(palette.isDark ? Color(white: 0.2) : Color.white))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(palette.cardRim))
    }
}

private struct AppDragSource<Preview: View>: NSViewRepresentable {
    let model: PermissionGuideModel
    let preview: Preview

    func makeNSView(context: Context) -> AppDragSourceView {
        let view = AppDragSourceView(model: model)
        view.makePreview = { scale in Self.render(preview, scale: scale) }
        return view
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.makePreview = { scale in Self.render(preview, scale: scale) }
    }

    @MainActor
    private static func render(_ preview: Preview, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: preview)
        renderer.scale = scale
        return renderer.nsImage
    }
}

/// Starts a file drag of the app bundle. Built in AppKit because the panel never becomes key, and the
/// drag has to start on the first click while System Settings is the active app.
private final class AppDragSourceView: NSView, NSDraggingSource {
    private let model: PermissionGuideModel
    private var mouseDown: NSEvent?
    var makePreview: ((CGFloat) -> NSImage?)?

    init(model: PermissionGuideModel) {
        self.model = model
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        model.isHoveringRow = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        model.isHoveringRow = false
        if !model.isDragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        mouseDown = nil
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDown else { return }
        let start = mouseDown.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        self.mouseDown = nil

        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let scale = window?.backingScaleFactor ?? 2
        guard let image = makePreview?(scale) ?? NSApp.applicationIconImage else { return }
        // Keep the preview under the pointer where the row was grabbed.
        let grab = convert(start, from: nil)
        let origin = NSPoint(x: grab.x - min(grab.x, image.size.width - 20), y: bounds.midY - image.size.height / 2)
        item.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
        let session = beginDraggingSession(with: [item], event: mouseDown, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        model.isDragging = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never .move: dropped on a Finder window by mistake, the app must not be moved.
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model.isDragging = false
        model.isHoveringRow = false
        NSCursor.arrow.set()
    }
}
