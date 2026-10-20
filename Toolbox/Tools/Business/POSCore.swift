import Foundation

// MARK: - Model

struct POSProduct: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    /// SKU or barcode. A barcode scanner types it into the search field.
    var sku = ""
    var price: Decimal = 0
    var gstRate: Decimal = GSTRates.standard
    var hsn = ""
    /// Retail prices (MRP) usually include GST.
    var taxInclusive = true
    var category = ""
}

enum POSPaper: String, Codable, CaseIterable, Identifiable {
    case mm58, mm80, a5, a4
    var id: Self { self }

    var label: String {
        switch self {
        case .mm58: "58 mm thermal"
        case .mm80: "80 mm thermal"
        case .a5: "A5"
        case .a4: "A4"
        }
    }

    /// Paper width in points.
    var width: CGFloat {
        switch self {
        case .mm58: 58 / 25.4 * 72
        case .mm80: 80 / 25.4 * 72
        case .a5: 419.53
        case .a4: 595.28
        }
    }

    /// Nil for roll paper: the page is as tall as the receipt.
    var height: CGFloat? {
        switch self {
        case .mm58, .mm80: nil
        case .a5: 595.28
        case .a4: 841.89
        }
    }

    var isThermal: Bool { height == nil }
    var margin: CGFloat { isThermal ? (self == .mm58 ? 8 : 10) : 36 }
    var fontSize: CGFloat {
        switch self {
        case .mm58: 7
        case .mm80: 8.5
        case .a5: 9.5
        case .a4: 10.5
        }
    }
}

struct POSShop: Codable, Hashable {
    var name = "My Shop"
    var address = ""
    var phone = ""
    var gstin = ""
    var upiID = ""
    var footer = "Thank you! Visit again."
    var receiptPrefix = "R-"
    var nextReceipt = 1
    /// Unregistered and composition shops can't charge GST; their bills show no tax.
    var gstRegistered = true
    var roundsTotal = true
    var paper = POSPaper.mm80
    var showsUPIQR = true

    var nextReceiptNumber: String { receiptPrefix + String(format: "%04d", nextReceipt) }
}

struct POSCartLine: Codable, Hashable, Identifiable {
    var id = UUID()
    /// A copy, so old sales keep the price they were sold at.
    var product: POSProduct
    var quantity: Decimal = 1
    var discountPercent: Decimal = 0
}

enum POSPayment: String, Codable, CaseIterable, Identifiable {
    case cash, upi, card
    var id: Self { self }
    var label: String {
        switch self {
        case .cash: "Cash"
        case .upi: "UPI"
        case .card: "Card"
        }
    }
}

struct POSSale: Codable, Hashable, Identifiable {
    var id = UUID()
    var number = ""
    var date = Date()
    var lines: [POSCartLine] = []
    /// Whether the bill discount is `billDiscountPercent` or `billDiscountAmount` rupees.
    var billDiscountIsPercent = true
    var billDiscountPercent: Decimal = 0
    var billDiscountAmount: Decimal = 0
    var payment = POSPayment.cash
    /// Cash handed over, for working out change.
    var tendered: Decimal?
    var customerName = ""
    var customerPhone = ""
    /// The shop's details when the sale was made, for reprinting.
    var shop = POSShop()

    var totals: POSTotals { POSTotals(self) }
}

// MARK: - Totals

struct POSTotals {
    struct Line {
        /// Quantity × price.
        var gross: Decimal
        var discount: Decimal
        /// The line's part of the bill discount.
        var billShare: Decimal
        var tax: GSTBreakdown
        /// After the line discount, before the bill discount: what the receipt shows for the line.
        var amount: Decimal { gross - discount }
    }

    struct RateRow: Identifiable {
        var rate: Decimal
        var tax: GSTBreakdown
        var id: Decimal { rate }
    }

    var lines: [Line]
    /// Sum of line amounts.
    var subtotal: Decimal
    var billDiscount: Decimal
    var sum: GSTBreakdown
    /// GST added on top of tax-exclusive prices.
    var taxAdded: Decimal
    var roundOff: Decimal
    var total: Decimal
    var byRate: [RateRow]
    var itemCount: Decimal
    /// Nil unless paid in cash with enough tendered.
    var change: Decimal?

