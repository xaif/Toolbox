import AppKit
import CoreText
import PDFKit

/// Which pages a page tool changes.
enum PDFPageScope: String, CaseIterable, Identifiable {
    case all, odd, even, custom
    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All pages"
        case .odd: "Odd pages"
        case .even: "Even pages"
        case .custom: "Custom range"
        }
    }

    /// Zero-based indices of the pages in scope. `range` is used for `.custom`, e.g. "1-3, 5".
    func pages(range: String, pageCount: Int) throws -> Set<Int> {
        switch self {
        case .all: Set(0..<pageCount)
        case .odd: Set(stride(from: 0, to: pageCount, by: 2))
        case .even: Set(stride(from: 1, to: pageCount, by: 2))
        case .custom: Set(try PDFOps.indices(range, pageCount: pageCount))
        }
    }
}

/// Where something sits on a page: a corner, an edge's middle or the center.
enum PDFStampPosition: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: Self { self }

    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top center"
        case .topRight: "Top right"
        case .left: "Middle left"
        case .center: "Center"
        case .right: "Middle right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom center"
        case .bottomRight: "Bottom right"
        }
    }

    /// The positions along the top and bottom edges, for page numbers and headers.
    static let edges: [Self] = [.topLeft, .top, .topRight, .bottomLeft, .bottom, .bottomRight]

    /// -1 left, 0 middle, 1 right.
    var column: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .center, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// 1 top, 0 middle, -1 bottom.
    var row: Int {
        switch self {
        case .topLeft, .top, .topRight: 1
        case .left, .center, .right: 0
        case .bottomLeft, .bottom, .bottomRight: -1
        }
    }
}

enum PDFStampColor: String, CaseIterable, Identifiable {
    case black, gray, red, blue, green, white
    var id: Self { self }
    var label: String { rawValue.capitalized }

