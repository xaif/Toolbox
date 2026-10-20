import SwiftUI
import UniformTypeIdentifiers

struct POSBillingView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sell, products, sales, shop
        var id: Self { self }
        var label: String {
            switch self {
            case .sell: "Sell"
            case .products: "Products"
            case .sales: "Sales"
            case .shop: "Shop"
            }
        }
    }

    let tool: Tool

    @State private var store: POSStore
    @State private var runner: JobRunner
    @AppStorage("business.pos.tab") private var tab = Tab.sell
    @State private var receipt: POSSale?

    /// `store` defaults to the user's saved catalog and sales.
    init(tool: Tool, store: POSStore? = nil) {
        self.tool = tool
        _store = State(initialValue: store ?? .shared)
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, scrolls: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    BusinessSaveStatus(runner: runner)
                }
                switch tab {
                case .sell: POSSellPane(store: store) { receipt = $0 }
                case .products: POSProductsPane(store: store, runner: runner)
                case .sales: POSSalesPane(store: store, runner: runner) { receipt = $0 }
                case .shop: POSShopPane(store: store)
                }
            }
        }
        .sheet(item: $receipt) { POSReceiptSheet(sale: $0, runner: runner) }
    }
}

// MARK: - Sell

private struct POSSellPane: View {
    @Bindable var store: POSStore
    var onComplete: (POSSale) -> Void

    @State private var query = ""
    @State private var selection: POSProduct.ID?
    @State private var message: String?
    @FocusState private var searchFocused: Bool

