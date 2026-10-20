import SwiftUI
import AVKit

/// AppKit's AVPlayerView in SwiftUI, with native inline controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controls: AVPlayerViewControlsStyle = .inline

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controls
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.controlsStyle = controls
    }
}

/// Two-handle slider for picking a time range, with an optional playhead marker.
struct RangeSlider: View {
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    var playhead: Double?
    var minimumLength: Double = 0.1
    var tint: Color = .accentColor
    /// Called while dragging with the time under the handle, e.g. to seek a preview.
    var onScrub: ((Double) -> Void)?

    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - handleWidth * 2, 1)
            let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
            let lowerX = CGFloat((range.lowerBound - bounds.lowerBound) / span) * width
            let upperX = CGFloat((range.upperBound - bounds.lowerBound) / span) * width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(tint.opacity(0.25))
                    .frame(width: max(upperX - lowerX + handleWidth * 2, 0))
                    .offset(x: lowerX)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 2)
                            .frame(width: max(upperX - lowerX + handleWidth * 2, 0))
                            .offset(x: lowerX)
                    }
                if let playhead, bounds.contains(playhead) {
                    Rectangle().fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: handleWidth + CGFloat((playhead - bounds.lowerBound) / span) * width - 1)
                        .allowsHitTesting(false)
                }
                handle.offset(x: lowerX)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let time = bounds.lowerBound + Double(min(max(value.location.x - handleWidth / 2, 0), width) / width) * span
                        let lower = min(max(time, bounds.lowerBound), range.upperBound - minimumLength)
                        range = lower...range.upperBound
                        onScrub?(lower)
                    })
                handle.offset(x: upperX + handleWidth)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let time = bounds.lowerBound + Double(min(max(value.location.x - handleWidth * 1.5, 0), width) / width) * span
                        let upper = max(min(time, bounds.upperBound), range.lowerBound + minimumLength)
                        range = range.lowerBound...upper
                        onScrub?(upper)
                    })
            }
            .coordinateSpace(name: "slider")
        }
        .frame(height: 36)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(tint)
            .frame(width: handleWidth)
            .overlay(Capsule().fill(Color.onAccent.opacity(0.9)).frame(width: 2, height: 14))
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}

/// Editable time field in h:mm:ss.s format.
struct TimeField: View {
    let label: String
    @Binding var seconds: Double
    var range: ClosedRange<Double>

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: 110)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
        }
        .onAppear { text = TimeFormat.string(seconds, precise: true) }
        .onChange(of: seconds) { if !focused { text = TimeFormat.string(seconds, precise: true) } }
    }

    private func commit() {
        if let value = TimeFormat.parse(text) {
            seconds = min(max(value, range.lowerBound), range.upperBound)
        }
        text = TimeFormat.string(seconds, precise: true)
    }
}

enum TimeFormat {
    /// "1:02:03" or "2:03"; with `precise`, adds tenths: "2:03.4".
    static func string(_ seconds: Double, precise: Bool = false) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(seconds, 0)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = total.truncatingRemainder(dividingBy: 60)
        let secondsText = precise ? String(format: "%04.1f", secs) : String(format: "%02d", Int(secs))
        return hours > 0 ? String(format: "%d:%02d:", hours, minutes) + secondsText : String(format: "%d:", minutes) + secondsText
    }

    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}
