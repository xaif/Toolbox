import AppKit

/// Receipts for thermal roll printers (a single page as tall as the receipt) or A5/A4 sheets.
enum POSReceiptPDF {
    private enum Block {
        case text(NSAttributedString)
        /// A label on the left and an amount on the right.
        case pair(NSAttributedString, NSAttributedString)
        case rule
        case image(CGImage, side: CGFloat)
        case space(CGFloat)
    }

    static func render(_ sale: POSSale, paper: POSPaper) throws -> Data {
        let margin = paper.margin
        let contentWidth = min(paper.width - margin * 2, 340)
        let left = (paper.width - contentWidth) / 2
        let blocks = blocks(for: sale, paper: paper)
        let measure = BusinessPDFCanvas(pageSize: CGSize(width: paper.width, height: 1000))
        let heights = blocks.map { height(of: $0, width: contentWidth, canvas: measure) }
        let pageHeight = paper.height ?? ceil(heights.reduce(0, +) + margin * 2)

        return try BusinessPDFCanvas.render(pageSize: CGSize(width: paper.width, height: pageHeight)) { canvas, _ in
            canvas.beginPage()
            var y = margin
            for (block, height) in zip(blocks, heights) {
                if let fixed = paper.height, y + height > fixed - margin {
                    canvas.beginPage()
                    y = margin
                }
                draw(block, at: CGPoint(x: left, y: y), width: contentWidth, canvas: canvas)
                y += height
            }
        }
    }

    private static func height(of block: Block, width: CGFloat, canvas: BusinessPDFCanvas) -> CGFloat {
        switch block {
        case .text(let text): canvas.height(of: text, width: width)
        case .pair(let label, let value):
            max(canvas.height(of: label, width: width - valueWidth(value, canvas: canvas) - 4), canvas.height(of: value, width: width))
        case .rule: 7
        case .image(_, let side): side + 4
        case .space(let height): height
        }
    }

    private static func valueWidth(_ value: NSAttributedString, canvas: BusinessPDFCanvas) -> CGFloat {
        ceil(value.size().width) + 1
    }

    private static func draw(_ block: Block, at origin: CGPoint, width: CGFloat, canvas: BusinessPDFCanvas) {
        switch block {
        case .text(let text):
            canvas.draw(text, at: origin, width: width)
        case .pair(let label, let value):
            let valueWidth = valueWidth(value, canvas: canvas)
            canvas.draw(label, at: origin, width: width - valueWidth - 4)
            canvas.draw(value, at: CGPoint(x: origin.x + width - valueWidth, y: origin.y), width: valueWidth)
        case .rule:
            canvas.line(from: CGPoint(x: origin.x, y: origin.y + 3.5), to: CGPoint(x: origin.x + width, y: origin.y + 3.5),
                        color: .black, width: 0.6, dash: [2, 1.5])
        case .image(let image, let side):
            canvas.draw(image, fitting: CGRect(x: origin.x, y: origin.y + 2, width: width, height: side), alignment: .center, crisp: true)
        case .space:
            break
        }
    }

