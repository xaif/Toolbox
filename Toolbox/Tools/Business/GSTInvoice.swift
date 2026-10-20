import AppKit

// MARK: - Model

struct GSTParty: Codable, Hashable {
    var name = ""
    var address = ""
    var gstin = ""
    /// GST state code, e.g. "27".
    var stateCode = "27"
    var phone = ""
    var email = ""

    var state: IndianState? { IndianState.named(stateCode) }
}

/// The seller's saved details, reused for every new invoice.
struct GSTSellerProfile: Codable, Hashable {
    var party = GSTParty()
    var bankName = ""
    var accountName = ""
    var accountNumber = ""
    var ifsc = ""
    var upiID = ""
    /// Prints a UPI QR code for the invoice total.
    var showsUPIQR = true
    var logoPNG: Data?
    var signaturePNG: Data?
    var invoicePrefix = "INV-"
    var nextNumber = 1
    var terms = "Goods once sold will not be taken back. Interest @18% p.a. will be charged if payment is delayed beyond the due date."

    var nextInvoiceNumber: String { invoicePrefix + String(format: "%04d", nextNumber) }
}

struct GSTLineItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var description = ""
    var hsn = ""
    var quantity: Decimal = 1
    var unit = "Nos"
    var rate: Decimal = 0
    var discountPercent: Decimal = 0
    var gstRate: Decimal = GSTRates.standard
}

struct GSTInvoice: Codable, Hashable, Identifiable {
    enum Copy: String, Codable, CaseIterable, Identifiable {
        case original, duplicate, triplicate
        var id: Self { self }
        var label: String {
            switch self {
            case .original: "Original for Recipient"
            case .duplicate: "Duplicate for Transporter"
            case .triplicate: "Triplicate for Supplier"
            }
        }
    }

    var id = UUID()
    var number = ""
    var date = Date()
    var dueDate: Date?
    var seller = GSTSellerProfile()
    var buyer = GSTParty(stateCode: "")
    /// State code of the place of supply. Matching the seller's state means CGST + SGST, otherwise IGST.
    var placeOfSupply = "27"
    var items: [GSTLineItem] = [GSTLineItem()]
    var pricesIncludeTax = false
    var roundsTotal = true
    var reverseCharge = false
    var copy = Copy.original
    var notes = ""
    var modified = Date()

    var isInterState: Bool { seller.party.stateCode != placeOfSupply }
}

// MARK: - Totals

struct GSTInvoiceTotals {
    struct Line {
        var gross: Decimal
        var discount: Decimal
        var tax: GSTBreakdown
    }

    struct HSNRow: Identifiable {
        var hsn: String
        var rate: Decimal
        var tax: GSTBreakdown
        var id: String { "\(hsn)|\(rate)" }
    }

    var lines: [Line]
    var sum: GSTBreakdown
    var roundOff: Decimal
    var grandTotal: Decimal
    var isInterState: Bool
    /// "SGST", or "UTGST" when the place of supply is a union territory without a legislature.
    var stateTaxName: String
    var hsnSummary: [HSNRow]
    var totalQuantity: Decimal

    init(_ invoice: GSTInvoice) {
        isInterState = invoice.isInterState
        stateTaxName = IndianState.named(invoice.placeOfSupply)?.chargesUTGST == true ? "UTGST" : "SGST"
        lines = invoice.items.map { item in
            let gross = Money.round(item.quantity * item.rate)
            let discount = Money.round(gross * item.discountPercent / 100)
            let tax = GSTMath.breakdown(net: gross - discount, rate: item.gstRate,
                                        inclusive: invoice.pricesIncludeTax, interState: invoice.isInterState)
            return Line(gross: gross, discount: discount, tax: tax)
        }
        sum = lines.reduce(GSTBreakdown()) { $0 + $1.tax }
        roundOff = invoice.roundsTotal ? GSTMath.roundOff(sum.total) : 0
        grandTotal = sum.total + roundOff
        totalQuantity = invoice.items.reduce(0) { $0 + $1.quantity }
        var rows: [String: HSNRow] = [:]
        var order: [String] = []
        for (item, line) in zip(invoice.items, lines) {
            let key = "\(item.hsn)|\(item.gstRate)"
            if rows[key] == nil { order.append(key) }
            let row = rows[key] ?? HSNRow(hsn: item.hsn, rate: item.gstRate, tax: GSTBreakdown())
            rows[key] = HSNRow(hsn: row.hsn, rate: row.rate, tax: row.tax + line.tax)
        }
        hsnSummary = order.compactMap { rows[$0] }
    }
}

