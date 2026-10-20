import SwiftUI

/// PDF tools built on on-device text recognition: OCR, scanning and redaction.
enum PDFOCRTools {
    static let all: [Tool] = [
        Tool(id: "pdf.ocr", name: "Make PDF Searchable (OCR)", shortName: "Make Searchable", category: .pdf, symbol: "doc.text.magnifyingglass",
             summary: "Add a hidden text layer to scanned PDFs so you can search, select and copy their text.",
             keywords: ["ocr", "searchable", "scanned", "scan", "recognize", "text layer", "copy text", "image pdf"],
             input: .pdfs, quickAction: QuickAction("Make Searchable", settings: PDFSearchableView.Settings.self)) { PDFSearchableView(tool: $0) },
        Tool(id: "pdf.scan", name: "Scan to PDF", shortName: "Scan", category: .pdf, symbol: "doc.viewfinder",
             summary: "Scan paper with your iPhone, iPad or Mac camera. Pages are cropped and straightened automatically.",
             keywords: ["scan", "scanner", "camera", "webcam", "iphone", "ipad", "continuity", "deskew", "crop", "document", "photo to pdf", "ocr"]) { ScanToPDFView(tool: $0) },
        Tool(id: "pdf.redact", name: "Redact PDF", shortName: "Redact", category: .pdf, symbol: "text.badge.xmark",
             summary: "Black out sensitive text and areas for good. What's underneath is removed, not just covered.",
             keywords: ["redact", "black out", "blackout", "censor", "sensitive", "privacy", "hide", "remove text", "confidential", "gdpr"],
             input: .pdf) { PDFRedactView(tool: $0) },
    ]
}
