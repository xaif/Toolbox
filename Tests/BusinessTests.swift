import XCTest
import AppKit
import PDFKit
@testable import Toolbox

final class BusinessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BusinessTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func d(_ text: String) -> Decimal { Decimal(string: text)! }

    private func invoice(place: String = "27", items: [GSTLineItem]? = nil) -> GSTInvoice {
        var invoice = GSTInvoice()
        invoice.number = "INV-0001"
        invoice.seller.party = GSTParty(name: "Acme Traders", address: "1 MG Road, Pune 411001", gstin: "27AAPFU0939F1ZV", stateCode: "27")
        invoice.seller.upiID = "acme@okbank"
        invoice.buyer = GSTParty(name: "Blue Mart", address: "Bengaluru", gstin: "", stateCode: place)
        invoice.placeOfSupply = place
        invoice.items = items ?? [GSTLineItem(description: "Steel bottle", hsn: "7323", quantity: 2, unit: "Nos", rate: 500, gstRate: 18)]
        return invoice
    }

    private func pdfText(_ data: Data) throws -> (PDFDocument, String) {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return (document, text)
    }

    // MARK: Tax

    func testIntraStateSplitsIntoCGSTAndSGSTAndInterStateUsesIGST() {
        var intra = GSTInvoiceTotals(invoice())
        XCTAssertFalse(intra.isInterState)
        XCTAssertEqual(intra.sum, GSTBreakdown(taxable: 1000, cgst: 90, sgst: 90, igst: 0))
        XCTAssertEqual(intra.grandTotal, 1180)
        XCTAssertEqual(intra.stateTaxName, "SGST")

        let inter = GSTInvoiceTotals(invoice(place: "29"))
        XCTAssertTrue(inter.isInterState)
        XCTAssertEqual(inter.sum, GSTBreakdown(taxable: 1000, cgst: 0, sgst: 0, igst: 180))

        var chandigarh = invoice(place: "04")
        chandigarh.seller.party.stateCode = "04"
        intra = GSTInvoiceTotals(chandigarh)
        XCTAssertEqual(intra.stateTaxName, "UTGST")

        // Discounts reduce the taxable value; HSN rows group by code and rate.
        let mixed = invoice(items: [
            GSTLineItem(description: "A", hsn: "1001", quantity: 3, rate: d("99.99"), discountPercent: 10, gstRate: 5),
            GSTLineItem(description: "B", hsn: "1001", quantity: 1, rate: 200, gstRate: 5),
            GSTLineItem(description: "C", hsn: "9983", quantity: 1, rate: 1000, gstRate: 18),
        ])
        let totals = GSTInvoiceTotals(mixed)
        XCTAssertEqual(totals.lines[0].gross, d("299.97"))
        XCTAssertEqual(totals.lines[0].discount, 30)
        XCTAssertEqual(totals.lines[0].tax.taxable, d("269.97"))
        XCTAssertEqual(totals.lines[0].tax.cgst, d("6.75"))
        XCTAssertEqual(totals.hsnSummary.count, 2)
        XCTAssertEqual(totals.hsnSummary[0].tax.taxable, d("469.97"))
        XCTAssertEqual(totals.sum.taxable, d("1469.97"))
    }

    func testInclusivePricesAreBackCalculatedAndStillTotalTheSame() {
        XCTAssertEqual(GSTMath.breakdown(net: 118, rate: 18, inclusive: true, interState: false), GSTBreakdown(taxable: 100, cgst: 9, sgst: 9))
        let hundred = GSTMath.breakdown(net: 100, rate: 18, inclusive: true, interState: false)
        XCTAssertEqual(hundred.total, 100)
        XCTAssertEqual(hundred.cgst, hundred.sgst)
        XCTAssertEqual(hundred.cgst, d("7.63"))
        XCTAssertEqual(GSTMath.breakdown(net: 100, rate: 18, inclusive: true, interState: true), GSTBreakdown(taxable: d("84.75"), igst: d("15.25")))
        XCTAssertEqual(GSTMath.breakdown(net: 105, rate: 5, inclusive: true, interState: false), GSTBreakdown(taxable: 100, cgst: d("2.5"), sgst: d("2.5")))
        XCTAssertEqual(GSTMath.breakdown(net: 50, rate: 0, inclusive: true, interState: false), GSTBreakdown(taxable: 50))

        var inclusive = invoice()
        inclusive.pricesIncludeTax = true
        inclusive.items = [GSTLineItem(description: "Phone case", quantity: 3, rate: 499, gstRate: 18)]
        let totals = GSTInvoiceTotals(inclusive)
        XCTAssertEqual(totals.sum.total, 1497)
        XCTAssertEqual(totals.sum.cgst, totals.sum.sgst)
    }

    func testRoundingIsHalfUpToPaiseAndRoundOffReachesWholeRupees() {
        XCTAssertEqual(Money.round(d("2.345")), d("2.35"))
        XCTAssertEqual(Money.round(d("2.344")), d("2.34"))
        XCTAssertEqual(GSTMath.roundOff(d("1180.49")), d("-0.49"))
        XCTAssertEqual(GSTMath.roundOff(d("1180.50")), d("0.5"))

        var invoice = invoice(items: [GSTLineItem(description: "Service", quantity: 1, rate: d("1046.24"), gstRate: 18)])
        var totals = GSTInvoiceTotals(invoice)
        XCTAssertEqual(totals.sum.total, d("1234.56"))
        XCTAssertEqual(totals.roundOff, d("0.44"))
        XCTAssertEqual(totals.grandTotal, 1235)
        invoice.roundsTotal = false
        totals = GSTInvoiceTotals(invoice)
        XCTAssertEqual(totals.roundOff, 0)
        XCTAssertEqual(totals.grandTotal, d("1234.56"))
        XCTAssertEqual(Money.parse("₹ 1,234.50"), d("1234.5"))
        XCTAssertEqual(Money.parse("18%"), 18)
        XCTAssertNil(Money.parse("12abc"))
    }

    func testGSTINValidation() {
        XCTAssertNil(GSTIN.validate("27AAPFU0939F1ZV"))
        XCTAssertNil(GSTIN.validate(" 27aapfu0939f1zv "))
        XCTAssertEqual(GSTIN.validate("27AAPFU0939F1ZA"), .checksum)
        XCTAssertEqual(GSTIN.validate("27AAPFU0939F2ZV"), .checksum)
        XCTAssertEqual(GSTIN.validate("27AAPFU0939F1Z"), .length)
        XCTAssertEqual(GSTIN.validate("99AAPFU0939F1ZV"), .stateCode)
        XCTAssertEqual(GSTIN.validate("2XAAPFU0939F1ZV"), .characters)
        XCTAssertEqual(GSTIN.validate("27AAPFU0939F1Z-"), .characters)
        XCTAssertEqual(GSTIN.checkCharacter(for: "27AAPFU0939F1Z"), "V")
        XCTAssertEqual(GSTIN.stateCode(of: "29"), "29")
        XCTAssertNil(GSTIN.stateCode(of: "2"))
        var invoice = invoice()
        invoice.buyer.gstin = "29AAPFU0939F1ZX"
        XCTAssertTrue(invoice.problems.contains { $0.hasPrefix("Buyer GSTIN") })
    }

    func testIndianNumberingAndWords() {
        XCTAssertEqual(IndianNumber.format(d("12345678.5")), "1,23,45,678.50")
        XCTAssertEqual(IndianNumber.format(999), "999.00")
        XCTAssertEqual(IndianNumber.format(d("-1234.5")), "-1,234.50")
        XCTAssertEqual(IndianNumber.format(100000), "1,00,000.00")
        XCTAssertEqual(IndianNumber.rupees(d("1180")), "₹1,180.00")
        XCTAssertEqual(IndianNumber.words(d("12345678.50")),
                       "Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight and Fifty Paise Only")
        XCTAssertEqual(IndianNumber.words(0), "Rupees Zero Only")
        XCTAssertEqual(IndianNumber.words(d("0.75")), "Seventy Five Paise Only")
        XCTAssertEqual(IndianNumber.words(100000), "Rupees One Lakh Only")
        XCTAssertEqual(IndianNumber.words(1_000_000_000), "Rupees One Hundred Crore Only")
        XCTAssertEqual(IndianNumber.words(1180), "Rupees One Thousand One Hundred Eighty Only")
        XCTAssertEqual(IndianNumber.words(d("1015.05")), "Rupees One Thousand Fifteen and Five Paise Only")
    }

    // MARK: Invoice PDF

    func testInvoicePDFHasRealTextWithTotalsCopiesAndPages() throws {
        let (document, text) = try pdfText(GSTInvoicePDF.render(invoice()))
        XCTAssertEqual(document.pageCount, 1)
        let size = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, 595.28, accuracy: 0.5)
        XCTAssertEqual(size.height, 841.89, accuracy: 0.5)
        for expected in ["TAX INVOICE", "INV-0001", "Blue Mart", "27AAPFU0939F1ZV", "1,180.00", "CGST", "SGST", "7323",
                         "Rupees One Thousand One Hundred Eighty Only", "ORIGINAL FOR RECIPIENT", "Authorised Signatory"] {
            XCTAssertTrue(text.contains(expected), "Missing “\(expected)”")
        }
        XCTAssertFalse(text.contains("IGST"))

        let (copies, copiesText) = try pdfText(GSTInvoicePDF.render(invoice(place: "29"), copies: GSTInvoice.Copy.allCases))
        XCTAssertEqual(copies.pageCount, 3)
        XCTAssertTrue(copiesText.contains("IGST"))
        XCTAssertTrue(copiesText.contains("DUPLICATE FOR TRANSPORTER"))
        XCTAssertTrue(copiesText.contains("TRIPLICATE FOR SUPPLIER"))

        let many = (1...70).map { GSTLineItem(description: "Item \($0) with a reasonably long description", hsn: "8471", quantity: 1, rate: 100, gstRate: 18) }
        let (long, longText) = try pdfText(GSTInvoicePDF.render(invoice(items: many)))
        XCTAssertGreaterThan(long.pageCount, 1)
        XCTAssertTrue(longText.contains("Page 1 of \(long.pageCount)"))
        XCTAssertTrue(longText.contains("Item 70 with"))
        XCTAssertTrue(longText.contains("8,260.00"))
    }

    @MainActor
    func testInvoiceStoreNumbersAndDrafts() throws {
        let store = GSTInvoiceStore(folder: root.appendingPathComponent("Invoices"))
        var profile = GSTSellerProfile()
        profile.party.name = "Acme"
        profile.invoicePrefix = "AC/25-26/"
        try store.saveProfile(profile)
        let first = store.newInvoice()
        XCTAssertEqual(first.number, "AC/25-26/0001")
        XCTAssertEqual(first.seller.party.name, "Acme")
        store.didIssue(first)
        XCTAssertEqual(store.newInvoice().number, "AC/25-26/0002")
        store.didIssue(first)
        XCTAssertEqual(store.profile.nextNumber, 2, "Re-exporting an old number doesn't skip ahead")

        try store.saveDraft(first)
        let reloaded = GSTInvoiceStore(folder: root.appendingPathComponent("Invoices"))
        XCTAssertEqual(reloaded.drafts.map(\.id), [first.id])
        XCTAssertEqual(reloaded.profile.nextNumber, 2)
        reloaded.working.buyer.name = "Kept"
        reloaded.saveWorking()
        XCTAssertEqual(GSTInvoiceStore(folder: root.appendingPathComponent("Invoices")).working.buyer.name, "Kept")
        reloaded.deleteDraft(first)
        XCTAssertTrue(reloaded.drafts.isEmpty)
    }

    // MARK: POS

    private func product(_ name: String, _ price: String, rate: Decimal = 18, inclusive: Bool = true, sku: String = "") -> POSProduct {
        POSProduct(name: name, sku: sku, price: d(price), gstRate: rate, hsn: "2106", taxInclusive: inclusive)
    }

    func testPOSTotalsSpreadBillDiscountAndWorkOutChange() {
        var sale = POSSale()
        sale.shop.roundsTotal = false
        sale.lines = [POSCartLine(product: product("Tea", "118")), POSCartLine(product: product("Biscuits", "100", rate: 5, inclusive: false), quantity: 2)]
        var totals = sale.totals
        XCTAssertEqual(totals.subtotal, 318)
        XCTAssertEqual(totals.lines[0].tax, GSTBreakdown(taxable: 100, cgst: 9, sgst: 9))
        XCTAssertEqual(totals.lines[1].tax, GSTBreakdown(taxable: 200, cgst: 5, sgst: 5))
        XCTAssertEqual(totals.taxAdded, 10)
        XCTAssertEqual(totals.total, 328)
        XCTAssertEqual(totals.byRate.map(\.rate), [5, 18])

        sale.billDiscountIsPercent = false
        sale.billDiscountAmount = 31
        totals = sale.totals
        XCTAssertEqual(totals.billDiscount, 31)
        XCTAssertEqual(totals.lines.reduce(0) { $0 + $1.billShare }, 31)
        XCTAssertEqual(totals.lines[0].billShare, d("11.5"))

        sale.billDiscountIsPercent = true
        sale.billDiscountPercent = 10
        sale.shop.roundsTotal = true
        sale.payment = .cash
        sale.tendered = 500
        totals = sale.totals
        XCTAssertEqual(totals.billDiscount, d("31.8"))
        XCTAssertEqual(totals.total, Money.round(totals.total, scale: 0))
        XCTAssertEqual(totals.change, 500 - totals.total)
        sale.tendered = 10
        XCTAssertNil(sale.totals.change)

        sale.shop.gstRegistered = false
        totals = sale.totals
        XCTAssertEqual(totals.sum.tax, 0)
        XCTAssertTrue(totals.byRate.isEmpty)
    }

    func testThermalReceiptsAreNarrowAndGrowWithItems() throws {
        var sale = POSSale()
        sale.number = "R-0001"
        sale.shop.name = "Corner Store"
        sale.shop.gstin = "27AAPFU0939F1ZV"
        sale.shop.upiID = "corner@upi"
        sale.payment = .upi
        sale.lines = [POSCartLine(product: product("Masala Tea", "118")), POSCartLine(product: product("Butter Cookies", "45", rate: 5), quantity: 3)]
        let short = try XCTUnwrap(PDFDocument(data: POSReceiptPDF.render(sale, paper: .mm58)))
        let shortBox = try XCTUnwrap(short.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(short.pageCount, 1)
        XCTAssertEqual(shortBox.width, 164.4, accuracy: 0.5)
        let text = try XCTUnwrap(short.page(at: 0)?.string)
        for expected in ["Corner Store", "R-0001", "Masala Tea", "TOTAL", "₹253.00", "CGST", "Scan to pay"] {
            XCTAssertTrue(text.contains(expected), "Missing “\(expected)”")
        }

        sale.lines += (1...20).map { POSCartLine(product: product("Item \($0)", "10")) }
        let long = try XCTUnwrap(PDFDocument(data: POSReceiptPDF.render(sale, paper: .mm58)))
        XCTAssertEqual(long.pageCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(long.page(at: 0)).bounds(for: .mediaBox).height, shortBox.height + 200)

        let wide = try XCTUnwrap(PDFDocument(data: POSReceiptPDF.render(sale, paper: .mm80)))
        XCTAssertEqual(try XCTUnwrap(wide.page(at: 0)).bounds(for: .mediaBox).width, 226.8, accuracy: 0.5)
        let a5 = try XCTUnwrap(PDFDocument(data: POSReceiptPDF.render(sale, paper: .a5)))
        XCTAssertEqual(try XCTUnwrap(a5.page(at: 0)).bounds(for: .mediaBox).height, 595.28, accuracy: 0.5)
    }

    @MainActor
    func testPOSStoreImportsCSVRecordsSalesAndExports() throws {
        let folder = root.appendingPathComponent("POS")
        let store = POSStore(folder: folder)
        let csv = """
        Name,SKU,Price,GST,HSN,Inclusive,Category
        "Tea, Masala",8901234567890,118,18,0902,yes,Drinks
        Cookies,COOK1,₹45.50,5%,1905,no,Snacks
        """
        XCTAssertEqual(try store.importCSV(csv), 2)
        let tea = try XCTUnwrap(store.product(forCode: "8901234567890"))
        XCTAssertEqual(tea.name, "Tea, Masala")
        XCTAssertEqual(store.product(forCode: "cook1")?.price, d("45.5"))
        XCTAssertEqual(store.product(forCode: "cookies")?.taxInclusive, false)
        XCTAssertEqual(try store.importCSV("Tea Updated,8901234567890,120,18,0902,yes,Drinks\n"), 1)
        XCTAssertEqual(store.products.count, 2, "Same SKU updates the product")
        XCTAssertThrowsError(try store.importCSV("name,price\nBroken,abc\n"))
        XCTAssertEqual(BusinessCSV.parse(store.catalogCSV()).count, 3)

        store.shop.receiptPrefix = "B"
        try store.saveShop()
        let updated = try XCTUnwrap(store.product(forCode: "8901234567890"))
        store.add(updated)
        store.add(updated)
        XCTAssertEqual(store.cart.lines.first?.quantity, 2)
        let sale = try store.completeSale()
        XCTAssertEqual(sale.number, "B0001")
        XCTAssertTrue(store.cart.lines.isEmpty)
        XCTAssertThrowsError(try store.completeSale())

        let reopened = POSStore(folder: folder)
        XCTAssertEqual(reopened.sales.count, 1)
        XCTAssertEqual(reopened.shop.nextReceiptNumber, "B0002")
        XCTAssertEqual(reopened.days().first?.total, 240)
        XCTAssertEqual(reopened.days().first?.byPayment[.cash], 240)
        let rows = BusinessCSV.parse(reopened.salesCSV())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][0], "B0001")
        XCTAssertEqual(rows[1][10], "240")
    }

    func testUPILinksAndQRCodes() throws {
        let link = try XCTUnwrap(UPI.link(payee: "shop@okaxis", name: "Corner Store", amount: d("1180.5"), note: "Bill R-1"))
        XCTAssertTrue(link.hasPrefix("upi://pay?pa=shop@okaxis&pn=Corner%20Store&am=1180.50&cu=INR"))
        XCTAssertNil(UPI.link(payee: "not-a-vpa", name: "X", amount: 1))
        XCTAssertNotNil(QRCode.image(for: link))
        XCTAssertNotNil(NSImage(systemSymbolName: "indianrupeesign.square", accessibilityDescription: nil))
        XCTAssertEqual(ToolRegistry.tools(in: .business).map(\.id), ["business.gst-invoice", "business.pos"])
    }
}
