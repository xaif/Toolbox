import AppKit
import CoreText
import PDFKit

/// Font, size, color and alignment of text added or retyped in Edit PDF.
struct PDFEditTextStyle: Equatable {
    var family = "Helvetica"
    var size: CGFloat = 14
    var color = CGColor(gray: 0, alpha: 1)
    var bold = false
    var italic = false
    var alignment = NSTextAlignment.left

    static let families = ["Helvetica", "Helvetica Neue", "Arial", "Avenir Next", "Gill Sans", "Verdana",
                           "Times New Roman", "Georgia", "Palatino", "Baskerville", "Courier New", "Menlo"]

    /// The installed font closest to the style. `scale` multiplies the size, e.g. for on-screen zoom.
    func font(scale: CGFloat = 1) -> NSFont {
        let size = max(size * scale, 0.5)
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let font = manager.font(withFamily: family, traits: traits, weight: 5, size: size) { return font }
        var font = NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size)
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Core Text attributes (AppKit's color and paragraph keys aren't read by Core Text).
    func attributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        var ctAlignment: CTTextAlignment
        switch alignment {
        case .center: ctAlignment = .center
        case .right: ctAlignment = .right
        case .justified: ctAlignment = .justified
        default: ctAlignment = .left
        }
        let paragraph = withUnsafeBytes(of: &ctAlignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        return [.font: font(scale: scale),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
    }
}

/// Something Edit PDF draws onto a page. Rects are normalized (0…1) on the displayed page
/// (crop box, rotation applied), origin top-left.
struct PDFEditItem: Identifiable {
    enum Kind { case text, image, box }

    let id = UUID()
    var pageIndex: Int
    var rect: CGRect
    var kind: Kind
    var text = ""
    var style = PDFEditTextStyle()
    /// Text boxes wrap to their width; retyped lines of existing text stay on one line.
    var wraps = true
    var image: CGImage?
    var fill: CGColor?
    var stroke: CGColor?
    var lineWidth: CGFloat = 2
    /// For retyped text: the original words' area, painted with `coverColor` first. It stays put when
    /// the new text is moved.
    var cover: CGRect?
    var coverColor = CGColor(gray: 1, alpha: 1)
    /// The words this item replaces, if it retypes existing text.
    var original: String?

    var isReplacement: Bool { original != nil }
}

/// Edit PDF's page operations. Pure PDFKit/Quartz so they can be tested and run off the main thread.
enum PDFEditOps {
    // MARK: - Coordinates

    /// Displayed-page points (origin bottom-left) for a normalized, top-left-origin rect.
    static func displayRect(_ rect: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(x: rect.minX * pageSize.width, y: (1 - rect.maxY) * pageSize.height,
               width: rect.width * pageSize.width, height: rect.height * pageSize.height)
    }

    static func normalizedRect(_ rect: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(x: rect.minX / pageSize.width, y: 1 - rect.maxY / pageSize.height,
               width: rect.width / pageSize.width, height: rect.height / pageSize.height)
    }

    // MARK: - Existing text

    /// The line of existing text under `point` (normalized, top-left) in displayed-page points.
    static func lineSelection(on page: PDFPage, at point: CGPoint) -> (selection: PDFSelection, bounds: CGRect)? {
        let size = PDFOps.displaySize(of: page)
        let toDisplay = page.transform(for: .cropBox)
        let displayPoint = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        guard let selection = page.selectionForLine(at: displayPoint.applying(toDisplay.inverted())),
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = selection.bounds(for: page).applying(toDisplay)
        guard bounds.width > 0, bounds.height > 0, bounds.insetBy(dx: -2, dy: -2).contains(displayPoint) else { return nil }
        return (selection, bounds)
    }

