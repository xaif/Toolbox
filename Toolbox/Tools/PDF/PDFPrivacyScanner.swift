import CoreGraphics
import Foundation
import ImageIO

/// One kind of hidden data found in a PDF.
struct PDFPrivacyFinding: Identifiable, Hashable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    enum Kind: String, Sendable {
        case metadata, xmp, comments, forms, attachments, scripts, links, hiddenText, images, thumbnails, revisions, appData, fileAttributes
    }

    var id: String { "\(kind.rawValue)-\(title)" }
    let kind: Kind
    var severity: Severity
    let title: String
    let detail: String
    /// 1-based pages it appears on, when it's on pages.
    var pages: [Int] = []

    var pageDescription: String? {
        guard !pages.isEmpty else { return nil }
        let unique = Array(Set(pages)).sorted()
        return (unique.count == 1 ? "Page " : "Pages ") + PDFOps.rangeString(unique.map { $0 - 1 }).replacingOccurrences(of: "-", with: "–")
    }
}

/// The findings for one file.
struct PDFPrivacyReport: Sendable {
    let fileName: String
    var findings: [PDFPrivacyFinding] = []
    /// Set when the file couldn't be scanned.
    var error: String?

    var highest: PDFPrivacyFinding.Severity? { findings.map(\.severity).max() }

    func findings(_ kind: PDFPrivacyFinding.Kind) -> [PDFPrivacyFinding] { findings.filter { $0.kind == kind } }

    var markdown: String {
        var lines = ["## \(fileName)"]
        if let error {
            lines += ["", "Couldn't scan: \(error)"]
        } else if findings.isEmpty {
            lines += ["", "No hidden data found."]
        } else {
            lines += ["", "Highest risk: **\(highest?.label ?? "")**", ""]
            for finding in findings {
                var line = "- **\(finding.severity.label)** · \(finding.title) — \(finding.detail)"
                if let pages = finding.pageDescription { line += " (\(pages))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ reports: [PDFPrivacyReport], title: String = "PDF Privacy Report") -> String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return (["# \(title)", "", "_Scanned \(date) with Toolbox_"] + reports.map { "\n" + $0.markdown }).joined(separator: "\n") + "\n"
    }
}

/// Looks for data that travels inside a PDF without showing on its pages: who made it and with what,
/// comments, filled-in forms, attachments, scripts, photo locations, hidden text and earlier versions.
enum PDFPrivacyScanner {
    static func scan(_ url: URL, includeFileAttributes: Bool = true) -> PDFPrivacyReport {
        var report = PDFPrivacyReport(fileName: url.lastPathComponent)
        guard let provider = CGDataProvider(url: url as CFURL), let document = CGPDFDocument(provider) else {
            report.error = "It isn't a readable PDF. Try Repair PDF first."
            return report
        }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            report.error = "It's password-protected. Remove the password first, then scan it."
            return report
        }
        var scan = Scan()
        if let info = document.info { scan.info(info) }
        if let catalog = document.catalog { scan.catalog(catalog) }
        for number in stride(from: 1, through: document.numberOfPages, by: 1) {
            guard let page = document.page(at: number) else { continue }
            scan.page(page, number: number)
        }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { scan.revisions(data) }
        if includeFileAttributes { scan.fileAttributes(url) }
        scan.summarize()
        report.findings = scan.findings.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.title < $1.title }
        return report
    }
}

// MARK: - Scanning

private struct Scan {
    var findings: [PDFPrivacyFinding] = []

    private var commentsByAuthor: [String: (count: Int, pages: [Int], sample: String?)] = [:]
    private var anonymousComments: (count: Int, pages: [Int]) = (0, [])
    private var attachments: [(name: String, page: Int?)] = []
    private var media: [Int] = []
    private var scripts: [(String, Int?)] = []
    private var links: [String: [Int]] = [:]
    private var thumbnails: [Int] = []
    private var filledFields: [String] = []
    private var signers: [String] = []
    private var visitedStreams = Set<Int>()
    private var images = ImageFindings()

