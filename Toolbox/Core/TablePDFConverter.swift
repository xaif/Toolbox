import AppKit
import CoreText

/// CSV/TSV → PDF tables drawn natively: header detection, measured column widths, zebra rows,
/// the header repeated on every page and landscape pages for wide tables.
enum TablePDFConverter {
    static func convert(_ input: URL, to output: URL) throws {
        let data = try Data(contentsOf: input)
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ToolError.unreadableInput(input)
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let separator = input.pathExtension.lowercased() == "tsv" ? "\t" : delimiter(in: text)
        let rows = parse(text, delimiter: separator)
        guard !rows.isEmpty else { throw ToolError.failed("“\(input.lastPathComponent)” has no rows.") }
        try render(rows, header: hasHeader(rows), title: input.deletingPathExtension().lastPathComponent, to: output)
    }

    // MARK: - Parsing

    /// The most consistent of `,` `;` tab and `|` across the first lines, ignoring quoted text.
    static func delimiter(in text: String) -> Character {
        let sample = text.split(whereSeparator: \.isNewline).prefix(20)
        var best: (Character, Int) = (",", -1)
        for candidate in [",", ";", "\t", "|"] as [Character] {
            let counts = sample.map { line -> Int in
                var count = 0, quoted = false
                for character in line {
                    if character == "\"" { quoted.toggle() } else if character == candidate, !quoted { count += 1 }
                }
                return count
            }
            guard let first = counts.first, first > 0 else { continue }
            let score = counts.filter { $0 == first }.count * 10 + first
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }

    /// RFC 4180: quoted fields may contain the delimiter, newlines and doubled quotes. Rows are padded
    /// to the same width; trailing blank rows are dropped.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        while let last = rows.last, last.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.removeLast() }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    static func isNumber(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[,$€£¥₹%\\s]", with: "", options: .regularExpression)
        return !cleaned.isEmpty && Double(cleaned) != nil
    }

    /// Like Python's csv.Sniffer: a column votes for a header when its first cell differs in kind
    /// (text above numbers) or length from the cells below. All-text tables get a header when the
    /// first row is filled in, unique and has no numbers.
    static func hasHeader(_ rows: [[String]]) -> Bool {
        guard rows.count > 1, let first = rows.first else { return false }
        let body = rows.dropFirst().prefix(50)
        var votes = 0
        for column in first.indices {
            let cells = body.map { $0[column] }.filter { !$0.isEmpty }
            guard !cells.isEmpty else { continue }
            if cells.allSatisfy(isNumber) {
                votes += isNumber(first[column]) ? -1 : 1
            } else if let length = cells.first?.count, cells.allSatisfy({ $0.count == length }) {
                votes += first[column].count == length ? -1 : 1
            }
        }
        if votes != 0 { return votes > 0 }
        let filled = first.map { $0.trimmingCharacters(in: .whitespaces) }
        return filled.allSatisfy { !$0.isEmpty && !isNumber($0) } && Set(filled).count == filled.count
    }

    // MARK: - Rendering

    private static let margin: CGFloat = 36
    private static let padding = CGSize(width: 6, height: 4)

