import SwiftUI

enum PDFIntegrityTools {
    static let all: [Tool] = [
        Tool(id: "pdf.repair", name: "Repair PDF", shortName: "Repair", category: .pdf, symbol: "bandage",
             summary: "Recover pages from damaged, truncated or corrupted PDFs.",
             keywords: ["fix", "broken", "corrupt", "corrupted", "damaged", "recover", "truncated", "salvage", "won't open", "rebuild"],
             input: .pdfs, quickAction: QuickAction("Repair") { _ in PDFRepairView.job(report: nil) }) { PDFRepairView(tool: $0) },
        Tool(id: "pdf.privacy-scan", name: "PDF Privacy Scan", shortName: "Privacy Scan", category: .pdf, symbol: "checkmark.shield",
             summary: "Find hidden author names, photo locations, scripts and attachments, then strip them.",
             keywords: ["privacy", "risk", "scanner", "metadata", "gps", "location", "author", "hidden data", "sanitize", "scrub", "exif", "clean", "redact metadata"],
             input: .pdfs, quickAction: QuickAction("Remove Hidden Data from", settings: PDFPrivacyScanView.Settings.self)) { PDFPrivacyScanView(tool: $0) },
    ]
}