    var cgColor: CGColor {
        switch self {
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .gray: CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        case .red: CGColor(srgbRed: 0.85, green: 0.12, blue: 0.12, alpha: 1)
        case .blue: CGColor(srgbRed: 0.1, green: 0.32, blue: 0.85, alpha: 1)
        case .green: CGColor(srgbRed: 0.1, green: 0.55, blue: 0.25, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

/// How text drawn onto pages looks.
struct PDFTextStyle {
    var size: CGFloat = 12
    var bold = false
    var color = PDFStampColor.black.cgColor

    func line(_ text: String) -> CTLine {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }
}

enum PDFLengthUnit: String, CaseIterable, Identifiable {
    case points, millimeters, inches
    var id: Self { self }

    var label: String {
        switch self {
        case .points: "pt"
        case .millimeters: "mm"
        case .inches: "in"
        }
    }

    /// Points in one unit.
    var points: CGFloat {
        switch self {
        case .points: 1
        case .millimeters: 72 / 25.4
        case .inches: 72
        }
    }
}

enum PDFPaperSize: String, CaseIterable, Identifiable {
    case original, a3, a4, a5, letter, legal, custom
    var id: Self { self }

    var label: String {
        switch self {
        case .original: "Keep original size"
        case .a3: "A3"
        case .a4: "A4"
        case .a5: "A5"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .custom: "Custom"
        }
    }

    /// Portrait size in points. Nil for `.original` and `.custom`.
    var size: CGSize? {
        switch self {
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .original, .custom: nil
        }
    }
}

enum PDFPaperOrientation: String, CaseIterable, Identifiable {
    case match, portrait, landscape
    var id: Self { self }

    var label: String {
        switch self {
        case .match: "Match each page"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }
}

struct PDFCropResize {
    /// Margins to cut off, in points, measured on the page as it's displayed.
    var top: CGFloat = 0, right: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0
    /// Crops to the page's non-white content first.
    var trimWhitespace = false
    /// Portrait size of the new pages. Nil keeps each page's size.
    var paper: CGSize?
    var orientation = PDFPaperOrientation.match

    var hasMargins: Bool { top > 0 || right > 0 || bottom > 0 || left > 0 }
}

struct PDFWatermark {
    enum Content {
        case text(String, PDFTextStyle)
        /// `widthFraction` of the page's width.
        case image(CGImage, widthFraction: CGFloat)
    }

    var content: Content
    var opacity: CGFloat = 0.3
    /// Counterclockwise degrees.
    var rotation: CGFloat = 45
    /// Repeats the mark across the whole page instead of placing it once at `position`.
    var tiled = false
    var position = PDFStampPosition.center
}

enum PDFPageNumberFormat: String, CaseIterable, Identifiable {
    case number, page, pageOfTotal, slash, dashes, roman
    var id: Self { self }

    var label: String {
        switch self {
        case .number: "1"
        case .page: "Page 1"
        case .pageOfTotal: "Page 1 of 9"
        case .slash: "1 / 9"
        case .dashes: "- 1 -"
        case .roman: "i, ii, iii"
        }
    }

    func text(_ number: Int, total: Int) -> String {
        switch self {
        case .number: "\(number)"
        case .page: "Page \(number)"
        case .pageOfTotal: "Page \(number) of \(total)"
        case .slash: "\(number) / \(total)"
        case .dashes: "- \(number) -"
        case .roman: Self.roman(number)
        }
    }

    /// Lowercase Roman numerals; plain digits outside 1…3999.
    static func roman(_ number: Int) -> String {
        guard (1...3999).contains(number) else { return "\(number)" }
        let symbols: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                        (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var remaining = number, result = ""
        for (value, symbol) in symbols {
            while remaining >= value { result += symbol; remaining -= value }
        }
        return result
    }
}

struct PDFPageNumbering {
    var format = PDFPageNumberFormat.number
    var position = PDFStampPosition.bottom
    var start = 1
    var style = PDFTextStyle(size: 11)
    var margin: CGFloat = 28
    var skipFirst = false
}

enum PDFDateStyle: String, CaseIterable, Identifiable {
    case medium, long, iso, numeric
    var id: Self { self }

    func string(_ date: Date) -> String {
        switch self {
        case .medium: date.formatted(date: .abbreviated, time: .omitted)
        case .long: date.formatted(date: .long, time: .omitted)
        case .iso: date.formatted(.iso8601.year().month().day())
        case .numeric: date.formatted(date: .numeric, time: .omitted)
        }
    }

    var label: String { string(Date()) }
}

struct PDFHeaderFooter {
    /// Text for each edge position. Tokens: {page} {pages} {date} {time} {filename} {title}.
    var texts: [PDFStampPosition: String] = [:]
    var style = PDFTextStyle(size: 10)
    var margin: CGFloat = 28
    var skipFirst = false
    /// Draws a thin rule under the header and above the footer.
    var rules = false
    var dateStyle = PDFDateStyle.medium
    var date = Date()

    var isEmpty: Bool { texts.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    static let tokens = ["{page}", "{pages}", "{date}", "{time}", "{filename}", "{title}"]

    func resolve(_ template: String, page: Int, pages: Int, fileName: String, title: String) -> String {
        let values = ["{page}": "\(page)", "{pages}": "\(pages)", "{date}": dateStyle.string(date),
                      "{time}": date.formatted(date: .omitted, time: .shortened), "{filename}": fileName, "{title}": title]
        var result = template
        for (token, value) in values {
            result = result.replacingOccurrences(of: token, with: value, options: .caseInsensitive)
        }
        return result
    }
}

enum PDFColorMode: String, CaseIterable, Identifiable {
    case dark, softDark, sepia, grayscale
    var id: Self { self }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .softDark: "Soft dark"
        case .sepia: "Sepia"
        case .grayscale: "Grayscale"
        }
    }

    var suffix: String {
        switch self {
        case .dark, .softDark: "dark"
        case .sepia: "sepia"
        case .grayscale: "grayscale"
        }
    }
}

/// An invisible mark that ties a copy of a PDF to the person it was sent to.
struct PDFFingerprint: Hashable, Sendable {
    var recipient: String
    var code: String

    /// Document info key that holds the token too.
    static let metadataKey = "ToolboxFingerprint"
    private static let prefix = "[TBXFP1:"

    /// What's hidden in the page text and metadata, e.g. "[TBXFP1:QUJD…]".
    var token: String {
        let base64 = Data("\(code)|\(recipient)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + base64 + "]"
    }

    init(recipient: String, code: String = PDFFingerprint.newCode()) {
        self.recipient = recipient
        self.code = code
    }

    /// Reads the base64 payload between the token's prefix and its closing bracket.
    init?(payload: String) {
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8),
              let bar = text.firstIndex(of: "|") else { return nil }
        code = String(text[..<bar])
        recipient = String(text[text.index(after: bar)...])
    }

    /// A short code unique to one copy, e.g. "7F3A9C2D1B".
    static func newCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
    }

    /// Every fingerprint in `text`.
    static func find(in text: String) -> [PDFFingerprint] {
        guard let regex = try? NSRegularExpression(pattern: #"\[TBXFP1:([A-Za-z0-9_-]+)\]"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { PDFFingerprint(payload: String(text[$0])) }
        }
    }
}

/// Page operations behind Rotate, Crop & Resize, Watermark, Page Numbers, Headers & Footers, Invert Colors,
/// Flatten and Fingerprint. Pages are redrawn with Core Graphics, so text and vector graphics stay as they are.
enum PDFStampOps {
    // MARK: - Rebuilding pages

    /// The new page a source page is redrawn onto.
    struct PageGeometry {
        var mediaBox: CGRect
        /// Maps the source page's space into the new page's, for the annotations carried over.
        var transform = CGAffineTransform.identity
        /// Keeps the source page's rotation and crop box. False when the drawing bakes them in.
        var keepsBoxes = true
    }

    /// Redraws every page of `source` into a new document. `draw` gets a context in the source page's own
    /// space (unrotated, like its media box). Annotations `keepAnnotation` accepts move to the new pages,
    /// links re-pointed; the rest are dropped. Bookmarks and metadata are kept.
    ///
    /// Annotations are detached from `source` before drawing so `PDFPage.draw` doesn't paint the kept ones,
    /// which leaves `source` without them: open the file again to rebuild it twice.
    static func rebuild(
        _ source: PDFDocument,
        keepAnnotation: (PDFAnnotation) -> Bool = { _ in true },
        geometry: ((_ index: Int, _ page: PDFPage) throws -> PageGeometry)? = nil,
        progress: ((Double) -> Void)? = nil,
        draw: (_ index: Int, _ page: PDFPage, _ context: CGContext) throws -> Void
    ) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, PDFOps.pdfInfo(from: source) as CFDictionary) else {
            throw ToolError.failed("Couldn't create the PDF.")
        }
        var kept: [[PDFAnnotation]] = []
        var geometries: [PageGeometry] = []
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            guard let page = source.page(at: index) else { throw ToolError.failed("Couldn't read page \(index + 1).") }
            let keep = page.annotations.filter(keepAnnotation)
            for annotation in keep { page.removeAnnotation(annotation) }
            kept.append(keep)
            var pageGeometry = try geometry?(index, page) ?? PageGeometry(mediaBox: page.bounds(for: .mediaBox))
            geometries.append(pageGeometry)
            context.beginPDFPage(PDFOps.pageInfo(mediaBox: &pageGeometry.mediaBox))
            context.saveGState()
            try draw(index, page, context)
            context.restoreGState()
            context.endPDFPage()
            progress?(Double(index + 1) / Double(source.pageCount) * 0.9)
        }
        context.closePDF()
        guard let drawn = PDFDocument(data: data as Data), drawn.pageCount == source.pageCount else {
            throw ToolError.failed("Couldn't create the PDF.")
        }
        // Saved straight from Core Graphics data, pages drop added annotations and links to other pages;
        // copies of them in a document PDFKit made keep both.
        let output = PDFDocument()
        for index in 0..<drawn.pageCount {
            guard let page = drawn.page(at: index)?.copy() as? PDFPage else { throw ToolError.failed("Couldn't create the PDF.") }
            output.insert(page, at: index)
        }

        for index in 0..<output.pageCount {
            guard let page = source.page(at: index), let newPage = output.page(at: index) else { continue }
            let pageGeometry = geometries[index]
            if pageGeometry.keepsBoxes {
                newPage.rotation = page.rotation
                newPage.setBounds(page.bounds(for: .cropBox), for: .cropBox)
            }
            for annotation in kept[index] {
                if !pageGeometry.transform.isIdentity { annotation.bounds = annotation.bounds.applying(pageGeometry.transform) }
                newPage.addAnnotation(annotation)
            }
        }
        retargetLinks(in: output, from: source) { geometries[$0].transform }
        if let root = source.outlineRoot {
            let newRoot = PDFOutline()
            let identity = Dictionary(uniqueKeysWithValues: (0..<source.pageCount).map { ($0, $0) })
            PDFOps.copyOutline(root, source: source, into: newRoot, destination: output, pageMap: identity)
            if newRoot.numberOfChildren > 0 { output.outlineRoot = newRoot }
        }
        PDFOps.copyAttributes(from: source, to: output)
        progress?(1)
        return output
    }

