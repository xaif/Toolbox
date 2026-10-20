// Renders the app icon PNGs into the asset catalog. Run: swift scripts/make-icon.swift
// The mark is Lucide's "search-code" (a magnifying glass around code brackets) in near-white on a dark
// gradient tile, laid out on the macOS icon grid. BrandMark.swift draws the same glyph inside the app.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : "Toolbox/Resources/Assets.xcassets/AppIcon.appiconset")

/// The glyph's strokes in Lucide's 24-unit space, y pointing down.
let glyphLines: [[CGPoint]] = [
    [CGPoint(x: 9, y: 9), CGPoint(x: 7, y: 11), CGPoint(x: 9, y: 13)],    // <
    [CGPoint(x: 13, y: 13), CGPoint(x: 15, y: 11), CGPoint(x: 13, y: 9)], // >
    [CGPoint(x: 21, y: 21), CGPoint(x: 16.7, y: 16.7)],                    // handle
]
let glyphCircle = (center: CGPoint(x: 11, y: 11), radius: CGFloat(8))

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

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

    // A dark tile, a little lighter at the top left (the design's 135° gradient).
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [rgb(32, 33, 35), rgb(21, 21, 21), rgb(13, 13, 14)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.35, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    // The glyph fills 360/488 of the tile, centered, with Lucide's 2-unit round strokes.
    let box = body.width * 360 / 488
    let scale = box / 24
    let origin = CGPoint(x: body.midX - box / 2, y: body.midY + box / 2)
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale) }
    ctx.setStrokeColor(rgb(250, 250, 250))
    ctx.setLineWidth(max(2 * scale, px <= 32 ? 1.3 : 0))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for line in glyphLines {
        ctx.addLines(between: line.map(point))
    }
    let center = point(glyphCircle.center)
    ctx.addEllipse(in: CGRect(x: center.x - glyphCircle.radius * scale, y: center.y - glyphCircle.radius * scale,
                              width: glyphCircle.radius * 2 * scale, height: glyphCircle.radius * 2 * scale))
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(px).png"))
}
print("Wrote icons to \(out.path)")