    static func render(_ rows: [[String]], header: Bool, title: String, to output: URL) throws {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { throw ToolError.failed("The table is empty.") }
        let body = header ? Array(rows.dropFirst()) : rows
        let headerRow = header ? rows.first : nil
        let numeric = (0..<columnCount).map { column in
            let cells = body.prefix(200).map { $0[column] }.filter { !$0.isEmpty }
            return !cells.isEmpty && cells.filter(isNumber).count * 10 >= cells.count * 9
        }

        let portrait = PDFPageSetup.Paper.a4.size
        var fontSize: CGFloat = 9
        var natural = naturalWidths(rows, fontSize: fontSize)
        var pageSize = portrait
        if natural.reduce(0, +) > portrait.width - margin * 2 { pageSize = CGSize(width: portrait.height, height: portrait.width) }
        if natural.reduce(0, +) > (pageSize.width - margin * 2) * 1.6 {
            fontSize = 7
            natural = naturalWidths(rows, fontSize: fontSize)
        }
        let widths = fit(natural, into: pageSize.width - margin * 2)
        let fonts = (regular: NSFont.systemFont(ofSize: fontSize), bold: NSFont.boldSystemFont(ofSize: fontSize))

        func height(of row: [String], font: NSFont) -> CGFloat {
            row.enumerated().map { column, text in
                cellSize(text, font: font, width: widths[column] - padding.width * 2).height
            }.max().map { $0 + padding.height * 2 } ?? 0
        }

        // Paginate first so every page can say "Page x of y".
        let titleHeight: CGFloat = 28
        let headerHeight = headerRow.map { height(of: $0, font: fonts.bold) } ?? 0
        let footerHeight: CGFloat = 18
        var pages: [[(row: [String], index: Int, height: CGFloat)]] = [[]]
        var used = titleHeight + headerHeight
        let available = pageSize.height - margin * 2 - footerHeight
        for (index, row) in body.enumerated() {
            let rowHeight = min(height(of: row, font: fonts.regular), available - headerHeight - titleHeight)
            if used + rowHeight > available, !(pages.last?.isEmpty ?? true) {
                pages.append([])
                used = headerHeight
            }
            pages[pages.count - 1].append((row, index, rowHeight))
            used += rowHeight
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, [kCGPDFContextTitle: title] as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(output.lastPathComponent)”.")
        }
        let grid = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor
        for (pageIndex, page) in pages.enumerated() {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            var top = margin
            if pageIndex == 0 {
                draw(title, font: .boldSystemFont(ofSize: 13), color: .black,
                     in: CGRect(x: margin, y: top, width: pageSize.width - margin * 2, height: 20), pageHeight: pageSize.height, context: context)
                top += titleHeight
            }
            func drawRow(_ cells: [String], height: CGFloat, font: NSFont, fill: NSColor?) {
                var x = margin
                let rowRect = CGRect(x: margin, y: top, width: widths.reduce(0, +), height: height)
                if let fill {
                    context.setFillColor(fill.cgColor)
                    context.fill(flipped(rowRect, pageHeight: pageSize.height))
                }
                for (column, text) in cells.enumerated() where column < widths.count {
                    let cell = CGRect(x: x + padding.width, y: top + padding.height,
                                      width: widths[column] - padding.width * 2, height: height - padding.height * 2)
                    draw(text, font: font, color: .black, in: cell, pageHeight: pageSize.height, context: context,
                         alignment: numeric[column] && font == fonts.regular ? .right : .left)
                    x += widths[column]
                }
                context.setStrokeColor(grid)
                context.setLineWidth(0.5)
                context.stroke(flipped(rowRect, pageHeight: pageSize.height))
                var divider = margin
                for width in widths.dropLast() {
                    divider += width
                    context.move(to: CGPoint(x: divider, y: pageSize.height - top))
                    context.addLine(to: CGPoint(x: divider, y: pageSize.height - top - height))
                }
                context.strokePath()
                top += height
            }
            if let headerRow { drawRow(headerRow, height: headerHeight, font: fonts.bold, fill: NSColor(calibratedWhite: 0.91, alpha: 1)) }
            for entry in page {
                drawRow(entry.row, height: entry.height, font: fonts.regular,
                        fill: entry.index % 2 == 1 ? NSColor(calibratedWhite: 0.965, alpha: 1) : nil)
            }
            let footer = pages.count > 1 ? "Page \(pageIndex + 1) of \(pages.count)" : ""
            draw(footer, font: .systemFont(ofSize: 8), color: .gray,
                 in: CGRect(x: margin, y: pageSize.height - margin - 10, width: pageSize.width - margin * 2, height: 12),
                 pageHeight: pageSize.height, context: context, alignment: .center)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Single-line widths, capped so one long cell can't take the whole page.
    private static func naturalWidths(_ rows: [[String]], fontSize: CGFloat) -> [CGFloat] {
        let columnCount = rows.map(\.count).max() ?? 0
        let regular = NSFont.systemFont(ofSize: fontSize), bold = NSFont.boldSystemFont(ofSize: fontSize)
        return (0..<columnCount).map { column in
            let widest = rows.prefix(500).enumerated().map { index, row -> CGFloat in
                let text = column < row.count ? row[column] : ""
                return (text as NSString).size(withAttributes: [.font: index == 0 ? bold : regular]).width
            }.max() ?? 0
            return min(max(widest, fontSize * 2), 260) + padding.width * 2 + 1
        }
    }

    /// Shrinks the widest columns first until the table fits, so narrow columns never wrap.
    static func fit(_ natural: [CGFloat], into total: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > total else { return natural }
        var widths = natural
        var remaining = total
        var open = Set(widths.indices)
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let small = open.filter { widths[$0] <= share }
            if small.isEmpty {
                for index in open { widths[index] = share }
                break
            }
            for index in small { remaining -= widths[index]; open.remove(index) }
        }
        return widths
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func cellSize(_ text: String, font: NSFont, width: CGFloat) -> CGSize {
        guard !text.isEmpty else { return CGSize(width: 0, height: font.ascender - font.descender) }
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, color: .black, alignment: .left))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
        return CGSize(width: size.width, height: ceil(size.height))
    }

    private static func flipped(_ rect: CGRect, pageHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Draws wrapped text in a rect given in top-left coordinates; overflow is clipped.
    private static func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, pageHeight: CGFloat,
                             context: CGContext, alignment: NSTextAlignment = .left) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, color: color, alignment: alignment))
        let path = CGPath(rect: flipped(rect, pageHeight: pageHeight).insetBy(dx: 0, dy: -1), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
    }
}
