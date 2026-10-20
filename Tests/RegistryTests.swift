import XCTest
@testable import Toolbox

final class RegistryTests: XCTestCase {
    func testToolIDsAreUniqueAndEveryCategoryHasTools() {
        let ids = ToolRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for category in ToolCategory.allCases {
            XCTAssertFalse(ToolRegistry.tools(in: category).isEmpty, "\(category) has no tools")
        }
    }

    /// Every tool on ihatepdf.cv, searched by its name there, finds the tool that covers it.
    func testIHatePDFToolNamesFindTheirTools() {
        let expected: [(String, String)] = [
            ("Merge PDFs", "pdf.merge"), ("Compress PDF", "pdf.compress"), ("Split PDF", "pdf.split"),
            ("PDF to JPG", "pdf.to-images"), ("Word to PDF", "files.convert"), ("PDF to Word", "files.convert"),
            ("Images to PDF", "pdf.images-to-pdf"),
            ("Edit PDF Text", "pdf.edit"), ("Organize Pages", "pdf.organize"), ("Rotate PDF", "pdf.rotate"),
            ("Crop & Resize", "pdf.crop-resize"), ("Add Watermark", "pdf.watermark"), ("Add Page Numbers", "pdf.page-numbers"),
            ("Headers & Footers", "pdf.headers-footers"), ("Extract Text", "ai.extract-text"), ("OCR Searchable PDF", "pdf.ocr"),
            ("Encrypt PDF", "pdf.add-password"), ("Remove Password", "pdf.remove-password"), ("Redact PDF", "pdf.redact"),
            ("Flatten PDF", "pdf.flatten"), ("Privacy Risk Scanner", "pdf.privacy-scan"),
            ("Create PDF", "pdf.create"), ("Markdown to PDF", "files.convert"), ("HTML to PDF", "files.convert"),
            ("Excel to PDF", "files.convert"), ("CSV to PDF", "files.convert"), ("PowerPoint to PDF", "files.convert"),
            ("PDF to PowerPoint", "files.convert"), ("PDF to Excel", "files.convert"), ("PDF to HTML", "files.convert"),
            ("PDF to EPUB", "files.convert"), ("PDF to Audio", "ai.pdf-to-audio"), ("eBook to PDF", "files.convert"),
            ("Audio to PDF", "ai.transcribe"), ("PDF to ZIP", "pdf.to-images"), ("Invert PDF Colours", "pdf.invert-colors"),
            ("Chat with PDF AI", "ai.chat-pdf"), ("AI PDF Summarizer", "ai.summarize"), ("Compare PDFs", "pdf.compare"),
            ("Repair PDF", "pdf.repair"),
            ("Scan to PDF", "pdf.scan"), ("P2P Share", "files.share-wifi"), ("Collaborative Whiteboard", "image.whiteboard"),
            ("GST Invoice Generator", "business.gst-invoice"), ("POS Billing", "business.pos"), ("Fingerprint PDF", "pdf.fingerprint"),
        ]
        for (query, id) in expected {
            XCTAssertNotNil(ToolRegistry.tool(id), "\(id) isn't registered")
            let top = ToolRegistry.search(query).prefix(3).map(\.id)
            XCTAssertTrue(top.contains(id), "“\(query)” → \(top), expected \(id)")
        }
        XCTAssertEqual(ToolRegistry.search("word to pdf").first?.id, "files.convert")
        XCTAssertEqual(ToolRegistry.search("pdf to html").first?.id, "files.convert")
    }
}
