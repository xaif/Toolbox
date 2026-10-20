import SwiftUI

enum OnboardingPage: Int, CaseIterable {
    case welcome, permissions, ready

    var primaryTitle: String {
        switch self {
        case .welcome: "Get Started"
        case .permissions: "Continue"
        case .ready: "Start Using \(AppInfo.name)"
        }
    }

    /// Washes the top of the window, so each page has its own light.
    var tint: Color {
        switch self {
        case .welcome: ToolCategory.ai.tint
        case .permissions: ToolCategory.files.tint
        case .ready: ToolCategory.image.tint
        }
    }
}

@MainActor
@Observable
final class OnboardingModel {
    private(set) var page: OnboardingPage
    /// Which side the next page slides in from.
    private(set) var movingForward = true

    init() {
        page = OnboardingPage(rawValue: UserDefaults.standard.integer(forKey: SettingsKey.onboardingPage)) ?? .welcome
    }

    func go(to page: OnboardingPage) {
        guard page != self.page else { return }
        movingForward = page.rawValue > self.page.rawValue
        save(page)
        withAnimation(.spring(duration: 0.45, bounce: 0)) { self.page = page }
    }

    func jump(to page: OnboardingPage) {
        movingForward = true
        save(page)
        self.page = page
    }

    private func save(_ page: OnboardingPage) {
        UserDefaults.standard.set(page.rawValue, forKey: SettingsKey.onboardingPage)
    }
}

struct OnboardingView: View {
    let model: OnboardingModel
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page
                    .id(model.page)
                    .transition(.asymmetric(insertion: insertion, removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .frame(width: OnboardingController.size.width, height: OnboardingController.size.height)
        .background { OnboardingBackdrop(tint: model.page.tint) }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .welcome: WelcomePage()
        case .permissions: PermissionsPage()
        case .ready: ReadyPage()
        }
    }

    /// The incoming page drifts in from the side you're heading to. Reduce Motion cross-fades instead.
    private var insertion: AnyTransition {
        reduceMotion ? .opacity : .offset(x: model.movingForward ? 40 : -40).combined(with: .opacity)
    }

    private var bottomBar: some View {
        HStack {
            if let previous = OnboardingPage(rawValue: model.page.rawValue - 1) {
                Button("Back") { model.go(to: previous) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .transition(.opacity)
            }
            Spacer()
            Button(model.page.primaryTitle) {
                if let next = OnboardingPage(rawValue: model.page.rawValue + 1) { model.go(to: next) } else { onFinish() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .overlay { PageDots(page: model.page) }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

private struct OnboardingBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
                .animation(.easeInOut(duration: 0.5), value: tint)
        }
        .ignoresSafeArea()
    }
}

private struct PageDots: View {
    let page: OnboardingPage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == page ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: item == page ? 20 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0), value: page)
        .accessibilityElement()
        .accessibilityLabel("Step \(page.rawValue + 1) of \(OnboardingPage.allCases.count)")
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            WelcomeHero(appeared: appeared)
            Text("Welcome to \(AppInfo.name)")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .padding(.top, 14)
            Text("\(ToolRegistry.all.count) tools for video, audio, images, PDFs and documents, in one app. Everything runs on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 12) {
                FeatureCard(symbol: "lock.shield.fill", tint: ToolCategory.image.tint, title: "Private by design",
                            detail: "Files never leave your Mac, and the AI tools run on-device.")
                FeatureCard(symbol: "command", tint: ToolCategory.ai.tint, title: "Open from anywhere",
                            detail: AppSettings.hotKeyEnabled
                                ? "Press \(HotKeyShortcut.current.displayString) in any app to find a tool."
                                : "Click \(AppInfo.name) in the menu bar from any app to find a tool.")
                FeatureCard(symbol: "square.stack.3d.up.fill", tint: ToolCategory.audio.tint, title: "Built for batches",
                            detail: "Drop a whole folder. Results land next to the originals.")
            }
            .padding(.top, 28)
            .padding(.horizontal, 36)
            Spacer(minLength: 0)
        }
        .onAppear { appeared = true }
    }
}

