import SwiftUI

enum ImageTools {
    static let all: [Tool] = [
        Tool(id: "image.convert", name: "Convert Images", shortName: "Convert", category: .image, symbol: "arrow.triangle.2.circlepath",
             summary: "Change format to JPEG, PNG, HEIC, TIFF and more.",
             keywords: ["jpg", "jpeg", "png", "heic", "tiff", "gif", "bmp", "format", "webp"], input: .images) { ConvertImagesView(tool: $0) },
        Tool(id: "image.compress", name: "Compress Images", shortName: "Compress", category: .image, symbol: "arrow.down.right.and.arrow.up.left",
             summary: "Make photos smaller with adjustable quality.",
             keywords: ["shrink", "reduce", "size", "optimize"], input: .images) { CompressImagesView(tool: $0) },
        Tool(id: "image.resize", name: "Resize Images", shortName: "Resize", category: .image, symbol: "arrow.up.left.and.arrow.down.right",
             summary: "Scale images by percentage or to exact dimensions.",
             keywords: ["scale", "dimensions", "width", "height", "thumbnail"], input: .images) { ResizeImagesView(tool: $0) },
        Tool(id: "image.rotate", name: "Rotate Images", shortName: "Rotate", category: .image, symbol: "rotate.right",
             summary: "Rotate or flip images.",
             keywords: ["flip", "mirror", "orientation", "turn"], input: .images) { RotateImagesView(tool: $0) },
        Tool(id: "image.remove-background", name: "Remove Background", category: .image, symbol: "person.crop.rectangle.badge.plus",
             summary: "Cut out the subject and make the background transparent.",
             keywords: ["cutout", "transparent", "subject", "lift", "ai"], input: .images) { RemoveBackgroundView(tool: $0) },
        Tool(id: "image.remove-metadata", name: "Remove Metadata", category: .image, symbol: "eye.slash",
             summary: "Strip location, camera and other hidden data.",
             keywords: ["exif", "gps", "location", "privacy", "strip"], input: .images) { RemoveMetadataView(tool: $0) },
    ]
}
