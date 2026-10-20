import AppKit
import SwiftUI

/// Toolbox's mark: a magnifying glass around code brackets (Lucide's "search-code"), the glyph on the app
/// icon. scripts/make-icon.swift draws the same strokes for the icon itself.
enum BrandMark {
    /// The strokes in a 24-unit square, y pointing down, drawn 2 units wide with round ends.
    static let lines: [[CGPoint]] = [
        [CGPoint(x: 9, y: 9), CGPoint(x: 7, y: 11), CGPoint(x: 9, y: 13)],
        [CGPoint(x: 13, y: 13), CGPoint(x: 15, y: 11), CGPoint(x: 13, y: 9)],
        [CGPoint(x: 21, y: 21), CGPoint(x: 16.7, y: 16.7)],
    ]
    static let circle = (center: CGPoint(x: 11, y: 11), radius: CGFloat(8))

    /// The strokes scaled to fit `rect`, centered, y pointing down.
    static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        let path = CGMutablePath()
        for line in lines { path.addLines(between: line.map(point)) }
        let center = point(circle.center), radius = circle.radius * scale
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }

    /// The mark as a template image, for the menu bar, which tints it to match.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = NSBezierPath(cgPath: BrandMark.path(in: rect))
            path.lineWidth = 2 * rect.width / 24
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }

    /// The app icon as SVG, for the pages Toolbox serves to browsers (Share on Wi-Fi, Whiteboard and the
    /// teleprompter remote).
    static let iconSVG = #"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#202123"/><stop offset=".35" stop-color="#151515"/><stop offset="1" stop-color="#0d0d0e"/></linearGradient></defs><rect width="24" height="24" rx="5.5" fill="url(#g)"/><g transform="translate(3.15 3.15) scale(.737)" fill="none" stroke="#fafafa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 9-2 2 2 2"/><path d="m13 13 2-2-2-2"/><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></g></svg>
    """#

    /// `<link>` tags that put the mark in the browser tab, for pasting into a page's `<head>`.
    static var faviconLinks: String {
        let encoded = iconSVG.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: " ./:=-"))) ?? ""
        return #"<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,\#(encoded)">"#
    }
}

/// The mark as a shape, for stroking in place of a plain magnifying glass, as in the search fields.
struct BrandGlyph: Shape {
    func path(in rect: CGRect) -> Path { Path(BrandMark.path(in: rect)) }
}

extension NSColor {
    /// Text and symbols on the accent color, which follows the icon: near-black in Light Mode and near-white
    /// in Dark Mode (Assets.xcassets/AccentColor).
    static let onAccent = NSColor(name: "onAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 21 / 255, green: 21 / 255, blue: 21 / 255, alpha: 1)
            : .white
    }
}

extension Color {
    /// Text and symbols on the accent color.
    static let onAccent = Color(nsColor: .onAccent)
    /// Selections, outlines and handles drawn over documents, photos and the camera. Pages stay white in Dark
    /// Mode, where the accent turns white too, so these use blue in both.
    static let documentMarkup = Color(nsColor: .systemBlue)
}