/// The app icon with a tile for each kind of tool gathered around it.
private struct WelcomeHero: View {
    let appeared: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Satellite {
        let symbol: String
        let tint: Color
        let offset: CGSize
        let size: CGFloat
        let tilt: Double
    }

    private let satellites: [Satellite] = [
        Satellite(symbol: ToolCategory.video.symbol, tint: ToolCategory.video.tint, offset: CGSize(width: -206, height: -14), size: 46, tilt: -8),
        Satellite(symbol: ToolCategory.image.symbol, tint: ToolCategory.image.tint, offset: CGSize(width: -128, height: -84), size: 40, tilt: 9),
        Satellite(symbol: ToolCategory.audio.symbol, tint: ToolCategory.audio.tint, offset: CGSize(width: -142, height: 74), size: 38, tilt: 6),
        Satellite(symbol: "square.stack.3d.up", tint: ToolCategory.files.tint, offset: CGSize(width: -274, height: 50), size: 30, tilt: -12),
        Satellite(symbol: ToolCategory.pdf.symbol, tint: ToolCategory.pdf.tint, offset: CGSize(width: 132, height: -82), size: 42, tilt: -6),
        Satellite(symbol: ToolCategory.ai.symbol, tint: ToolCategory.ai.tint, offset: CGSize(width: 208, height: -8), size: 48, tilt: 8),
        Satellite(symbol: ToolCategory.files.symbol, tint: ToolCategory.files.tint, offset: CGSize(width: 146, height: 78), size: 38, tilt: -10),
        Satellite(symbol: ToolCategory.business.symbol, tint: ToolCategory.business.tint, offset: CGSize(width: 276, height: 46), size: 30, tilt: 12),
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [ToolCategory.ai.tint.opacity(0.3), .clear], center: .center, startRadius: 20, endRadius: 170))
                .frame(width: 340, height: 340)
                .opacity(appeared ? 1 : 0)
            ForEach(satellites.indices, id: \.self) { index in
                let satellite = satellites[index]
                ToolIcon(symbol: satellite.symbol, tint: satellite.tint, size: satellite.size)
                    .rotationEffect(.degrees(satellite.tilt))
                    .offset(appeared || reduceMotion ? satellite.offset : .zero)
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.3)
                               : .spring(duration: 0.8, bounce: 0.25).delay(0.12 + Double(index) * 0.04),
                               value: appeared)
            }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: appeared)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }
}

private struct FeatureCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.bottom, 4)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    private var center: PermissionCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow access")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.5)
                    Text("Each permission powers specific tools, so allow the ones you'll use. You can change them anytime in System Settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                Text("\(center.grantedCount) of \(AppPermission.allCases.count) allowed")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: center.grantedCount)
            }
            VStack(spacing: 0) {
                ForEach(AppPermission.allCases) { permission in
                    PermissionRow(permission: permission)
                    if permission != AppPermission.allCases.last {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 14)
    }
}

private struct PermissionRow: View {
    let permission: AppPermission

    private var center: PermissionCenter { .shared }
    private var state: PermissionState { center.state(permission) }
    private var isRequesting: Bool { center.requesting.contains(permission) }

    var body: some View {
        HStack(spacing: 14) {
            ToolIcon(symbol: permission.symbol, tint: permission.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.body.weight(.semibold))
                    if permission.isOptional {
                        Text("Optional")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                note
            }
            Spacer(minLength: 12)
            trailing
                .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: state)
        .animation(.easeOut(duration: 0.2), value: isRequesting)
    }