// MARK: - Problems

extension GSTInvoice {
    /// What has to be fixed before the invoice can be exported. Empty when it's ready.
    var problems: [String] {
        var result: [String] = []
        if seller.party.name.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Enter the seller's name.") }
        if !seller.party.gstin.isEmpty, let problem = GSTIN.validate(seller.party.gstin) { result.append("Seller GSTIN: " + problem.message) }
        if !buyer.gstin.isEmpty, let problem = GSTIN.validate(buyer.gstin) { result.append("Buyer GSTIN: " + problem.message) }
        if buyer.name.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Enter the buyer's name.") }
        if number.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Enter an invoice number.") }
        if number.count > 16 { result.append("GST invoice numbers can have at most 16 characters.") }
        if IndianState.named(placeOfSupply) == nil { result.append("Choose the place of supply.") }
        let filled = items.filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }
        if filled.isEmpty { result.append("Add at least one item.") }
        if items.contains(where: { $0.quantity <= 0 || $0.rate < 0 || $0.discountPercent < 0 || $0.discountPercent > 100 }) {
            result.append("Quantities must be positive and discounts between 0 and 100%.")
        }
        return result
    }
}

// MARK: - Storage

/// The seller profile and invoice drafts, as JSON in Application Support/Toolbox/Invoices.
@MainActor
@Observable
final class GSTInvoiceStore {
    static let shared = GSTInvoiceStore(folder: BusinessStorage.defaultFolder("Invoices"))

    let folder: URL
    var profile: GSTSellerProfile
    private(set) var drafts: [GSTInvoice] = []
    /// The invoice being edited. Kept here, and on disk, so it survives switching tools and relaunching.
    var working = GSTInvoice()

    init(folder: URL) {
        self.folder = folder
        profile = BusinessStorage.load(GSTSellerProfile.self, from: folder.appendingPathComponent("profile.json")) ?? GSTSellerProfile()
        working = BusinessStorage.load(GSTInvoice.self, from: folder.appendingPathComponent("working.json")) ?? GSTInvoice()
        if working.number.isEmpty { working = newInvoice() }
        reloadDrafts()
    }

    private var draftsFolder: URL { folder.appendingPathComponent("Drafts", isDirectory: true) }

    func saveWorking() {
        try? BusinessStorage.save(working, to: folder.appendingPathComponent("working.json"))
    }

    func startNew() {
        working = newInvoice()
        saveWorking()
    }

    func saveProfile(_ profile: GSTSellerProfile) throws {
        self.profile = profile
        try BusinessStorage.save(profile, to: folder.appendingPathComponent("profile.json"))
    }

    /// A blank invoice from the saved seller profile, with the next number.
    func newInvoice() -> GSTInvoice {
        var invoice = GSTInvoice()
        invoice.seller = profile
        invoice.number = profile.nextInvoiceNumber
        invoice.placeOfSupply = profile.party.stateCode
        return invoice
    }

    func saveDraft(_ invoice: GSTInvoice) throws {
        var invoice = invoice
        invoice.modified = Date()
        try BusinessStorage.save(invoice, to: draftsFolder.appendingPathComponent("\(invoice.id.uuidString).json"))
        reloadDrafts()
    }

    func deleteDraft(_ invoice: GSTInvoice) {
        try? FileManager.default.removeItem(at: draftsFolder.appendingPathComponent("\(invoice.id.uuidString).json"))
        reloadDrafts()
    }

