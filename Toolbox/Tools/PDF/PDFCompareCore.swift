import AppKit
import CoreText
import PDFKit

enum PDFCompareSide: Sendable {
    case original, revised
}

/// Word-level differences between the text of two PDFs.
struct PDFTextDiff: Sendable {
    struct Word: Equatable, Sendable {
        let page: Int
        /// Range in the page's `string`, for highlighting.
        let range: NSRange
        let text: String
        /// What's compared: ligatures and other compatibility characters folded, so producers that
        /// encode "ﬁ" differently don't show up as changes.
        let key: String
    }

    /// A run of words removed from the original and/or added in the revision at the same spot.
    struct Change: Identifiable, Sendable {
        enum Kind { case removed, added, changed }

        let id: Int
        /// Indices into `original`.
        let removed: Range<Int>
        /// Indices into `revised`.
        let added: Range<Int>

        var kind: Kind { removed.isEmpty ? .added : (added.isEmpty ? .removed : .changed) }
    }

    let original: [Word]
    let revised: [Word]
    let changes: [Change]

    var removedWordCount: Int { changes.reduce(0) { $0 + $1.removed.count } }
    var addedWordCount: Int { changes.reduce(0) { $0 + $1.added.count } }

    init(original: PDFDocument, revised: PDFDocument) {
        self.init(original: Self.words(in: original), revised: Self.words(in: revised))
    }

    init(original: [Word], revised: [Word]) {
        self.original = original
        self.revised = revised
        changes = Self.changes(original, revised)
    }

    static func words(in document: PDFDocument) -> [Word] {
        let pattern = try! NSRegularExpression(pattern: "\\S+")
        var words: [Word] = []
        for index in 0..<document.pageCount {
            guard let string = document.page(at: index)?.string else { continue }
            let text = string as NSString
            for match in pattern.matches(in: string, range: NSRange(location: 0, length: text.length)) {
                let word = text.substring(with: match.range)
                words.append(Word(page: index, range: match.range, text: word, key: word.precomposedStringWithCompatibilityMapping))
            }
        }
        return words
    }

    /// Myers diff over the whole text, so reflowed pages don't count as changes. Very different large
    /// documents are compared page by page instead, which keeps the work bounded.
    static func changes(_ original: [Word], _ revised: [Word]) -> [Change] {
        guard original.count * revised.count > 25_000_000 else {
            return hunks(original[...], revised[...], firstID: 0)
        }
        let pages = max(original.last?.page ?? 0, revised.last?.page ?? 0) + 1
        var result: [Change] = []
        var a = original.startIndex, b = revised.startIndex
        for page in 0..<pages {
            let aEnd = original[a...].firstIndex { $0.page > page } ?? original.endIndex
            let bEnd = revised[b...].firstIndex { $0.page > page } ?? revised.endIndex
            result += hunks(original[a..<aEnd], revised[b..<bEnd], firstID: result.count)
            a = aEnd
            b = bEnd
        }
        return result
    }

    /// Groups the diff of two word runs into changes. Indices are those of the full arrays.
    private static func hunks(_ a: ArraySlice<Word>, _ b: ArraySlice<Word>, firstID: Int) -> [Change] {
        let difference = b.map(\.key).difference(from: a.map(\.key))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(a.startIndex + offset)
            case .insert(let offset, _, _): inserted.insert(b.startIndex + offset)
            }
        }
        var changes: [Change] = []
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex || j < b.endIndex {
            if removed.contains(i) || inserted.contains(j) {
                let start = (i, j)
                // Alternating removals and insertions belong to the same change.
                while removed.contains(i) || inserted.contains(j) {
                    while removed.contains(i) { i += 1 }
                    while inserted.contains(j) { j += 1 }
                }
                changes.append(Change(id: firstID + changes.count, removed: start.0..<i, added: start.1..<j))
            } else {
                i += 1
                j += 1
            }
        }
        return changes
    }

    func words(of change: Change, on side: PDFCompareSide) -> [Word] {
        side == .original ? Array(original[change.removed]) : Array(revised[change.added])
    }

    func text(of change: Change, on side: PDFCompareSide) -> String {
        words(of: change, on: side).map(\.text).joined(separator: " ")
    }

    /// The page a change is on in either document. Words added to the revision have no place in the
    /// original, so the original side uses the word before them.
    func page(of change: Change, on side: PDFCompareSide) -> Int {
        let words = side == .original ? original : revised
        let range = side == .original ? change.removed : change.added
        if let first = range.first { return words[first].page }
        if range.lowerBound > 0, range.lowerBound - 1 < words.count { return words[range.lowerBound - 1].page }
        return words.first?.page ?? 0
    }

    /// Selections covering `range` of the words, one per run of words on the same page.
    static func selections(_ range: Range<Int>, of words: [Word], in document: PDFDocument) -> [PDFSelection] {
        var result: [PDFSelection] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = start
            while end + 1 < range.upperBound, words[end + 1].page == words[start].page { end += 1 }
            if let page = document.page(at: words[start].page) {
                let location = words[start].range.location
                if let selection = page.selection(for: NSRange(location: location, length: NSMaxRange(words[end].range) - location)) {
                    result.append(selection)
                }
            }
            start = end + 1
        }
        return result
    }
}

