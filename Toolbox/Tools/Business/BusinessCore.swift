import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit

// MARK: - Money

/// Money helpers. Amounts are `Decimal` rupees, rounded half up to paise.
enum Money {
    static func round(_ value: Decimal, scale: Int = 2) -> Decimal {
        var input = value, result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    /// Parses typed or imported amounts like "1,234.50", "₹ 99" or "18%". Nil for anything else.
    static func parse(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard cleaned.range(of: #"^-?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A rate as a label, e.g. 18 → "18%", 0.25 → "0.25%".
    static func percent(_ rate: Decimal) -> String { "\(plain(rate))%" }

    /// The shortest plain form, e.g. 2 → "2", 1.5 → "1.5".
    static func plain(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}

// MARK: - Indian numbering

enum IndianNumber {
    /// Groups digits the Indian way: 12345678.5 → "1,23,45,678.50".
    static func format(_ value: Decimal, decimals: Int = 2) -> String {
        let rounded = Money.round(value, scale: decimals)
        let negative = rounded < 0
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.minimumIntegerDigits = 1
        let plain = formatter.string(from: NSDecimalNumber(decimal: negative ? -rounded : rounded)) ?? "0"
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        var digits = String(parts[0])
        var groups: [String] = []
        if digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
            while digits.count > 2 {
                groups.insert(String(digits.suffix(2)), at: 0)
                digits.removeLast(2)
            }
        }
        groups.insert(digits, at: 0)
        let integer = groups.joined(separator: ",")
        let fraction = parts.count > 1 ? "." + parts[1] : ""
        return (negative ? "-" : "") + integer + fraction
    }

    /// "₹1,23,456.00"
    static func rupees(_ value: Decimal) -> String {
        value < 0 ? "-₹" + format(-value) : "₹" + format(value)
    }

    /// Amount in words for invoices, e.g. 12345678.50 →
    /// "Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight and Fifty Paise Only".
    static func words(_ amount: Decimal) -> String {
        let rounded = Money.round(amount < 0 ? -amount : amount)
        var value = rounded, whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .down)
        let rupees = NSDecimalNumber(decimal: whole).uint64Value
        let paise = NSDecimalNumber(decimal: (rounded - whole) * 100).uint64Value
        var text = rupees > 0 || paise == 0 ? "Rupees " + (rupees == 0 ? "Zero" : spell(rupees)) : ""
        if paise > 0 { text += (text.isEmpty ? "" : " and ") + spell(paise) + " Paise" }
        return (amount < 0 ? "Minus " : "") + text + " Only"
    }

    private static let ones = ["", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten",
                               "Eleven", "Twelve", "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"]
    private static let tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]

    private static func belowHundred(_ n: UInt64) -> String {
        n < 20 ? ones[Int(n)] : [tens[Int(n / 10)], ones[Int(n % 10)]].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func spell(_ n: UInt64) -> String {
        var parts: [String] = []
        let crore = n / 10_000_000, rest = n % 10_000_000
        if crore > 0 { parts.append(spell(crore) + " Crore") }
        if rest / 100_000 > 0 { parts.append(belowHundred(rest / 100_000) + " Lakh") }
        if rest % 100_000 / 1000 > 0 { parts.append(belowHundred(rest % 100_000 / 1000) + " Thousand") }
        if rest % 1000 / 100 > 0 { parts.append(ones[Int(rest % 1000 / 100)] + " Hundred") }
        if rest % 100 > 0 { parts.append(belowHundred(rest % 100)) }
        return parts.joined(separator: " ")
    }
}

// MARK: - States and GSTIN

struct IndianState: Identifiable, Hashable {
    /// GST state code, e.g. "27".
    let code: String
    let name: String
    var id: String { code }
    var label: String { "\(code) · \(name)" }
    /// Union territories without a legislature charge UTGST instead of SGST.
    var chargesUTGST: Bool { ["04", "26", "31", "35", "38"].contains(code) }

    static let all: [IndianState] = [
        ("01", "Jammu and Kashmir"), ("02", "Himachal Pradesh"), ("03", "Punjab"), ("04", "Chandigarh"),
        ("05", "Uttarakhand"), ("06", "Haryana"), ("07", "Delhi"), ("08", "Rajasthan"), ("09", "Uttar Pradesh"),
        ("10", "Bihar"), ("11", "Sikkim"), ("12", "Arunachal Pradesh"), ("13", "Nagaland"), ("14", "Manipur"),
        ("15", "Mizoram"), ("16", "Tripura"), ("17", "Meghalaya"), ("18", "Assam"), ("19", "West Bengal"),
        ("20", "Jharkhand"), ("21", "Odisha"), ("22", "Chhattisgarh"), ("23", "Madhya Pradesh"), ("24", "Gujarat"),
        ("26", "Dadra and Nagar Haveli and Daman and Diu"), ("27", "Maharashtra"), ("29", "Karnataka"), ("30", "Goa"),
        ("31", "Lakshadweep"), ("32", "Kerala"), ("33", "Tamil Nadu"), ("34", "Puducherry"),
        ("35", "Andaman and Nicobar Islands"), ("36", "Telangana"), ("37", "Andhra Pradesh"), ("38", "Ladakh"),
        ("96", "Other Country (export)"), ("97", "Other Territory"),
    ].map { IndianState(code: $0.0, name: $0.1) }

    static func named(_ code: String) -> IndianState? { all.first { $0.code == code } }
}

/// GST identification numbers: 2-digit state code, PAN, entity number, a letter and a mod-36 check character.
enum GSTIN {
    enum Problem: Equatable {
        case length, characters, stateCode, checksum

        var message: String {
            switch self {
            case .length: "A GSTIN has 15 characters."
            case .characters: "A GSTIN starts with a 2-digit state code followed by letters and digits."
            case .stateCode: "The first two digits aren't a GST state code."
            case .checksum: "The last character doesn't match. Check for a typo."
            }
        }
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func normalized(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace }
    }

    /// The check character for the first 14 characters.
    static func checkCharacter(for prefix: String) -> Character? {
        let characters = Array(normalized(prefix).prefix(14))
        guard characters.count == 14 else { return nil }
        var sum = 0
        for (index, character) in characters.enumerated() {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            let product = value * (index % 2 == 0 ? 1 : 2)
            sum += product / 36 + product % 36
        }
        return alphabet[(36 - sum % 36) % 36]
    }

    /// Nil when `raw` is a valid GSTIN.
    static func validate(_ raw: String) -> Problem? {
        let value = normalized(raw)
        guard value.count == 15 else { return .length }
        guard value.range(of: #"^[0-9]{2}[0-9A-Z]{13}$"#, options: .regularExpression) != nil else { return .characters }
        guard IndianState.named(String(value.prefix(2))) != nil else { return .stateCode }
        guard checkCharacter(for: value) == value.last else { return .checksum }
        return nil
    }

    /// The state code a GSTIN was issued in, once its first two characters are typed.
    static func stateCode(of raw: String) -> String? {
        let prefix = String(normalized(raw).prefix(2))
        return IndianState.named(prefix)?.code
    }
}

// MARK: - Tax math

enum GSTRates {
    /// Rates offered in pickers. Most goods and services moved to 5% and 18% in September 2025, with 40% for
    /// luxury and sin goods. 12% and 28% stay available for older invoices and cess-era items.
    static let all: [Decimal] = [0, Decimal(string: "0.25")!, 3, 5, 12, 18, 28, 40]
    static let standard: Decimal = 18
}

/// One line's tax, after discounts.
struct GSTBreakdown: Equatable {
    var taxable: Decimal = 0
    var cgst: Decimal = 0
    var sgst: Decimal = 0
    var igst: Decimal = 0
    var tax: Decimal { cgst + sgst + igst }
    var total: Decimal { taxable + tax }

    static func + (lhs: GSTBreakdown, rhs: GSTBreakdown) -> GSTBreakdown {
        GSTBreakdown(taxable: lhs.taxable + rhs.taxable, cgst: lhs.cgst + rhs.cgst, sgst: lhs.sgst + rhs.sgst, igst: lhs.igst + rhs.igst)
    }
}

enum GSTMath {
    /// Splits `net` (the amount after discounts) into taxable value and tax.
    ///
    /// Tax-exclusive amounts are the taxable value. Tax-inclusive amounts are back-calculated so the line
    /// still totals exactly `net`. Intra-state tax is split into equal CGST and SGST halves.
    static func breakdown(net: Decimal, rate: Decimal, inclusive: Bool, interState: Bool) -> GSTBreakdown {
        if inclusive {
            let taxable = Money.round(net * 100 / (100 + rate))
            if interState { return GSTBreakdown(taxable: taxable, igst: Money.round(net) - taxable) }
            let half = Money.round((Money.round(net) - taxable) / 2)
            return GSTBreakdown(taxable: Money.round(net) - half * 2, cgst: half, sgst: half)
        }
        let taxable = Money.round(net)
        if interState { return GSTBreakdown(taxable: taxable, igst: Money.round(taxable * rate / 100)) }
        let half = Money.round(taxable * rate / 200)
        return GSTBreakdown(taxable: taxable, cgst: half, sgst: half)
    }

    /// The amount to add to `total` so it becomes a whole number of rupees.
    static func roundOff(_ total: Decimal) -> Decimal { Money.round(total, scale: 0) - total }
}

// MARK: - Storage

/// JSON files the business tools keep in Application Support. Stores take their folder, so tests use temp folders.
enum BusinessStorage {
    static func defaultFolder(_ name: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Toolbox", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Downscales a picked logo or signature and stores it as PNG.
    static func pngData(fromImageAt url: URL, maxPixelSize: Int = 600) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary),
              let data = PDFOps.encode(image, as: .png, quality: 1, dpi: nil) else { throw ToolError.unreadableInput(url) }
        return data
    }

    static func cgImage(_ data: Data?) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - CSV

enum BusinessCSV {
    static func field(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    static func line(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") }

    /// Rows of an RFC 4180 CSV (quoted fields, doubled quotes, CRLF or LF).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
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
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                row.append(field); field = ""
            } else if character.isNewline {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }
}

// MARK: - UPI and QR

enum UPI {
    /// A UPI payment link, e.g. upi://pay?pa=shop@upi&pn=Shop&am=120.00&cu=INR.
    static func link(payee: String, name: String, amount: Decimal?, note: String? = nil) -> String? {
        let vpa = payee.trimmingCharacters(in: .whitespaces)
        guard vpa.contains("@") else { return nil }
        var components = URLComponents()
        components.scheme = "upi"
        components.host = "pay"
        var items = [URLQueryItem(name: "pa", value: vpa), URLQueryItem(name: "pn", value: name)]
        if let amount, amount > 0 { items.append(URLQueryItem(name: "am", value: IndianNumber.format(amount).replacingOccurrences(of: ",", with: ""))) }
        items.append(URLQueryItem(name: "cu", value: "INR"))
        if let note, !note.isEmpty { items.append(URLQueryItem(name: "tn", value: note)) }
        components.queryItems = items
        return components.string
    }
}

enum QRCode {
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

// MARK: - PDF drawing

/// Draws business documents top-down in points. Text is real, selectable text.
///
/// Created without a context it only measures, so a first pass can count pages (for "Page 1 of 2")
/// or find the height of a variable-length receipt.
final class BusinessPDFCanvas {
    private(set) var pageSize: CGSize
    private let context: CGContext?
    private var graphics: NSGraphicsContext?
    private(set) var pageCount = 0
    private var pageOpen = false

    /// Measures only.
    init(pageSize: CGSize) {
        self.pageSize = pageSize
        self.context = nil
    }

    init(pageSize: CGSize, context: CGContext) {
        self.pageSize = pageSize
        self.context = context
    }

    var isMeasuring: Bool { context == nil }

    func beginPage(size: CGSize? = nil) {
        if pageOpen { endPage() }
        if let size { pageSize = size }
        pageCount += 1
        pageOpen = true
        guard let context else { return }
        var box = CGRect(origin: .zero, size: pageSize)
        context.beginPDFPage(PDFOps.pageInfo(mediaBox: &box))
        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        graphics = NSGraphicsContext(cgContext: context, flipped: true)
    }

    func endPage() {
        guard pageOpen else { return }
        pageOpen = false
        guard let context else { return }
        context.restoreGState()
        context.endPDFPage()
        graphics = nil
    }

    private func withGraphics(_ body: () -> Void) {
        guard let graphics else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black,
                     alignment: NSTextAlignment = .left, monospaced: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return ceil(text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// Draws `text` wrapped to the rect's width, starting at its top. Returns the height used.
    @discardableResult
    func draw(_ text: NSAttributedString, at origin: CGPoint, width: CGFloat) -> CGFloat {
        let height = height(of: text, width: width)
        withGraphics {
            text.draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        return height
    }

    func fill(_ rect: CGRect, color: NSColor) {
        guard let context else { return }
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    func line(from start: CGPoint, to end: CGPoint, color: NSColor = .black, width: CGFloat = 0.5, dash: [CGFloat] = []) {
        guard let context else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineDash(phase: 0, lengths: dash)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    func stroke(_ rect: CGRect, color: NSColor = .black, width: CGFloat = 0.5) {
        guard let context else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.stroke(rect)
    }

    /// Draws `image` aspect-fit in `rect`, upright. Returns the drawn rect.
    @discardableResult
    func draw(_ image: CGImage, fitting rect: CGRect, alignment: NSTextAlignment = .left, crisp: Bool = false) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let x: CGFloat = switch alignment {
        case .center: rect.midX - size.width / 2
        case .right: rect.maxX - size.width
        default: rect.minX
        }
        let target = CGRect(x: x, y: rect.minY, width: size.width, height: size.height)
        guard let context else { return target }
        context.saveGState()
        if crisp { context.interpolationQuality = .none }
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
        return target
    }

    /// Renders pages drawn by `body` into PDF data. `body` runs once to measure and once to draw, so
    /// it can print the page count it gets.
    static func render(pageSize: CGSize, _ body: (BusinessPDFCanvas, _ totalPages: Int) throws -> Void) throws -> Data {
        let measure = BusinessPDFCanvas(pageSize: pageSize)
        try body(measure, 0)
        measure.endPage()
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ToolError.failed("Couldn't create the PDF.") }
        let canvas = BusinessPDFCanvas(pageSize: pageSize, context: context)
        try body(canvas, measure.pageCount)
        canvas.endPage()
        context.closePDF()
        return data as Data
    }
}

// MARK: - Printing

@MainActor
enum BusinessPrinting {
    /// Shows the print panel for a rendered PDF, on paper the size of its first page with no margins.
    static func printPDF(_ data: Data, jobTitle: String) {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = page.bounds(for: .mediaBox).size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