    private struct ImageFindings {
        var locations: [(String, Int)] = []
        var cameras: [String: [Int]] = [:]
        var details: [String: [Int]] = [:]
    }

    // MARK: Document info

    mutating func info(_ info: CGPDFDictionaryRef) {
        var values: [(String, String)] = []
        var dates: [(String, Date)] = []
        PDFObjects.forEach(info) { key, object in
            if key == "CreationDate" || key == "ModDate" {
                if let date = PDFObjects.date(object) { dates.append((key == "CreationDate" ? "Created" : "Modified", date)) }
            } else if key != "Trapped", let text = PDFObjects.text(object), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append((key, text))
            }
        }
        let lookup = Dictionary(values, uniquingKeysWith: { first, _ in first })
        if let author = lookup["Author"] {
            add(.metadata, .medium, "Author name", author)
        }
        let apps = [lookup["Creator"], lookup["Producer"]].compactMap { $0 }
        if !apps.isEmpty { add(.metadata, .low, "Apps used to make it", apps.joined(separator: " · ")) }
        let described = ["Title", "Subject", "Keywords"].compactMap { key in lookup[key].map { "\(key): \($0)" } }
        if !described.isEmpty { add(.metadata, .low, "Title, subject and keywords", described.joined(separator: " · ")) }
        if !dates.isEmpty {
            add(.metadata, .low, "Creation and edit dates",
                dates.map { "\($0.0) \($0.1.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: " · "))
        }
        let standard: Set = ["Author", "Creator", "Producer", "Title", "Subject", "Keywords"]
        let custom = values.filter { !standard.contains($0.0) }
        if !custom.isEmpty {
            add(.metadata, .medium, "Custom metadata fields", custom.map { "\($0.0): \(PDFObjects.clip($0.1))" }.joined(separator: " · "))
        }
    }

    // MARK: Catalog

    mutating func catalog(_ catalog: CGPDFDictionaryRef) {
        if let metadata = PDFObjects.stream(catalog, "Metadata"), let xmp = PDFObjects.data(metadata) {
            xmpFinding(xmp, title: "XMP metadata")
        }
        if let names = PDFObjects.dictionary(catalog, "Names") {
            if let tree = PDFObjects.dictionary(names, "EmbeddedFiles") {
                for (name, object) in PDFObjects.nameTree(tree) {
                    attachments.append((PDFObjects.fileName(object) ?? name, nil))
                }
            }
            if let tree = PDFObjects.dictionary(names, "JavaScript") {
                for (name, object) in PDFObjects.nameTree(tree) {
                    var dictionary: CGPDFDictionaryRef?
                    let snippet = CGPDFObjectGetValue(object, .dictionary, &dictionary) ? dictionary.flatMap(PDFObjects.javaScript) : nil
                    scripts.append(("Document script “\(name)”" + (snippet.map { ": \($0)" } ?? ""), nil))
                }
            }
        }
        var openAction: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "OpenAction", &openAction), let openAction {
            action(openAction, context: "when the file opens", page: nil)
        }
        if let actions = PDFObjects.dictionary(catalog, "AA") { additionalActions(actions, context: "on document events", page: nil) }
        if let form = PDFObjects.dictionary(catalog, "AcroForm") { self.form(form) }
        if let pieces = PDFObjects.dictionary(catalog, "PieceInfo") { appData(pieces, page: nil) }
    }

    // MARK: Pages

