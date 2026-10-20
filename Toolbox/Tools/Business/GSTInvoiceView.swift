import SwiftUI

struct GSTInvoiceView: View {
    let tool: Tool

    @State private var store: GSTInvoiceStore
    @State private var runner: JobRunner
    @State private var preview: Data?
    @State private var allCopies = false
    @State private var sellerExpanded: Bool
    /// The invoice being exported, so its number is used up only once the PDF is saved.
    @State private var exporting: GSTInvoice?
    @State private var notice: String?

    /// `store` defaults to the user's saved invoices.
    init(tool: Tool, store: GSTInvoiceStore? = nil) {
        let store = store ?? .shared
        self.tool = tool
        _store = State(initialValue: store)
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
        _sellerExpanded = State(initialValue: store.working.seller.party.name.isEmpty)
    }

    private var invoice: GSTInvoice { store.working }

    var body: some View {
        @Bindable var store = store
        ToolPage(tool: tool, scrolls: false) {
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        draftBar
                        sellerSection($store.working.seller)
                        buyerSection($store.working)
                        detailsSection($store.working)
                        itemsSection($store.working)
                        optionsSection($store.working)
                    }
                    .padding(.trailing, 8)
                    .disabled(runner.isRunning)
                }
                .frame(minWidth: 500, maxWidth: .infinity)
                previewPane
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 400)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Export PDF", canRun: invoice.problems.isEmpty,
                   hint: invoice.problems.first, action: export)
        }
        .task(id: store.working) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            preview = try? GSTInvoicePDF.render(store.working)
            store.saveWorking()
        }
        .onChange(of: runner.phase) { _, phase in
            guard let issued = exporting, phase != .running else { return }
            if phase == .succeeded {
                store.didIssue(issued)
                try? store.saveDraft(issued)
            }
            exporting = nil
        }
    }

    // MARK: Drafts

    private var draftBar: some View {
        HStack(spacing: 8) {
            Button("New Invoice", systemImage: "doc.badge.plus") {
                store.startNew()
                notice = nil
            }
            Menu("Drafts") {
                if store.drafts.isEmpty { Text("No saved drafts") }
                ForEach(store.drafts) { draft in
                    Button("\(draft.number) · \(draft.buyer.name.isEmpty ? "No buyer" : draft.buyer.name) · \(draft.date.formatted(date: .abbreviated, time: .omitted))") {
                        store.working = draft
                        notice = "Opened \(draft.number)"
                    }
                }
                if store.drafts.contains(where: { $0.id == invoice.id }) {
                    Divider()
                    Button("Delete This Draft", role: .destructive) {
                        if let draft = store.drafts.first(where: { $0.id == invoice.id }) { store.deleteDraft(draft) }
                        notice = "Deleted the draft"
                    }
                }
            }
            .fixedSize()
            Button("Save Draft") {
                do {
                    try store.saveDraft(invoice)
                    notice = "Saved \(invoice.number)"
                } catch {
                    notice = error.localizedDescription
                }
            }
            .keyboardShortcut("s")
            if let notice { Text(notice).foregroundStyle(.secondary).font(.callout) }
            Spacer()
        }
    }

    // MARK: Seller

    private func sellerSection(_ seller: Binding<GSTSellerProfile>) -> some View {
        ToolSection("Seller", footnote: sellerExpanded ? "Saved details fill in every new invoice." : nil) {
            DisclosureGroup(isExpanded: $sellerExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    BusinessFormRow("Business name") { textField("Your business name", seller.party.name) }
                    BusinessFormRow("Address") { textField("Street, city, PIN", seller.party.address, multiline: true) }
                    BusinessFormRow("GSTIN") {
                        GSTINField(text: seller.party.gstin)
                            .onChange(of: seller.wrappedValue.party.gstin) { _, value in
                                guard GSTIN.validate(value) == nil, let code = GSTIN.stateCode(of: value) else { return }
                                if store.working.placeOfSupply == seller.wrappedValue.party.stateCode { store.working.placeOfSupply = code }
                                seller.wrappedValue.party.stateCode = code
                            }
                    }
                    BusinessFormRow("State") { IndianStatePicker(title: "State", code: seller.party.stateCode) }
                    BusinessFormRow("Phone · Email") {
                        HStack { textField("Phone", seller.party.phone); textField("Email", seller.party.email) }
                    }
                    BusinessFormRow("Bank") {
                        HStack { textField("Bank name", seller.bankName); textField("Account name", seller.accountName) }
                    }
                    BusinessFormRow("Account · IFSC") {
                        HStack { textField("Account number", seller.accountNumber); textField("IFSC", seller.ifsc).frame(width: 130) }
                    }
                    BusinessFormRow("UPI ID") {
                        HStack {
                            textField("name@bank", seller.upiID)
                            Toggle("QR code for the total", isOn: seller.showsUPIQR).fixedSize()
                        }
                    }
                    BusinessFormRow("Logo · Signature") {
                        HStack(spacing: 12) {
                            imageButton("Logo", data: seller.logoPNG)
                            imageButton("Signature", data: seller.signaturePNG)
                        }
                    }
                    BusinessFormRow("Numbering") {
                        HStack {
                            textField("Prefix", seller.invoicePrefix).frame(width: 90)
                            Stepper("Next: \(seller.wrappedValue.nextInvoiceNumber)", value: seller.nextNumber, in: 1...999_999)
                        }
                    }
                    BusinessFormRow("Terms") { textField("Payment terms and conditions", seller.terms, multiline: true) }
                }
                .padding(.top, 8)
                HStack {
                    Spacer()
                    Button("Save as Default Seller") {
                        do {
                            try store.saveProfile(seller.wrappedValue)
                            notice = "Saved your business details"
                        } catch {
                            notice = error.localizedDescription
                        }
                    }
                }
            } label: {
                let party = seller.wrappedValue.party
                Text(party.name.isEmpty ? "Add your business details" : [party.name, party.gstin].filter { !$0.isEmpty }.joined(separator: " · "))
                    .fontWeight(.medium)
            }
        }
    }

    private func imageButton(_ title: String, data: Binding<Data?>) -> some View {
        HStack(spacing: 6) {
            if let image = data.wrappedValue.flatMap(NSImage.init(data:)) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
                Button("Remove \(title)") { data.wrappedValue = nil }.buttonStyle(.link)
            } else {
                Button("Choose \(title)…") { if let png = BusinessFiles.pickImage() { data.wrappedValue = png } }
            }
        }
    }

    // MARK: Buyer

    private func buyerSection(_ invoice: Binding<GSTInvoice>) -> some View {
        ToolSection("Bill To") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                BusinessFormRow("Name") { textField("Customer or business name", invoice.buyer.name) }
                BusinessFormRow("Address") { textField("Billing address", invoice.buyer.address, multiline: true) }
                BusinessFormRow("GSTIN") {
                    GSTINField(text: invoice.buyer.gstin, optional: true)
                        .onChange(of: invoice.wrappedValue.buyer.gstin) { _, value in
                            guard GSTIN.validate(value) == nil, let code = GSTIN.stateCode(of: value) else { return }
                            let old = invoice.wrappedValue.buyer.stateCode
                            if invoice.wrappedValue.placeOfSupply == old || old.isEmpty { invoice.wrappedValue.placeOfSupply = code }
                            invoice.wrappedValue.buyer.stateCode = code
                        }
                }
                BusinessFormRow("State") {
                    IndianStatePicker(title: "State", code: invoice.buyer.stateCode, allowsNone: true)
                        .onChange(of: invoice.wrappedValue.buyer.stateCode) { old, code in
                            if !code.isEmpty, invoice.wrappedValue.placeOfSupply == old || old.isEmpty { invoice.wrappedValue.placeOfSupply = code }
                        }
                }
                BusinessFormRow("Phone · Email") {
                    HStack { textField("Phone", invoice.buyer.phone); textField("Email", invoice.buyer.email) }
                }
            }
        }
    }

    // MARK: Details

    private func detailsSection(_ invoice: Binding<GSTInvoice>) -> some View {
        ToolSection("Invoice") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                BusinessFormRow("Number") {
                    HStack {
                        textField("Invoice number", invoice.number).frame(width: 160)
                        DatePicker("Date", selection: invoice.date, displayedComponents: .date).fixedSize()
                    }
                }
                BusinessFormRow("Due date") {
                    HStack {
                        Toggle("Due date", isOn: Binding(
                            get: { invoice.wrappedValue.dueDate != nil },
                            set: { invoice.wrappedValue.dueDate = $0 ? Calendar.current.date(byAdding: .day, value: 15, to: invoice.wrappedValue.date) : nil }))
                            .labelsHidden()
                        if invoice.wrappedValue.dueDate != nil {
                            DatePicker("Due", selection: Binding(get: { invoice.wrappedValue.dueDate ?? Date() }, set: { invoice.wrappedValue.dueDate = $0 }),
                                       displayedComponents: .date)
                                .labelsHidden().fixedSize()
                        }
                    }
                }
                BusinessFormRow("Place of supply") {
                    HStack {
                        IndianStatePicker(title: "Place of supply", code: invoice.placeOfSupply)
                        Text(invoice.wrappedValue.isInterState ? "Inter-state: IGST" : "Intra-state: CGST + \(GSTInvoiceTotals(invoice.wrappedValue).stateTaxName)")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
                BusinessFormRow("") { Toggle("Tax payable on reverse charge", isOn: invoice.reverseCharge) }
            }
        }
    }

    // MARK: Items

    private func itemsSection(_ invoice: Binding<GSTInvoice>) -> some View {
        let totals = GSTInvoiceTotals(invoice.wrappedValue)
        return ToolSection("Items") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("Description"); Text("HSN/SAC"); Text("Qty"); Text("Unit"); Text("Rate"); Text("Disc %"); Text("GST")
                    Text("Amount").gridColumnAlignment(.trailing); Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(invoice.items) { $item in
                    GridRow(alignment: .firstTextBaseline) {
                        TextField("Item or service", text: $item.description).textFieldStyle(.roundedBorder).frame(minWidth: 120)
                        TextField("HSN", text: $item.hsn).textFieldStyle(.roundedBorder).frame(width: 66)
                        DecimalField(title: "Qty", value: $item.quantity, width: 52)
                        TextField("Unit", text: $item.unit).textFieldStyle(.roundedBorder).frame(width: 44)
                        DecimalField(title: "Rate", value: $item.rate, width: 78)
                        DecimalField(title: "Discount", value: $item.discountPercent, width: 44)
                        Picker("GST", selection: $item.gstRate) {
                            ForEach(GSTRates.all, id: \.self) { Text(Money.percent($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 72)
                        Text(IndianNumber.format(lineTotal(item, in: invoice.wrappedValue)))
                            .monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                        Button {
                            invoice.wrappedValue.items.removeAll { $0.id == item.id }
                            if invoice.wrappedValue.items.isEmpty { invoice.wrappedValue.items = [GSTLineItem()] }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove item")
                    }
                }
            }
            HStack {
                Button("Add Item", systemImage: "plus") {
                    var item = GSTLineItem()
                    if let last = invoice.wrappedValue.items.last { item.gstRate = last.gstRate; item.unit = last.unit }
                    invoice.wrappedValue.items.append(item)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Spacer()
            }
            Divider()
            VStack(alignment: .trailing, spacing: 3) {
                summaryRow("Taxable value", totals.sum.taxable)
                if totals.isInterState {
                    summaryRow("IGST", totals.sum.igst)
                } else {
                    summaryRow("CGST", totals.sum.cgst)
                    summaryRow(totals.stateTaxName, totals.sum.sgst)
                }
                if totals.roundOff != 0 { summaryRow("Round off", totals.roundOff) }
                HStack {
                    Text("Total").font(.headline)
                    Text(IndianNumber.rupees(totals.grandTotal)).font(.headline.monospacedDigit()).frame(minWidth: 110, alignment: .trailing)
                }
                Text(IndianNumber.words(totals.grandTotal)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func lineTotal(_ item: GSTLineItem, in invoice: GSTInvoice) -> Decimal {
        let gross = Money.round(item.quantity * item.rate)
        let net = gross - Money.round(gross * item.discountPercent / 100)
        return GSTMath.breakdown(net: net, rate: item.gstRate, inclusive: invoice.pricesIncludeTax, interState: invoice.isInterState).total
    }

    private func summaryRow(_ title: String, _ value: Decimal) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Text(IndianNumber.format(value)).monospacedDigit().frame(minWidth: 110, alignment: .trailing)
        }
    }

    // MARK: Options

    private func optionsSection(_ invoice: Binding<GSTInvoice>) -> some View {
        ToolSection("Options") {
            Toggle("Rates include GST", isOn: invoice.pricesIncludeTax)
            Toggle("Round the total to the nearest rupee", isOn: invoice.roundsTotal)
            HStack {
                Picker("Copy", selection: invoice.copy) {
                    ForEach(GSTInvoice.Copy.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .disabled(allCopies)
                Toggle("Export all three copies", isOn: $allCopies)
            }
            textField("Notes for this invoice (optional)", invoice.notes, multiline: true)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.headline)
            BusinessPDFPreview(data: preview)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            HStack {
                Button("Print…", systemImage: "printer") { printInvoice() }
                    .keyboardShortcut("p")
                    .disabled(!invoice.problems.isEmpty)
                Spacer()
            }
        }
    }

    // MARK: Actions

    private func textField(_ prompt: String, _ text: Binding<String>, multiline: Bool = false) -> some View {
        TextField(prompt, text: text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .lineLimit(multiline ? 1...4 : 1...1)
    }

    private var copies: [GSTInvoice.Copy]? { allCopies ? GSTInvoice.Copy.allCases : nil }

    private func export() {
        let invoice = invoice
        let copies = copies
        if store.profile.party.name.isEmpty { try? store.saveProfile(invoice.seller) }
        exporting = invoice
        runner.start(title: tool.name) { context in
            let data = try GSTInvoicePDF.render(invoice, copies: copies)
            try data.write(to: context.output(named: "Invoice \(invoice.number)", extension: "pdf"))
        }
        if !runner.isRunning { exporting = nil }
    }

    private func printInvoice() {
        guard let data = try? GSTInvoicePDF.render(invoice, copies: copies) else { return }
        BusinessPrinting.printPDF(data, jobTitle: "Invoice \(invoice.number)")
    }
}