    init(_ sale: POSSale) {
        let shop = sale.shop
        var lines = sale.lines.map { line -> Line in
            let gross = Money.round(line.quantity * line.product.price)
            let discount = Money.round(gross * line.discountPercent / 100)
            return Line(gross: gross, discount: discount, billShare: 0, tax: GSTBreakdown())
        }
        subtotal = lines.reduce(0) { $0 + $1.amount }
        let requested = sale.billDiscountIsPercent
            ? Money.round(subtotal * sale.billDiscountPercent / 100)
            : Money.round(sale.billDiscountAmount)
        billDiscount = min(max(requested, 0), max(subtotal, 0))
        // Spread the bill discount over the lines by value, so each line's taxable value drops with it.
        if billDiscount > 0, subtotal > 0 {
            var remaining = billDiscount
            let last = lines.lastIndex { $0.amount > 0 }
            for index in lines.indices where lines[index].amount > 0 {
                let share = index == last ? remaining : Money.round(billDiscount * lines[index].amount / subtotal)
                lines[index].billShare = share
                remaining -= share
            }
        }
        for (index, line) in sale.lines.enumerated() {
            let net = lines[index].amount - lines[index].billShare
            lines[index].tax = shop.gstRegistered
                ? GSTMath.breakdown(net: net, rate: line.product.gstRate, inclusive: line.product.taxInclusive, interState: false)
                : GSTBreakdown(taxable: net)
        }
        self.lines = lines
        sum = lines.reduce(GSTBreakdown()) { $0 + $1.tax }
        taxAdded = sum.total - (subtotal - billDiscount)
        roundOff = shop.roundsTotal ? GSTMath.roundOff(sum.total) : 0
        total = sum.total + roundOff
        var rows: [Decimal: GSTBreakdown] = [:]
        if shop.gstRegistered {
            for (line, total) in zip(sale.lines, lines) { rows[line.product.gstRate] = (rows[line.product.gstRate] ?? GSTBreakdown()) + total.tax }
        }
        byRate = rows.keys.sorted().map { RateRow(rate: $0, tax: rows[$0]!) }
        itemCount = sale.lines.reduce(0) { $0 + $1.quantity }
        if sale.payment == .cash, let tendered = sale.tendered, tendered >= total { change = tendered - total } else { change = nil }
    }
}

// MARK: - Store

/// The catalog, shop profile and sales history, as JSON in Application Support/Toolbox/POS.
@MainActor
@Observable
final class POSStore {
    static let shared = POSStore(folder: BusinessStorage.defaultFolder("POS"))

    struct DaySummary: Identifiable {
        var day: Date
        var sales: [POSSale]
        var total: Decimal
        var tax: Decimal
        var byPayment: [POSPayment: Decimal]
        var id: Date { day }
    }

    let folder: URL
    private(set) var products: [POSProduct]
    private(set) var sales: [POSSale]
    var shop: POSShop
    /// The sale being rung up. Kept here so it survives switching tools.
    var cart = POSSale()

    init(folder: URL) {
        self.folder = folder
        products = BusinessStorage.load([POSProduct].self, from: folder.appendingPathComponent("products.json")) ?? []
        sales = BusinessStorage.load([POSSale].self, from: folder.appendingPathComponent("sales.json")) ?? []
        shop = BusinessStorage.load(POSShop.self, from: folder.appendingPathComponent("shop.json")) ?? POSShop()
        cart.shop = shop
    }

    // MARK: Catalog

    func upsert(_ product: POSProduct) {
        if let index = products.firstIndex(where: { $0.id == product.id }) { products[index] = product } else { products.append(product) }
        saveProducts()
    }

    func delete(_ ids: Set<POSProduct.ID>) {
        products.removeAll { ids.contains($0.id) }
        saveProducts()
    }

    /// Products matching every word of `query` in name, SKU, HSN or category.
    func search(_ query: String) -> [POSProduct] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let sorted = products.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !words.isEmpty else { return sorted }
        return sorted.filter { product in
            let haystack = [product.name, product.sku, product.hsn, product.category].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The product a scanned or typed code refers to: an exact SKU match, or the only search result.
    func product(forCode code: String) -> POSProduct? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = products.first(where: { !$0.sku.isEmpty && $0.sku.caseInsensitiveCompare(trimmed) == .orderedSame }) { return exact }
        let matches = search(trimmed)
        return matches.count == 1 ? matches[0] : nil
    }

    static let csvHeader = ["name", "sku", "price", "gst_rate", "hsn", "tax_inclusive", "category"]

    func catalogCSV() -> String {
        ([BusinessCSV.line(Self.csvHeader)] + products.map { product in
            BusinessCSV.line([product.name, product.sku, Money.plain(product.price), Money.plain(product.gstRate),
                              product.hsn, product.taxInclusive ? "yes" : "no", product.category])
        }).joined(separator: "\n") + "\n"
    }