    mutating func page(_ page: CGPDFPage, number: Int) {
        guard let dictionary = page.dictionary else { return }
        if let annotations = PDFObjects.array(dictionary, "Annots") {
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
                self.annotation(annotation, page: number)
            }
        }
        if let actions = PDFObjects.dictionary(dictionary, "AA") { additionalActions(actions, context: "when page \(number) opens or closes", page: number) }
        if let pieces = PDFObjects.dictionary(dictionary, "PieceInfo") { appData(pieces, page: number) }
        if PDFObjects.stream(dictionary, "Thumb") != nil { thumbnails.append(number) }
        if let resources = PDFObjects.dictionary(dictionary, "Resources") { xObjects(resources, page: number, depth: 0) }
        hiddenText(page, number: number)
    }

    private mutating func annotation(_ annotation: CGPDFDictionaryRef, page: Int) {
        let subtype = PDFObjects.name(annotation, "Subtype") ?? ""
        if let action = PDFObjects.dictionary(annotation, "A") { self.action(action, context: "when a link or button is clicked", page: page) }
        if let actions = PDFObjects.dictionary(annotation, "AA") { additionalActions(actions, context: "from a form field or link", page: page) }
        switch subtype {
        case "Widget":
            // Fields merged with their widget carry their value here too.
            if let name = PDFObjects.string(annotation, "T") { field(annotation, name: name) }
        case "Link", "Popup":
            break
        case "FileAttachment":
            let name = PDFObjects.dictionary(annotation, "FS").flatMap { PDFObjects.fileName(dictionary: $0) }
                ?? PDFObjects.string(annotation, "FS") ?? "Attached file"
            attachments.append((name, page))
        case "Sound", "Movie", "Screen", "RichMedia", "3D":
            media.append(page)
        default:
            let author = PDFObjects.string(annotation, "T")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let contents = PDFObjects.string(annotation, "Contents").map { PDFObjects.clip($0, 60) }
            if author.isEmpty {
                anonymousComments.count += 1
                anonymousComments.pages.append(page)
            } else {
                var entry = commentsByAuthor[author] ?? (0, [], nil)
                entry.count += 1
                entry.pages.append(page)
                if entry.sample == nil, let contents, !contents.isEmpty { entry.sample = contents }
                commentsByAuthor[author] = entry
            }
        }
    }

    // MARK: Actions

    private mutating func action(_ action: CGPDFDictionaryRef, context: String, page: Int?, depth: Int = 0) {
        guard depth < 8 else { return }
        switch PDFObjects.name(action, "S") ?? "" {
        case "JavaScript":
            scripts.append(("Runs a script \(context)" + (PDFObjects.javaScript(action).map { ": \($0)" } ?? ""), page))
        case "Launch":
            scripts.append(("Opens another file or app \(context)", page))
        case "SubmitForm":
            let target = PDFObjects.dictionary(action, "F").flatMap { PDFObjects.fileName(dictionary: $0) } ?? PDFObjects.string(action, "F")
            scripts.append(("Sends form data to \(target ?? "a server") \(context)", page))
        case "ImportData", "Rendition", "GoToE":
            scripts.append(("Runs an automatic action \(context)", page))
        case "URI":
            if let uri = PDFObjects.string(action, "URI") {
                if context == "when the file opens" {
                    add(.links, .medium, "Opens a web page when the file opens", uri)
                } else {
                    links[uri, default: []].append(contentsOf: page.map { [$0] } ?? [])
                }
            }
        default:
            break
        }
        if let next = PDFObjects.dictionary(action, "Next") { self.action(next, context: context, page: page, depth: depth + 1) }
    }

    private mutating func additionalActions(_ actions: CGPDFDictionaryRef, context: String, page: Int?) {
        var found: [CGPDFDictionaryRef] = []
        PDFObjects.forEach(actions) { _, object in
            var dictionary: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary { found.append(dictionary) }
        }
        for action in found { self.action(action, context: context, page: page) }
    }

    // MARK: Forms