    /// Points links to other pages, which still lead to `source`'s pages, at the same pages of `output`.
    /// `transform` maps a source page's space into its new page's.
    static func retargetLinks(in output: PDFDocument, from source: PDFDocument,
                              transform: (Int) -> CGAffineTransform = { _ in .identity }) {
        func retarget(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let target = destination.page else { return nil }
            let index = source.index(for: target)
            guard index != NSNotFound, let page = output.page(at: index) else { return nil }
            return PDFDestination(page: page, at: destination.point.applying(transform(index)))
        }
        for index in 0..<output.pageCount {
            for annotation in output.page(at: index)?.annotations ?? [] {
                if let action = annotation.action as? PDFActionGoTo {
                    if let destination = retarget(action.destination) { annotation.action = PDFActionGoTo(destination: destination) }
                } else if let destination = retarget(annotation.destination) {
                    annotation.destination = destination
                }
            }
        }
    }

    /// Redraws every page and lets `draw` add to the pages in `pages`, in displayed space: upright, with the
    /// origin at the bottom left of the visible page, which is `size` points.
    static func overlay(
        _ source: PDFDocument,
        pages: Set<Int>,
        progress: ((Double) -> Void)? = nil,
        draw: (_ index: Int, _ size: CGSize, _ context: CGContext) throws -> Void
    ) throws -> PDFDocument {
        try rebuild(source, progress: progress) { index, page, context in
            guard let pageRef = page.pageRef else { throw ToolError.failed("Couldn't read page \(index + 1).") }
            context.drawPDFPage(pageRef)
            guard pages.contains(index) else { return }
            context.concatenate(page.transform(for: .cropBox).inverted())
            try draw(index, PDFOps.displaySize(of: page), context)
        }
    }

