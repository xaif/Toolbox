import AppKit
import SwiftUI

/// The prompter's window. It's left out of screen sharing, recordings and screenshots, shows on every
/// Space and above full-screen apps, and never takes the keyboard from the app you're presenting in.
final class TeleprompterPanel: NSPanel {
    let mode: TeleprompterDisplayMode
    /// A floating window was given its first position; after that it stays where you put it.
    var isPlaced = false
    /// Trackpad and mouse-wheel scrolling, in points; positive moves on through the script.
    var onScroll: ((CGFloat) -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(mode: TeleprompterDisplayMode) {
        self.mode = mode
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if mode == .floating { style.insert(.resizable) }
        super.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 170), styleMask: style, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = mode == .floating
        // Above the menu bar, so it can hang from the notch.
        level = .statusBar
        sharingType = .none
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugTeleprompterCapturable") { sharingType = .readOnly }
        #endif
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Floating windows move and resize with the handles in `TeleprompterOverlay`, and by their edges.
        isMovable = mode == .floating
        minSize = CGSize(width: 260, height: 110)
        animationBehavior = .none
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.onFrameChange?(self.frame)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would push a window below the menu bar; the notch prompter belongs over it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        mode == .notch ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    private var dragStart: (mouse: CGPoint, frame: CGRect)?

    /// Moves the window, or resizes it from the bottom-right corner, following the pointer.
    func drag(resizing: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart else {
            dragStart = (mouse, frame)
            return
        }
        var frame = start.frame
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        if resizing {
            frame.size.width = max(minSize.width, frame.width + dx)
            frame.size.height = max(minSize.height, frame.height - dy)
            frame.origin.y = start.frame.maxY - frame.height
        } else {
            frame.origin.x += dx
            frame.origin.y += dy
        }
        setFrame(frame, display: true)
    }

    func endDrag() {
        dragStart = nil
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14
            onScroll?(-delta)
            return
        }
        super.sendEvent(event)
    }
}

/// A shape that flows out of the camera notch: square to the top of the screen with small inward
/// curves where it meets the menu bar, and rounded at the bottom.
struct TeleprompterNotchShape: Shape {
    var ear: CGFloat = 10
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.height / 2, (rect.width - 2 * ear) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + radius, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - radius), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Overlay

struct TeleprompterTextStyle: Equatable {
    var size: CGFloat
    var font: TeleprompterFont
    var color: Color
    var lineSpacing: CGFloat
    var alignment: TeleprompterAlignment
}

/// Everything inside the prompter window.
struct TeleprompterOverlay: View {
    let prompter: Teleprompter
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: TeleprompterSettings { prompter.settings }
    private var isNotch: Bool { settings.display == .notch }
    private static let ear: CGFloat = 10

