import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A page in an edited document: which source page it comes from and how much extra rotation to apply.
struct PDFPageRef: Hashable, Sendable {
    var index: Int
    /// Clockwise degrees added to the page's own rotation (multiples of 90).
    var rotation: Int = 0
}

/// An image placed on a page, e.g. a signature.
struct PDFStampPlacement {
    var pageIndex: Int
    /// Normalized rect (0…1) in the page's *displayed* space (crop box, rotation applied), origin bottom-left.
    var rect: CGRect
    var image: CGImage
}

enum PDFSplitMode: Hashable {
    case everyPage
    case everyN(Int)
    case ranges(String)
}

enum PDFCompressionLevel: String, CaseIterable, Identifiable {
    case light, recommended, maximum
    var id: Self { self }
}

enum PDFImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: Self { self }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
}

struct PDFImageLayout {
    enum PageSize: String, CaseIterable, Identifiable {
        case fit, a4, letter
        var id: Self { self }
        var label: String {
            switch self {
            case .fit: "Fit to image"
            case .a4: "A4"
            case .letter: "US Letter"
            }
        }
        /// Portrait size in points.
        var size: CGSize? {
            switch self {
            case .fit: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable {
        case auto, portrait, landscape
        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    var pageSize: PageSize = .a4
    var orientation: Orientation = .auto
    /// Margin in points.
    var margin: CGFloat = 0
    /// Downscale so the longest side is at most this many pixels. Nil keeps the original resolution.
    var maxPixelSize: Int?
    /// Re-encode as JPEG at this quality. Nil keeps original JPEG data where possible.
    var jpegQuality: CGFloat?
}

struct PDFProtection {
    var userPassword: String
    var ownerPassword: String = ""
    var allowPrinting = true
    var allowCopying = true
    var allowEditing = true

    var hasRestrictions: Bool { !(allowPrinting && allowCopying && allowEditing) }
}

/// PDF operations used by the PDF tools. Pure PDFKit/Quartz; safe to call off the main thread
/// as long as a document isn't shared with UI code that mutates it.
enum PDFOps {
    // MARK: - Opening and saving

    /// Opens a PDF. Locked PDFs need `password`; otherwise a clear error explains what to do.
    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ToolError.unreadableInput(url) }
        if document.isLocked {
            guard let password, !password.isEmpty else {
                throw ToolError.failed("“\(url.lastPathComponent)” is password-protected. Unlock it first with Remove PDF Password.")
            }
            guard document.unlock(withPassword: password) else {
                throw ToolError.failed("The password for “\(url.lastPathComponent)” is incorrect.")
            }
        }
        guard document.pageCount > 0 else { throw ToolError.failed("“\(url.lastPathComponent)” has no pages.") }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        guard document.write(to: url, withOptions: options) else {
            throw ToolError.failed("Couldn't save “\(url.lastPathComponent)”.")
        }
    }

    // MARK: - Page ranges

    /// Parses "1-3, 5, 8-" (1-based, open-ended ranges allowed) into validated 1-based closed ranges.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ToolError.failed("Enter pages, e.g. 1-3, 5, 8-.") }
        var ranges: [ClosedRange<Int>] = []
        for part in parts {
            let normalized = part.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
                .replacingOccurrences(of: " ", with: "")
            let bounds: (Int?, Int?)
            if normalized.lowercased() == "all" {
                bounds = (1, pageCount)
            } else if let dash = normalized.firstIndex(of: "-") {
                let lower = String(normalized[..<dash]), upper = String(normalized[normalized.index(after: dash)...])
                bounds = (lower.isEmpty ? 1 : Int(lower), upper.isEmpty ? pageCount : Int(upper))
            } else {
                let value = Int(normalized)
                bounds = (value, value)
            }
            guard let lower = bounds.0, let upper = bounds.1 else {
                throw ToolError.failed("“\(part)” isn't a valid page or range.")
            }
            guard lower >= 1, upper <= pageCount, lower <= upper else {
                throw ToolError.failed("“\(part)” is outside pages 1–\(pageCount).")
            }
            ranges.append(lower...upper)
        }
        return ranges
    }

