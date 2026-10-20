import SwiftUI
import UniformTypeIdentifiers

enum PDFEditorTools {
    static let all: [Tool] = [
        Tool(id: "pdf.edit", name: "Edit PDF", shortName: "Edit", category: .pdf, symbol: "pencil.line",
             summary: "Change existing text, add text boxes, images, signatures and whiteout.",
             keywords: ["edit text", "add text", "typewriter", "fill", "whiteout", "text box", "image", "signature", "change text", "annotate"],
             input: .pdf) { PDFEditView(tool: $0) },
        Tool(id: "pdf.compare", name: "Compare PDFs", shortName: "Compare", category: .pdf, symbol: "rectangle.split.2x1",
             summary: "See two versions side by side with every changed word highlighted.",
             keywords: ["diff", "difference", "versions", "side by side", "changes", "redline", "compare documents"],
             input: ToolInput(types: UTType.pdfInputs)) { PDFCompareView(tool: $0) },
    ]
}