    /// A replacement for the line of text under `point`, prefilled with its words and the closest
    /// matching font, size and color. Nil where there's no text.
    static func textLine(on page: PDFPage, pageIndex: Int, at point: CGPoint) -> PDFEditItem? {
        guard let (selection, bounds) = lineSelection(on: page, at: point) else { return nil }
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let colors = sampleColors(page, in: bounds)
        var style = PDFEditTextStyle(color: colors.text)
        // Fonts can report odd sizes (text matrices scale them), so sanity-check against the line height.
        let estimated = bounds.height / 1.2
        style.size = (estimated * 10).rounded() / 10
        if let font = dominantFont(selection.attributedString) {
            if font.pointSize > estimated * 0.6, font.pointSize < estimated * 1.5 { style.size = (font.pointSize * 10).rounded() / 10 }
            let traits = font.fontDescriptor.symbolicTraits
            let name = font.fontName.lowercased()
            style.bold = traits.contains(.bold) || name.contains("bold")
            style.italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
            // Embedded fonts often aren't installed; fall back to a similar standard family.
            if let family = font.familyName, NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
                style.family = family
            } else if traits.contains(.monoSpace) || name.contains("courier") || name.contains("mono") {
                style.family = "Courier New"
            } else if name.contains("times") || (name.contains("serif") && !name.contains("sans")) {
                style.family = "Times New Roman"
            }
        }
        let size = PDFOps.displaySize(of: page)
        let cover = bounds.insetBy(dx: -1, dy: -1)
        return PDFEditItem(pageIndex: pageIndex, rect: normalizedRect(bounds, pageSize: size), kind: .text, text: text,
                           style: style, wraps: false, cover: normalizedRect(cover, pageSize: size),
                           coverColor: colors.background, original: text)
    }

    /// The font used by most characters.
    static func dominantFont(_ string: NSAttributedString?) -> NSFont? {
        guard let string, string.length > 0 else { return nil }
        var counts: [NSFont: Int] = [:]
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let font = value as? NSFont { counts[font, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// The page color around `rect` (displayed points) and the color of the text inside it.
    static func sampleColors(_ page: PDFPage, in rect: CGRect) -> (background: CGColor, text: CGColor) {
        let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
        let margin: CGFloat = 3, scale: CGFloat = 3
        let region = rect.insetBy(dx: -margin, dy: -margin)
        let width = max(Int(region.width * scale), 8), height = max(Int(region.height * scale), 8)
        guard width * height < 30_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (white, black) }
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        page.draw(with: .cropBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return (white, black) }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * width * 4 + x * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }
        // The outer ring of the margin is the background; take the per-channel median.
        let ring = 4
        var reds: [Int] = [], greens: [Int] = [], blues: [Int] = []
        for y in 0..<height {
            for x in 0..<width where x < ring || y < ring || x >= width - ring || y >= height - ring {
                let (r, g, b) = pixel(x, y)
                reds.append(r); greens.append(g); blues.append(b)
            }
        }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        let background = (median(reds), median(greens), median(blues))
        func distance(_ c: (Int, Int, Int)) -> Int { abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2) }
        // The text is what differs most from the background; average the strongest pixels to skip anti-aliasing.
        let inset = Int(margin * scale)
        var strongest = 0
        for y in inset..<max(height - inset, inset) { for x in inset..<max(width - inset, inset) { strongest = max(strongest, distance(pixel(x, y))) } }
        func color(_ c: (Int, Int, Int)) -> CGColor {
            CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        let backgroundColor = color(background)
        guard strongest > 60 else {
            let light = background.0 + background.1 + background.2 > 380
            return (backgroundColor, light ? black : white)
        }
        var sum = (0, 0, 0), count = 0
        for y in inset..<max(height - inset, inset) {
            for x in inset..<max(width - inset, inset) {
                let c = pixel(x, y)
                if distance(c) * 10 >= strongest * 8 { sum.0 += c.0; sum.1 += c.1; sum.2 += c.2; count += 1 }
            }
        }
        return (backgroundColor, color((sum.0 / count, sum.1 / count, sum.2 / count)))
    }

    // MARK: - Text layout

    /// The size in points `text` needs: wrapped to `width`, or on one line.
    static func textSize(_ text: String, style: PDFEditTextStyle, wraps: Bool, width: CGFloat) -> CGSize {
        let sample = text.isEmpty ? "Ag" : text
        let string = NSAttributedString(string: sample, attributes: style.attributes())
        if wraps {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                    CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
            return CGSize(width: width, height: ceil(size.height) + 2)
        }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: ceil(lineWidth) + 2, height: ceil(ascent + descent))
    }

