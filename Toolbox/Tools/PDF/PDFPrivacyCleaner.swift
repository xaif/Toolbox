import AppKit
import PDFKit

/// Writes a copy of a PDF without the hidden data `PDFPrivacyScanner` finds.
///
/// Copying the pages into a fresh document leaves document scripts, attachments, XMP, private app data
/// and earlier saved versions behind; annotations are then removed or anonymized with PDFKit. Two things
/// survive a PDFKit save and are patched in the saved bytes without moving anything: the document info
/// PDFKit writes, and the EXIF data inside JPEG images, which PDFKit passes through untouched.
enum PDFPrivacyCleaner {
    enum CommentPolicy: String, CaseIterable, Identifiable, Sendable {
        case remove, anonymize, keep
        var id: Self { self }

        var label: String {
            switch self {
            case .remove: "Remove"
            case .anonymize: "Keep without names"
            case .keep: "Keep"
            }
        }
    }

    struct Options: Sendable {
        var metadata = true
        var comments = CommentPolicy.remove
        var forms = false
        var images = true
        var keepLinks = true
    }

    /// Cleans `input` into `output`. Returns the scan of the cleaned copy.
    @discardableResult
    static func clean(_ input: URL, to output: URL, options: Options) throws -> PDFPrivacyReport {
        let source = try PDFOps.open(input)
        try cleanedData(source, options: options, flatten: []).write(to: output)
        var report = PDFPrivacyScanner.scan(output, includeFileAttributes: false)
        if options.images {
            // JPEGs wrapped in another filter can't be patched in place, so those pages become images.
            let pages = Set(report.findings(.images).filter { $0.severity >= .medium }.flatMap(\.pages))
            if !pages.isEmpty {
                try cleanedData(source, options: options, flatten: pages).write(to: output)
                report = PDFPrivacyScanner.scan(output, includeFileAttributes: false)
            }
        }
        return report
    }

    /// `flatten` holds 1-based pages to replace with a picture of themselves.
    private static func cleanedData(_ source: PDFDocument, options: Options, flatten: Set<Int>) throws -> Data {
        let document = PDFOps.document(from: source, indices: PDFOps.allPages(source))
        document.documentAttributes = options.metadata ? [:] : source.documentAttributes
        for index in 0..<document.pageCount {
            guard var page = document.page(at: index) else { continue }
            if flatten.contains(index + 1), let flat = flattened(page) {
                document.insert(flat, at: index)
                document.removePage(at: index + 1)
                page = flat
            }
            for annotation in page.annotations {
                if shouldRemove(annotation, options) {
                    page.removeAnnotation(annotation)
                } else if options.comments == .anonymize, role(of: annotation) == .comment || role(of: annotation) == .popup {
                    annotation.userName = nil
                    annotation.modificationDate = nil
                }
            }
        }
        guard var data = document.dataRepresentation() else { throw ToolError.failed("Couldn't save the cleaned copy.") }
        let raw = PDFRawFile(data: data)
        if options.metadata { blankInfo(&data, raw: raw) }
        if options.images { scrubImages(&data, raw: raw) }
        return data
    }

    // MARK: Annotations

    private enum Role { case link, widget, attachment, popup, comment }

    private static func role(of annotation: PDFAnnotation) -> Role {
        switch annotation.type ?? "" {
        case "Link": .link
        case "Widget": .widget
        case "FileAttachment", "Sound", "Movie", "Screen", "RichMedia", "3D": .attachment
        case "Popup": .popup
        default: .comment
        }
    }

    private static func shouldRemove(_ annotation: PDFAnnotation, _ options: Options) -> Bool {
        switch role(of: annotation) {
        case .link:
            // A link that does more than open a page or web address is a script.
            if let action = annotation.action, !(action is PDFActionURL || action is PDFActionGoTo || action is PDFActionNamed) { return true }
            return !options.keepLinks && (annotation.action is PDFActionURL || annotation.url != nil)
        case .widget: return options.forms
        case .attachment: return true
        case .popup, .comment: return options.comments == .remove
        }
    }

    private static func flattened(_ page: PDFPage) -> PDFPage? {
        let dpi: CGFloat = 200
        guard let image = PDFOps.renderPage(page, scale: dpi / 72),
              let data = PDFOps.encode(image, as: .jpeg, quality: 0.85, dpi: dpi),
              let picture = NSImage(data: data) else { return nil }
        picture.size = PDFOps.displaySize(of: page)
        return PDFPage(image: picture)
    }

    // MARK: Byte patches

    /// Blanks the document info dictionary and the trailer's reference to it, keeping every offset.
    static func blankInfo(_ data: inout Data, raw: PDFRawFile) {
        for trailer in raw.trailers {
            guard let number = PDFRawFile.reference("Info", in: trailer.text) else { continue }
            let text = trailer.text as NSString
            let reference = text.range(of: #"/Info\s+\d+\s+\d+\s+R"#, options: .regularExpression)
            if reference.location != NSNotFound {
                // Latin-1 text: one UTF-16 unit per byte.
                blank(&data, trailer.range.lowerBound + reference.location..<trailer.range.lowerBound + NSMaxRange(reference))
            }
            for object in raw.objects where object.number == number {
                guard let range = object.valueRange, range.count >= 4,
                      data[range.lowerBound] == 0x3C, data[range.lowerBound + 1] == 0x3C,
                      data[range.upperBound - 1] == 0x3E, data[range.upperBound - 2] == 0x3E else { continue }
                blank(&data, range.lowerBound + 2..<range.upperBound - 2)
            }
        }
    }

    /// Blanks EXIF, XMP, IPTC and comments in every plain JPEG image. Returns how many changed.
    @discardableResult
    static func scrubImages(_ data: inout Data, raw: PDFRawFile) -> Int {
        var changed = 0
        for object in raw.objects {
            guard let range = object.streamRange,
                  object.text.range(of: #"/Filter\s*(/DCTDecode|\[\s*/DCTDecode\s*\])"#, options: .regularExpression) != nil else { continue }
            var bytes = [UInt8](data[range])
            if PDFJPEG.scrubMetadata(&bytes) {
                data.replaceSubrange(range, with: bytes)
                changed += 1
            }
        }
        return changed
    }

    private static func blank(_ data: inout Data, _ range: Range<Int>) {
        guard range.lowerBound >= 0, range.upperBound <= data.count, !range.isEmpty else { return }
        data.replaceSubrange(range, with: repeatElement(UInt8(0x20), count: range.count))
    }
}