    /// Adds products from CSV, updating ones with the same SKU. Columns are matched by header name when
    /// there's a header row, otherwise read in `csvHeader` order. Returns how many rows were imported.
    @discardableResult
    func importCSV(_ text: String) throws -> Int {
        var rows = BusinessCSV.parse(text)
        guard !rows.isEmpty else { throw ToolError.failed("The CSV file is empty.") }
        var columns = Dictionary(uniqueKeysWithValues: Self.csvHeader.enumerated().map { ($1, $0) })
        let first = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if first.contains("name") {
            columns = [:]
            let aliases = ["name": ["name", "product", "item"], "sku": ["sku", "barcode", "code"], "price": ["price", "mrp", "rate"],
                           "gst_rate": ["gst_rate", "gst", "gst %", "tax", "tax_rate"], "hsn": ["hsn", "hsn/sac", "sac"],
                           "tax_inclusive": ["tax_inclusive", "inclusive", "includes_tax"], "category": ["category", "group"]]
            for (key, names) in aliases {
                if let index = first.firstIndex(where: { names.contains($0) }) { columns[key] = index }
            }
            rows.removeFirst()
            guard columns["name"] != nil, columns["price"] != nil else { throw ToolError.failed("The CSV needs “name” and “price” columns.") }
        }
        func value(_ row: [String], _ key: String) -> String {
            guard let index = columns[key], index < row.count else { return "" }
            return row[index].trimmingCharacters(in: .whitespaces)
        }
        var imported = 0
        for (number, row) in rows.enumerated() {
            let name = value(row, "name")
            guard !name.isEmpty else { continue }
            guard let price = Money.parse(value(row, "price")), price >= 0 else {
                throw ToolError.failed("Row \(number + 1) (“\(name)”) has no valid price.")
            }
            let sku = value(row, "sku")
            var product = products.first { !sku.isEmpty && $0.sku == sku } ?? POSProduct()
            product.name = name
            product.sku = sku
            product.price = price
            if let rate = Money.parse(value(row, "gst_rate")) { product.gstRate = rate }
            product.hsn = value(row, "hsn")
            let inclusive = value(row, "tax_inclusive").lowercased()
            if !inclusive.isEmpty { product.taxInclusive = ["yes", "y", "true", "1", "inclusive"].contains(inclusive) }
            product.category = value(row, "category")
            if let index = products.firstIndex(where: { $0.id == product.id }) { products[index] = product } else { products.append(product) }
            imported += 1
        }
        saveProducts()
        return imported
    }

    // MARK: Cart

    func add(_ product: POSProduct) {
        if let index = cart.lines.firstIndex(where: { $0.product.id == product.id && $0.discountPercent == 0 }) {
            cart.lines[index].quantity += 1
        } else {
            cart.lines.append(POSCartLine(product: product))
        }
    }

    func clearCart() {
        cart = POSSale()
        cart.shop = shop
    }

    /// Records the cart as a sale with the next receipt number and starts an empty cart.
    @discardableResult
    func completeSale() throws -> POSSale {
        guard !cart.lines.isEmpty else { throw ToolError.failed("The cart is empty.") }
        var sale = cart
        sale.shop = shop
        sale.number = shop.nextReceiptNumber
        sale.date = Date()
        sales.append(sale)
        shop.nextReceipt += 1
        try saveShop()
        try BusinessStorage.save(sales, to: folder.appendingPathComponent("sales.json"))
        clearCart()
        return sale
    }

    // MARK: Shop

    func saveShop() throws {
        cart.shop = shop
        try BusinessStorage.save(shop, to: folder.appendingPathComponent("shop.json"))
    }

    // MARK: History

    func days(calendar: Calendar = .current) -> [DaySummary] {
        let grouped = Dictionary(grouping: sales) { calendar.startOfDay(for: $0.date) }
        return grouped.map { day, sales in
            var byPayment: [POSPayment: Decimal] = [:]
            var total: Decimal = 0, tax: Decimal = 0
            for sale in sales {
                let totals = sale.totals
                total += totals.total
                tax += totals.sum.tax
                byPayment[sale.payment, default: 0] += totals.total
            }
            return DaySummary(day: day, sales: sales.sorted { $0.date > $1.date }, total: total, tax: tax, byPayment: byPayment)
        }
        .sorted { $0.day > $1.day }
    }

    func salesCSV(_ sales: [POSSale]? = nil) -> String {
        let header = ["receipt", "date", "time", "items", "subtotal", "discount", "taxable", "cgst", "sgst", "round_off", "total", "payment", "customer", "phone"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let rows = (sales ?? self.sales).sorted { $0.date < $1.date }.map { sale -> String in
            let totals = sale.totals
            return BusinessCSV.line([sale.number, formatter.string(from: sale.date),
                                     sale.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)),
                                     Money.plain(totals.itemCount), Money.plain(totals.subtotal), Money.plain(totals.billDiscount),
                                     Money.plain(totals.sum.taxable), Money.plain(totals.sum.cgst), Money.plain(totals.sum.sgst),
                                     Money.plain(totals.roundOff), Money.plain(totals.total), sale.payment.label,
                                     sale.customerName, sale.customerPhone])
        }
        return ([BusinessCSV.line(header)] + rows).joined(separator: "\n") + "\n"
    }

    private func saveProducts() {
        try? BusinessStorage.save(products, to: folder.appendingPathComponent("products.json"))
    }
}
