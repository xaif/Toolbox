import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Corners of a document in a photo, normalized (0…1) with the origin at the bottom left.
struct ScanQuad: Sendable, Equatable {
    enum Corner: CaseIterable { case topLeft, topRight, bottomRight, bottomLeft }

    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let full = ScanQuad(topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1),
                               bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 0))

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    init(_ observation: some QuadrilateralProviding) {
        self.init(topLeft: observation.topLeft.cgPoint, topRight: observation.topRight.cgPoint,
                  bottomRight: observation.bottomRight.cgPoint, bottomLeft: observation.bottomLeft.cgPoint)
    }

    subscript(corner: Corner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: topLeft
            case .topRight: topRight
            case .bottomRight: bottomRight
            case .bottomLeft: bottomLeft
            }
        }
        set {
            let clamped = CGPoint(x: min(max(newValue.x, 0), 1), y: min(max(newValue.y, 0), 1))
            switch corner {
            case .topLeft: topLeft = clamped
            case .topRight: topRight = clamped
            case .bottomRight: bottomRight = clamped
            case .bottomLeft: bottomLeft = clamped
            }
        }
    }

    /// Area as a fraction of the photo (shoelace formula).
    var area: CGFloat {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        var sum: CGFloat = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    var isFull: Bool { self == .full }

    /// Moves each corner `fraction` of the way to the center. Detected edges often sit a pixel or two
    /// outside the paper, which would leave a dark sliver of the desk.
    func insetToCenter(by fraction: CGFloat) -> ScanQuad {
        let corners = [topLeft, topRight, bottomRight, bottomLeft]
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        func inset(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + (center.x - point.x) * fraction, y: point.y + (center.y - point.y) * fraction)
        }
        return ScanQuad(topLeft: inset(topLeft), topRight: inset(topRight), bottomRight: inset(bottomRight), bottomLeft: inset(bottomLeft))
    }
}

enum ScanFilter: String, CaseIterable, Identifiable, Sendable {
    case original, color, grayscale, blackAndWhite
    var id: Self { self }

    var label: String {
        switch self {
        case .original: "Original"
        case .color: "Color"
        case .grayscale: "Grayscale"
        case .blackAndWhite: "B&W"
        }
    }
}

/// One scanned page: the photo (encoded, to keep memory down) and how to turn it into a page.
struct ScanPageSpec: Sendable {
    var source: Data
    var quad: ScanQuad
    var filter: ScanFilter
    /// Clockwise degrees, a multiple of 90.
    var rotation: Int
}

