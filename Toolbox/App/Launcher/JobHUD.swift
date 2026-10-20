import AppKit
import SwiftUI

/// Reports jobs started without the window (from the launcher or a tool hotkey) the way Raycast's HUD
/// does: a small dark pill at the bottom of the screen with progress, then the result. Pointing at it
/// shows its action (Cancel, Show in Finder or Open Tool) and keeps it from fading out.
@MainActor
final class JobHUD {
    static let shared = JobHUD()

    struct Entry: Identifiable {
        let id = UUID()
        let tool: Tool
        let runner: JobRunner
    }

    private let model = JobHUDModel()
    private var panel: JobHUDPanel?
    /// Visible frame of the screen the pills appear on, picked when the first one shows.
    private var area: NSRect = .zero

    func show(_ tool: Tool, runner: JobRunner) {
        model.entries.removeAll { $0.runner === runner }
        model.entries.append(Entry(tool: tool, runner: runner))
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            area = screen.visibleFrame
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // The panel is sized once SwiftUI lays out the new pill; see `fit(to:)`.
        fade(panel, to: 1)
    }

    func dismiss(_ entry: Entry) {
        guard let panel, model.entries.contains(where: { $0.id == entry.id }) else { return }
        guard model.entries.count == 1 else {
            model.entries.removeAll { $0.id == entry.id }
            return
        }
        // The last pill fades out with the panel.
        fade(panel, to: 0) { [weak self] in
            guard let self else { return }
            model.entries.removeAll { $0.id == entry.id }
            if model.entries.isEmpty {
                panel.orderOut(nil)
                model.isHovered = false
            }
        }
    }

    /// Sizes the panel to the pills, centered above the Dock.
    fileprivate func fit(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 72, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        // A pill can move out from under a pointer that didn't, which sends no exit event.
        model.isHovered = frame.contains(NSEvent.mouseLocation)
        // The shadow follows the transparent window's contents, so refresh it once they're drawn.
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, then completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.15 : 0.25
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    private func makePanel() -> JobHUDPanel {
        let panel = JobHUDPanel()
        panel.contentView = JobHUDHostingView(model: model)
        self.panel = panel
        return panel
    }
}

@MainActor
@Observable
final class JobHUDModel {
    var entries: [JobHUD.Entry] = []
    var isHovered = false
}

/// Borderless, transparent panel that never takes focus from the app you're in. Always dark, like
/// Raycast's HUD.
private final class JobHUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Tracks the pointer even while another app is active, which SwiftUI's hover doesn't in a panel
/// that never becomes key.
private final class JobHUDHostingView: NSHostingView<JobHUDView> {
    private let model: JobHUDModel

    init(model: JobHUDModel) {
        self.model = model
        super.init(rootView: JobHUDView(model: model))
        sizingOptions = []
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init(rootView: JobHUDView) { fatalError("Use init(model:)") }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    // Toolbox is usually in the background, so the first click has to reach the pill's button.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        model.isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        model.isHovered = false
    }
}

private struct JobHUDView: View {
    let model: JobHUDModel

    var body: some View {
        PillStack(spacing: 8, maxWidth: 520) {
            ForEach(model.entries) { JobHUDPill(entry: $0, model: model) }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // Resizing the window from inside SwiftUI's layout pass would re-enter it.
            DispatchQueue.main.async { JobHUD.shared.fit(to: size) }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Stacks the pills centered, each at its natural width up to `maxWidth`. It takes that size whatever
/// the window's size, so the window can be fitted to it.
private struct PillStack: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat

    private var pillProposal: ProposedViewSize { ProposedViewSize(width: maxWidth, height: nil) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(pillProposal) }
        guard !sizes.isEmpty else { return .zero }
        return CGSize(width: sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).reduce(0, +) + spacing * CGFloat(sizes.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(pillProposal)
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(size))
            y += size.height + spacing
        }
    }
}

private struct JobHUDPill: View {
    static let height: CGFloat = 36

    let entry: JobHUD.Entry
    let model: JobHUDModel

    private var runner: JobRunner { entry.runner }

    var body: some View {
        HStack(spacing: 8) {
            icon
                .font(.system(size: 15))
                .frame(width: 16, height: 16)
            Text(entry.tool.name)
                .fontWeight(.medium)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .truncationMode(.tail)
                    .help(detail)
            }
            if model.isHovered, let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.leading, 11)
        .padding(.trailing, model.isHovered && action != nil ? 7 : 15)
        .frame(height: Self.height)
        .background {
            ZStack {
                LauncherBackground(cornerRadius: Self.height / 2)
                Color.black.opacity(0.45)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .task(id: runner.phase) { await dismissWhenFinished() }
    }

    @ViewBuilder
    private var icon: some View {
        switch runner.phase {
        case .idle, .running:
            ProgressRing(progress: runner.progress)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var detail: String? {
        switch runner.phase {
        case .idle, .running:
            runner.progress > 0 ? runner.progress.formatted(.percent.precision(.fractionLength(0))) : nil
        case .succeeded:
            if runner.outputFolder == nil { "Done" } else {
                "\(runner.outputs.count) \(runner.outputs.count == 1 ? "file" : "files") saved"
            }
        case .failed(let message):
            message
        case .cancelled:
            "Cancelled"
        }
    }

    private var action: (title: String, perform: () -> Void)? {
        switch runner.phase {
        case .idle, .running:
            return ("Cancel", { runner.cancel() })
        case .succeeded:
            guard let folder = runner.outputFolder else { return nil }
            let outputs = runner.outputs
            return ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting(outputs.isEmpty ? [folder] : outputs) })
        case .failed:
            return ("Open Tool", {
                JobHUD.shared.dismiss(entry)
                AppModel.shared.openTool(entry.tool)
            })
        case .cancelled:
            return nil
        }
    }

    /// Finished pills fade out on their own, errors later so they can be read, but not while pointed at.
    private func dismissWhenFinished() async {
        let delay: Duration
        switch runner.phase {
        case .idle, .running:
            // Restarted from the tool's window: that page reports it now.
            if !runner.runsInBackground { JobHUD.shared.dismiss(entry) }
            return
        case .succeeded: delay = .seconds(3)
        case .cancelled: delay = .seconds(2)
        case .failed: delay = .seconds(8)
        }
        try? await Task.sleep(for: delay)
        while model.isHovered, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
        if !Task.isCancelled { JobHUD.shared.dismiss(entry) }
    }
}

/// A ring that fills with the job's progress, or spins until there's some to show.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2)
            if progress > 0 {
                arc(to: progress)
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                TimelineView(.animation) { context in
                    arc(to: 0.25)
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }
        .padding(1)
    }

    private func arc(to end: Double) -> some View {
        Circle()
            .trim(from: 0, to: end)
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.14), in: Capsule())
            .contentShape(Capsule())
    }
}
