import SwiftUI
import UniformTypeIdentifiers

/// A category groups related tools in the sidebar and on the home screen.
enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case video, audio, image, pdf, ai, files, business

    var id: String { rawValue }

    var name: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .pdf: "PDF"
        case .ai: "On-device AI"
        case .files: "Files"
        case .business: "Business"
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
        case .business: "briefcase"
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
        case .business: Color(red: 0.10, green: 0.62, blue: 0.60)
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
    case libreoffice
    case exiftool
    case webp
    case avif
    case calibre

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ffmpeg: "FFmpeg"
        case .ytdlp: "yt-dlp"
        case .libreoffice: "LibreOffice"
        case .exiftool: "ExifTool"
        case .webp: "WebP"
        case .avif: "libavif"
        case .calibre: "Calibre"
        }
    }

    /// Executable name looked up on disk.
    var executableName: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        case .libreoffice: "soffice"
        case .exiftool: "exiftool"
        case .webp: "cwebp"
        case .avif: "avifenc"
        case .calibre: "ebook-convert"
        }
    }

    /// Homebrew formula used by the one-click installer.
    var brewFormula: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        case .libreoffice: "libreoffice"
        case .exiftool: "exiftool"
        case .webp: "webp"
        case .avif: "libavif"
        case .calibre: "calibre"
        }
    }

    /// Installed with `brew install --cask` (an app bundle) rather than as a formula.
    var isCask: Bool { self == .calibre }

    var purpose: String {
        switch self {
        case .ffmpeg: "Video and audio tools use FFmpeg to read, convert and encode media."
        case .ytdlp: "Download Video uses yt-dlp to fetch videos from a link."
        case .libreoffice: "Converts Office presentations and spreadsheets locally, preserving their layout."
        case .exiftool: "Reads, edits and removes embedded metadata in photos, media and PDFs."
        case .webp: "Encodes WebP images locally when macOS can't write WebP."
        case .avif: "Encodes AVIF images locally with the libavif image encoder."
        case .calibre: "Converts MOBI, AZW3 and other Kindle ebooks locally with Calibre."
        }
    }
}

/// The files a tool takes in its main input list (`JobRunner.inputs`). The launcher uses this to
/// offer tools for the files selected in Finder and to hand those files over.
struct ToolInput {
    let types: [UTType]
    var multiple = true
    var expandsFolders = true

    static let videos = ToolInput(types: UTType.videoInputs)
    static let video = ToolInput(types: UTType.videoInputs, multiple: false)
    static let audios = ToolInput(types: UTType.audioInputs)
    static let audio = ToolInput(types: UTType.audioInputs, multiple: false)
    static let media = ToolInput(types: UTType.mediaInputs)
    static let images = ToolInput(types: UTType.imageInputs)
    static let pdfs = ToolInput(types: UTType.pdfInputs)
    static let pdf = ToolInput(types: UTType.pdfInputs, multiple: false)
    static let imagesAndPDFs = ToolInput(types: [.image, .pdf])
    static let anyFiles = ToolInput(types: [.data])

    /// The files from `urls` this tool would accept (folders are expanded).
    @MainActor
    func accepted(from urls: [URL]) -> [URL] {
        let matches = expandsFolders ? FileListInput.expand(urls, accepting: types) : urls.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) && FileListInput.conforms($0, to: types)
        }
        return multiple ? matches : Array(matches.prefix(1))
    }
}

/// A tool's options, saved between runs with `@AppStorage`: the form shown on the tool's page and in
/// the launcher, plus the job those options configure. `job(for:)` reads the saved values, so a fresh
/// instance built anywhere (`Settings()`) runs with the user's last choices.
protocol ToolSettings: View {
    init()
    /// The job for the saved options, or nil while they can't run (say, no language chosen).
    func job(for tool: Tool) -> ToolJob?
}

/// A tool's one-step job, run on files without the tool's window (see `QuickRun`).
struct QuickAction {
    /// Shown in the launcher, e.g. "Compress" → "Compress 3 Files".
    let verb: String
    /// Show the options in the launcher before running, for tools whose settings usually change from
    /// run to run (a size, an angle).
    let asksFirst: Bool
    /// Combining tools, like Merge, need at least two files.
    let minimumFiles: Int
    /// Joins the files into one result. The launcher uses them in name order (see `QuickRun.start`).
    let combinesFiles: Bool
    /// Builds the job from the tool's saved settings. Returns nil when the tool can't run unattended
    /// yet, so it opens instead.
    let makeJob: @MainActor (Tool) -> ToolJob?
    /// The options form shown in the launcher. Nil for tools without options.
    let makeOptions: (@MainActor () -> AnyView)?

    /// A tool without options.
    init(_ verb: String, minimumFiles: Int = 1, makeJob: @escaping @MainActor (Tool) -> ToolJob?) {
        self.verb = verb
        self.asksFirst = false
        self.minimumFiles = minimumFiles
        self.combinesFiles = false
        self.makeJob = makeJob
        self.makeOptions = nil
    }

    /// A tool whose options are `settings`.
    init<S: ToolSettings>(_ verb: String, settings: S.Type, asksFirst: Bool = false, minimumFiles: Int = 1,
                          combinesFiles: Bool = false) {
        self.verb = verb
        self.asksFirst = asksFirst
        self.minimumFiles = minimumFiles
        self.combinesFiles = combinesFiles
        self.makeJob = { S().job(for: $0) }
        self.makeOptions = { AnyView(S()) }
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
    /// Nil for tools without a file list (recorders, Download Video, text-based tools).
    var input: ToolInput?
    /// Set for tools that can run on files with their saved settings and nothing else. The launcher
    /// and tool hotkeys run these on the Finder selection without opening the window. Nil for tools
    /// that need more input first (a time range, a password, a page selection…).
    var quickAction: QuickAction?
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
        input: ToolInput? = nil,
        quickAction: QuickAction? = nil,
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
        self.input = input
        self.quickAction = quickAction
        self.makeView = { AnyView(view($0)) }
    }

    static func == (lhs: Tool, rhs: Tool) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
