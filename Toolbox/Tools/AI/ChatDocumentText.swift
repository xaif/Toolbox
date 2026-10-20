import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A page of readable text. Documents without real pages (text, Word, EPUB) are cut into numbered parts.
struct AIDocumentPage: Hashable, Sendable {
    /// 1-based page (or part) number.
    var number: Int
    var text: String
}

/// A document's text, page by page, for Chat with PDF and PDF to Audio.
struct AIDocumentText: Sendable {
    var name: String
    var pages: [AIDocumentPage]
    /// False when `pages` are parts of a document without pages.
    var isPaged: Bool

    var fullText: String { pages.map(\.text).joined(separator: "\n\n") }

    /// How a citation reads, e.g. "p. 3" or "part 3".
    var citationPrefix: String { isPaged ? "p." : "part" }

    /// Files the loader reads.
    static let types: [UTType] = AIText.documentTypes + [UTType(filenameExtension: "epub")].compactMap { $0 }

    /// Characters per part for documents without pages.
    static let partCharacters = 3000

    /// Reads `url`. PDF pages without a text layer are recognized with OCR when `ocr` is on.
    static func load(_ url: URL, pages range: [Int]? = nil, ocr: Bool = true,
                     progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> AIDocumentText {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || AIText.conforms(url, to: [.pdf]) {
            guard let document = PDFDocument(url: url) else { throw ToolError.unreadableInput(url) }
            if document.isLocked {
                throw ToolError.failed("“\(url.lastPathComponent)” is password-protected. Unlock it first with Remove PDF Password.")
            }
            guard document.pageCount > 0 else { throw ToolError.failed("“\(url.lastPathComponent)” has no pages.") }
            let indices = range ?? Array(0..<document.pageCount)
            var pages: [AIDocumentPage] = []
            for (position, index) in indices.enumerated() {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                var text = page.string ?? ""
                if ocr, text.filter({ !$0.isWhitespace }).count < 20, let image = AIOCR.render(page, dpi: 300) {
                    progress?(Double(position) / Double(indices.count), "Recognizing text on page \(index + 1)…")
                    text = try await AIOCR.recognize(image, options: AIOCR.Options())
                }
                pages.append(AIDocumentPage(number: index + 1, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                progress?(Double(position + 1) / Double(indices.count), "Reading page \(index + 1) of \(document.pageCount)…")
            }
            guard pages.contains(where: { !$0.text.isEmpty }) else {
                throw ToolError.failed("No text was found in “\(url.lastPathComponent)”.")
            }
            return AIDocumentText(name: name, pages: pages, isPaged: true)
        }

        progress?(0, "Reading \(url.lastPathComponent)…")
        let text: String
        if ext == "epub" {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("read-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            text = try await DocumentConverter.readEPUB(url, scratch: scratch)
        } else {
            text = try await AIText.extract(from: url)
        }
        let parts = AISummarizer.split(text.trimmingCharacters(in: .whitespacesAndNewlines), limit: partCharacters)
        guard !parts.isEmpty else { throw ToolError.failed("No text was found in “\(url.lastPathComponent)”.") }
        progress?(1, "")
        return AIDocumentText(name: name, pages: parts.enumerated().map { AIDocumentPage(number: $0.offset + 1, text: $0.element) },
                              isPaged: false)
    }
}