/// Crops, straightens and cleans up document photos, and writes them as a PDF.
enum ScanProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Loading

    /// Decodes an image upright (EXIF orientation applied), at most `maxPixels` on its longest side.
    static func image(from data: Data, maxPixels: Int = 3600) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source, maxPixels: maxPixels)
    }

    static func image(at url: URL, maxPixels: Int = 3600) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: source, maxPixels: maxPixels)
    }

    private static func image(from source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Compact storage for a captured photo.
    static func encode(_ image: CGImage) -> Data? { PDFOps.encode(image, as: .jpeg, quality: 0.92, dpi: nil) }

    /// Each page of a PDF (such as an iPhone document scan) as an image, about 300 DPI.
    static func images(fromPDF document: PDFDocument) -> [CGImage] {
        (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let size = PDFOps.displaySize(of: page)
            return PDFOps.renderPage(page, scale: min(300.0 / 72, 3600 / max(size.width, size.height, 1)))
        }
    }

    // MARK: - Detection

    /// The document's corners, or nil when no page-like shape stands out.
    static func detectQuad(_ image: CGImage) async -> ScanQuad? {
        if let document = try? await DetectDocumentSegmentationRequest().perform(on: image), document.confidence >= 0.5 {
            let quad = ScanQuad(document)
            if quad.area >= 0.08, !quad.isFull { return quad.insetToCenter(by: 0.012) }
        }
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.25
        request.minimumConfidence = 0.6
        request.quadratureToleranceDegrees = 30
        request.maximumObservations = 1
        if let rectangle = try? await request.perform(on: image).first {
            let quad = ScanQuad(rectangle)
            if quad.area >= 0.08 { return quad.insetToCenter(by: 0.012) }
        }
        return nil
    }

    /// The same detection for live camera frames, which arrive on a capture queue.
    static func detectQuad(in pixelBuffer: CVPixelBuffer) -> ScanQuad? {
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
        guard let observation = request.results?.first, observation.confidence >= 0.5 else { return nil }
        let quad = ScanQuad(topLeft: observation.topLeft, topRight: observation.topRight,
                            bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
        return quad.area >= 0.08 ? quad.insetToCenter(by: 0.012) : nil
    }

    // MARK: - Processing

    /// The finished page image: cropped and straightened to the quad, rotated and filtered.
    static func process(_ spec: ScanPageSpec, maxPixels: Int = 3600) -> CGImage? {
        guard let photo = image(from: spec.source, maxPixels: maxPixels) else { return nil }
        return process(photo, quad: spec.quad, filter: spec.filter, rotation: spec.rotation)
    }

    static func process(_ photo: CGImage, quad: ScanQuad, filter: ScanFilter, rotation: Int) -> CGImage? {
        var image = corrected(CIImage(cgImage: photo), quad: quad)
        image = rotated(image, by: rotation)
        image = filtered(image, filter)
        // Whole pixels only: partly covered edge pixels would come out as a dark border.
        let bounds = image.extent
        let extent = CGRect(x: ceil(bounds.minX), y: ceil(bounds.minY),
                            width: floor(bounds.maxX) - ceil(bounds.minX), height: floor(bounds.maxY) - ceil(bounds.minY))
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        if filter == .grayscale || filter == .blackAndWhite,
           let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) {
            return context.createCGImage(image, from: extent, format: .L8, colorSpace: gray)
        }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Maps the quad onto a rectangle, which crops the background and removes perspective and skew.
    static func corrected(_ image: CIImage, quad: ScanQuad) -> CIImage {
        guard !quad.isFull else { return image }
        let extent = image.extent
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + point.y * extent.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = pixel(quad.topLeft)
        filter.topRight = pixel(quad.topRight)
        filter.bottomRight = pixel(quad.bottomRight)
        filter.bottomLeft = pixel(quad.bottomLeft)
        guard let output = filter.outputImage else { return image }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
    }

    static func rotated(_ image: CIImage, by degrees: Int) -> CIImage {
        let turns = ((degrees / 90) % 4 + 4) % 4
        guard turns > 0 else { return image }
        // Negative angles turn clockwise in Core Image's y-up space.
        let turned = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    }

    static func filtered(_ image: CIImage, _ filter: ScanFilter) -> CIImage {
        let extent = image.extent
        switch filter {
        case .original:
            return image
        case .color:
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = image
            enhancer.amount = 1
            return (enhancer.outputImage ?? image).cropped(to: extent)
        case .grayscale:
            let controls = CIFilter.colorControls()
            controls.inputImage = flattened(image)
            controls.contrast = 1.15
            controls.saturation = 0
            return (controls.outputImage ?? image).cropped(to: extent)
        case .blackAndWhite:
            let threshold = CIFilter.colorThreshold()
            threshold.inputImage = flattened(image)
            threshold.threshold = 0.6
            return (threshold.outputImage ?? image).cropped(to: extent)
        }
    }

    /// Grayscale with uneven lighting and shadows removed: each pixel divided by the local paper brightness.
    private static func flattened(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let gray = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        // Estimate the paper at low resolution: grow light areas over the ink, then smooth.
        let scale = min(1, 400 / max(extent.width, extent.height, 1))
        let paper = gray.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 6])
            .applyingGaussianBlur(sigma: 6)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
        let divide = CIFilter.divideBlendMode()
        // Divide blend computes background ÷ input.
        divide.inputImage = paper
        divide.backgroundImage = gray
        return (divide.outputImage ?? gray).cropped(to: extent)
    }

    // MARK: - Writing

    /// Writes one PDF page per scan. With `ocr`, each page gets an invisible text layer.
    static func writePDF(_ pages: [ScanPageSpec], to url: URL, pageSize: PDFImageLayout.PageSize, quality: CGFloat,
                         ocr: AIOCR.Options?, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !pages.isEmpty else { throw ToolError.failed("Add a page first.") }
        guard let context = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextCreator as String: "Toolbox"] as CFDictionary) else {
            throw ToolError.failed("Couldn't create “\(url.lastPathComponent)”.")
        }
        for (index, spec) in pages.enumerated() {
            try Task.checkCancellation()
            guard let image = process(spec) else { throw ToolError.failed("Couldn't process page \(index + 1).") }
            var (pageRect, drawRect) = layout(CGSize(width: image.width, height: image.height), pageSize: pageSize)
            var lines: [PDFTextLine] = []
            if let ocr { lines = try await PDFTextLayer.recognize(image, options: ocr) }
            context.beginPDFPage(PDFOps.pageInfo(mediaBox: &pageRect))
            try PDFTextLayer.drawImage(image, in: drawRect, lines: lines, quality: quality, context: context)
            context.endPDFPage()
            progress?(Double(index + 1) / Double(pages.count))
        }
        context.closePDF()
    }

    /// The page and the image's rect on it. "Fit" pages match the scan, with the longest side as long as A4's.
    static func layout(_ pixels: CGSize, pageSize: PDFImageLayout.PageSize) -> (page: CGRect, image: CGRect) {
        let aspect = pixels.width / max(pixels.height, 1)
        guard var size = pageSize.size else {
            let long: CGFloat = 841.89
            let fit = aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
            let rect = CGRect(origin: .zero, size: fit)
            return (rect, rect)
        }
        if aspect > 1 { size = CGSize(width: size.height, height: size.width) }
        let page = CGRect(origin: .zero, size: size)
        let scale = min(size.width / pixels.width, size.height / pixels.height)
        let drawn = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return (page, CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                             width: drawn.width, height: drawn.height))
    }
}
