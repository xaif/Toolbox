import SwiftUI

/// A category groups related tools in the sidebar and on the home screen.
enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case video, audio, image, pdf, ai, files

    var id: String { rawValue }

    var name: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .pdf: "PDF"
        case .ai: "On-device AI"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .ai: "sparkles"
        case .files: "folder"
        }
    }

    var tint: Color {
        switch self {
        case .video: Color(red: 0.93, green: 0.30, blue: 0.45)
        case .audio: Color(red: 0.98, green: 0.55, blue: 0.20)
        case .image: Color(red: 0.20, green: 0.72, blue: 0.45)
        case .pdf: Color(red: 0.90, green: 0.25, blue: 0.22)
        case .ai: Color(red: 0.45, green: 0.38, blue: 0.95)
        case .files: Color(red: 0.20, green: 0.60, blue: 0.85)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// External command-line programs some tools depend on.
enum ExternalDependency: String, CaseIterable, Identifiable, Hashable {
    case ffmpeg
    case ytdlp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ffmpeg: "FFmpeg"
        case .ytdlp: "yt-dlp"
        }
    }

    /// Executable name looked up on disk.
    var executableName: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        }
    }

    /// Homebrew formula used by the one-click installer.
    var brewFormula: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        }
    }

    var purpose: String {
        switch self {
        case .ffmpeg: "Video and audio tools use FFmpeg to read, convert and encode media."
        case .ytdlp: "Download Video uses yt-dlp to fetch videos from a link."
        }
    }
}

/// A single tool shown in the app. Each tool owns its SwiftUI view.
struct Tool: Identifiable, Hashable {
    let id: String
    /// Full, unambiguous name used in search and page headers, e.g. "Compress Video".
    let name: String
    /// Short name used inside a category list, e.g. "Compress".
    let shortName: String
    let category: ToolCategory
    let symbol: String
    let summary: String
    var keywords: [String] = []
    var requirements: [ExternalDependency] = []
    let makeView: @MainActor (Tool) -> AnyView

    init(
        id: String,
        name: String,
        shortName: String? = nil,
        category: ToolCategory,
        symbol: String,
        summary: String,
        keywords: [String] = [],
        requirements: [ExternalDependency] = [],
        @ViewBuilder view: @escaping @MainActor (Tool) -> some View
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName ?? name
        self.category = category
        self.symbol = symbol
        self.summary = summary
        self.keywords = keywords
        self.requirements = requirements
        self.makeView = { AnyView(view($0)) }
    }

    static func == (lhs: Tool, rhs: Tool) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