    private static func blocks(for sale: POSSale, paper: POSPaper) -> [Block] {
        let shop = sale.shop
        let totals = sale.totals
        let size = paper.fontSize
        func text(_ string: String, scale: CGFloat = 1, weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) -> NSAttributedString {
            BusinessPDFCanvas.text(string, size: size * scale, weight: weight, alignment: alignment, monospaced: true)
        }
        func pair(_ label: String, _ value: Decimal, weight: NSFont.Weight = .regular, scale: CGFloat = 1) -> Block {
            .pair(text(label, scale: scale, weight: weight), text(IndianNumber.format(value), scale: scale, weight: weight, alignment: .right))
        }

        var blocks: [Block] = []
        blocks.append(.text(text(shop.name, scale: 1.45, weight: .bold, alignment: .center)))
        let header = [shop.address, shop.phone.isEmpty ? "" : "Ph: \(shop.phone)",
                      shop.gstRegistered && !shop.gstin.isEmpty ? "GSTIN: \(GSTIN.normalized(shop.gstin))" : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if !header.isEmpty { blocks.append(.text(text(header, alignment: .center))) }
        blocks.append(.space(4))
        blocks.append(.text(text(shop.gstRegistered ? "TAX INVOICE" : "BILL OF SUPPLY", weight: .bold, alignment: .center)))
        blocks.append(.rule)
        blocks.append(.pair(text("Bill: \(sale.number)"), text(sale.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()), alignment: .right)))
        blocks.append(.pair(text("Pay: \(sale.payment.label)"), text(sale.date.formatted(.dateTime.hour().minute()), alignment: .right)))
        let customer = [sale.customerName, sale.customerPhone].filter { !$0.isEmpty }.joined(separator: " · ")
        if !customer.isEmpty { blocks.append(.text(text("Customer: \(customer)"))) }
        blocks.append(.rule)

        for (line, total) in zip(sale.lines, totals.lines) {
            blocks.append(.text(text(line.product.name, weight: .semibold)))
            var detail = "  \(Money.plain(line.quantity)) x \(IndianNumber.format(line.product.price))"
            if shop.gstRegistered { detail += "  \(Money.percent(line.product.gstRate))\(line.product.taxInclusive ? "" : "+")" }
            blocks.append(.pair(text(detail), text(IndianNumber.format(total.gross), alignment: .right)))
            if total.discount > 0 {
                blocks.append(.pair(text("  Disc \(Money.percent(line.discountPercent))"), text("-" + IndianNumber.format(total.discount), alignment: .right)))
            }
        }
        blocks.append(.rule)
        blocks.append(pair("Items: \(Money.plain(totals.itemCount))   Subtotal", totals.subtotal))
        if totals.billDiscount > 0 {
            let label = sale.billDiscountIsPercent ? "Discount \(Money.percent(sale.billDiscountPercent))" : "Discount"
            blocks.append(.pair(text(label), text("-" + IndianNumber.format(totals.billDiscount), alignment: .right)))
        }
        if totals.taxAdded != 0 { blocks.append(pair("GST added", totals.taxAdded)) }
        if totals.roundOff != 0 { blocks.append(pair("Round off", totals.roundOff)) }
        blocks.append(.space(2))
        blocks.append(.pair(text("TOTAL", scale: 1.3, weight: .bold), text(IndianNumber.rupees(totals.total), scale: 1.3, weight: .bold, alignment: .right)))
        if sale.payment == .cash, let tendered = sale.tendered, tendered > 0 {
            blocks.append(pair("Cash", tendered))
            if let change = totals.change { blocks.append(pair("Change", change, weight: .semibold)) }
        }

        if shop.gstRegistered, !totals.byRate.isEmpty, totals.sum.tax > 0 {
            blocks.append(.rule)
            blocks.append(.text(text("GST SUMMARY", weight: .semibold)))
            for row in totals.byRate where row.rate > 0 {
                let half = Money.percent(row.rate / 2)
                blocks.append(pair("Taxable @\(Money.percent(row.rate))", row.tax.taxable))
                blocks.append(pair("  CGST \(half)", row.tax.cgst))
                blocks.append(pair("  SGST \(half)", row.tax.sgst))
            }
            blocks.append(pair("Total GST", totals.sum.tax, weight: .semibold))
            if totals.taxAdded == 0 { blocks.append(.text(text("Prices include GST.", scale: 0.9))) }
        }

        if shop.showsUPIQR, sale.payment == .upi,
           let link = UPI.link(payee: shop.upiID, name: shop.name, amount: totals.total, note: "Bill \(sale.number)"),
           let qr = QRCode.image(for: link) {
            blocks.append(.rule)
            blocks.append(.text(text("Scan to pay \(IndianNumber.rupees(totals.total))", alignment: .center)))
            blocks.append(.image(qr, side: paper == .mm58 ? 92 : 110))
            blocks.append(.text(text(shop.upiID, scale: 0.9, alignment: .center)))
        }
        if !shop.footer.isEmpty {
            blocks.append(.rule)
            blocks.append(.text(text(shop.footer, alignment: .center)))
        }
        return blocks
    }
}