    private var results: [POSProduct] { store.search(query) }
    private var totals: POSTotals { store.cart.totals }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search or scan a barcode", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit(addFromSearch)
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                if store.products.isEmpty {
                    ContentUnavailableView("No products yet", systemImage: "shippingbox",
                                           description: Text("Add products in the Products tab, or import a CSV."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(results, selection: $selection) { product in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(product.name).lineLimit(1)
                                if !product.sku.isEmpty { Text(product.sku).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(IndianNumber.rupees(product.price)).monospacedDigit()
                            Button { store.add(product) } label: { Image(systemName: "plus.circle.fill") }
                                .buttonStyle(.borderless).help("Add to bill")
                        }
                        .tag(product.id)
                    }
                    .contextMenu(forSelectionType: POSProduct.ID.self) { _ in } primaryAction: { ids in
                        for product in store.products where ids.contains(product.id) { store.add(product) }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)

            cart
        }
        .onAppear { searchFocused = true }
    }

    private func addFromSearch() {
        if let product = store.product(forCode: query) {
            store.add(product)
            query = ""
            message = nil
        } else if !query.isEmpty {
            message = results.isEmpty ? "No product matches “\(query)”." : "Several products match. Pick one from the list."
        }
        searchFocused = true
    }

    // MARK: Cart

    private var cart: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.cart.lines.isEmpty {
                ContentUnavailableView("Empty bill", systemImage: "cart",
                                       description: Text("Scan a barcode, or press Return on a search to add the matching product."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($store.cart.lines) { $line in
                        cartRow($line)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                BusinessFormRow("Customer") {
                    HStack {
                        TextField("Name (optional)", text: $store.cart.customerName).textFieldStyle(.roundedBorder)
                        TextField("Phone", text: $store.cart.customerPhone).textFieldStyle(.roundedBorder).frame(width: 130)
                    }
                }
                BusinessFormRow("Bill discount") {
                    HStack {
                        Picker("Discount type", selection: $store.cart.billDiscountIsPercent) {
                            Text("%").tag(true)
                            Text("₹").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        DecimalField(title: "Discount", value: store.cart.billDiscountIsPercent ? $store.cart.billDiscountPercent : $store.cart.billDiscountAmount)
                    }
                }
                BusinessFormRow("Payment") {
                    HStack {
                        Picker("Payment", selection: $store.cart.payment) {
                            ForEach(POSPayment.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if store.cart.payment == .cash {
                            DecimalField(title: "Cash received", value: Binding(get: { store.cart.tendered ?? 0 },
                                                                                set: { store.cart.tendered = $0 > 0 ? $0 : nil }), width: 90)
                            if let change = totals.change {
                                Text("Change \(IndianNumber.rupees(change))").fontWeight(.semibold).foregroundStyle(.green)
                            } else if let tendered = store.cart.tendered, tendered < totals.total {
                                Text("Short by \(IndianNumber.rupees(totals.total - tendered))").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                if store.cart.payment == .upi, store.shop.showsUPIQR,
                   let link = UPI.link(payee: store.shop.upiID, name: store.shop.name, amount: totals.total),
                   let qr = QRCode.image(for: link) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 96, height: 96)
                        .help("Customers scan this to pay \(IndianNumber.rupees(totals.total))")
                } else if store.cart.payment == .upi, store.shop.upiID.isEmpty {
                    Text("Add your UPI ID in the Shop tab to show a payment QR code.").font(.caption).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    summaryRow("Subtotal (\(Money.plain(totals.itemCount)) items)", totals.subtotal)
                    if totals.billDiscount > 0 { summaryRow("Discount", -totals.billDiscount) }
                    if totals.taxAdded != 0 { summaryRow("GST added", totals.taxAdded) }
                    if totals.roundOff != 0 { summaryRow("Round off", totals.roundOff) }
                    if store.shop.gstRegistered, totals.sum.tax > 0 {
                        Text("Includes CGST \(IndianNumber.format(totals.sum.cgst)) + SGST \(IndianNumber.format(totals.sum.sgst))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(IndianNumber.rupees(totals.total)).font(.system(size: 28, weight: .bold).monospacedDigit())
                }
            }
            HStack {
                Button("Clear Bill", role: .destructive) { store.clearCart(); searchFocused = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.cart.lines.isEmpty)
                Spacer()
                Button {
                    complete()
                } label: {
                    Text("Charge \(IndianNumber.rupees(totals.total))").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.cart.lines.isEmpty)
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity)
    }

    private func cartRow(_ line: Binding<POSCartLine>) -> some View {
        let value = line.wrappedValue
        let gross = Money.round(value.quantity * value.product.price)
        let amount = gross - Money.round(gross * value.discountPercent / 100)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value.product.name).lineLimit(1)
                Text("\(IndianNumber.rupees(value.product.price)) · GST \(Money.percent(value.product.gstRate))\(value.product.taxInclusive ? " incl." : " extra")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { change(line, by: -1) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
            DecimalField(title: "Quantity", value: line.quantity, width: 50)
            Button { change(line, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            DecimalField(title: "Discount %", value: line.discountPercent, width: 44).help("Line discount in percent")
            Text("%").foregroundStyle(.secondary)
            Text(IndianNumber.format(amount)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { store.cart.lines.removeAll { $0.id == value.id } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
        }
    }

    private func change(_ line: Binding<POSCartLine>, by delta: Decimal) {
        let quantity = line.wrappedValue.quantity + delta
        if quantity <= 0 {
            store.cart.lines.removeAll { $0.id == line.wrappedValue.id }
        } else {
            line.wrappedValue.quantity = quantity
        }
    }

    private func summaryRow(_ title: String, _ value: Decimal) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Text(IndianNumber.format(value)).monospacedDigit().frame(minWidth: 90, alignment: .trailing)
        }
    }

    private func complete() {
        do {
            onComplete(try store.completeSale())
            message = nil
        } catch {
            message = error.localizedDescription
        }
        searchFocused = true
    }
}

// MARK: - Products

private struct POSProductsPane: View {
    @Bindable var store: POSStore
    let runner: JobRunner

    @State private var selection: Set<POSProduct.ID> = []
    @State private var draft = POSProduct()
    @State private var message: String?
    @FocusState private var nameFocused: Bool

    private var products: [POSProduct] { store.search("") }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Table(products, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("SKU / Barcode", value: \.sku)
                    TableColumn("Price") { Text(IndianNumber.format($0.price)).monospacedDigit() }.width(70)
                    TableColumn("GST") { Text(Money.percent($0.gstRate) + ($0.taxInclusive ? "" : " +")) }.width(54)
                    TableColumn("HSN", value: \.hsn).width(64)
                    TableColumn("Category", value: \.category)
                }
                HStack {
                    Button("Delete", role: .destructive) {
                        store.delete(selection)
                        selection = []
                        draft = POSProduct()
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    Button("Import CSV…", action: importCSV)
                    Button("Export CSV") {
                        let csv = store.catalogCSV()
                        runner.start(title: "POS Billing") { context in
                            try csv.write(to: context.output(named: "Products", extension: "csv"), atomically: true, encoding: .utf8)
                        }
                    }
                    .disabled(store.products.isEmpty)
                }
                Text("CSV columns: " + POSStore.csvHeader.joined(separator: ", ") + ". A header row is optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ToolSection(store.products.contains { $0.id == draft.id } ? "Edit Product" : "New Product") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    BusinessFormRow("Name") { TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder).focused($nameFocused) }
                    BusinessFormRow("SKU / Barcode") { TextField("Scan or type", text: $draft.sku).textFieldStyle(.roundedBorder) }
                    BusinessFormRow("Price") { DecimalField(title: "Price", value: $draft.price, width: 100) }
                    BusinessFormRow("GST") {
                        Picker("GST", selection: $draft.gstRate) {
                            ForEach(GSTRates.all, id: \.self) { Text(Money.percent($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    BusinessFormRow("") { Toggle("Price includes GST", isOn: $draft.taxInclusive) }
                    BusinessFormRow("HSN") { TextField("HSN code", text: $draft.hsn).textFieldStyle(.roundedBorder).frame(width: 120) }
                    BusinessFormRow("Category") { TextField("Optional", text: $draft.category).textFieldStyle(.roundedBorder) }
                }
                HStack {
                    Button("New") {
                        selection = []
                        draft = POSProduct()
                        nameFocused = true
                    }
                    Spacer()
                    Button("Save Product") {
                        store.upsert(draft)
                        selection = [draft.id]
                        message = "Saved \(draft.name)"
                    }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(width: 320)
        }
        .onChange(of: selection) { _, ids in
            if ids.count == 1, let product = store.products.first(where: { ids.contains($0.id) }) { draft = product }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw ToolError.unreadableInput(url) }
            let count = try store.importCSV(text)
            message = "Imported \(count) product\(count == 1 ? "" : "s")"
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Sales

private struct POSSalesPane: View {
    let store: POSStore
    let runner: JobRunner
    var onReprint: (POSSale) -> Void

    @State private var selectedDay: Date?
    @State private var selectedSale: POSSale.ID?

    var body: some View {
        let days = store.days()
        if days.isEmpty {
            ContentUnavailableView("No sales yet", systemImage: "chart.bar", description: Text("Completed bills show up here, grouped by day."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let day = days.first { $0.day == selectedDay } ?? days[0]
            HStack(alignment: .top, spacing: 16) {
                List(days, selection: $selectedDay) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.day.formatted(date: .abbreviated, time: .omitted)).fontWeight(.medium)
                        Text("\(summary.sales.count) sale\(summary.sales.count == 1 ? "" : "s") · \(IndianNumber.rupees(summary.total))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(summary.day)
                }
                .frame(width: 220)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 22) {
                        stat("Total", day.total)
                        stat("GST", day.tax)
                        ForEach(POSPayment.allCases) { payment in stat(payment.label, day.byPayment[payment] ?? 0) }
                    }
                    Table(day.sales, selection: $selectedSale) {
                        TableColumn("Receipt", value: \.number).width(80)
                        TableColumn("Time") { Text($0.date.formatted(date: .omitted, time: .shortened)) }.width(70)
                        TableColumn("Customer") { Text($0.customerName.isEmpty ? "—" : $0.customerName) }
                        TableColumn("Payment") { Text($0.payment.label) }.width(64)
                        TableColumn("Total") { Text(IndianNumber.format($0.totals.total)).monospacedDigit() }.width(80)
                    }
                    .contextMenu(forSelectionType: POSSale.ID.self) { ids in
                        Button("Show Receipt") { reprint(ids, in: day) }
                    } primaryAction: { ids in reprint(ids, in: day) }
                    HStack {
                        Button("Show Receipt") { reprint(selectedSale.map { [$0] } ?? [], in: day) }
                            .disabled(selectedSale == nil)
                        Spacer()
                        Button("Export Day as CSV") { export(day.sales, name: "Sales " + day.day.formatted(.iso8601.year().month().day())) }
                        Button("Export All Sales") { export(store.sales, name: "Sales") }
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(IndianNumber.rupees(value)).font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    private func reprint(_ ids: Set<POSSale.ID>, in day: POSStore.DaySummary) {
        if let sale = day.sales.first(where: { ids.contains($0.id) }) { onReprint(sale) }
    }

    private func export(_ sales: [POSSale], name: String) {
        let csv = store.salesCSV(sales)
        runner.start(title: "POS Billing") { context in
            try csv.write(to: context.output(named: name, extension: "csv"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Shop

private struct POSShopPane: View {
    @Bindable var store: POSStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ToolSection("Shop", footnote: "Printed at the top of every receipt.") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        BusinessFormRow("Name") { field("Shop name", $store.shop.name) }
                        BusinessFormRow("Address") { field("Address", $store.shop.address, multiline: true) }
                        BusinessFormRow("Phone") { field("Phone", $store.shop.phone) }
                        BusinessFormRow("") { Toggle("GST registered (charge GST on bills)", isOn: $store.shop.gstRegistered) }
                        if store.shop.gstRegistered {
                            BusinessFormRow("GSTIN") { GSTINField(text: $store.shop.gstin) }
                        }
                        BusinessFormRow("UPI ID") {
                            HStack {
                                field("name@bank", $store.shop.upiID)
                                Toggle("Show payment QR", isOn: $store.shop.showsUPIQR).fixedSize()
                            }
                        }
                        BusinessFormRow("Footer") { field("Message at the bottom", $store.shop.footer, multiline: true) }
                    }
                }
                ToolSection("Receipts") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        BusinessFormRow("Paper") {
                            Picker("Paper", selection: $store.shop.paper) {
                                ForEach(POSPaper.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        BusinessFormRow("Numbering") {
                            HStack {
                                field("Prefix", $store.shop.receiptPrefix).frame(width: 80)
                                Stepper("Next: \(store.shop.nextReceiptNumber)", value: $store.shop.nextReceipt, in: 1...9_999_999)
                            }
                        }
                        BusinessFormRow("") { Toggle("Round totals to the nearest rupee", isOn: $store.shop.roundsTotal) }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onChange(of: store.shop) { try? store.saveShop() }
    }

    private func field(_ prompt: String, _ text: Binding<String>, multiline: Bool = false) -> some View {
        TextField(prompt, text: text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .lineLimit(multiline ? 1...3 : 1...1)
    }
}

// MARK: - Receipt

private struct POSReceiptSheet: View {
    let sale: POSSale
    let runner: JobRunner

    @Environment(\.dismiss) private var dismiss
    @State private var paper: POSPaper
    @State private var data: Data?

    init(sale: POSSale, runner: JobRunner) {
        self.sale = sale
        self.runner = runner
        _paper = State(initialValue: sale.shop.paper)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receipt \(sale.number)").font(.headline)
                    Text("\(IndianNumber.rupees(sale.totals.total)) · \(sale.payment.label)" +
                         (sale.totals.change.map { " · Change \(IndianNumber.rupees($0))" } ?? ""))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Paper", selection: $paper) {
                    ForEach(POSPaper.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            BusinessPDFPreview(data: data)
                .frame(width: 380, height: 470)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            HStack {
                Button("Save PDF") {
                    let sale = sale, paper = paper
                    runner.start(title: "POS Billing") { context in
                        try POSReceiptPDF.render(sale, paper: paper).write(to: context.output(named: "Receipt \(sale.number)", extension: "pdf"))
                    }
                }
                Button("Print…", systemImage: "printer") {
                    if let data { BusinessPrinting.printPDF(data, jobTitle: "Receipt \(sale.number)") }
                }
                .keyboardShortcut("p")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task(id: paper) { data = try? POSReceiptPDF.render(sale, paper: paper) }
    }
}