    // MARK: - Text

    /// A line's width and its height above and below the baseline.
    static func measure(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (CGFloat(width), ascent, descent)
    }

    /// Draws `line` with the left end of its baseline at `point`.
    static func draw(_ line: CTLine, at point: CGPoint, in context: CGContext) {
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// Draws a line of text at one of the page's corners, edges or its center, `margin` points in.
    static func drawLabel(_ text: String, style: PDFTextStyle, at position: PDFStampPosition, in size: CGSize,
                          margin: CGFloat, context: CGContext) {
        guard !text.isEmpty else { return }
        let line = style.line(text)
        let metrics = measure(line)
        let x: CGFloat = switch position.column {
        case -1: margin
        case 0: (size.width - metrics.width) / 2
        default: size.width - margin - metrics.width
        }
        let y: CGFloat = switch position.row {
        case 1: size.height - margin - metrics.ascent
        case 0: (size.height - metrics.ascent + metrics.descent) / 2
        default: margin + metrics.descent
        }
        draw(line, at: CGPoint(x: x, y: y), in: context)
    }

    // MARK: - Rotate

    /// Turns `pages` clockwise by `degrees` (a multiple of 90). Lossless: only the pages' rotation changes.
    static func rotate(_ source: PDFDocument, pages: Set<Int>, degrees: Int) -> PDFDocument {
        let output = editable(source)
        for index in pages {
            guard let page = output.page(at: index) else { continue }
            page.rotation = PDFOps.normalizedRotation(page.rotation + degrees)
        }
        return output
    }

    /// `source` itself when its pages can be changed in place, which keeps everything else about it: page
    /// copies in a new document lose their links to other pages. Otherwise (pages locked by permissions), a copy.
    private static func editable(_ source: PDFDocument) -> PDFDocument {
        source.allowsDocumentAssembly ? source : PDFOps.document(from: source, indices: PDFOps.allPages(source))
    }

    // MARK: - Crop & resize

    /// Crops margins (losslessly, through the crop box) and optionally fits every page onto a new paper size.
    static func cropResize(_ source: PDFDocument, options: PDFCropResize, progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        // The part of each page to keep, in displayed space.
        var visible: [CGRect] = []
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            guard let page = source.page(at: index) else { throw ToolError.failed("Couldn't read page \(index + 1).") }
            let size = PDFOps.displaySize(of: page)
            var rect = CGRect(origin: .zero, size: size)
            if options.trimWhitespace, let content = contentBounds(of: page) {
                rect = content.insetBy(dx: -6, dy: -6).intersection(rect)
            }
            let width = rect.width - options.left - options.right, height = rect.height - options.top - options.bottom
            guard width >= 18, height >= 18 else {
                throw ToolError.failed("The margins are larger than page \(index + 1).")
            }
            rect = CGRect(x: rect.minX + options.left, y: rect.minY + options.bottom, width: width, height: height)
            visible.append(rect)
            progress?(Double(index + 1) / Double(source.pageCount) * (options.paper == nil ? 0.9 : 0.3))
        }

        guard let paper = options.paper else {
            let output = editable(source)
            for index in 0..<output.pageCount {
                guard let page = output.page(at: index) else { continue }
                let pageRect = visible[index].applying(page.transform(for: .cropBox).inverted())
                page.setBounds(pageRect.intersection(page.bounds(for: .mediaBox)), for: .cropBox)
            }
            progress?(1)
            return output
        }

        var transforms: [CGAffineTransform] = []
        var clips: [CGRect] = []
        return try rebuild(source, geometry: { index, page in
            let rect = visible[index]
            let landscape = switch options.orientation {
            case .match: rect.width > rect.height
            case .portrait: false
            case .landscape: true
            }
            let target = landscape == (paper.width > paper.height) ? paper : CGSize(width: paper.height, height: paper.width)
            let scale = min(target.width / rect.width, target.height / rect.height)
            let offset = CGPoint(x: (target.width - rect.width * scale) / 2, y: (target.height - rect.height * scale) / 2)
            let transform = page.transform(for: .cropBox)
                .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
            transforms.append(transform)
            clips.append(CGRect(x: offset.x, y: offset.y, width: rect.width * scale, height: rect.height * scale))
            return PageGeometry(mediaBox: CGRect(origin: .zero, size: target), transform: transform, keepsBoxes: false)
        }, progress: { progress?(0.3 + $0 * 0.7) }) { index, page, context in
            guard let pageRef = page.pageRef else { throw ToolError.failed("Couldn't read page \(index + 1).") }
            // Only the kept part shows, scaled and centered on the new page.
            context.clip(to: clips[index])
            context.concatenate(transforms[index])
            context.drawPDFPage(pageRef)
        }
    }