enum PDFCompareOps {
    struct VisualDifference {
        let image: CGImage
        /// Share of the page's pixels that differ.
        let changedFraction: Double
    }

    /// Overlays two pages: unchanged content faded, ink only in the original red, ink only in the revision green.
    /// A missing page counts as blank.
    static func visualDifference(original: PDFPage?, revised: PDFPage?, maxDimension: CGFloat = 1400) -> VisualDifference? {
        guard let reference = original ?? revised else { return nil }
        let size = PDFOps.displaySize(of: reference)
        let scale = maxDimension / max(size.width, size.height, 1)
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        guard let a = render(original, width: width, height: height), let b = render(revised, width: width, height: height) else { return nil }
        var output = [UInt8](repeating: 255, count: width * height * 4)
        var changed = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let la = luminance(a, index), lb = luminance(b, index)
            if abs(la - lb) > 32 {
                changed += 1
                let color: (UInt8, UInt8, UInt8) = la < lb ? (225, 45, 45) : (30, 165, 70)
                output[index] = color.0; output[index + 1] = color.1; output[index + 2] = color.2
            } else {
                // Fade what's the same so the differences stand out.
                let ink = 255 - min(la, lb)
                let gray = UInt8(255 - ink * 35 / 100)
                output[index] = gray; output[index + 1] = gray; output[index + 2] = gray
            }
        }
        let data = Data(output)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return VisualDifference(image: image, changedFraction: Double(changed) / Double(width * height))
    }

    private static func luminance(_ pixels: [UInt8], _ index: Int) -> Int {
        (Int(pixels[index]) * 299 + Int(pixels[index + 1]) * 587 + Int(pixels[index + 2]) * 114) / 1000
    }

    /// RGBA pixels of a page fitted into `width` × `height` on white.
    private static func render(_ page: PDFPage?, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let page else { return pixels }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            let size = PDFOps.displaySize(of: page)
            let scale = min(CGFloat(width) / size.width, CGFloat(height) / size.height)
            context.interpolationQuality = .high
            context.translateBy(x: (CGFloat(width) - size.width * scale) / 2, y: (CGFloat(height) - size.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            return true
        }
        return drawn ? pixels : nil
    }

    /// A printable list of every change, removed words in red and added words in green.
    static func report(_ diff: PDFTextDiff, originalName: String, revisedName: String) -> NSAttributedString {
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let body = NSFont.systemFont(ofSize: 11)
        let report = NSMutableAttributedString()
        func add(_ text: String, font: NSFont = body, color: CGColor = CGColor(gray: 0.1, alpha: 1)) {
            report.append(NSAttributedString(string: text, attributes: [.font: font, colorKey: color]))
        }
        add("Comparison\n", font: .boldSystemFont(ofSize: 18))
        add("Original: \(originalName)\nRevised: \(revisedName)\n", color: CGColor(gray: 0.35, alpha: 1))
        add("Compared \(Date().formatted(date: .abbreviated, time: .shortened))\n\n", color: CGColor(gray: 0.35, alpha: 1))
        if diff.changes.isEmpty {
            add("The text of both documents is the same.\n")
            return report
        }
        add("\(diff.changes.count) change\(diff.changes.count == 1 ? "" : "s"): \(diff.removedWordCount) word\(diff.removedWordCount == 1 ? "" : "s") removed, \(diff.addedWordCount) added.\n\n",
            font: .boldSystemFont(ofSize: 12))
        let red = CGColor(srgbRed: 0.78, green: 0.1, blue: 0.1, alpha: 1), green = CGColor(srgbRed: 0.05, green: 0.5, blue: 0.2, alpha: 1)
        for change in diff.changes {
            let pages = "Page \(diff.page(of: change, on: .original) + 1) → \(diff.page(of: change, on: .revised) + 1)"
            add("\(change.id + 1). \(pages)\n", font: .boldSystemFont(ofSize: 11))
            if !change.removed.isEmpty { add("− \(diff.text(of: change, on: .original))\n", color: red) }
            if !change.added.isEmpty { add("+ \(diff.text(of: change, on: .revised))\n", color: green) }
            add("\n", font: .systemFont(ofSize: 5))
        }
        return report
    }
}
