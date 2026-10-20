import AppKit
import PDFKit
import CoreText
import Vision

enum DocumentConverter {
    static func convert(_ input: URL, target: String, context: JobContext) async throws {
        let scratch = try context.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let family = ConversionCatalog.family(of: input)
        let output = context.output(for: input, extension: target)
        if family == .spreadsheet, target == "pdf", ["csv", "tsv"].contains(input.pathExtension.lowercased()) {
            try TablePDFConverter.convert(input, to: output)
            return
        }
        if family == .slides || family == .spreadsheet {
            if ["jpg", "png"].contains(target) {
                let intermediate = scratch.appendingPathComponent("slides.pdf")
                try await office(input, target: "pdf", to: intermediate, scratch: scratch)
                try exportPages(try PDFOps.open(intermediate), input: input, target: target, context: context)
            } else { try await office(input, target: target, to: output, scratch: scratch) }
            return
        }
        var source = input
        if EbookConverter.needsCalibre(input) {
            if EbookConverter.calibreTargets.contains(target) {
                try await EbookConverter.calibre(input, to: output, context: context)
                return
            }
            source = scratch.appendingPathComponent("book.epub")
            try await EbookConverter.calibre(input, to: source, context: context)
        }
        if input.pathExtension.lowercased() == "pages" {
            source = scratch.appendingPathComponent("source.docx")
            try await pages(input, target: "docx", to: source, scratch: scratch)
        }
        if target == "pages" {
            if !["docx", "rtf", "rtfd", "doc"].contains(source.pathExtension.lowercased()) {
                let richText = try await read(source, scratch: scratch)
                source = scratch.appendingPathComponent("source.docx")
                try await writeDocx(richText, to: source, scratch: scratch)
            }
            try await pages(source, target: "pages", to: output, scratch: scratch)
            return
        }
        // Prefer the Office layout engine when available for Word → PDF/image export.
        if ["pdf", "png", "jpg"].contains(target), ["docx", "doc"].contains(source.pathExtension.lowercased()), Dependencies.locate(.libreoffice) != nil {
            let pdfURL = target == "pdf" ? output : scratch.appendingPathComponent("document.pdf")
            try await office(source, target: "pdf", to: pdfURL, scratch: scratch)
            if target != "pdf" { try exportPages(try PDFOps.open(pdfURL), input: input, target: target, context: context) }
            return
        }
        let sourceExtension = ConversionCatalog.normalizedExtension(source.pathExtension)
        if ["pdf", "png", "jpg"].contains(target), ["html", "md", "epub"].contains(sourceExtension) {
            // WebKit lays these out, so CSS, tables and images survive.
            let pdfURL = target == "pdf" ? output : scratch.appendingPathComponent("document.pdf")
            switch sourceExtension {
            case "html": try await WebPDFConverter.render(file: source, to: pdfURL)
            case "md": try await WebPDFConverter.render(html: MarkdownHTML.document(try readText(source), title: input.deletingPathExtension().lastPathComponent),
                                                       baseURL: source.deletingLastPathComponent(), to: pdfURL)
            default: try await EbookConverter.epubToPDF(source, to: pdfURL, scratch: scratch, context: context)
            }
            if target != "pdf" { try exportPages(try PDFOps.open(pdfURL), input: input, target: target, context: context) }
            return
        }
        if target == "html", sourceExtension == "md" {
            try MarkdownHTML.document(try readText(source), title: input.deletingPathExtension().lastPathComponent).write(to: output, atomically: true, encoding: .utf8)
            return
        }
        let rich = try await read(source, scratch: scratch)
        switch target {
        case "txt", "md": try rich.string.write(to: output, atomically: true, encoding: .utf8)
        case "html": try html(rich.string, title: input.deletingPathExtension().lastPathComponent).write(to: output, atomically: true, encoding: .utf8)
        case "docx": try await writeDocx(rich, to: output, scratch: scratch)
        case "pdf": try renderPDF(rich, to: output)
        case "jpg", "png":
            let pdf = scratch.appendingPathComponent("document.pdf")
            try renderPDF(rich, to: pdf)
            try exportPages(try PDFOps.open(pdf), input: input, target: target, context: context)
        case "epub": try await writeEPUB(text: rich.string, title: input.deletingPathExtension().lastPathComponent, to: output, scratch: scratch)
        default: throw ToolError.unsupported(target)
        }
    }