    /// Moves the counter past `invoice`'s number once it's exported, if it used the next number.
    func didIssue(_ invoice: GSTInvoice) {
        guard invoice.number == profile.nextInvoiceNumber else { return }
        var updated = profile
        updated.nextNumber += 1
        try? saveProfile(updated)
        if working.id == invoice.id { working.seller.nextNumber = updated.nextNumber }
    }

    func reloadDrafts() {
        let files = (try? FileManager.default.contentsOfDirectory(at: draftsFolder, includingPropertiesForKeys: nil)) ?? []
        drafts = files.filter { $0.pathExtension == "json" }
            .compactMap { BusinessStorage.load(GSTInvoice.self, from: $0) }
            .sorted { $0.modified > $1.modified }
    }
}

// MARK: - PDF

enum GSTInvoicePDF {
    static let a4 = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 36
    private static let accent = NSColor(red: 0.10, green: 0.42, blue: 0.42, alpha: 1)
    private static let rule = NSColor(white: 0.75, alpha: 1)
    private static let shade = NSColor(white: 0.94, alpha: 1)

    /// The invoice as A4 PDF data. `copies` prints one set of pages per copy label.
    static func render(_ invoice: GSTInvoice, copies: [GSTInvoice.Copy]? = nil) throws -> Data {
        let totals = GSTInvoiceTotals(invoice)
        let labels = copies ?? [invoice.copy]
        return try BusinessPDFCanvas.render(pageSize: a4) { canvas, totalPages in
            for copy in labels {
                var layout = Layout(invoice: invoice, totals: totals, copy: copy, canvas: canvas,
                                    totalPages: totalPages / max(labels.count, 1))
                layout.draw()
            }
        }
    }

    private typealias T = BusinessPDFCanvas

    private struct Layout {
        let invoice: GSTInvoice
        let totals: GSTInvoiceTotals
        let copy: GSTInvoice.Copy
        let canvas: BusinessPDFCanvas
        let totalPages: Int
        var y: CGFloat = 0
        var page = 0

        init(invoice: GSTInvoice, totals: GSTInvoiceTotals, copy: GSTInvoice.Copy, canvas: BusinessPDFCanvas, totalPages: Int) {
            self.invoice = invoice
            self.totals = totals
            self.copy = copy
            self.canvas = canvas
            self.totalPages = totalPages
        }

        private var width: CGFloat { a4.width - margin * 2 }
        private var bottom: CGFloat { a4.height - margin - 22 }

        mutating func draw() {
            newPage()
            header()
            parties()
            itemsTable()
            totalsBlock()
            hsnTable()
            footerBlock()
        }

        // MARK: Pages

        private mutating func newPage() {
            canvas.beginPage(size: a4)
            page += 1
            y = margin
            let label = T.text(copy.label.uppercased(), size: 7.5, weight: .semibold, color: .darkGray, alignment: .right)
            canvas.draw(label, at: CGPoint(x: margin, y: margin - 16), width: width)
            let footer = T.text("This is a computer-generated invoice." + (totalPages > 1 ? "   Page \(page) of \(totalPages)" : ""),
                                size: 7, color: .gray, alignment: .center)
            canvas.draw(footer, at: CGPoint(x: margin, y: a4.height - margin), width: width)
            if page > 1 {
                let title = T.text("Tax Invoice \(invoice.number) (continued)", size: 9, weight: .semibold)
                y += canvas.draw(title, at: CGPoint(x: margin, y: y), width: width) + 8
            }
        }

        /// Starts a new page unless `height` more points fit on this one.
        private mutating func reserve(_ height: CGFloat) {
            if y + height > bottom { newPage() }
        }

        // MARK: Header

