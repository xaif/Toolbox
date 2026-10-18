// Renders the app icon PNGs into the asset catalog. Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "Toolbox/Resources/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.47, green: 0.42, blue: 1.0, alpha: 1).cgColor,
                  NSColor(red: 0.93, green: 0.30, blue: 0.55, alpha: 1).cgColor,
                  NSColor(red: 0.99, green: 0.60, blue: 0.25, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft top highlight.
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.25).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    // 2x2 grid of tool glyphs.
    let symbols = ["film.fill", "waveform", "doc.richtext.fill", "sparkles"]
    let cell = body.width * 0.30
    let gap = body.width * 0.06
    let originX = body.midX - cell - gap / 2
    let originY = body.midY - cell - gap / 2
    for (i, name) in symbols.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
        let rect = CGRect(x: originX + col * (cell + gap), y: originY + row * (cell + gap), width: cell, height: cell)
        let tile = CGPath(roundedRect: rect, cornerWidth: cell * 0.26, cornerHeight: cell * 0.26, transform: nil)
        ctx.addPath(tile); ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor); ctx.fillPath()
        let config = NSImage.SymbolConfiguration(pointSize: cell * 0.48, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = image.size
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(px).png"))
}
print("Wrote icons to \(out.path)")