    /// Zero-based page indices for a range string, in the order given, without duplicates.
    static func indices(_ text: String, pageCount: Int) throws -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for range in try parseRanges(text, pageCount: pageCount) {
            for page in range where seen.insert(page - 1).inserted { result.append(page - 1) }
        }
        return result
    }

    /// Formats zero-based indices as a compact 1-based range string, e.g. "1-3, 5".
    static func rangeString(_ indices: some Sequence<Int>) -> String {
        let sorted = Array(Set(indices)).sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end == index ? "\(sorted[index] + 1)" : "\(sorted[index] + 1)-\(sorted[end] + 1)")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Building documents

    /// A new document containing copies of `pages` (in order, with extra rotation), keeping metadata
    /// and the bookmarks that point at included pages.
    static func document(from source: PDFDocument, pages: [PDFPageRef]) -> PDFDocument {
        let output = PDFDocument()
        var pageMap: [Int: Int] = [:]
        for ref in pages {
            guard let original = source.page(at: ref.index), let page = copy(original, into: output) else { continue }
            if ref.rotation != 0 { page.rotation = normalizedRotation(original.rotation + ref.rotation) }
            if pageMap[ref.index] == nil { pageMap[ref.index] = output.pageCount - 1 }
        }
        copyAttributes(from: source, to: output)
        if let root = source.outlineRoot {
            let newRoot = PDFOutline()
            copyOutline(root, source: source, into: newRoot, destination: output, pageMap: pageMap)
            if newRoot.numberOfChildren > 0 { output.outlineRoot = newRoot }
        }
        return output
    }

    static func document(from source: PDFDocument, indices: [Int]) -> PDFDocument {
        document(from: source, pages: indices.map { PDFPageRef(index: $0) })
    }

    static func allPages(_ document: PDFDocument) -> [Int] { Array(0..<document.pageCount) }