    /// The part of the page that isn't white, in displayed space, or nil for a blank page.
    static func contentBounds(of page: PDFPage) -> CGRect? {
        guard let image = PDFOps.renderPage(page, scale: 2) else { return nil }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minRow = height, maxX = -1, maxRow = -1
        for row in 0..<height {
            let base = row * width * 4
            for x in 0..<width {
                let index = base + x * 4
                if min(pixels[index], pixels[index + 1], pixels[index + 2]) < 235 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minRow = min(minRow, row); maxRow = max(maxRow, row)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows count down from the top; displayed space counts up from the bottom.
        let size = PDFOps.displaySize(of: page)
        let scaleX = size.width / CGFloat(width), scaleY = size.height / CGFloat(height)
        return CGRect(x: CGFloat(minX) * scaleX, y: CGFloat(height - 1 - maxRow) * scaleY,
                      width: CGFloat(maxX - minX + 1) * scaleX, height: CGFloat(maxRow - minRow + 1) * scaleY)
    }

    // MARK: - Watermark

    static func watermark(_ source: PDFDocument, mark: PDFWatermark, pages: Set<Int>,
                          progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        try overlay(source, pages: pages, progress: progress) { _, size, context in
            drawWatermark(mark, in: size, context: context)
        }
    }

    static func drawWatermark(_ mark: PDFWatermark, in size: CGSize, context: CGContext) {
        let itemSize: CGSize
        let drawItem: (CGContext) -> Void
        switch mark.content {
        case .text(let text, let style):
            let line = style.line(text)
            let metrics = measure(line)
            itemSize = CGSize(width: metrics.width, height: metrics.ascent + metrics.descent)
            drawItem = { draw(line, at: CGPoint(x: -metrics.width / 2, y: -(metrics.ascent - metrics.descent) / 2), in: $0) }
        case .image(let image, let fraction):
            let width = size.width * fraction
            let height = width * CGFloat(image.height) / CGFloat(max(image.width, 1))
            itemSize = CGSize(width: width, height: height)
            drawItem = {
                $0.interpolationQuality = .high
                $0.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            }
        }
        let radians = mark.rotation * .pi / 180
        let bounds = CGSize(width: abs(itemSize.width * cos(radians)) + abs(itemSize.height * sin(radians)),
                            height: abs(itemSize.width * sin(radians)) + abs(itemSize.height * cos(radians)))
        var centers: [CGPoint] = []
        if mark.tiled {
            let stepX = bounds.width + max(48, size.width * 0.08), stepY = bounds.height + max(48, size.height * 0.06)
            var row = 0
            var y = stepY / 2
            while y - bounds.height / 2 < size.height {
                var x = row.isMultiple(of: 2) ? stepX / 2 : 0
                while x - bounds.width / 2 < size.width {
                    centers.append(CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            let margin: CGFloat = 36
            let x: CGFloat = switch mark.position.column {
            case -1: margin + bounds.width / 2
            case 0: size.width / 2
            default: size.width - margin - bounds.width / 2
            }
            let y: CGFloat = switch mark.position.row {
            case 1: size.height - margin - bounds.height / 2
            case 0: size.height / 2
            default: margin + bounds.height / 2
            }
            centers = [CGPoint(x: x, y: y)]
        }
        context.saveGState()
        context.setAlpha(mark.opacity)
        for center in centers {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: radians)
            drawItem(context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    // MARK: - Page numbers, headers and footers

    static func addPageNumbers(_ source: PDFDocument, numbering: PDFPageNumbering, pages: Set<Int>,
                               progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        let numbered = pages.subtracting(numbering.skipFirst ? [0] : []).sorted()
        let numbers = Dictionary(uniqueKeysWithValues: numbered.enumerated().map { ($1, numbering.start + $0) })
        let total = numbering.start + numbered.count - 1
        return try overlay(source, pages: Set(numbered), progress: progress) { index, size, context in
            guard let number = numbers[index] else { return }
            drawLabel(numbering.format.text(number, total: total), style: numbering.style, at: numbering.position,
                      in: size, margin: numbering.margin, context: context)
        }
    }

    static func addHeadersFooters(_ source: PDFDocument, layout: PDFHeaderFooter, fileName: String,
                                  progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        let title = (source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fileName
        let pageCount = source.pageCount
        let pages = Set(0..<pageCount).subtracting(layout.skipFirst ? [0] : [])
        return try overlay(source, pages: pages, progress: progress) { index, size, context in
            for position in PDFStampPosition.edges {
                guard let template = layout.texts[position], !template.isEmpty else { continue }
                let text = layout.resolve(template, page: index + 1, pages: pageCount, fileName: fileName, title: title)
                drawLabel(text, style: layout.style, at: position, in: size, margin: layout.margin, context: context)
            }
            guard layout.rules else { return }
            let metrics = measure(layout.style.line("Hg"))
            context.setStrokeColor(layout.style.color.copy(alpha: 0.5) ?? layout.style.color)
            context.setLineWidth(0.5)
            for row in [1, -1] where PDFStampPosition.edges.contains(where: { $0.row == row && !(layout.texts[$0] ?? "").isEmpty }) {
                let y = row == 1 ? size.height - layout.margin - metrics.ascent - metrics.descent - 4
                    : layout.margin + metrics.descent + metrics.ascent + 4
                context.move(to: CGPoint(x: layout.margin, y: y))
                context.addLine(to: CGPoint(x: size.width - layout.margin, y: y))
                context.strokePath()
            }
        }
    }

    // MARK: - Colors

    /// Recolors pages with blend modes over their vector content, so text stays selectable. Annotations
    /// other than links are painted into the page so they're recolored too.
    static func recolor(_ source: PDFDocument, mode: PDFColorMode, progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        try rebuild(source, keepAnnotation: isLink, progress: progress) { _, page, context in
            let box = page.bounds(for: .mediaBox)
            // An explicit white sheet, so the blend has paper to work against.
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(box)
            context.saveGState()
            context.concatenate(page.transform(for: .mediaBox).inverted())
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            func gray(_ value: CGFloat) -> CGColor { CGColor(srgbRed: value, green: value, blue: value, alpha: 1) }
            func blend(_ mode: CGBlendMode, _ color: CGColor) {
                context.setBlendMode(mode)
                context.setFillColor(color)
                context.fill(box)
            }
            switch mode {
            case .dark:
                blend(.difference, gray(1))
            case .softDark:
                // White paper becomes a dark gray and black text a light one.
                blend(.difference, gray(0.9))
            case .grayscale:
                blend(.saturation, gray(0.5))
            case .sepia:
                blend(.saturation, gray(0.5))
                blend(.multiply, CGColor(srgbRed: 0.957, green: 0.925, blue: 0.847, alpha: 1))
                blend(.lighten, CGColor(srgbRed: 0.36, green: 0.27, blue: 0.21, alpha: 1))
            }
        }
    }

    // MARK: - Flatten

    /// Paints annotations and form fields into the page content and drops them, along with the form,
    /// scripts and open actions (a fresh document has none of them). Optionally keeps links clickable.
    static func flatten(_ source: PDFDocument, keepLinks: Bool, progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        try rebuild(source, keepAnnotation: { keepLinks && isLink($0) }, progress: progress) { _, page, context in
            context.concatenate(page.transform(for: .mediaBox).inverted())
            page.draw(with: .mediaBox, to: context)
        }
    }

    static func isLink(_ annotation: PDFAnnotation) -> Bool { annotation.type == "Link" }

    // MARK: - Fingerprint

    /// Spots on each page where the fingerprint is hidden, as fractions of the displayed page.
    private static let fingerprintSpots: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.04), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.06, y: 0.96), CGPoint(x: 0.55, y: 0.22),
    ]

    /// Hides `fingerprint` on every page as invisible text (selectable and searchable, never shown or
    /// printed) and in the document's metadata.
    static func fingerprint(_ source: PDFDocument, with fingerprint: PDFFingerprint,
                            progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        let line = PDFTextStyle(size: 4).line(fingerprint.token)
        let width = measure(line).width
        let output = try overlay(source, pages: Set(0..<source.pageCount), progress: progress) { _, size, context in
            context.setTextDrawingMode(.invisible)
            for spot in fingerprintSpots {
                let x = min(max(spot.x * size.width, 2), max(size.width - width - 2, 2))
                let y = min(max(spot.y * size.height, 4), size.height - 6)
                draw(line, at: CGPoint(x: x, y: y), in: context)
            }
            context.setTextDrawingMode(.fill)
        }
        var attributes = output.documentAttributes ?? [:]
        attributes[PDFFingerprint.metadataKey] = fingerprint.token
        output.documentAttributes = attributes
        return output
    }

    /// The fingerprints in a document, with the 1-based pages each was found on (empty when it's only in
    /// the metadata).
    static func fingerprints(in document: PDFDocument) -> [(fingerprint: PDFFingerprint, pages: [Int])] {
        var found: [PDFFingerprint: Set<Int>] = [:]
        var order: [PDFFingerprint] = []
        func add(_ fingerprint: PDFFingerprint, page: Int?) {
            if found[fingerprint] == nil { order.append(fingerprint); found[fingerprint] = [] }
            if let page { found[fingerprint]?.insert(page) }
        }
        for index in 0..<document.pageCount {
            for fingerprint in PDFFingerprint.find(in: document.page(at: index)?.string ?? "") { add(fingerprint, page: index + 1) }
        }
        if let token = document.documentAttributes?[PDFFingerprint.metadataKey] as? String {
            for fingerprint in PDFFingerprint.find(in: token) { add(fingerprint, page: nil) }
        }
        return order.map { ($0, (found[$0] ?? []).sorted()) }
    }
}