        private mutating func header() {
            let seller = invoice.seller
            var textX = margin
            var logoHeight: CGFloat = 0
            if let logo = BusinessStorage.cgImage(seller.logoPNG) {
                let rect = canvas.draw(logo, fitting: CGRect(x: margin, y: y, width: 90, height: 54))
                textX = rect.maxX + 12
                logoHeight = rect.height
            }
            let sellerWidth = width * 0.58 - (textX - margin)
            var top = y
            top += canvas.draw(T.text(seller.party.name, size: 15, weight: .bold, color: accent), at: CGPoint(x: textX, y: top), width: sellerWidth)
            var lines: [String] = []
            if !seller.party.address.isEmpty { lines.append(seller.party.address) }
            let contact = [seller.party.phone, seller.party.email].filter { !$0.isEmpty }.joined(separator: " · ")
            if !contact.isEmpty { lines.append(contact) }
            if !seller.party.gstin.isEmpty { lines.append("GSTIN: \(GSTIN.normalized(seller.party.gstin))") }
            if let state = seller.party.state { lines.append("State: \(state.name) (\(state.code))") }
            top += 2 + canvas.draw(T.text(lines.joined(separator: "\n"), size: 8.5, color: .darkGray), at: CGPoint(x: textX, y: top), width: sellerWidth)

            let metaX = margin + width * 0.6
            let metaWidth = width * 0.4
            var right = y
            right += canvas.draw(T.text("TAX INVOICE", size: 17, weight: .heavy, alignment: .right), at: CGPoint(x: metaX, y: right), width: metaWidth) + 4
            var meta: [(String, String)] = [("Invoice No.", invoice.number), ("Invoice Date", date(invoice.date))]
            if let due = invoice.dueDate { meta.append(("Due Date", date(due))) }
            let place = IndianState.named(invoice.placeOfSupply).map { "\($0.name) (\($0.code))" } ?? "—"
            meta.append(("Place of Supply", place))
            meta.append(("Reverse Charge", invoice.reverseCharge ? "Yes" : "No"))
            for (key, value) in meta {
                let h = canvas.draw(T.text(key, size: 8.5, color: .darkGray), at: CGPoint(x: metaX, y: right), width: metaWidth * 0.45)
                let v = canvas.draw(T.text(value, size: 8.5, weight: .semibold, alignment: .right), at: CGPoint(x: metaX + metaWidth * 0.4, y: right), width: metaWidth * 0.6)
                right += max(h, v) + 2
            }
            y = max(top, right, y + logoHeight) + 12
            canvas.line(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + width, y: y), color: accent, width: 1.2)
            y += 10
        }

        private mutating func parties() {
            let buyer = invoice.buyer
            let columnWidth = (width - 16) / 2
            func block(_ title: String, _ lines: [String], x: CGFloat) -> CGFloat {
                var top = y
                top += canvas.draw(T.text(title, size: 7.5, weight: .bold, color: accent), at: CGPoint(x: x, y: top), width: columnWidth) + 2
                top += canvas.draw(T.text(lines.first ?? "", size: 10, weight: .semibold), at: CGPoint(x: x, y: top), width: columnWidth) + 1
                top += canvas.draw(T.text(lines.dropFirst().joined(separator: "\n"), size: 8.5, color: .darkGray), at: CGPoint(x: x, y: top), width: columnWidth)
                return top
            }
            var billTo = [buyer.name]
            if !buyer.address.isEmpty { billTo.append(buyer.address) }
            let contact = [buyer.phone, buyer.email].filter { !$0.isEmpty }.joined(separator: " · ")
            if !contact.isEmpty { billTo.append(contact) }
            billTo.append(buyer.gstin.isEmpty ? "GSTIN: Unregistered" : "GSTIN: \(GSTIN.normalized(buyer.gstin))")
            if let state = buyer.state { billTo.append("State: \(state.name) (\(state.code))") }
            let left = block("BILL TO", billTo, x: margin)
            var supply = [IndianState.named(invoice.placeOfSupply)?.name ?? "—"]
            supply.append(totals.isInterState ? "Inter-state supply · IGST" : "Intra-state supply · CGST + \(totals.stateTaxName)")
            supply.append(invoice.pricesIncludeTax ? "Rates include GST" : "Rates exclude GST")
            let right = block("PLACE OF SUPPLY", supply, x: margin + columnWidth + 16)
            y = max(left, right) + 14
        }

        // MARK: Items