    private mutating func form(_ form: CGPDFDictionaryRef) {
        func walk(_ field: CGPDFDictionaryRef, prefix: String, depth: Int) {
            guard depth < 16 else { return }
            let name = PDFObjects.string(field, "T").map { prefix.isEmpty ? $0 : "\(prefix).\($0)" } ?? prefix
            self.field(field, name: name)
            if let kids = PDFObjects.array(field, "Kids") {
                for index in 0..<CGPDFArrayGetCount(kids) {
                    var kid: CGPDFDictionaryRef?
                    if CGPDFArrayGetDictionary(kids, index, &kid), let kid { walk(kid, prefix: name, depth: depth + 1) }
                }
            }
        }
        if let fields = PDFObjects.array(form, "Fields") {
            for index in 0..<CGPDFArrayGetCount(fields) {
                var field: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(fields, index, &field), let field { walk(field, prefix: "", depth: 0) }
            }
        }
        var xfa: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(form, "XFA", &xfa) {
            add(.forms, .medium, "XFA form data", "The form carries a separate XML copy of its contents.")
        }
    }

    private mutating func field(_ field: CGPDFDictionaryRef, name: String) {
        var valueObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(field, "V", &valueObject), let valueObject else { return }
        var signature: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(valueObject, .dictionary, &signature), let signature {
            let signer = PDFObjects.string(signature, "Name") ?? (name.isEmpty ? "Signature" : name)
            if !signers.contains(signer) { signers.append(signer) }
        } else if let value = PDFObjects.text(valueObject), !value.isEmpty, value != "Off" {
            let entry = "\(name.isEmpty ? "Field" : name): \(PDFObjects.clip(value, 40))"
            if !filledFields.contains(entry) { filledFields.append(entry) }
        }
    }

    // MARK: Images

    private mutating func xObjects(_ resources: CGPDFDictionaryRef, page: Int, depth: Int) {
        guard depth < 8, let named = PDFObjects.dictionary(resources, "XObject") else { return }
        var streams: [CGPDFStreamRef] = []
        PDFObjects.forEach(named) { _, object in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
        }
        for stream in streams {
            guard visitedStreams.insert(unsafeBitCast(stream, to: Int.self)).inserted, let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
            switch PDFObjects.name(dictionary, "Subtype") {
            case "Image": image(stream, dictionary: dictionary, page: page)
            case "Form":
                if let inner = PDFObjects.dictionary(dictionary, "Resources") { xObjects(inner, page: page, depth: depth + 1) }
            default: break
            }
        }
    }

