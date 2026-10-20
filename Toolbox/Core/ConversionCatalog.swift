import Foundation
import UniformTypeIdentifiers

/// A single source of truth for the format menu, drag wheel and conversion validation.
enum ConversionFamily: String, CaseIterable, Identifiable {
    case image, video, audio, pdf, document, slides, spreadsheet, ebook, subtitle, archive
    var id: Self { self }
    var title: String {
        switch self {
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Documents"
        case .slides: "Slides"
        case .spreadsheet: "Spreadsheets"
        case .ebook: "eBooks"
        case .subtitle: "Subtitles"
        case .archive: "Archives"
        }
    }
    var extensions: [String] {
        switch self {
        case .image: ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
        case .video: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"]
        case .audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        case .pdf: ["pdf"]
        case .document: ["docx", "pages", "md", "txt", "rtf", "rtfd", "textclipping", "html", "doc"]
        case .slides: ["ppt", "pptx"]
        case .spreadsheet: ["xlsx", "xls", "ods", "csv", "tsv"]
        case .ebook: ["epub", "mobi", "azw3", "azw", "fb2"]
        case .subtitle: ["srt", "vtt"]
        case .archive: ["zip", "tar", "gz", "tgz", "rar"]
        }
    }
    var types: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }
}

enum ConversionCatalog {
    static func normalizedExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "aif", "aifc": "aiff"
        case "markdown": "md"
        case "htm": "html"
        case "wave": "wav"
        case "tgz": "gz"
        default: ext.lowercased()
        }
    }
    static func family(of url: URL) -> ConversionFamily? {
        ConversionFamily.allCases.first { $0.extensions.contains(normalizedExtension(url.pathExtension)) }
    }
    static func targets(for url: URL) -> [String] {
        let ext = normalizedExtension(url.pathExtension)
        let targets: [String]
        switch family(of: url) {
        case .image: targets = ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"]
        case .video: targets = ext == "gif" ? ["mp4", "mov", "mkv", "webm", "avi", "wmv"] : ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]
        case .audio: targets = ConversionFamily.audio.extensions
        case .pdf: targets = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md", "html"]
        case .document: targets = ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"]
        case .slides: targets = ["pdf", "jpg", "png"]
        case .spreadsheet: targets = ["xlsx", "ods", "csv", "tsv", "pdf"]
        case .ebook: targets = ["pdf", "epub", "docx", "pages", "txt", "md", "html"]
        case .subtitle: targets = ["srt", "vtt", "txt"]
        case .archive: targets = ["zip", "tar", "gz"]
        case nil: targets = []
        }
        return targets.filter { $0 != ext }
    }
    static func commonTargets(for files: [URL]) -> [String] {
        guard let first = files.first else { return [] }
        return targets(for: first).filter { target in files.dropFirst().allSatisfy { targets(for: $0).contains(target) } }
    }
    static func label(_ target: String) -> String { target == "gz" ? "GZIP" : target.uppercased() }
}
