import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Image formats the image tools can write with ImageIO.
enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff, gif, bmp, webp

    var id: Self { self }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .webp: .webP
        }
    }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .webp: "WebP"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    var supportsQuality: Bool { self == .jpeg || self == .heic || self == .webp }
    var supportsAlpha: Bool { self != .jpeg && self != .bmp }

    /// Formats this Mac's ImageIO can encode.
    static let writable: [ImageFormat] = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { identifiers.contains($0.utType.identifier) }
    }()

    /// The writable format matching a file's type, if any.
    static func of(_ url: URL) -> ImageFormat? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        return writable.first { type.conforms(to: $0.utType) }
    }
}

/// Shared ImageIO helpers. All functions are thread-safe and run off the main actor.
enum ImageIOHelpers {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func source(for url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ToolError.unreadableInput(url) }
        return source
    }

    static func properties(_ source: CGImageSource, index: Int) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
    }

    static func orientation(_ properties: [CFString: Any]) -> CGImagePropertyOrientation {
        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    /// Decodes a frame with its EXIF orientation baked into the pixels.
    static func orientedImage(_ source: CGImageSource, index: Int) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ToolError.failed("Couldn't decode the image.")
        }
        let orientation = orientation(properties(source, index: index))
        return orientation == .up ? image : try apply(orientation, to: image)
    }

    /// Redraws `image` with an EXIF-style orientation transform (rotations and mirrors).
    static func apply(_ orientation: CGImagePropertyOrientation, to image: CGImage) throws -> CGImage {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swaps: Bool = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let outWidth = swaps ? image.height : image.width
        let outHeight = swaps ? image.width : image.height
        guard let context = makeContext(width: outWidth, height: outHeight, like: image) else {
            throw ToolError.failed("Couldn't create a drawing context.")
        }
        // Transforms in Core Graphics' bottom-left coordinate space.
        var transform = CGAffineTransform.identity
        switch orientation {
        case .up: break
        case .upMirrored: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .leftMirrored: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        context.concatenate(transform)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw ToolError.failed("Couldn't render the image.") }
        return result
    }

    /// A bitmap context matching the image's color space and depth where Core Graphics supports it.
    static func makeContext(width: Int, height: Int, like image: CGImage, forceAlpha: Bool = false) -> CGContext? {
        let hasAlpha = forceAlpha || image.hasAlpha
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let space = image.colorSpace
        if let space, space.model == .rgb {
            let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                       space: space, bitmapInfo: info) { return context }
        } else if let space, space.model == .monochrome, !hasAlpha {
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                       space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) { return context }
        } else if let space, space.model == .cmyk, !hasAlpha {
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) { return context }
        }
        let fallback = (space?.model == .rgb ? space : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: fallback,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Composites transparent images onto a solid color (used for formats without alpha).
    static func flatten(_ image: CGImage, onto color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        guard image.hasAlpha else { return image }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.failed("Couldn't create a drawing context.")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ToolError.failed("Couldn't render the image.") }
        return result
    }

    /// High-quality Lanczos resampling to an exact pixel size, keeping the image's color space.
    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let width = max(width, 1), height = max(height, 1)
        guard width != image.width || height != image.height else { return image }
        let input = CIImage(cgImage: image)
        let scale = CGFloat(height) / CGFloat(image.height)
        let aspect = (CGFloat(width) / CGFloat(image.width)) / scale
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw ToolError.failed("Couldn't resize the image.")
        }
        return try render(scaled, like: image)
    }

    /// Renders a Core Image result into a CGImage in the original image's color space and depth.
    static func render(_ ciImage: CIImage, like original: CGImage) throws -> CGImage {
        let space = original.colorSpace?.model == .rgb ? original.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = original.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let result = ciContext.createCGImage(ciImage, from: ciImage.extent.integral, format: format, colorSpace: space) else {
            throw ToolError.failed("Couldn't render the image.")
        }
        if !original.hasAlpha, let opaque = try? flatten(result) { return opaque }
        return result
    }

    /// Metadata worth carrying over when re-encoding, with orientation reset (pixels are already upright).
    static func carriedProperties(_ properties: [CFString: Any], keepMetadata: Bool) -> [CFString: Any] {
        var result: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard keepMetadata else { return result }
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { result[key] = value }
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // Dimensions change on resize/rotate; let ImageIO write the real ones.
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            result[kCGImagePropertyExifDictionary] = exif
        }
        return result
    }

    /// Re-encodes an image file frame by frame.
    ///
    /// - Each frame is decoded with EXIF orientation applied, passed through `transform`, and written in `format`.
    /// - Animated GIFs stay animated when the output is GIF; otherwise the primary frame is used.
    /// - Transparent images are flattened onto white for formats without alpha.
    static func reencode(
        _ input: URL,
        to output: URL,
        format: ImageFormat,
        quality: Double? = nil,
        keepMetadata: Bool = true,
        transform: (CGImage) throws -> CGImage = { $0 }
    ) throws {
        let source = try source(for: input)
        let count = CGImageSourceGetCount(source)
        let animated = count > 1 && format == .gif
        let indices = animated ? Array(0..<count) : [CGImageSourceGetPrimaryImageIndex(source)]

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.utType.identifier as CFString,
                                                                indices.count, nil) else {
            throw ToolError.unsupported("\(format.label) isn't supported on this Mac.")
        }
        if animated, let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = fileProperties[kCGImagePropertyGIFDictionary] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
        }

        for index in indices {
            let sourceProperties = properties(source, index: index)
            var image = try transform(try orientedImage(source, index: index))
            if !format.supportsAlpha { image = try flatten(image) }
            var properties = carriedProperties(sourceProperties, keepMetadata: keepMetadata)
            if animated, let gif = sourceProperties[kCGImagePropertyGIFDictionary] { properties[kCGImagePropertyGIFDictionary] = gif }
            if let quality, format.supportsQuality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError.failed("Couldn't write \(format.label).")
        }
    }

    /// Output format for tools that keep the input's format: the same format if writable,
    /// otherwise PNG for images with transparency and JPEG for the rest (e.g. camera RAW).
    static func keepFormat(for input: URL) -> ImageFormat {
        if let format = ImageFormat.of(input) { return format }
        if let source = try? source(for: input), let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.hasAlpha {
            return .png
        }
        return .jpeg
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