        private struct Column {
            let title: String
            let width: CGFloat
            let alignment: NSTextAlignment
        }

        private var columns: [Column] {
            let fixed: [Column] = [
                Column(title: "#", width: 18, alignment: .left),
                Column(title: "Item", width: 0, alignment: .left),
                Column(title: "HSN/SAC", width: 48, alignment: .left),
                Column(title: "Qty", width: 46, alignment: .right),
                Column(title: "Rate", width: 56, alignment: .right),
                Column(title: "Disc.", width: 32, alignment: .right),
                Column(title: "Taxable", width: 62, alignment: .right),
                Column(title: "GST", width: 34, alignment: .right),
                Column(title: "Tax", width: 52, alignment: .right),
                Column(title: "Amount", width: 64, alignment: .right),
            ]
            let flexible = width - fixed.reduce(0) { $0 + $1.width } - CGFloat(fixed.count - 1) * 4
            return fixed.map { $0.width == 0 ? Column(title: $0.title, width: flexible, alignment: $0.alignment) : $0 }
        }

        private mutating func tableHeader() {
            let cells = columns
            let height: CGFloat = 16
            canvas.fill(CGRect(x: margin, y: y, width: width, height: height), color: accent)
            var x = margin
            for column in cells {
                canvas.draw(T.text(column.title, size: 7.5, weight: .bold, color: .white, alignment: column.alignment),
                            at: CGPoint(x: x + 2, y: y + 3.5), width: column.width - 4)
                x += column.width + 4
            }
            y += height + 3
        }

