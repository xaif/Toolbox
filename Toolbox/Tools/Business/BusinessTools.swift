import SwiftUI
import PDFKit
import UniformTypeIdentifiers

enum BusinessTools {
    static let all: [Tool] = [
        Tool(id: "business.gst-invoice", name: "GST Invoice", category: .business, symbol: "indianrupeesign.square",
             summary: "Create GST tax invoices with CGST, SGST or IGST worked out for you.",
             keywords: ["gst", "invoice", "tax invoice", "bill", "cgst", "sgst", "igst", "hsn", "gstin", "india", "generator"]) { GSTInvoiceView(tool: $0) },
        Tool(id: "business.pos", name: "POS Billing", category: .business, symbol: "cart",
             summary: "Ring up sales, print thermal receipts and track daily totals.",
             keywords: ["pos", "point of sale", "billing", "receipt", "cart", "thermal", "shop", "retail", "upi", "gst", "barcode"]) { POSBillingView(tool: $0) },
    ]
}

/// A rendered PDF shown at fit-to-width.
struct BusinessPDFPreview: NSViewRepresentable {
    var data: Data?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = data.flatMap(PDFDocument.init(data:))
        if let target = view.document?.page(at: min(page, max((view.document?.pageCount ?? 1) - 1, 0))), page > 0 { view.go(to: target) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var data: Data?
    }
}

/// A labelled row in a business form grid.
struct BusinessFormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A GSTIN text field that shows whether the number is valid.
struct GSTINField: View {
    @Binding var text: String
    var optional = false

    var body: some View {
        HStack(spacing: 6) {
            TextField("GSTIN", text: $text, prompt: Text(optional ? "Optional, e.g. 27AAPFU0939F1ZV" : "e.g. 27AAPFU0939F1ZV"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onChange(of: text) { _, value in
                    let normalized = GSTIN.normalized(value)
                    if normalized != value { text = normalized }
                }
            if !text.isEmpty {
                let problem = GSTIN.validate(text)
                Image(systemName: problem == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(problem == nil ? .green : .orange)
                    .help(problem?.message ?? "Valid GSTIN")
            }
        }
    }
}

struct IndianStatePicker: View {
    let title: String
    @Binding var code: String
    var allowsNone = false

    var body: some View {
        Picker(title, selection: $code) {
            if allowsNone { Text("Not set").tag("") }
            ForEach(IndianState.all) { Text($0.label).tag($0.code) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A right-aligned number field for amounts, quantities and percentages.
struct DecimalField: View {
    let title: String
    @Binding var value: Decimal
    var width: CGFloat = 80

    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)).grouping(.never))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
    }
}

/// Where the last export went, or why it failed.
struct BusinessSaveStatus: View {
    let runner: JobRunner

    var body: some View {
        switch runner.phase {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            if !runner.outputs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(runner.outputs[0].lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(runner.outputs) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).lineLimit(2)
        default:
            EmptyView()
        }
    }
}

enum BusinessFiles {
    /// Asks for an image and returns it downscaled as PNG.
    @MainActor
    static func pickImage() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? BusinessStorage.pngData(fromImageAt: url)
    }
}