    /// Appends a copy of `page` to `document`. Rotation is re-applied after insertion because PDFKit
    /// refuses to rotate pages that still belong to a document without page-assembly permission.
    @discardableResult
    static func copy(_ page: PDFPage, into document: PDFDocument) -> PDFPage? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        document.insert(copy, at: document.pageCount)
        if copy.rotation != page.rotation { copy.rotation = page.rotation }
        return copy
    }

    static func normalizedRotation(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    static func copyAttributes(from source: PDFDocument, to destination: PDFDocument) {
        guard var attributes = source.documentAttributes else { return }
        attributes[PDFDocumentAttribute.producerAttribute] = "Toolbox"
        destination.documentAttributes = attributes
    }

    /// Recursively copies bookmarks, re-pointing destinations through `pageMap` (source index → destination index).
    /// Items whose target page isn't included are dropped unless they have included children.
    static func copyOutline(_ item: PDFOutline, source: PDFDocument, into parent: PDFOutline,
                            destination: PDFDocument, pageMap: [Int: Int]) {
        for childIndex in 0..<item.numberOfChildren {
            guard let child = item.child(at: childIndex) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            var hasTarget = false
            let target = child.destination ?? (child.action as? PDFActionGoTo)?.destination
            if let target, let page = target.page {
                let sourceIndex = source.index(for: page)
                if sourceIndex != NSNotFound, let mapped = pageMap[sourceIndex], let newPage = destination.page(at: mapped) {
                    copy.destination = PDFDestination(page: newPage, at: target.point)
                    hasTarget = true
                }
            } else if let action = child.action as? PDFActionURL, let url = action.url {
                copy.action = PDFActionURL(url: url)
                hasTarget = true
            }
            copyOutline(child, source: source, into: copy, destination: destination, pageMap: pageMap)
            if hasTarget || copy.numberOfChildren > 0 {
                copy.isOpen = child.isOpen
                parent.insertChild(copy, at: parent.numberOfChildren)
            }
        }
    }

    // MARK: - Merge

    /// Combines PDFs in order. With `bookmarks`, adds one bookmark per file (holding that file's own bookmarks).
    static func merge(_ urls: [URL], bookmarks: Bool, progress: ((Double) -> Void)? = nil) throws -> PDFDocument {
        let output = PDFDocument()
        let root = PDFOutline()
        for (fileIndex, url) in urls.enumerated() {
            try Task.checkCancellation()
            let source = try open(url)
            let start = output.pageCount
            var pageMap: [Int: Int] = [:]
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index), copy(page, into: output) != nil else { continue }
                pageMap[index] = output.pageCount - 1
            }
            if fileIndex == 0 { copyAttributes(from: source, to: output) }
            if bookmarks {
                let fileItem = PDFOutline()
                fileItem.label = url.deletingPathExtension().lastPathComponent
                if let first = output.page(at: start) {
                    fileItem.destination = PDFDestination(page: first, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue))
                }
                if let sourceRoot = source.outlineRoot {
                    copyOutline(sourceRoot, source: source, into: fileItem, destination: output, pageMap: pageMap)
                }
                root.insertChild(fileItem, at: root.numberOfChildren)
            } else if let sourceRoot = source.outlineRoot {
                copyOutline(sourceRoot, source: source, into: root, destination: output, pageMap: pageMap)
            }
            progress?(Double(fileIndex + 1) / Double(urls.count))
        }
        if root.numberOfChildren > 0 { output.outlineRoot = root }
        var attributes = output.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = nil
        output.documentAttributes = attributes
        return output
    }

    // MARK: - Split

    /// Groups of zero-based page indices for a split mode.
    static func splitGroups(_ mode: PDFSplitMode, pageCount: Int) throws -> [[Int]] {
        switch mode {
        case .everyPage:
            return (0..<pageCount).map { [$0] }
        case .everyN(let n):
            guard n >= 1 else { throw ToolError.failed("Pages per file must be at least 1.") }
            return stride(from: 0, to: pageCount, by: n).map { Array($0..<min($0 + n, pageCount)) }
        case .ranges(let text):
            return try parseRanges(text, pageCount: pageCount).map { Array(($0.lowerBound - 1)...($0.upperBound - 1)) }
        }
    }

    /// File label for a group of zero-based pages, e.g. "page 03" or "pages 01-04" (zero-padded for sorting).
    static func label(for group: [Int], pageCount: Int) -> String {
        let width = max(String(pageCount).count, 2)
        func pad(_ index: Int) -> String { String(repeating: "0", count: max(width - String(index + 1).count, 0)) + String(index + 1) }
        guard let first = group.first, let last = group.last else { return "pages" }
        return group.count == 1 ? "page \(pad(first))" : "pages \(pad(first))-\(pad(last))"
    }

    // MARK: - Compress

    /// Compresses with PDFKit's image options, or by rasterizing pages for `.maximum`.
    static func compress(_ source: PDFDocument, level: PDFCompressionLevel, dpi: CGFloat, quality: CGFloat,
                         to url: URL, progress: ((Double) -> Void)? = nil) throws {
        switch level {
        case .light:
            try write(document(from: source, indices: allPages(source)), to: url, options: [.saveImagesAsJPEGOption: true])
        case .recommended:
            try write(document(from: source, indices: allPages(source)), to: url,
                      options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        case .maximum:
            try rasterize(source, to: url, dpi: dpi, quality: quality, progress: progress)
        }
        progress?(1)
    }

    /// Re-creates every page as a single JPEG image. Best for scans; text is no longer selectable.
    static func rasterize(_ source: PDFDocument, to url: URL, dpi: CGFloat, quality: CGFloat,
                          progress: ((Double) -> Void)? = nil) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, pdfInfo(from: source) as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            guard let page = source.page(at: index) else { continue }
            let size = displaySize(of: page)
            guard let rendered = renderPage(page, scale: dpi / 72),
                  let data = encode(rendered, as: .jpeg, quality: quality, dpi: dpi),
                  let provider = CGDataProvider(data: data as CFData),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw ToolError.failed("Couldn't render page \(index + 1).") }
            var box = CGRect(origin: .zero, size: size)
            context.beginPDFPage(pageInfo(mediaBox: &box))
            context.draw(jpeg, in: box)
            context.endPDFPage()
            progress?(Double(index + 1) / Double(source.pageCount))
        }
        context.closePDF()
    }

    // MARK: - Passwords

    /// Encrypts a document with AES (verified with poppler's pdfinfo). PDFKit writes a fresh document
    /// with AES; links, bookmarks and annotations are kept.
    static func encrypt(_ source: PDFDocument, protection: PDFProtection, to url: URL,
                        progress: ((Double) -> Void)? = nil) throws {
        guard !protection.userPassword.isEmpty else { throw ToolError.failed("Enter a password.") }
        let owner: String
        if !protection.ownerPassword.isEmpty {
            owner = protection.ownerPassword
        } else if protection.hasRestrictions {
            // Restrictions are only enforced when the owner password differs from the open password.
            owner = UUID().uuidString + UUID().uuidString
        } else {
            owner = protection.userPassword
        }
        var permissions: UInt = PDFAccessPermissions.allowsContentAccessibility.rawValue
        if protection.allowPrinting {
            permissions |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        }
        if protection.allowCopying { permissions |= PDFAccessPermissions.allowsContentCopying.rawValue }
        if protection.allowEditing {
            permissions |= PDFAccessPermissions.allowsDocumentChanges.rawValue | PDFAccessPermissions.allowsDocumentAssembly.rawValue
                | PDFAccessPermissions.allowsCommenting.rawValue | PDFAccessPermissions.allowsFormFieldEntry.rawValue
        }
        // Always write a fresh copy: re-saving an opened document can fall back to weaker RC4 encryption.
        try write(document(from: source, indices: allPages(source)), to: url, options: [
            .userPasswordOption: protection.userPassword,
            .ownerPasswordOption: owner,
            .accessPermissionsOption: NSNumber(value: permissions),
        ])
        guard let check = PDFDocument(url: url), check.isEncrypted, check.isLocked else {
            throw ToolError.failed("Encryption failed for “\(url.lastPathComponent)”.")
        }
        progress?(1)
    }

    /// Removes encryption. Returns the unlocked, unencrypted copy.
    static func removePassword(from url: URL, password: String) throws -> PDFDocument {
        guard let locked = PDFDocument(url: url) else { throw ToolError.unreadableInput(url) }
        guard locked.isEncrypted else { throw ToolError.failed("“\(url.lastPathComponent)” isn't password-protected.") }
        if locked.isLocked {
            guard !password.isEmpty else { throw ToolError.failed("Enter the password for “\(url.lastPathComponent)”.") }
            guard locked.unlock(withPassword: password) else {
                throw ToolError.failed("The password for “\(url.lastPathComponent)” is incorrect.")
            }
        }
        // PDFs with only permission restrictions open without a password; copying their pages removes them.
        // Writing an unlocked document keeps its encryption, so copy pages into a fresh document.
        return document(from: locked, indices: allPages(locked))
    }

    // MARK: - Images ⇄ PDF

    /// Lays out images one per page and writes the PDF to `url`.
    static func imagesToPDF(_ urls: [URL], layout: PDFImageLayout, to url: URL,
                            progress: ((Double) -> Void)? = nil) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator as String: "Toolbox"] as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for (index, imageURL) in urls.enumerated() {
            try Task.checkCancellation()
            let (image, pointSize) = try preparedImage(imageURL, layout: layout)
            var pageRect: CGRect
            if var size = layout.pageSize.size {
                let landscape: Bool
                switch layout.orientation {
                case .auto: landscape = pointSize.width > pointSize.height
                case .portrait: landscape = false
                case .landscape: landscape = true
                }
                if landscape { size = CGSize(width: size.height, height: size.width) }
                pageRect = CGRect(origin: .zero, size: size)
            } else {
                pageRect = CGRect(x: 0, y: 0, width: pointSize.width + layout.margin * 2, height: pointSize.height + layout.margin * 2)
            }
            let content = pageRect.insetBy(dx: layout.margin, dy: layout.margin)
            let scale = min(content.width / pointSize.width, content.height / pointSize.height)
            let drawSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
            let drawRect = CGRect(x: content.midX - drawSize.width / 2, y: content.midY - drawSize.height / 2,
                                  width: drawSize.width, height: drawSize.height)
            context.beginPDFPage(pageInfo(mediaBox: &pageRect))
            context.interpolationQuality = .high
            context.draw(image, in: drawRect)
            context.endPDFPage()
            progress?(Double(index + 1) / Double(urls.count))
        }
        context.closePDF()
    }

    /// Loads an image with EXIF orientation applied, optionally downscaled and re-encoded as JPEG.
    /// Returns the image and its natural size in points (using the image's DPI, 72 if unknown).
    private static func preparedImage(_ url: URL, layout: PDFImageLayout) throws -> (CGImage, CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ToolError.unreadableInput(url)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let dpi = max(properties[kCGImagePropertyDPIWidth] as? Double ?? 72, 72)
        let longest = max(pixelWidth, pixelHeight)
        let targetLongest = min(layout.maxPixelSize ?? longest, longest)
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier

        var image: CGImage
        if isJPEG, orientation == 1, targetLongest == longest, layout.jpegQuality == nil,
           let provider = CGDataProvider(url: url as CFURL),
           let passthrough = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            // Embed the original JPEG bytes untouched.
            image = passthrough
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetLongest,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ToolError.unreadableInput(url)
            }
            image = decoded
            let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo)
            if let quality = layout.jpegQuality ?? (isJPEG ? 0.9 : nil), !hasAlpha,
               let data = encode(decoded, as: .jpeg, quality: quality, dpi: nil),
               let provider = CGDataProvider(data: data as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                image = jpeg
            }
        }
        // Natural size uses the original pixel dimensions so downscaling doesn't shrink the page.
        let rotated = orientation >= 5
        let naturalWidth = Double(rotated ? pixelHeight : pixelWidth) * 72 / dpi
        let naturalHeight = Double(rotated ? pixelWidth : pixelHeight) * 72 / dpi
        // PDF pages max out at 200 inches.
        let limit = 14_400.0 - Double(layout.margin) * 2
        let fit = min(1, limit / max(naturalWidth, naturalHeight))
        return (image, CGSize(width: naturalWidth * fit, height: naturalHeight * fit))
    }

    /// Exports pages as image files into `folder`. Returns the files written.
    @discardableResult
    static func exportImages(_ document: PDFDocument, pages: [Int], to folder: URL, format: PDFImageFormat,
                             quality: CGFloat, dpi: CGFloat, progress: ((Double) -> Void)? = nil) throws -> [URL] {
        var written: [URL] = []
        for (position, index) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index),
                  let image = renderPage(page, scale: dpi / 72),
                  let data = encode(image, as: format, quality: quality, dpi: dpi) else {
                throw ToolError.failed("Couldn't render page \(index + 1).")
            }
            let url = uniqueURL(in: folder, name: label(for: [index], pageCount: document.pageCount).capitalized,
                                extension: format.fileExtension)
            try data.write(to: url)
            written.append(url)
            progress?(Double(position + 1) / Double(pages.count))
        }
        return written
    }

    // MARK: - Rendering

    /// Size of the page as displayed (crop box with rotation applied), in points.
    static func displaySize(of page: PDFPage, box: PDFDisplayBox = .cropBox) -> CGSize {
        let bounds = page.bounds(for: box)
        return normalizedRotation(page.rotation) % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    /// Renders a page on white with its rotation applied. `scale` 1 = 72 DPI.
    static func renderPage(_ page: PDFPage, scale: CGFloat, box: PDFDisplayBox = .cropBox) -> CGImage? {
        let size = displaySize(of: page, box: box)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: box, to: context)
        return context.makeImage()
    }

    static func thumbnail(_ page: PDFPage, maxDimension: CGFloat) -> NSImage? {
        let size = displaySize(of: page)
        let scale = maxDimension / max(size.width, size.height, 1) * 2 // @2x
        guard let image = renderPage(page, scale: scale) else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: size.width * scale / 2, height: size.height * scale / 2))
    }

    static func encode(_ image: CGImage, as format: PDFImageFormat, quality: CGFloat, dpi: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Stamps (signatures)

    /// Permanently draws images onto pages. Each affected page is redrawn with the stamps on top of its
    /// original content (text stays selectable); existing annotations and bookmarks are carried over.
    static func applyStamps(_ placements: [PDFStampPlacement], to document: PDFDocument) throws {
        let byPage = Dictionary(grouping: placements, by: \.pageIndex)
        for (pageIndex, stamps) in byPage {
            guard let page = document.page(at: pageIndex) else { continue }
            let newPage = try stampedPage(page, stamps: stamps)
            let annotations = page.annotations
            for annotation in annotations {
                page.removeAnnotation(annotation)
                newPage.addAnnotation(annotation)
            }
            document.insert(newPage, at: pageIndex)
            if let root = document.outlineRoot { retarget(root, from: page, to: newPage) }
            document.removePage(at: pageIndex + 1)
        }
    }

    private static func stampedPage(_ page: PDFPage, stamps: [PDFStampPlacement]) throws -> PDFPage {
        guard let pageRef = page.pageRef else { throw ToolError.failed("Couldn't read the page.") }
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed("Couldn't draw the signature.")
        }
        context.beginPDFPage(pageInfo(mediaBox: &mediaBox))
        context.drawPDFPage(pageRef)
        // Stamps are positioned in displayed space; map back into page space so they appear upright.
        let toDisplay = page.transform(for: .cropBox)
        let displayed = displaySize(of: page)
        for stamp in stamps {
            let rect = CGRect(x: stamp.rect.minX * displayed.width, y: stamp.rect.minY * displayed.height,
                              width: stamp.rect.width * displayed.width, height: stamp.rect.height * displayed.height)
            context.saveGState()
            context.concatenate(toDisplay.inverted())
            context.interpolationQuality = .high
            context.draw(stamp.image, in: rect)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let stampedDocument = PDFDocument(data: data as Data),
              let stamped = stampedDocument.page(at: 0)?.copy() as? PDFPage else {
            throw ToolError.failed("Couldn't draw the signature.")
        }
        stamped.rotation = page.rotation
        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            stamped.setBounds(page.bounds(for: box), for: box)
        }
        return stamped
    }

    private static func retarget(_ item: PDFOutline, from old: PDFPage, to new: PDFPage) {
        for index in 0..<item.numberOfChildren {
            guard let child = item.child(at: index) else { continue }
            if let destination = child.destination, destination.page === old {
                child.destination = PDFDestination(page: new, at: destination.point)
            }
            retarget(child, from: old, to: new)
        }
    }

    // MARK: - Helpers

    static func pageInfo(mediaBox: inout CGRect) -> CFDictionary {
        let boxData = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
        return [kCGPDFContextMediaBox as String: boxData] as CFDictionary
    }

    /// Title/author/etc. for a Core Graphics PDF context.
    static func pdfInfo(from document: PDFDocument) -> [String: Any] {
        var info: [String: Any] = [kCGPDFContextCreator as String: "Toolbox"]
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle as String] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor as String] = author }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String { info[kCGPDFContextSubject as String] = subject }
        return info
    }

    /// A file URL in `folder` that doesn't exist yet: "name.ext", then "name 2.ext", …
    static func uniqueURL(in folder: URL, name: String, extension ext: String) -> URL {
        let clean = OutputManager.sanitize(name)
        var url = folder.appendingPathComponent(clean).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(clean) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