    /// Room at the top for the camera notch (or the drag handle), with the voice beam under it.
    private var topInset: CGFloat {
        isNotch ? max(prompter.notchHeight, 6) + 8 : 24
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            VStack(spacing: 0) {
                TeleprompterTopStrip(prompter: prompter, isNotch: isNotch)
                    .frame(height: topInset)
                ZStack(alignment: .top) {
                    TeleprompterViewport(prompter: prompter, style: style)
                    overlays
                }
            }
            .padding(.horizontal, isNotch ? Self.ear + 18 : 18)
            .padding(.bottom, isNotch ? 10 : 12)
        }
        .environment(\.colorScheme, .dark)
        .scaleEffect(x: 1, y: revealed || reduceMotion ? 1 : 0.3, anchor: .top)
        .opacity(revealed || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { revealed = true }
        }
    }

    private var style: TeleprompterTextStyle {
        TeleprompterTextStyle(size: settings.fontSize, font: settings.font, color: settings.color,
                              lineSpacing: settings.lineSpacing, alignment: settings.alignment)
    }

    @ViewBuilder
    private var background: some View {
        if isNotch {
            TeleprompterNotchShape(ear: Self.ear).fill(.black)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(settings.floatingOpacity))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if let countdown = prompter.countdown {
            Text("\(countdown)")
                .font(.system(size: 54, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: countdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.55))
        } else if prompter.isFinished, !prompter.isHovering {
            VStack {
                Spacer()
                Label("The end", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        if prompter.savedOffset != nil {
            HStack {
                Spacer()
                Button { prompter.returnToSavedPlace() } label: {
                    Label("Back to where you were", systemImage: "arrow.uturn.backward")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help("Back to where you left off (⌃⌥⌘B)")
            }
        }
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 6) {
                TeleprompterControls(prompter: prompter, isNotch: isNotch)
                if !isNotch {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .gesture(TeleprompterWindowDrag(prompter: prompter, resizing: true).gesture)
                        .help("Drag to resize")
                }
            }
        }
        .opacity(prompter.isHovering ? 1 : 0)
        .allowsHitTesting(prompter.isHovering)
        .animation(.easeOut(duration: 0.15), value: prompter.isHovering)
    }
}

/// The scrolling text, faded at the edges. Only `TeleprompterScroller` redraws as it moves.
private struct TeleprompterViewport: View {
    let prompter: Teleprompter
    let style: TeleprompterTextStyle

    var body: some View {
        GeometryReader { proxy in
            TeleprompterScroller(prompter: prompter) {
                TeleprompterScriptText(cues: prompter.cues, style: style)
                    .equatable()
                    .frame(width: proxy.size.width)
                    .onPreferenceChange(TeleprompterLayoutKey.self) { prompter.layoutChanged($0) }
                    .padding(.top, 12)
                    // Room to scroll the last line up to the top.
                    .padding(.bottom, proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
            }
        }
        .scaleEffect(x: prompter.settings.mirrored ? -1 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Teleprompter script")
    }
}

private struct TeleprompterScroller<Content: View>: View {
    let prompter: Teleprompter
    @ViewBuilder var content: Content

    var body: some View {
        content.offset(y: -prompter.offset)
    }
}

/// The script, cue by cue. Reports its height and where each cue starts.
struct TeleprompterScriptText: View, Equatable {
    let cues: [TeleprompterCue]
    let style: TeleprompterTextStyle

    private static let space = "teleprompter.script"

    var body: some View {
        VStack(alignment: style.alignment.horizontal, spacing: style.size * 0.8) {
            ForEach(cues) { cue in
                VStack(alignment: style.alignment.horizontal, spacing: style.size * 0.2) {
                    if let title = cue.title {
                        Text(title.uppercased())
                            .font(.system(size: max(10, style.size * 0.42), weight: .bold, design: style.font.design))
                            .tracking(1.2)
                            .foregroundStyle(style.color.opacity(0.45))
                    }
                    if !cue.text.isEmpty {
                        Text(TeleprompterParser.styled(cue.text, noteColor: style.color.opacity(0.45)))
                            .font(.system(size: style.size, weight: .semibold, design: style.font.design))
                            .lineSpacing(style.size * style.lineSpacing)
                            .foregroundStyle(style.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: style.alignment.frame)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TeleprompterLayoutKey.self,
                                           value: TeleprompterLayout(cueStarts: [cue.id: proxy.frame(in: .named(Self.space)).minY]))
                })
            }
        }
        .multilineTextAlignment(style.alignment.text)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TeleprompterLayoutKey.self, value: TeleprompterLayout(height: proxy.size.height))
        })
        .coordinateSpace(.named(Self.space))
    }
}

struct TeleprompterLayoutKey: PreferenceKey {
    static let defaultValue = TeleprompterLayout()

    static func reduce(value: inout TeleprompterLayout, nextValue: () -> TeleprompterLayout) {
        let next = nextValue()
        value.height = max(value.height, next.height)
        value.cueStarts.merge(next.cueStarts) { $1 }
    }
}

// MARK: - Top strip