    private mutating func image(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, page: Int) {
        if let metadata = PDFObjects.stream(dictionary, "Metadata"), let xmp = PDFObjects.data(metadata),
           let text = String(data: xmp, encoding: .utf8), text.contains("GPS") || text.contains("exif:") || text.contains("tiff:Model") {
            images.details["Photo editing metadata (XMP)", default: []].append(page)
        }
        // Only JPEG and JPEG 2000 carry EXIF; decoding other images would be slow and pointless.
        let filters = PDFObjects.filters(dictionary)
        guard filters.contains("DCTDecode") || filters.contains("JPXDecode") || filters.contains("DCT") else { return }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format != .raw,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            images.locations.append((PDFObjects.coordinates(gps) ?? "Location data", page))
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var cameraLine = camera.joined(separator: " ")
        if let serial = exif[kCGImagePropertyExifBodySerialNumber] as? String { cameraLine += " (serial \(serial))" }
        if !cameraLine.isEmpty { images.cameras[cameraLine, default: []].append(page) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { images.details["Date taken \(taken)", default: []].append(page) }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { images.details["Edited with \(software)", default: []].append(page) }
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if let byline = (iptc[kCGImagePropertyIPTCByline] as? [String])?.first ?? tiff[kCGImagePropertyTIFFArtist] as? String {
            images.details["Photographer \(byline)", default: []].append(page)
        }
    }

    // MARK: Hidden text

    private mutating func hiddenText(_ page: CGPDFPage, number: Int) {
        let state = HiddenTextScan()
        let content = CGPDFContentStreamCreateWithPage(page)
        state.scan(content)
        CGPDFContentStreamRelease(content)
        if state.invisible > 0 {
            let sample = state.sample.isEmpty ? "" : " “\(PDFObjects.clip(state.sample, 60))”"
            // On a scan, invisible text is the searchable OCR layer. Without an image it's suspicious.
            let severity: PDFPrivacyFinding.Severity = state.drawsImages ? .low : .medium
            let detail = state.drawsImages ? "Usually a searchable text layer over a scan." : "Text that's never shown on the page."
            add(.hiddenText, severity, "Invisible text", detail + sample, pages: [number])
        }
        if state.white > 0 {
            add(.hiddenText, .low, "White text", "Can't be seen on a white background. Check it isn't hiding anything.", pages: [number])
        }
    }

    // MARK: App data, revisions, file attributes

    private mutating func appData(_ pieces: CGPDFDictionaryRef, page: Int?) {
        var apps: [String] = []
        PDFObjects.forEach(pieces) { key, _ in apps.append(key) }
        add(.appData, .low, "Private app data", "Editing data saved by \(apps.joined(separator: ", ")).", pages: page.map { [$0] } ?? [])
    }

    private mutating func xmpFinding(_ xmp: Data, title: String) {
        let text = String(data: xmp, encoding: .utf8) ?? String(data: xmp, encoding: .isoLatin1) ?? ""
        var parts: [String] = []
        let creators = PDFObjects.xmpValues(text, tag: "dc:creator")
        if !creators.isEmpty { parts.append("author " + creators.joined(separator: ", ")) }
        for (tag, label) in [("xmp:CreatorTool", "made with"), ("pdf:Producer", "saved by")] {
            if let value = PDFObjects.xmpValues(text, tag: tag).first { parts.append("\(label) \(value)") }
        }
        if text.contains("xmpMM:History") || text.contains("stEvt:") { parts.append("edit history") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(xmp.count), countStyle: .file))
        let detail = parts.joined(separator: " · ")
        add(.xmp, creators.isEmpty ? .low : .medium, title, detail.prefix(1).uppercased() + detail.dropFirst())
    }

    mutating func revisions(_ data: Data) {
        let marker = Data("%%EOF".utf8)
        var count = 0
        var searchRange = data.startIndex..<data.endIndex
        while let found = data.range(of: marker, in: searchRange) {
            count += 1
            searchRange = found.upperBound..<data.endIndex
        }
        // Linearized ("fast web view") files end their first page with an extra marker.
        let head = data.prefix(1024)
        if head.range(of: Data("/Linearized".utf8)) != nil { count -= 1 }
        if count > 1 {
            let earlier = count - 1
            add(.revisions, .medium, earlier == 1 ? "An earlier saved version" : "\(earlier) earlier saved versions",
                "Edited or deleted content from before the last save may still be recoverable.")
        }
    }

