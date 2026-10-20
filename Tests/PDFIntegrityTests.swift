import XCTest
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Toolbox

final class PDFIntegrityTests: XCTestCase {
    private var root: URL!
    private var staging: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFIntegrityTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in staging { OutputManager.discard(staging: folder) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Repair

    func testRepairRemovesJunkAroundTheFile() throws {
        let junk = Data(("<html><body>" + String(repeating: "Download failed. ", count: 200) + "</body></html>\n").utf8)
        let input = try write(junk + textPDF(pages: 10) + Data("\n<script>tracking()</script>\n".utf8), "junk.pdf")
        let (document, outcome) = try repair(input)
        XCTAssertEqual(document.pageCount, 10)
        XCTAssertTrue(document.page(at: 9)?.string?.contains("Page 10") == true)
        XCTAssertTrue(outcome.methods.contains(.trimmed))
        XCTAssertEqual(outcome.fixes.filter { $0.contains("junk") }.count, 2)
        XCTAssertFalse(outcome.isPartial)
    }

    func testRepairRebuildsATruncatedFile() throws {
        let full = textPDF(pages: 10)
        let input = try write(full.prefix(Int(Double(full.count) * 0.7)), "truncated.pdf")
        XCTAssertEqual(PDFRepair.readablePages(try Data(contentsOf: input)), 0, "The fixture should be unreadable as is.")
        let (document, outcome) = try repair(input)
        XCTAssertGreaterThanOrEqual(document.pageCount, 6)
        XCTAssertLessThan(document.pageCount, 10)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Page 1") == true)
        XCTAssertTrue(document.page(at: 5)?.string?.contains("Page 6") == true)
        XCTAssertTrue(outcome.methods.contains(.rebuilt))
        XCTAssertTrue(outcome.fixes.contains { $0.contains("list of pages") })
        XCTAssertFalse(outcome.lost.isEmpty)
    }

    func testRepairRecoversPagesFromTruncatedQuartzAndPDFKitFiles() throws {
        let quartz = root.appendingPathComponent("quartz.pdf")
        try DocumentConverter.renderPDF(DocumentConverter.styled(String(repeating: "A line of text for a long document.\n", count: 400)), to: quartz)
        let pages = try XCTUnwrap(PDFDocument(url: quartz)).pageCount
        XCTAssertGreaterThan(pages, 3)
        let pdfKit = try XCTUnwrap(PDFDocument(url: quartz)?.dataRepresentation())
        for (name, data) in [("quartz", try Data(contentsOf: quartz)), ("pdfkit", pdfKit)] {
            let input = try write(data.prefix(Int(Double(data.count) * 0.7)), "cut-\(name).pdf")
            let (document, outcome) = try repair(input)
            XCTAssertGreaterThanOrEqual(document.pageCount, 1, name)
            XCTAssertLessThanOrEqual(document.pageCount, pages, name)
            XCTAssertTrue(outcome.methods.contains(.rebuilt), name)
        }
    }

    func testRepairReparentsPagesWhosePageTreeWasLost() throws {
        // Two intermediate page-tree nodes, the root and the catalog are all at the end, and get cut off.
        var raw = RawPDF()
        raw.add(1, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        for index in 0..<8 {
            raw.addStream(10 + 2 * index, dict: "", Data("BT /F1 18 Tf 40 300 Td (Leaf \(index + 1)) Tj ET".utf8))
            raw.add(11 + 2 * index, "<< /Type /Page /Parent \(index < 4 ? 40 : 41) 0 R /Contents \(10 + 2 * index) 0 R >>")
        }
        raw.add(40, "<< /Type /Pages /Parent 42 0 R /Kids [11 0 R 13 0 R 15 0 R 17 0 R] /Count 4 /Resources << /Font << /F1 1 0 R >> >> >>")
        raw.add(41, "<< /Type /Pages /Parent 42 0 R /Kids [19 0 R 21 0 R 23 0 R 25 0 R] /Count 4 /Resources << /Font << /F1 1 0 R >> >> >>")
        raw.add(42, "<< /Type /Pages /Kids [40 0 R 41 0 R] /Count 8 /MediaBox [0 0 300 400] >>")
        raw.add(43, "<< /Type /Catalog /Pages 42 0 R >>")
        let full = raw.build(root: 43, info: nil)
        let complete = try write(full, "tree.pdf")
        XCTAssertEqual(PDFDocument(url: complete)?.page(at: 7)?.string?.contains("Leaf 8"), true)
        let marker = try XCTUnwrap(full.range(of: Data("40 0 obj".utf8)))
        let input = try write(full.prefix(marker.lowerBound + 20), "tree-cut.pdf")
        let (document, outcome) = try repair(input)
        XCTAssertEqual(document.pageCount, 8)
        // The lost root held the page size, so the pages fall back to US Letter.
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(outcome.methods.contains(.rebuilt))
        // With the intermediate nodes intact (only the root and catalog lost), inherited resources carry over.
        let rootMarker = try XCTUnwrap(full.range(of: Data("42 0 obj".utf8)))
        let (inherited, _) = try repair(try write(full.prefix(rootMarker.lowerBound + 10), "tree-root-cut.pdf"))
        XCTAssertEqual(inherited.pageCount, 8)
        XCTAssertTrue(inherited.page(at: 7)?.string?.contains("Leaf 8") == true)
    }

    func testRepairFixesBrokenCrossReferenceOffsets() throws {
        var bytes = [UInt8](textPDF(pages: 4))
        // Shift every object after the header so the xref table points at the wrong bytes.
        bytes.insert(contentsOf: Array(repeating: UInt8(0x20), count: 57), at: 15)
        let input = try write(Data(bytes), "xref.pdf")
        XCTAssertFalse(PDFRepair.hasValidXref(Data(bytes)))
        let (document, outcome) = try repair(input)
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertTrue(document.page(at: 3)?.string?.contains("Page 4") == true)
        XCTAssertTrue(outcome.fixes.contains { $0.contains("cross-reference") })
        XCTAssertTrue(PDFRepair.hasValidXref(try Data(contentsOf: try XCTUnwrap(document.documentURL))))
    }

    func testRepairSalvagesImagesFromGarbage() throws {
        var generator = SeededGenerator(seed: 7)
        let noise = { (count: Int) in Data((0..<count).map { _ in UInt8.random(in: 0...0xFE, using: &generator) }) }
        let jpeg = makeJPEG(width: 120, height: 80, gps: false)
        let stream = Data("7 0 obj << /Type /XObject /Subtype /Image /Filter /DCTDecode /Length \(jpeg.count) >> stream\n".utf8)
            + jpeg + Data("\nendstream endobj\n".utf8)
        let input = try write(noise(5000) + stream + noise(3000), "garbage.pdf")
        let (document, outcome) = try repair(input)
        XCTAssertEqual(outcome.methods, [.salvaged])
        XCTAssertEqual(document.pageCount, 1)
        let size = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.01)
        XCTAssertTrue(outcome.isPartial)
    }

    func testRepairLeavesHealthyFilesWhole() throws {
        let input = try write(textPDF(pages: 3), "healthy.pdf")
        let (document, outcome) = try repair(input)
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertFalse(outcome.damageFound)
        XCTAssertEqual(outcome.methods, [.rewritten])
    }

    func testRepairRejectsFilesWithNothingInThem() throws {
        var generator = SeededGenerator(seed: 3)
        let input = try write(Data((0..<4000).map { _ in UInt8.random(in: 0...0xFE, using: &generator) }), "noise.pdf")
        XCTAssertThrowsError(try PDFRepair.repair(input, to: root.appendingPathComponent("out.pdf")))
    }

    func testRawFileUnpacksObjectStreams() throws {
        // An object stream holding the catalog and page tree, with no usable cross-reference.
        let catalog = "<< /Type /Catalog /Pages 2 0 R >> "
        let header = "1 0 2 \(catalog.utf8.count) "
        let body = Data((header + catalog + "<< /Type /Pages /Kids [3 0 R] /Count 1 >>").utf8)
        let compressed = try XCTUnwrap(zlib(body))
        var raw = RawPDF()
        raw.addStream(9, dict: "/Type /ObjStm /N 2 /First \(header.count) /Filter /FlateDecode", compressed)
        raw.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>")
        raw.add(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        raw.addStream(5, dict: "", Data("BT /F1 12 Tf 20 100 Td (Packed hello) Tj ET".utf8))
        let parsed = PDFRawFile(data: raw.build(root: 1, info: nil, xref: false))
        XCTAssertTrue(PDFRawFile.hasType("Catalog", try XCTUnwrap(parsed.latest[1]).text))
        let rebuilt = try XCTUnwrap(PDFRepair.rebuild(parsed))
        XCTAssertEqual(PDFDocument(data: rebuilt.data)?.page(at: 0)?.string?.contains("Packed hello"), true)
    }

    // MARK: Privacy

    func testPrivacyScanFindsHiddenData() throws {
        let input = try write(privacyFixture(), "private.pdf")
        try setWhereFroms(["https://mail.example.com/attachment/private.pdf"], on: input)
        let report = PDFPrivacyScanner.scan(input)
        XCTAssertNil(report.error)
        func has(_ kind: PDFPrivacyFinding.Kind, _ text: String? = nil, _ severity: PDFPrivacyFinding.Severity? = nil, file: StaticString = #filePath, line: UInt = #line) {
            let matches = report.findings(kind).filter { finding in
                (text.map { finding.title.contains($0) || finding.detail.contains($0) } ?? true) && (severity.map { finding.severity == $0 } ?? true)
            }
            XCTAssertFalse(matches.isEmpty, "Missing \(kind) \(text ?? "") in \(report.markdown)", file: file, line: line)
        }
        has(.metadata, "Jane Doe", .medium)
        has(.metadata, "Acme Corp", .medium)
        has(.metadata, "Microsoft Word", .low)
        has(.xmp, "Jane Doe", .medium)
        has(.comments, "John Q Reviewer", .medium)
        has(.comments, "Please fix this")
        has(.forms, "jane@example.com", .medium)
        has(.attachments, "notes.txt", .high)
        has(.scripts, "app.alert", .high)
        has(.links, "example.com", .low)
        has(.hiddenText, "Invisible text")
        has(.hiddenText, "White text")
        has(.images, "37.7749° N, 122.4194° W", .high)
        has(.images, "iPhone 17 Pro", .medium)
        has(.thumbnails)
        has(.revisions, "earlier saved version", .medium)
        has(.fileAttributes, "mail.example.com", .medium)
        XCTAssertEqual(report.highest, .high)
        XCTAssertTrue(report.findings(.hiddenText).flatMap(\.pages) == [1, 1])
        XCTAssertTrue(PDFPrivacyReport.markdown([report]).contains("## private.pdf"))
    }

    func testPrivacyCleanRemovesHiddenData() async throws {
        let input = try write(privacyFixture(), "private.pdf")
        let context = try makeContext([input])
        try await run(PDFPrivacyScanView.Settings.job(options: PDFPrivacyCleaner.Options()), inputs: [input], context: context)
        let output = try XCTUnwrap(outputs(context).first)
        XCTAssertEqual(output.lastPathComponent, "private-clean.pdf")
        let report = PDFPrivacyScanner.scan(output)
        for kind in [PDFPrivacyFinding.Kind.metadata, .xmp, .comments, .attachments, .scripts, .images, .thumbnails, .revisions, .fileAttributes] {
            XCTAssertTrue(report.findings(kind).isEmpty, "\(kind) left: \(report.markdown)")
        }
        XCTAssertFalse(report.findings(.links).isEmpty, "Web links are kept by default.")
        XCTAssertFalse(report.findings(.forms).isEmpty, "Form fields are kept by default.")

        let bytes = try Data(contentsOf: output)
        let text = String(data: bytes, encoding: .isoLatin1) ?? ""
        for secret in ["Jane", "Reviewer", "app.alert", "secret attachment", "Acme", "Microsoft", "Distiller", "Quartz", "Secret plan"] {
            XCTAssertFalse(text.contains(secret), "“\(secret)” is still in the file")
        }
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Hello visible") == true)
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        // The image still decodes, without its location.
        let images = PDFRepair.salvageJPEGs([UInt8](bytes))
        XCTAssertEqual(images.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(images[0] as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
    }

    func testPrivacyCleanAnonymizesCommentsAndDropsLinksAndForms() throws {
        let input = try write(privacyFixture(), "private.pdf")
        let output = root.appendingPathComponent("anonymized.pdf")
        let report = try PDFPrivacyCleaner.clean(input, to: output, options: .init(comments: .anonymize, forms: true, keepLinks: false))
        XCTAssertTrue(report.findings(.links).isEmpty)
        XCTAssertTrue(report.findings(.forms).isEmpty)
        XCTAssertEqual(report.findings(.comments).map(\.severity), [.low])
        let text = String(data: try Data(contentsOf: output), encoding: .isoLatin1) ?? ""
        XCTAssertFalse(text.contains("Reviewer"))
        XCTAssertFalse(text.contains("jane@example.com"))
        XCTAssertFalse(text.contains("tracker"))
        let annotations = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)).annotations
        XCTAssertEqual(annotations.compactMap(\.contents), ["Please fix this"])
    }

    func testPrivacyCleanCanKeepMetadata() throws {
        let input = try write(privacyFixture(), "private.pdf")
        let output = root.appendingPathComponent("kept.pdf")
        let report = try PDFPrivacyCleaner.clean(input, to: output, options: .init(metadata: false, comments: .keep, images: false))
        XCTAssertFalse(report.findings(.metadata).isEmpty)
        XCTAssertFalse(report.findings(.images).isEmpty)
        XCTAssertFalse(report.findings(.comments).filter { $0.title.contains("John Q Reviewer") }.isEmpty)
        XCTAssertTrue(report.findings(.scripts).isEmpty)
        XCTAssertTrue(report.findings(.attachments).isEmpty)
    }

    func testJPEGScrubKeepsTheImageAndItsSize() throws {
        var bytes = [UInt8](makeJPEG(width: 64, height: 48, gps: true))
        let count = bytes.count
        XCTAssertTrue(PDFJPEG.scrubMetadata(&bytes))
        XCTAssertEqual(bytes.count, count)
        XCTAssertFalse(PDFJPEG.scrubMetadata(&bytes), "Scrubbing twice changes nothing.")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 64)
        XCTAssertNil((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(PDFJPEG.end(of: bytes, from: 0), count)
    }

    // MARK: Helpers

    private func repair(_ input: URL) throws -> (PDFDocument, PDFRepairOutcome) {
        let output = root.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "-repaired.pdf")
        let outcome = try PDFRepair.repair(input, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output), "The repaired file doesn't open.")
        return (document, outcome)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeContext(_ inputs: [URL]) throws -> JobContext {
        let context = try JobContext(destination: OutputDestination(folder: root.appendingPathComponent("results"), besideSources: false),
                                     inputs: inputs, runner: nil)
        if let folder = context.stagingRoot { staging.append(folder) }
        return context
    }

    private func outputs(_ context: JobContext) throws -> [URL] {
        try context.stagedResults.flatMap { try FileManager.default.contentsOfDirectory(at: $0.staging, includingPropertiesForKeys: nil) }
    }

    private func run(_ job: ToolJob, inputs: [URL], context: JobContext) async throws {
        switch job {
        case .each(_, let body): for input in inputs { try await body(input, context, { _ in }) }
        case .all(let body): try await body(inputs, context)
        }
    }

    /// Pages that each say "Page N hello world" in a standard font, laid out like Quartz writes them:
    /// pages first, then the page tree and catalog at the end.
    private func textPDF(pages: Int) -> Data {
        var raw = RawPDF()
        raw.add(1, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let tree = 2 * pages + 2
        for index in 0..<pages {
            let content = Data("BT /F1 18 Tf 40 300 Td (Page \(index + 1) hello world) Tj ET\n".utf8) + Data(repeating: 0x20, count: 400)
            raw.addStream(2 + 2 * index, dict: "", content)
            raw.add(3 + 2 * index, "<< /Type /Page /Parent \(tree) 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 1 0 R >> >> /Contents \(2 + 2 * index) 0 R >>")
        }
        raw.add(tree, "<< /Type /Pages /Kids [\((0..<pages).map { "\(3 + 2 * $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>")
        raw.add(tree + 1, "<< /Type /Catalog /Pages \(tree) 0 R >>")
        return raw.build(root: tree + 1, info: nil)
    }

    private func privacyFixture() -> Data {
        var raw = RawPDF()
        raw.add(1, "<< /Type /Catalog /Pages 2 0 R /OpenAction 8 0 R /Names << /EmbeddedFiles 10 0 R /JavaScript 12 0 R >> /Metadata 13 0 R /AcroForm << /Fields [16 0 R] >> >>")
        raw.add(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        raw.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R /Annots [7 0 R 14 0 R 16 0 R] /Thumb 17 0 R >>")
        raw.addStream(4, dict: "", Data("BT /F1 18 Tf 40 300 Td (Hello visible) Tj ET BT 3 Tr /F1 10 Tf 40 280 Td (hidden secret) Tj ET q 0 Tr 1 1 1 rg BT /F1 10 Tf 40 260 Td (white text) Tj ET Q q 128 0 0 96 40 40 cm /Im1 Do Q".utf8))
        raw.add(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        raw.addStream(6, dict: "/Type /XObject /Subtype /Image /Width 64 /Height 48 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", makeJPEG(width: 64, height: 48, gps: true))
        raw.add(7, "<< /Type /Annot /Subtype /Text /Rect [300 300 320 320] /T (John Q Reviewer) /Contents (Please fix this) /M (D:20260101120000Z) >>")
        raw.add(8, "<< /S /JavaScript /JS (app.alert\\('hi'\\);) >>")
        raw.addStream(9, dict: "/Type /EmbeddedFile", Data("secret attachment contents".utf8))
        raw.add(10, "<< /Names [(notes.txt) 11 0 R] >>")
        raw.add(11, "<< /Type /Filespec /F (notes.txt) /UF (notes.txt) /EF << /F 9 0 R >> >>")
        raw.add(12, "<< /Names [(init) 8 0 R] >>")
        raw.addStream(13, dict: "/Type /Metadata /Subtype /XML", Data("<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/' xmlns:xmp='http://ns.adobe.com/xap/1.0/'><dc:creator><rdf:Seq><rdf:li>Jane Doe</rdf:li></rdf:Seq></dc:creator><xmp:CreatorTool>Microsoft Word</xmp:CreatorTool></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>".utf8))
        raw.add(14, "<< /Type /Annot /Subtype /Link /Rect [40 290 200 320] /A << /S /URI /URI (https://example.com/tracker) >> >>")
        raw.add(15, "<< /Author (Jane Doe) /Creator (Microsoft Word) /Producer (Acrobat Distiller 9) /Title (Secret plan) /CreationDate (D:20250101) /Company (Acme Corp) >>")
        raw.add(16, "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Email) /V (jane@example.com) /Rect [40 200 240 220] /P 3 0 R /DA (/Helv 10 Tf 0 g) >>")
        raw.addStream(17, dict: "/Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", Data(repeating: 0x80, count: 64))
        var data = raw.build(root: 1, info: 15)
        // A second save: an incremental update that changes the title.
        let previous = data.count
        let info = data.count + 1
        data += Data("\n15 0 obj\n<< /Author (Jane Doe) /Creator (Microsoft Word) /Producer (Acrobat Distiller 9) /Title (Secret plan v2) /Company (Acme Corp) >>\nendobj\n".utf8)
        let xref = data.count
        let startxref = String(data: data.prefix(previous), encoding: .isoLatin1)!.components(separatedBy: "startxref\n").last!.prefix { $0.isNumber }
        data += Data("xref\n15 1\n\(String(format: "%010d", info)) 00000 n \ntrailer\n<< /Size 18 /Root 1 0 R /Info 15 0 R /Prev \(startxref) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return data
    }

    private func makeJPEG(width: Int, height: Int, gps: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"]
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func setWhereFroms(_ sources: [String], on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", buffer.baseAddress, buffer.count, 0, 0)
        }
        XCTAssertEqual(result, 0)
    }

    private func zlib(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        // NSData's zlib is raw deflate; PDF's FlateDecode wants the RFC 1950 wrapper.
        var checksumA: UInt32 = 1, checksumB: UInt32 = 0
        for byte in data { checksumA = (checksumA + UInt32(byte)) % 65521; checksumB = (checksumB + checksumA) % 65521 }
        let adler = checksumB << 16 | checksumA
        return Data([0x78, 0x9C]) + deflated + Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
    }
}

/// Assembles PDFs object by object, for fixtures no PDF writer would produce.
private struct RawPDF {
    private var objects: [(Int, Data)] = []

    mutating func add(_ number: Int, _ value: String) { objects.append((number, Data(value.utf8))) }

    mutating func addStream(_ number: Int, dict: String, _ data: Data) {
        objects.append((number, Data("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream".utf8)))
    }

    func build(root: Int, info: Int?, xref: Bool = true) -> Data {
        var output = Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int: Int] = [:]
        for (number, body) in objects {
            offsets[number] = output.count
            output += Data("\(number) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        guard xref else { return output }
        let size = (objects.map(\.0).max() ?? 0) + 1
        let start = output.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<size {
            table += offsets[number].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 00001 f \n"
        }
        table += "trailer\n<< /Size \(size) /Root \(root) 0 R\(info.map { " /Info \($0) 0 R" } ?? "") >>\nstartxref\n\(start)\n%%EOF\n"
        return output + Data(table.utf8)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