/// Beside the notch: what the prompter is doing and the time left. Under it: the voice beam.
private struct TeleprompterTopStrip: View {
    let prompter: Teleprompter
    let isNotch: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                status
                // Keep clear of the camera.
                Spacer(minLength: isNotch ? prompter.cameraNotchWidth + 16 : 40)
                TeleprompterTimeLeft(prompter: prompter)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxHeight: .infinity)
            .padding(.top, isNotch ? 0 : 4)
            if !isNotch {
                Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 4)
            }
            if prompter.listensToVoice, prompter.isShowing {
                TeleprompterVoiceBeam(prompter: prompter)
            }
        }
        .contentShape(Rectangle())
        .gesture(TeleprompterWindowDrag(prompter: prompter, resizing: false).gesture, including: isNotch ? .subviews : .all)
        .help(isNotch ? "" : "Drag to move")
    }

    @ViewBuilder
    private var status: some View {
        if prompter.voiceProblem != nil {
            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                .help(prompter.voiceProblem ?? "")
        } else if !prompter.isPlaying {
            Image(systemName: "pause.fill")
        } else if prompter.settings.hoverToPause, prompter.isHovering {
            Image(systemName: "hand.point.up.fill")
        } else if prompter.listensToVoice {
            Image(systemName: prompter.isSpeaking ? "waveform" : "mic.fill")
                .foregroundStyle(prompter.isSpeaking ? .green : .white.opacity(0.6))
        } else {
            Image(systemName: "play.fill")
        }
    }
}

private struct TeleprompterTimeLeft: View {
    let prompter: Teleprompter

    var body: some View {
        let seconds = prompter.secondsLeft
        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .monospacedDigit()
    }
}

/// A glow under the notch that follows how loud you are.
private struct TeleprompterVoiceBeam: View {
    let prompter: Teleprompter

    var body: some View {
        let level = prompter.voiceLevel
        let speaking = prompter.isSpeaking
        Capsule()
            .fill(speaking ? Color.green : Color.white.opacity(0.35))
            .frame(width: 24 + 150 * level, height: 3)
            .shadow(color: speaking ? .green.opacity(0.9) : .clear, radius: 3 + 5 * level)
            .padding(.bottom, 2)
            .animation(.easeOut(duration: 0.2), value: speaking)
            .accessibilityHidden(true)
    }
}

/// Moves or resizes the floating window with the pointer.
@MainActor
private struct TeleprompterWindowDrag {
    let prompter: Teleprompter
    let resizing: Bool

    var gesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in prompter.dragWindow(resizing: resizing) }
            .onEnded { _ in prompter.endWindowDrag() }
    }
}

// MARK: - Controls

/// Shown while you hover over the prompter.
private struct TeleprompterControls: View {
    let prompter: Teleprompter
    let isNotch: Bool

    private var settings: TeleprompterSettings { prompter.settings }

    var body: some View {
        HStack(spacing: 4) {
            button("arrow.counterclockwise", "Start over (⌃⌥⌘R)") { prompter.restart() }
            button("backward.end.fill", "Previous cue (⌃⌥⌘[)") { prompter.previousCue() }
            Button { prompter.togglePlay() } label: {
                Image(systemName: prompter.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 26)
                    .background(.white.opacity(0.2), in: Capsule())
                    .contentShape(Capsule())
            }
            .help(prompter.isPlaying ? "Pause (⌃⌥⌘Space)" : "Play (⌃⌥⌘Space)")
            button("forward.end.fill", "Next cue (⌃⌥⌘])") { prompter.nextCue() }
            if prompter.cues.count > 1 {
                Menu {
                    ForEach(prompter.cues) { cue in
                        Button { prompter.jump(toCue: cue.id) } label: {
                            if cue.id == prompter.currentCue { Label(cue.label, systemImage: "checkmark") } else { Text(cue.label) }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Jump to a cue")
            }
            Spacer(minLength: 4)
            button("minus", "Slower (⌃⌥⌘−)") { prompter.changeSpeed(by: -10) }
            Text("\(Int(settings.wordsPerMinute)) wpm")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(minWidth: 52)
            button("plus", "Faster (⌃⌥⌘=)") { prompter.changeSpeed(by: 10) }
            Spacer(minLength: 4)
            button(settings.scrollMode == .voice ? "mic.fill" : "metronome.fill",
                   settings.scrollMode == .voice ? "Follows your voice. Click to scroll steadily." : "Scrolls steadily. Click to follow your voice.") {
                settings.scrollMode = settings.scrollMode == .voice ? .steady : .voice
                prompter.scrollModeChanged()
            }
            button("xmark", "Close the teleprompter (⌃⌥⌘T)") { prompter.hide() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