    mutating func fileAttributes(_ url: URL) {
        if let data = PDFObjects.extendedAttribute("com.apple.metadata:kMDItemWhereFroms", of: url),
           let sources = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String], !sources.isEmpty {
            add(.fileAttributes, .medium, "Download source saved by macOS",
                sources.map { PDFObjects.clip($0, 80) }.joined(separator: " · ") + ". Stored next to the file, not inside it; copies Toolbox saves don't keep it.")
        }
        if let data = PDFObjects.extendedAttribute("com.apple.quarantine", of: url), let value = String(data: data, encoding: .utf8) {
            let fields = value.split(separator: ";", omittingEmptySubsequences: false)
            let agent = fields.count > 2 && !fields[2].isEmpty ? " with \(fields[2])" : ""
            add(.fileAttributes, .low, "Download record", "macOS noted it was downloaded\(agent).")
        }
    }

    // MARK: Collecting

    mutating func add(_ kind: PDFPrivacyFinding.Kind, _ severity: PDFPrivacyFinding.Severity, _ title: String, _ detail: String, pages: [Int] = []) {
        if let index = findings.firstIndex(where: { $0.kind == kind && $0.title == title }) {
            // Same finding on another page: merge.
            findings[index].pages += pages
            findings[index].severity = max(findings[index].severity, severity)
            return
        }
        findings.append(PDFPrivacyFinding(kind: kind, severity: severity, title: title, detail: detail, pages: pages))
    }

    /// Adds the findings gathered across pages. Called once, after the last page.
    mutating func summarize() {
        for (author, entry) in commentsByAuthor.sorted(by: { $0.key < $1.key }) {
            let count = entry.count == 1 ? "1 comment" : "\(entry.count) comments"
            add(.comments, .medium, "Comments by \(author)", count + (entry.sample.map { " · “\($0)”" } ?? ""), pages: entry.pages)
        }
        if anonymousComments.count > 0 {
            add(.comments, .low, anonymousComments.count == 1 ? "A comment" : "\(anonymousComments.count) comments",
                "Notes and markup that can be hidden or collapsed.", pages: anonymousComments.pages)
        }
        if !attachments.isEmpty {
            let names = attachments.map(\.name)
            add(.attachments, .high, names.count == 1 ? "An attached file" : "\(names.count) attached files",
                names.prefix(5).joined(separator: ", ") + (names.count > 5 ? ", …" : ""), pages: attachments.compactMap(\.page))
        }
        if !media.isEmpty {
            add(.attachments, .medium, "Embedded media", "Sound, video or 3D content inside the file.", pages: media)
        }
        if !scripts.isEmpty {
            let descriptions = Array(Set(scripts.map(\.0))).sorted()
            add(.scripts, .high, scripts.count == 1 ? "A script or automatic action" : "\(scripts.count) scripts and automatic actions",
                descriptions.prefix(3).joined(separator: " · ") + (descriptions.count > 3 ? " · …" : ""), pages: scripts.compactMap(\.1))
        }
        if !links.isEmpty {
            let hosts = Array(Set(links.keys.map { URL(string: $0)?.host() ?? $0 })).sorted()
            add(.links, .low, links.count == 1 ? "A link to a web address" : "Links to \(links.count) web addresses",
                hosts.prefix(4).joined(separator: ", ") + (hosts.count > 4 ? ", …" : "") + ". Links can carry tracking codes.",
                pages: links.values.flatMap { $0 })
        }
        if !filledFields.isEmpty {
            add(.forms, .medium, filledFields.count == 1 ? "A filled-in form field" : "\(filledFields.count) filled-in form fields",
                filledFields.prefix(6).joined(separator: " · ") + (filledFields.count > 6 ? " · …" : ""))
        }
        if !signers.isEmpty {
            add(.forms, .medium, "Digital signatures", "Signed by " + signers.joined(separator: ", "))
        }
        if !thumbnails.isEmpty {
            add(.thumbnails, .medium, "Page thumbnails", "Small preview images that may show pages as they were before edits.", pages: thumbnails)
        }
        if !images.locations.isEmpty {
            let places = Array(Set(images.locations.map(\.0))).sorted()
            add(.images, .high, images.locations.count == 1 ? "Photo location" : "Locations in \(images.locations.count) photos",
                places.prefix(3).joined(separator: " · "), pages: images.locations.map(\.1))
        }
        for (camera, pages) in images.cameras.sorted(by: { $0.key < $1.key }) {
            add(.images, .medium, "Camera details in photos", camera, pages: pages)
        }
        if !images.details.isEmpty {
            add(.images, .low, "Other photo details", images.details.keys.sorted().prefix(4).joined(separator: " · "),
                pages: images.details.values.flatMap { $0 })
        }
    }
}

// MARK: - Hidden text

