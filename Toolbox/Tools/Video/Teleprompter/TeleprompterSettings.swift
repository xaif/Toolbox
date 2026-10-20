import SwiftUI

enum TeleprompterDisplayMode: String, CaseIterable, Identifiable {
    /// Hangs from the top of the screen, under the camera.
    case notch
    /// A window you move and resize anywhere, like a classic teleprompter.
    case floating

    var id: Self { self }
    var label: String { self == .notch ? "Under the Camera" : "Floating Window" }
    var symbol: String { self == .notch ? "macbook" : "macwindow" }
}

enum TeleprompterScrollMode: String, CaseIterable, Identifiable {
    /// Moves while you speak and waits when you stop.
    case voice
    /// Moves at a steady pace.
    case steady

    var id: Self { self }
    var label: String { self == .voice ? "Follows Your Voice" : "Steady" }
}

enum TeleprompterFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono

    var id: Self { self }
    var label: String {
        switch self {
        case .system: "Default"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Monospaced"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
    }
}

enum TeleprompterAlignment: String, CaseIterable, Identifiable {
    case leading, center

    var id: Self { self }
    var label: String { self == .leading ? "Left" : "Centered" }
    var text: TextAlignment { self == .leading ? .leading : .center }
    var horizontal: HorizontalAlignment { self == .leading ? .leading : .center }
    var frame: Alignment { self == .leading ? .leading : .center }
}

/// The teleprompter's options, saved as you change them. The prompter on screen picks changes up live.
@MainActor
@Observable
final class TeleprompterSettings {
    static let shared = TeleprompterSettings()

    static let textColors = ["#FFFFFF", "#FFE066", "#8CE99A", "#74C0FC", "#FFA8A8", "#B197FC"]
    static let speeds: ClosedRange<Double> = 60...300
    static let fontSizes: ClosedRange<Double> = 14...72

    var display = Stored.load("display", TeleprompterDisplayMode.notch) { didSet { save("display", display.rawValue) } }
    var scrollMode = Stored.load("scrollMode", TeleprompterScrollMode.voice) { didSet { save("scrollMode", scrollMode.rawValue) } }
    /// How fast the text moves while it moves, in spoken words per minute.
    var wordsPerMinute = Stored.load("wordsPerMinute", 140.0) {
        didSet { save("wordsPerMinute", wordsPerMinute) }
    }
    /// Seconds before the text starts moving from the top. 0 is off.
    var countdown = Stored.load("countdown", 3) { didSet { save("countdown", countdown) } }
    var hoverToPause = Stored.load("hoverToPause", true) { didSet { save("hoverToPause", hoverToPause) } }

    var fontSize = Stored.load("fontSize", 26.0) { didSet { save("fontSize", fontSize) } }
    var font = Stored.load("font", TeleprompterFont.system) { didSet { save("font", font.rawValue) } }
    /// `#RRGGBB`.
    var textColor = Stored.load("textColor", "#FFFFFF") { didSet { save("textColor", textColor) } }
    /// Extra space between lines, as a fraction of the text size.
    var lineSpacing = Stored.load("lineSpacing", 0.3) { didSet { save("lineSpacing", lineSpacing) } }
    var alignment = Stored.load("alignment", TeleprompterAlignment.leading) { didSet { save("alignment", alignment.rawValue) } }
    /// Flips the text for a teleprompter with beam-splitter glass.
    var mirrored = Stored.load("mirrored", false) { didSet { save("mirrored", mirrored) } }

    var notchWidth = Stored.load("notchWidth", 480.0) { didSet { save("notchWidth", notchWidth) } }
    var notchHeight = Stored.load("notchHeight", 170.0) { didSet { save("notchHeight", notchHeight) } }
    var floatingOpacity = Stored.load("floatingOpacity", 0.92) { didSet { save("floatingOpacity", floatingOpacity) } }
    /// The display to use; 0 picks the one with the camera notch, or the main display.
    var screenID = Stored.load("screenID", 0) { didSet { save("screenID", screenID) } }

    /// 0 uses the system's input device.
    var microphoneID = Stored.load("microphoneID", 0) { didSet { save("microphoneID", microphoneID) } }
    /// 0…1. Higher picks up quieter speech, and more background noise.
    var sensitivity = Stored.load("sensitivity", 0.6) { didSet { save("sensitivity", sensitivity) } }

    /// ⌃⌥⌘ shortcuts that work in any app.
    var globalShortcuts = Stored.load("globalShortcuts", true) { didSet { save("globalShortcuts", globalShortcuts) } }

    /// The level, in dBFS, above which the microphone counts as speech.
    var speechThreshold: Float { Self.threshold(forSensitivity: sensitivity) }

    static func threshold(forSensitivity sensitivity: Double) -> Float {
        Float(-20 - 40 * min(max(sensitivity, 0), 1))
    }

    /// The sensitivity that puts the speech threshold `margin` dB above measured background noise.
    static func sensitivity(forNoise decibels: Float, margin: Float = 9) -> Double {
        min(max(Double(-20 - (decibels + margin)) / 40, 0.05), 1)
    }

    var color: Color { Color(cgColor: WhiteboardRenderer.cgColor(textColor)) }

    private func save(_ name: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: Stored.key(name))
    }
}

/// Saved values for `TeleprompterSettings`, under `teleprompter.` keys.
private enum Stored {
    static func key(_ name: String) -> String { "teleprompter." + name }

    static func load<T>(_ name: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key(name)) as? T ?? fallback
    }

    static func load<T: RawRepresentable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key(name)).flatMap(T.init(rawValue:)) ?? fallback
    }
}