    @ViewBuilder
    private var note: some View {
        if state == .denied {
            Label("Turned off in System Settings", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 2)
        } else if permission == .screenRecording, center.openedInSettings.contains(.screenRecording) {
            // macOS can hold Screen Recording back until the app relaunches.
            HStack(spacing: 4) {
                Text("Already switched on?")
                Button("Quit & Reopen \(AppInfo.name)") { AppRelauncher.relaunch() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if state == .granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Allowed").foregroundStyle(.secondary)
            }
            .font(.callout.weight(.semibold))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else if isRequesting {
            ProgressView().controlSize(.small)
        } else {
            Button(state == .denied ? "Open Settings" : "Allow") { center.request(permission) }
                .buttonStyle(.glass)
                .help(permission.isGrantedByDragging || state == .denied
                      ? "Opens System Settings and shows you what to do there"
                      : "Shows macOS's permission prompt")
        }
    }
}

// MARK: - Ready

private struct ReadyPage: View {
    // Read so the key caps update when the shortcut is changed below.
    @AppStorage(SettingsKey.hotKeyCode) private var hotKeyCode = -1
    @AppStorage(SettingsKey.hotKeyModifiers) private var hotKeyModifiers = -1
    @AppStorage(SettingsKey.hotKeyEnabled) private var hotKeyEnabled = true
    @AppStorage(SettingsKey.showsMenuBarIcon) private var showsMenuBarIcon = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        let _ = (hotKeyCode, hotKeyModifiers)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("You're all set")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.5)
            Text(hotKeyEnabled ? "Press this in any app to open the launcher and find a tool." : "Click \(AppInfo.name) in the menu bar to open the launcher.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            if hotKeyEnabled {
                KeyCaps(keys: HotKeyShortcut.current.keyCaps)
                    .padding(.top, 24)
                Text("Select files in Finder first, and \(AppInfo.name) suggests tools for them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            }
            VStack(spacing: 0) {
                SettingRow(symbol: "keyboard", tint: ToolCategory.ai.tint, title: "Launcher shortcut") {
                    ShortcutRecorder()
                }
                Divider().padding(.leading, 54)
                SettingRow(symbol: "power", tint: ToolCategory.image.tint, title: "Open at login",
                           detail: "Keeps the shortcut working after you restart your Mac.") {
                    Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: {
                        LaunchAtLogin.set($0)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                Divider().padding(.leading, 54)
                SettingRow(symbol: "menubar.rectangle", tint: ToolCategory.files.tint, title: "Show in the menu bar",
                           detail: "Click the icon to open the launcher.") {
                    Toggle("Show in the menu bar", isOn: $showsMenuBarIcon)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().padding(.leading, 54)
                FFmpegRow()
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
            .frame(maxWidth: 580)
            .padding(.top, 28)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 10) {
                ForEach(keys.indices, id: \.self) { index in
                    let key = keys[index]
                    Text(key)
                        .font(.system(size: key.count > 1 ? 19 : 26, weight: .medium, design: .rounded))
                        .frame(minWidth: 62, minHeight: 62)
                        .padding(.horizontal, key.count > 1 ? 14 : 0)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Shortcut \(keys.map { $0 == HotKeyShortcut.hyperSymbol ? "Hyper" : $0 }.joined(separator: " "))")
    }
}

private struct SettingRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String? = nil
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// FFmpeg isn't bundled; most video and audio tools need it, so offer it here once.
private struct FFmpegRow: View {
    @Environment(Dependencies.self) private var dependencies

    var body: some View {
        SettingRow(symbol: "film.stack", tint: ToolCategory.video.tint, title: "FFmpeg",
                   detail: "Free add-on for most video and audio tools. Installs through Homebrew.") {
            if dependencies.isAvailable(.ffmpeg) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Installed").foregroundStyle(.secondary)
                }
                .font(.callout.weight(.semibold))
            } else {
                switch dependencies.installState(.ffmpeg) {
                case .installing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Installing…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                        Button("Try Again") { dependencies.install(.ffmpeg) }.buttonStyle(.glass)
                    }
                case .idle:
                    if Dependencies.homebrewURL != nil {
                        Button("Install") { dependencies.install(.ffmpeg) }.buttonStyle(.glass)
                    } else {
                        Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                    }
                }
            }
        }
    }
}