/// Counts text drawn invisibly (rendering mode 3 or 7) or in white, following q/Q state.
private final class HiddenTextScan {
    struct State { var mode = 0; var white = false }
    var stack: [State] = []
    var state = State()
    var invisible = 0
    var white = 0
    var drawsImages = false
    var sample = ""
    var depth = 0

    private static let table: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            info.map { Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }.map { $0.stack.append($0.state) }
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            if let last = scan.stack.popLast() { scan.state = last }
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { scan.state.mode = mode }
        }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var gray: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &gray) { scan.state.white = gray >= 0.99 }
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var b: CGPDFReal = 0, g: CGPDFReal = 0, r: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &g), CGPDFScannerPopNumber(scanner, &r) {
                scan.state.white = min(r, g, b) >= 0.99
            }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var values: [CGPDFReal] = []
            var value: CGPDFReal = 0
            for _ in 0..<4 where CGPDFScannerPopNumber(scanner, &value) { values.append(value) }
            scan.state.white = values.count == 4 && values.allSatisfy { $0 <= 0.01 }
        }
        CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
            info.map { Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }?.state.white = false
        }
        for op in ["Tj", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
                var string: CGPDFStringRef?
                let text = CGPDFScannerPopString(scanner, &string) ? string.flatMap { CGPDFStringCopyTextString($0) as String? } : nil
                scan.shown(text)
            }
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var array: CGPDFArrayRef?
            var text = ""
            if CGPDFScannerPopArray(scanner, &array), let array {
                for index in 0..<CGPDFArrayGetCount(array) {
                    var string: CGPDFStringRef?
                    if CGPDFArrayGetString(array, index, &string), let string, let part = CGPDFStringCopyTextString(string) as String? { text += part }
                }
            }
            scan.shown(text)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let scan = info.map({ Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            switch PDFObjects.name(dictionary, "Subtype") {
            case "Image": scan.drawsImages = true
            case "Form" where scan.depth < 8:
                let inner = CGPDFContentStreamCreateWithStream(stream, PDFObjects.dictionary(dictionary, "Resources") ?? dictionary, content)
                scan.depth += 1
                scan.scan(inner)
                scan.depth -= 1
                CGPDFContentStreamRelease(inner)
            default: break
            }
        }
        CGPDFOperatorTableSetCallback(table, "BI") { scanner, info in
            info.map { Unmanaged<HiddenTextScan>.fromOpaque($0).takeUnretainedValue() }?.drawsImages = true
        }
        return table
    }()

    func scan(_ content: CGPDFContentStreamRef) {
        guard let table = Self.table else { return }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    func shown(_ text: String?) {
        if state.mode == 3 || state.mode == 7 {
            invisible += 1
            if let text, sample.count < 80, PDFObjects.isReadable(text) { sample += (sample.isEmpty ? "" : " ") + text }
        } else if state.white {
            white += 1
        }
    }
}

// MARK: - CGPDF helpers

