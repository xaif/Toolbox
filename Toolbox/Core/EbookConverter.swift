import Foundation
import PDFKit

/// Kindle and FictionBook ebooks through Calibre's `ebook-convert`, and EPUB → PDF through WebKit so
/// chapters keep their styling and pictures.
enum EbookConverter {
    /// Formats only Calibre can read.
    static let calibreExtensions = ["mobi", "azw3", "azw", "fb2"]
    /// Targets `ebook-convert` writes directly; other targets go through EPUB.
    static let calibreTargets = ["pdf", "epub", "docx", "txt"]

    static func needsCalibre(_ url: URL) -> Bool { calibreExtensions.contains(url.pathExtension.lowercased()) }

    /// Converts with `ebook-convert`; the output's extension picks the format.
    static func calibre(_ input: URL, to output: URL, context: JobContext? = nil) async throws {
        let executable = try Dependencies.require(.calibre)
        var arguments = [input.path, output.path]
        if output.pathExtension.lowercased() == "pdf" { arguments += ["--paper-size", Locale.current.region == .unitedStates ? "letter" : "a4"] }
        do {
            try await ProcessRunner.runChecked(executable, arguments: arguments, onStdoutLine: { line in
                // Progress lines look like "34% Converting input to HTML...".
                if let percent = line.split(separator: "%").first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                    context?.setProgress(percent / 100)
                }
            })
        } catch {
            throw ToolError.failed("Calibre couldn't convert “\(input.lastPathComponent)”. Books bought from Amazon are usually DRM-protected and can't be converted.")
        }
        guard PDFOps.fileSize(output) > 0 else { throw ToolError.failed("Calibre didn't produce a file.") }
    }

    /// Renders each chapter in reading order with WebKit and joins them into one PDF.
    static func epubToPDF(_ input: URL, to output: URL, scratch: URL, context: JobContext? = nil) async throws {
        let (folder, chapters) = try await DocumentConverter.epubSpine(input, scratch: scratch)
        guard !chapters.isEmpty else { throw ToolError.failed("This EPUB has no chapters.") }
        let setup = PDFPageSetup(paper: Locale.current.region == .unitedStates ? .letter : .a4, landscape: false, margin: 54)
        var parts: [URL] = []
        for (index, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            context?.setStatus("Laying out chapter \(index + 1) of \(chapters.count)…")
            let part = scratch.appendingPathComponent("chapter-\(index).pdf")
            try await WebPDFConverter.render(file: chapter, readAccess: folder, to: part, page: setup)
            parts.append(part)
            context?.setProgress(Double(index + 1) / Double(chapters.count) * 0.9)
        }
        try PDFOps.write(try PDFOps.merge(parts, bookmarks: false), to: output)
    }
}