    static func pdf(_ input: URL, target: String, fixedEPUB: Bool, reflowHTML: Bool = false, context: JobContext) async throws {
        let document = try PDFOps.open(input)
        if ["png", "jpg"].contains(target) { try exportPages(document, input: input, target: target, context: context); return }
        let scratch = try context.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let output = context.output(for: input, extension: target)
        if target == "html" {
            let html = try await PDFHTMLConverter.convert(document, title: input.deletingPathExtension().lastPathComponent, reflow: reflowHTML) {
                context.setProgress($0 * 0.95)
            }
            try html.write(to: output, atomically: true, encoding: .utf8)
            return
        }
        if target == "pptx" { try await OfficePackage.writeSlides(document, to: output, scratch: scratch); return }
        if target == "epub", fixedEPUB {
            try await writeEPUB(text: "", title: input.deletingPathExtension().lastPathComponent, to: output, scratch: scratch, pages: document)
            return
        }
        var texts: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            context.setStatus("Reading page \(index + 1) of \(document.pageCount)…")
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let image = PDFOps.renderPage(page, scale: 2) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            texts.append(text)
            context.setProgress(Double(index + 1) / Double(document.pageCount) * 0.8)
        }
        let text = texts.joined(separator: "\n\n")
        switch target {
        case "txt", "md": try text.write(to: output, atomically: true, encoding: .utf8)
        case "docx", "pages":
            let word = target == "pages" ? scratch.appendingPathComponent("converted.docx") : output
            try await writeDocx(styled(text), to: word, scratch: scratch)
            if target == "pages" { try await pages(word, target: "pages", to: output, scratch: scratch) }
        case "xlsx":
            let sheets = texts.enumerated().map { index, text in
                ("Page \(index + 1)", text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map {
                    $0.replacingOccurrences(of: " {2,}", with: "\t", options: .regularExpression).components(separatedBy: "\t")
                })
            }
            try await OfficePackage.writeWorkbook(sheets, to: output, scratch: scratch)
        case "epub": try await writeEPUB(text: text, title: input.deletingPathExtension().lastPathComponent, to: output, scratch: scratch)
        default: throw ToolError.unsupported(target)
        }
    }

    static func exportPages(_ document: PDFDocument, input: URL, target: String, context: JobContext) throws {
        let folder = try context.outputFolder(named: input.deletingPathExtension().lastPathComponent + "-pages", nextTo: input)
        try PDFOps.exportImages(document, pages: PDFOps.allPages(document), to: folder,
                                format: target == "jpg" ? .jpeg : .png, quality: 0.92, dpi: 300)
    }

    static func office(_ input: URL, target: String, to output: URL, scratch: URL) async throws {
        let executable = try Dependencies.require(.libreoffice)
        let destination = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let profile = scratch.appendingPathComponent("profile-" + UUID().uuidString).absoluteString
        try await ProcessRunner.runChecked(executable, arguments: ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", target,
                                                                 "--outdir", destination.path, input.path])
        let candidate = destination.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(target)
        guard FileManager.default.fileExists(atPath: candidate.path), PDFOps.fileSize(candidate) > 0 else {
            throw ToolError.failed("LibreOffice couldn't export this file as \(target.uppercased()). Check that the file opens in LibreOffice.")
        }
        try FileManager.default.moveItem(at: candidate, to: output)
    }

    /// Arguments carry paths as data; no file path is interpolated into AppleScript source.
    static func pages(_ input: URL, target: String, to output: URL, scratch: URL) async throws {
        let installed = await MainActor.run { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil }
        guard installed else { throw ToolError.failed("Install Apple Pages to read or write PAGES documents. Toolbox uses Pages locally and macOS will ask for Automation permission.") }
        let copy = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(input.pathExtension)
        try FileManager.default.copyItem(at: input.resolvingSymlinksInPath(), to: copy)
        let export: String
        switch target {
        case "pages": export = "save d in destinationFile"
        case "docx": export = "export d to destinationFile as Microsoft Word"
        case "pdf": export = "export d to destinationFile as PDF"
        default: throw ToolError.unsupported(target)
        }
        let script = """
        on run argv
            set sourceFile to POSIX file (item 1 of argv)
            set destinationFile to POSIX file (item 2 of argv)
            tell application "Pages"
                set d to open sourceFile
                try
                    \(export)
                    close d saving no
                on error messageText number errorNumber
                    close d saving no
                    error messageText number errorNumber
                end try
            end tell
        end run
        """
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script, copy.path, output.path])
        guard FileManager.default.fileExists(atPath: output.path) else { throw ToolError.failed("Pages didn't produce a document.") }
    }

    static func read(_ url: URL, scratch: URL) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "epub" { return styled(try await readEPUB(url, scratch: scratch)) }
        if ["docx", "doc", "rtf", "rtfd"].contains(ext) {
            let rtf = scratch.appendingPathComponent("read-\(UUID().uuidString).rtf")
            try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/textutil"), arguments: ["-convert", "rtf", "-output", rtf.path, url.path])
            guard let result = NSAttributedString(rtf: try Data(contentsOf: rtf), documentAttributes: nil) else { throw ToolError.unreadableInput(url) }
            return result
        }
        if ext == "textclipping" {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            let values = plist?["UTI-Data"] as? [String: Any] ?? plist ?? [:]
            for key in ["public.utf8-plain-text", "public.utf16-external-plain-text", "com.apple.traditional-mac-plain-text"] {
                if let data = values[key] as? Data, let text = String(data: data, encoding: key.contains("utf16") ? .utf16 : .utf8) ?? String(data: data, encoding: .macOSRoman) { return styled(text) }
                if let text = values[key] as? String { return styled(text) }
            }
            throw ToolError.failed("Couldn't read the text clipping. Open it in Finder and save its text as TXT or RTF.")
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ToolError.unreadableInput(url) }
        if ext == "html" || ext == "htm" { return styled(plainHTML(text)) }
        if ext == "md" || ext == "markdown", let markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) {
            let result = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
            result.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: result.length))
            return result
        }
        return styled(text)
    }

    /// A text file's contents in UTF-8, UTF-16 or Mac Roman.
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .macOSRoman) else {
            throw ToolError.unreadableInput(url)
        }
        return text
    }

    static func styled(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
    static func writeDocx(_ text: NSAttributedString, to output: URL, scratch: URL) async throws {
        let rtf = scratch.appendingPathComponent("write-\(UUID().uuidString).rtf")
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/textutil"), arguments: ["-convert", "docx", "-output", output.path, rtf.path])
    }
    static func renderPDF(_ text: NSAttributedString, to output: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &bounds, nil) else { throw ToolError.failed("Couldn't create PDF.") }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: bounds.insetBy(dx: 48, dy: 48), transform: nil)
        var offset = 0
        repeat {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 || text.length == 0 else { throw ToolError.failed("Couldn't lay out this document.") }
            offset += visible.length
        } while offset < text.length
        context.closePDF()
    }

    static func xml(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xfffe && $0.value != 0xffff) })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func html(_ text: String, title: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(xml(title))</title></head><body>" + text.components(separatedBy: "\n").map { "<p>\(xml($0))</p>" }.joined() + "</body></html>"
    }
    static func plainHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|tr)>|<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func readEPUB(_ input: URL, scratch: URL) async throws -> String {
        try await epubSpine(input, scratch: scratch).chapters.map { plainHTML(try String(contentsOf: $0, encoding: .utf8)) }.joined(separator: "\n\n")
    }

    /// Unpacks an EPUB into `scratch` and returns the folder with its chapter files in reading order.
    static func epubSpine(_ input: URL, scratch: URL) async throws -> (folder: URL, chapters: [URL]) {
        let folder = scratch.appendingPathComponent("book-" + UUID().uuidString, isDirectory: true)
        try await ArchiveEngine.extract(input, to: folder)
        let container = try XMLDocument(contentsOf: folder.appendingPathComponent("META-INF/container.xml"), options: .nodeLoadExternalEntitiesNever)
        guard let packagePath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else { throw ToolError.failed("This EPUB has no package document.") }
        try ArchiveEngine.validatePath(packagePath)
        let packageURL = folder.appendingPathComponent(packagePath)
        let package = try XMLDocument(contentsOf: packageURL, options: .nodeLoadExternalEntitiesNever)
        var manifest: [String: String] = [:]
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue { manifest[id] = href }
        }
        var chapters: [URL] = []
        for node in try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref") {
            try Task.checkCancellation()
            if let id = node.stringValue, let href = manifest[id] {
                let file = href.components(separatedBy: "#")[0].removingPercentEncoding ?? href
                let url = packageURL.deletingLastPathComponent().appendingPathComponent(file).standardizedFileURL
                guard url.path.hasPrefix(folder.standardizedFileURL.path + "/"), !file.hasPrefix("/"), !file.contains(":") else {
                    throw ToolError.failed("This EPUB refers to a chapter outside the book.")
                }
                chapters.append(url)
            }
        }
        return (folder, chapters)
    }

    static func writeEPUB(text: String, title: String, to output: URL, scratch: URL, pages: PDFDocument? = nil) async throws {
        let root = scratch.appendingPathComponent("epub-" + UUID().uuidString, isDirectory: true)
        let content = root.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        func write(_ string: String, _ name: String) throws { try string.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try write("application/epub+zip", "mimetype")
        try write("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>", "META-INF/container.xml")
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        var spine = "", links = ""
        let count = pages?.pageCount ?? 1
        for index in 0..<count {
            try Task.checkCancellation()
            let id = "page\(index + 1)"
            var body: String
            var head = ""
            if let page = pages?.page(at: index), let image = PDFOps.renderPage(page, scale: 2),
               let data = PDFOps.encode(image, as: .jpeg, quality: 0.9, dpi: 144) {
                try data.write(to: content.appendingPathComponent(id + ".jpg"))
                manifest += "<item id=\"image\(index)\" href=\"\(id).jpg\" media-type=\"image/jpeg\"/>"
                head = "<meta name=\"viewport\" content=\"width=\(image.width), height=\(image.height)\"/>"
                body = "<img src=\"\(id).jpg\" alt=\"Page \(index + 1)\" style=\"width:100%;height:100%\"/>"
            } else { body = text.components(separatedBy: "\n").map { "<p>\(xml($0))</p>" }.joined() }
            try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(xml(title))</title>\(head)</head><body>\(body)</body></html>", "OEBPS/\(id).xhtml")
            manifest += "<item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"\(id)\"/>"
            links += "<li><a href=\"\(id).xhtml\">\(pages == nil ? xml(title) : "Page \(index + 1)")</a></li>"
        }
        try write("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>\(links)</ol></nav></body></html>", "OEBPS/nav.xhtml")
        let modified = ISO8601DateFormatter().string(from: Date())
        let layout = pages == nil ? "" : "<meta property=\"rendition:layout\">pre-paginated</meta>"
        try write("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(UUID())</dc:identifier><dc:title>\(xml(title))</dc:title><dc:language>en</dc:language><meta property=\"dcterms:modified\">\(modified)</meta>\(layout)</metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>", "OEBPS/content.opf")
        try await ArchiveEngine.zipPackage(root, to: output, epub: true)
    }
}