enum PDFObjects {
    static func forEach(_ dictionary: CGPDFDictionaryRef, _ body: (String, CGPDFObjectRef) -> Void) {
        withoutActuallyEscaping(body) { body in
            CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
                body(String(cString: key), object)
                return true
            }, nil)
        }
    }

    static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var result: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &result) ? result : nil
    }

    static func array(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var result: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(dictionary, key, &result) ? result : nil
    }

    static func stream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var result: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(dictionary, key, &result) ? result : nil
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var result: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &result), let result else { return nil }
        return String(cString: result)
    }

    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var result: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &result), let result else { return nil }
        return CGPDFStringCopyTextString(result) as String?
    }

    static func data(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(stream, &format) as Data?
    }

    /// A string, name, number or boolean as text.
    static func text(_ object: CGPDFObjectRef) -> String? {
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(object, .string, &string), let string { return CGPDFStringCopyTextString(string) as String? }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return String(cString: name) }
        var integer: CGPDFInteger = 0
        if CGPDFObjectGetValue(object, .integer, &integer) { return String(integer) }
        var real: CGPDFReal = 0
        if CGPDFObjectGetValue(object, .real, &real) { return String(Double(real)) }
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array {
            let parts = (0..<CGPDFArrayGetCount(array)).compactMap { index -> String? in
                var item: CGPDFObjectRef?
                return CGPDFArrayGetObject(array, index, &item) ? item.flatMap(text) : nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }

    static func date(_ object: CGPDFObjectRef) -> Date? {
        var string: CGPDFStringRef?
        guard CGPDFObjectGetValue(object, .string, &string), let string else { return nil }
        return CGPDFStringCopyDate(string) as Date?
    }

    /// Every name and value in a name tree.
    static func nameTree(_ tree: CGPDFDictionaryRef, depth: Int = 0) -> [(String, CGPDFObjectRef)] {
        guard depth < 32 else { return [] }
        var result: [(String, CGPDFObjectRef)] = []
        if let names = array(tree, "Names") {
            var index = 0
            while index + 1 < CGPDFArrayGetCount(names) {
                var key: CGPDFStringRef?
                var value: CGPDFObjectRef?
                if CGPDFArrayGetString(names, index, &key), let key, CGPDFArrayGetObject(names, index + 1, &value), let value {
                    result.append(((CGPDFStringCopyTextString(key) as String?) ?? "", value))
                }
                index += 2
            }
        }
        if let kids = array(tree, "Kids") {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid { result += nameTree(kid, depth: depth + 1) }
            }
        }
        return result
    }

    static func fileName(_ object: CGPDFObjectRef) -> String? {
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return text(object) }
        return fileName(dictionary: dictionary)
    }

    static func fileName(dictionary: CGPDFDictionaryRef) -> String? {
        string(dictionary, "UF") ?? string(dictionary, "F")
    }

    static func javaScript(_ action: CGPDFDictionaryRef) -> String? {
        let code = string(action, "JS") ?? stream(action, "JS").flatMap(data).flatMap { String(data: $0, encoding: .utf8) }
        return code.map { clip($0, 60) }
    }

    static func filters(_ dictionary: CGPDFDictionaryRef) -> [String] {
        if let single = name(dictionary, "Filter") { return [single] }
        guard let list = array(dictionary, "Filter") else { return [] }
        return (0..<CGPDFArrayGetCount(list)).compactMap { index in
            var name: UnsafePointer<CChar>?
            return CGPDFArrayGetName(list, index, &name) ? name.map { String(cString: $0) } : nil
        }
    }

    static func coordinates(_ gps: [CFString: Any]) -> String? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N") == "N" ? "N" : "S"
        let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E") == "E" ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", latitude, north, longitude, east)
    }

    static func xmpValues(_ xmp: String, tag: String) -> [String] {
        var values: [String] = []
        // Element form, possibly holding an rdf:Seq/Bag/Alt of rdf:li items.
        if let start = xmp.range(of: "<\(tag)"), let end = xmp.range(of: "</\(tag)>", range: start.upperBound..<xmp.endIndex) {
            let inner = String(xmp[start.upperBound..<end.lowerBound])
            let items = inner.matches(of: #/<rdf:li[^>]*>([^<]*)</rdf:li>/#).map { String($0.1) }
            if !items.isEmpty { values = items }
            else if let close = inner.firstIndex(of: ">") { values = [String(inner[inner.index(after: close)...])] }
        } else if let match = xmp.firstMatch(of: try! Regex("\(tag)=[\"']([^\"']*)[\"']")) {
            values = [String(match.output[1].substring ?? "")]
        }
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func extendedAttribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read > 0 ? data.prefix(read) : nil
        }
    }

    static func clip(_ text: String, _ length: Int = 80) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }

    static func isReadable(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return false }
        let readable = scalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == " " || CharacterSet.punctuationCharacters.contains($0) }
        return Double(readable.count) / Double(scalars.count) > 0.8
    }
}