        private mutating func itemsTable() {
            tableHeader()
            let cells = columns
            let items = invoice.items.enumerated().filter { !$0.element.description.trimmingCharacters(in: .whitespaces).isEmpty }
            for (row, (index, item)) in items.enumerated() {
                let line = totals.lines[index]
                let quantity = Money.plain(item.quantity) + (item.unit.isEmpty ? "" : " " + item.unit)
                let values = ["\(row + 1)", item.description, item.hsn, quantity, IndianNumber.format(item.rate),
                              item.discountPercent > 0 ? Money.percent(item.discountPercent) : "—",
                              IndianNumber.format(line.tax.taxable), Money.percent(item.gstRate),
                              IndianNumber.format(line.tax.tax), IndianNumber.format(line.tax.total)]
                let texts = zip(values, cells).map { T.text($0, size: 8, weight: $1.title == "Amount" ? .semibold : .regular, alignment: $1.alignment) }
                let height = zip(texts, cells).map { canvas.height(of: $0, width: $1.width - 4) }.max() ?? 10
                if y + height + 6 > bottom {
                    newPage()
                    tableHeader()
                }
                if row % 2 == 1 { canvas.fill(CGRect(x: margin, y: y - 2, width: width, height: height + 5), color: shade) }
                var x = margin
                for (text, column) in zip(texts, cells) {
                    canvas.draw(text, at: CGPoint(x: x + 2, y: y), width: column.width - 4)
                    x += column.width + 4
                }
                y += height + 5
            }
            canvas.line(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + width, y: y), color: rule)
            y += 4
            let quantity = T.text("Total quantity: \(Money.plain(totals.totalQuantity))", size: 8, color: .darkGray)
            y += canvas.draw(quantity, at: CGPoint(x: margin, y: y), width: width / 2) + 10
        }

        // MARK: Totals

        private mutating func totalsBlock() {
            var rows: [(String, Decimal)] = [("Taxable Value", totals.sum.taxable)]
            if totals.isInterState {
                rows.append(("IGST", totals.sum.igst))
            } else {
                rows.append(("CGST", totals.sum.cgst))
                rows.append((totals.stateTaxName, totals.sum.sgst))
            }
            if totals.roundOff != 0 { rows.append(("Round Off", totals.roundOff)) }
            let height = CGFloat(rows.count) * 14 + 26
            reserve(height + 30)
            let boxX = margin + width * 0.58
            let boxWidth = width * 0.42
            var right = y
            for (label, value) in rows {
                canvas.draw(T.text(label, size: 8.5, color: .darkGray), at: CGPoint(x: boxX, y: right), width: boxWidth / 2)
                canvas.draw(T.text(IndianNumber.format(value), size: 8.5, alignment: .right), at: CGPoint(x: boxX + boxWidth / 2, y: right), width: boxWidth / 2)
                right += 14
            }
            canvas.fill(CGRect(x: boxX - 6, y: right, width: boxWidth + 6, height: 22), color: accent)
            canvas.draw(T.text("Total", size: 10.5, weight: .bold, color: .white), at: CGPoint(x: boxX, y: right + 4.5), width: boxWidth / 2)
            canvas.draw(T.text(IndianNumber.rupees(totals.grandTotal), size: 10.5, weight: .bold, color: .white, alignment: .right),
                        at: CGPoint(x: boxX + boxWidth / 2 - 4, y: right + 4.5), width: boxWidth / 2)
            right += 26

            let wordsWidth = width * 0.54
            var left = y
            left += canvas.draw(T.text("AMOUNT IN WORDS", size: 7.5, weight: .bold, color: accent), at: CGPoint(x: margin, y: left), width: wordsWidth) + 2
            left += canvas.draw(T.text(IndianNumber.words(totals.grandTotal), size: 9, weight: .semibold), at: CGPoint(x: margin, y: left), width: wordsWidth) + 6
            if totals.sum.tax > 0 {
                left += canvas.draw(T.text("Tax amount: " + IndianNumber.words(totals.sum.tax), size: 7.5, color: .darkGray),
                                    at: CGPoint(x: margin, y: left), width: wordsWidth)
            }
            if invoice.reverseCharge {
                left += 4 + canvas.draw(T.text("Tax is payable on reverse charge basis.", size: 7.5, weight: .semibold),
                                        at: CGPoint(x: margin, y: left + 4), width: wordsWidth)
            }
            y = max(left, right) + 14
        }

        private mutating func hsnTable() {
            guard !totals.hsnSummary.isEmpty else { return }
            let inter = totals.isInterState
            let titles = inter ? ["HSN/SAC", "Taxable Value", "IGST Rate", "IGST", "Total Tax"]
                : ["HSN/SAC", "Taxable Value", "CGST Rate", "CGST", "\(totals.stateTaxName) Rate", totals.stateTaxName, "Total Tax"]
            let first = width * 0.2
            let other = (width - first) / CGFloat(titles.count - 1)
            let widths = [first] + Array(repeating: other, count: titles.count - 1)
            reserve(16 * CGFloat(totals.hsnSummary.count + 3) + 14)
            y += canvas.draw(T.text("HSN/SAC SUMMARY", size: 7.5, weight: .bold, color: accent), at: CGPoint(x: margin, y: y), width: width) + 3
            func row(_ values: [String], weight: NSFont.Weight, fill: NSColor?) {
                if let fill { canvas.fill(CGRect(x: margin, y: y - 2, width: width, height: 15), color: fill) }
                var x = margin
                for (index, value) in values.enumerated() {
                    canvas.draw(T.text(value, size: 7.5, weight: weight, alignment: index == 0 ? .left : .right),
                                at: CGPoint(x: x + 2, y: y + 0.5), width: widths[index] - 4)
                    x += widths[index]
                }
                y += 15
            }
            row(titles, weight: .bold, fill: shade)
            for item in totals.hsnSummary {
                let half = Money.percent(item.rate / 2)
                let values = inter
                    ? [item.hsn.isEmpty ? "—" : item.hsn, IndianNumber.format(item.tax.taxable), Money.percent(item.rate),
                       IndianNumber.format(item.tax.igst), IndianNumber.format(item.tax.tax)]
                    : [item.hsn.isEmpty ? "—" : item.hsn, IndianNumber.format(item.tax.taxable), half, IndianNumber.format(item.tax.cgst),
                       half, IndianNumber.format(item.tax.sgst), IndianNumber.format(item.tax.tax)]
                row(values, weight: .regular, fill: nil)
            }
            let sum = totals.sum
            row(inter ? ["Total", IndianNumber.format(sum.taxable), "", IndianNumber.format(sum.igst), IndianNumber.format(sum.tax)]
                : ["Total", IndianNumber.format(sum.taxable), "", IndianNumber.format(sum.cgst), "", IndianNumber.format(sum.sgst), IndianNumber.format(sum.tax)],
                weight: .semibold, fill: shade)
            y += 12
        }

        // MARK: Footer

        private mutating func footerBlock() {
            let seller = invoice.seller
            var bank: [String] = []
            if !seller.bankName.isEmpty { bank.append("Bank: \(seller.bankName)") }
            if !seller.accountName.isEmpty { bank.append("A/c Name: \(seller.accountName)") }
            if !seller.accountNumber.isEmpty { bank.append("A/c No.: \(seller.accountNumber)") }
            if !seller.ifsc.isEmpty { bank.append("IFSC: \(seller.ifsc.uppercased())") }
            if !seller.upiID.isEmpty { bank.append("UPI: \(seller.upiID)") }
            let qr = seller.showsUPIQR
                ? UPI.link(payee: seller.upiID, name: seller.party.name, amount: totals.grandTotal, note: "Invoice \(invoice.number)").flatMap(QRCode.image)
                : nil
            let terms = [invoice.notes, seller.terms].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let leftWidth = width * 0.6
            let termsText = T.text(terms.joined(separator: "\n"), size: 7.5, color: .darkGray)
            let bankText = T.text(bank.joined(separator: "\n"), size: 8)
            let needed = max(canvas.height(of: bankText, width: leftWidth - 80) + canvas.height(of: termsText, width: leftWidth) + 40, 100)
            reserve(needed)

            var left = y
            if !bank.isEmpty || qr != nil {
                left += canvas.draw(T.text("PAYMENT DETAILS", size: 7.5, weight: .bold, color: accent), at: CGPoint(x: margin, y: left), width: leftWidth) + 3
                var textX = margin
                var qrHeight: CGFloat = 0
                if let qr {
                    let rect = canvas.draw(qr, fitting: CGRect(x: margin, y: left, width: 64, height: 64), crisp: true)
                    canvas.draw(T.text("Scan to pay", size: 6.5, color: .gray, alignment: .center), at: CGPoint(x: margin, y: rect.maxY + 1), width: 64)
                    textX = margin + 74
                    qrHeight = rect.height + 10
                }
                let h = canvas.draw(bankText, at: CGPoint(x: textX, y: left), width: leftWidth - (textX - margin))
                left += max(h, qrHeight) + 8
            }
            if !terms.isEmpty {
                left += canvas.draw(T.text("TERMS & NOTES", size: 7.5, weight: .bold, color: accent), at: CGPoint(x: margin, y: left), width: leftWidth) + 2
                left += canvas.draw(termsText, at: CGPoint(x: margin, y: left), width: leftWidth)
            }

            let signX = margin + width * 0.64
            let signWidth = width * 0.36
            var right = y
            right += canvas.draw(T.text("For \(seller.party.name)", size: 8.5, weight: .semibold, alignment: .right), at: CGPoint(x: signX, y: right), width: signWidth) + 4
            if let signature = BusinessStorage.cgImage(seller.signaturePNG) {
                let rect = canvas.draw(signature, fitting: CGRect(x: signX, y: right, width: signWidth, height: 40), alignment: .right)
                right = rect.maxY + 4
            } else {
                right += 40
            }
            canvas.line(from: CGPoint(x: signX + signWidth * 0.3, y: right), to: CGPoint(x: signX + signWidth, y: right), color: rule)
            right += 3 + canvas.draw(T.text("Authorised Signatory", size: 7.5, color: .darkGray, alignment: .right), at: CGPoint(x: signX, y: right + 3), width: signWidth)
            y = max(left, right) + 10
        }

        private func date(_ date: Date) -> String {
            date.formatted(.dateTime.day(.twoDigits).month(.abbreviated).year())
        }
    }
}