    /// Draws real text into `rect` (displayed points, origin bottom-left). Wrapped text starts at the top and
    /// grows downward rather than being clipped; one-line text is centred vertically on the rect.
    static func drawText(_ text: String, style: PDFEditTextStyle, wraps: Bool, in rect: CGRect, context: CGContext) {
        guard !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: style.attributes())
        context.saveGState()
        context.textMatrix = .identity
        if wraps {
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                      CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil).height
            var frameRect = rect
            if needed + 2 > rect.height {
                frameRect.origin.y -= needed + 2 - rect.height
                frameRect.size.height = needed + 2
            }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, context)
        } else {
            let line = CTLineCreateWithAttributedString(string)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let x: CGFloat
            switch style.alignment {
            case .center: x = rect.midX - width / 2
            case .right: x = rect.maxX - width
            default: x = rect.minX
            }
            context.textPosition = CGPoint(x: x, y: rect.midY - (ascent - descent) / 2)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    // MARK: - Drawing and saving

    /// Draws an item in displayed-page points (origin bottom-left). Shared by the on-screen preview and the
    /// saved PDF, so what you see is what's written. `includeText` false skips text being typed on screen.
    static func draw(_ item: PDFEditItem, in context: CGContext, pageSize: CGSize, includeText: Bool = true) {
        if let cover = item.cover {
            context.setFillColor(item.coverColor)
            context.fill(displayRect(cover, pageSize: pageSize))
        }
        let rect = displayRect(item.rect, pageSize: pageSize)
        switch item.kind {
        case .text:
            if includeText { drawText(item.text, style: item.style, wraps: item.wraps, in: rect, context: context) }
        case .image:
            guard let image = item.image else { return }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        case .box:
            if let fill = item.fill {
                context.setFillColor(fill)
                context.fill(rect)
            }
            if let stroke = item.stroke {
                context.setStrokeColor(stroke)
                context.setLineWidth(item.lineWidth)
                context.stroke(rect.insetBy(dx: item.lineWidth / 2, dy: item.lineWidth / 2))
            }
        }
    }

    /// Permanently draws `items` onto their pages. Each edited page is redrawn with its original content
    /// first, so text and vector graphics stay as they were; annotations (links, form fields) and
    /// bookmarks are carried over.
    static func apply(_ items: [PDFEditItem], to document: PDFDocument) throws {
        for (pageIndex, pageItems) in Dictionary(grouping: items, by: \.pageIndex) {
            guard let page = document.page(at: pageIndex) else { continue }
            let newPage = try editedPage(page, items: pageItems)
            for annotation in page.annotations {
                page.removeAnnotation(annotation)
                newPage.addAnnotation(annotation)
            }
            document.insert(newPage, at: pageIndex)
            if let root = document.outlineRoot { retarget(root, from: page, to: newPage) }
            document.removePage(at: pageIndex + 1)
        }
    }

    private static func editedPage(_ page: PDFPage, items: [PDFEditItem]) throws -> PDFPage {
        guard let pageRef = page.pageRef else { throw ToolError.failed("Couldn't read the page.") }
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed("Couldn't draw the edits.")
        }
        context.beginPDFPage(PDFOps.pageInfo(mediaBox: &mediaBox))
        context.drawPDFPage(pageRef)
        // Items are positioned on the displayed page; map back into page space so they appear upright.
        context.saveGState()
        context.concatenate(page.transform(for: .cropBox).inverted())
        let size = PDFOps.displaySize(of: page)
        for item in items { draw(item, in: context, pageSize: size) }
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        guard let edited = PDFDocument(data: data as Data), let newPage = edited.page(at: 0)?.copy() as? PDFPage else {
            throw ToolError.failed("Couldn't draw the edits.")
        }
        newPage.rotation = page.rotation
        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            newPage.setBounds(page.bounds(for: box), for: box)
        }
        return newPage
    }

    private static func retarget(_ item: PDFOutline, from old: PDFPage, to new: PDFPage) {
        for index in 0..<item.numberOfChildren {
            guard let child = item.child(at: index) else { continue }
            if let destination = child.destination, destination.page === old {
                child.destination = PDFDestination(page: new, at: destination.point)
            }
            retarget(child, from: old, to: new)
        }
    }

    /// Loads a picture for placing on a page, upright and at most `maxPixels` on its longest side.
    static func loadImage(_ url: URL, maxPixels: Int = 3000) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}
