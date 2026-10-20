import SwiftUI
import Observation

enum Destination: Hashable {
    case home
    case category(ToolCategory)
    case collection(FeaturedCollection)
    case tool(String)
}

/// Curated groups shown as feature cards on the home screen (⌘1–⌘4).
enum FeaturedCollection: String, CaseIterable, Identifiable, Hashable {
    case screenRecording, pdf, ai, batch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen recording studio"
        case .pdf: "PDF toolbox"
        case .ai: "On-device AI"
        case .batch: "Batch processing"
        }
    }

    var subtitle: String {
        switch self {
        case .screenRecording: "Record a display, window or area with your camera, then zoom, trim and caption."
        case .pdf: "Merge, split, reorder, sign and password-protect PDFs."
        case .ai: "Transcribe, summarize, read text from images and translate. All on your Mac."
        case .batch: "Convert, compress or rename a whole folder of files at once."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "record.circle"
        case .pdf: "doc.on.doc"
        case .ai: "sparkles"
        case .batch: "square.stack.3d.up"
        }
    }

    var tint: Color {
        switch self {
        case .screenRecording: ToolCategory.video.tint
        case .pdf: ToolCategory.pdf.tint
        case .ai: ToolCategory.ai.tint
        case .batch: ToolCategory.files.tint
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .screenRecording: "1"
        case .pdf: "2"
        case .ai: "3"
        case .batch: "4"
        }
    }

    /// What the card opens.
    var destination: Destination {
        switch self {
        case .screenRecording: .tool("video.record-screen")
        case .pdf: .category(.pdf)
        case .ai: .category(.ai)
        case .batch: .collection(.batch)
        }
    }

    var toolIDs: [String] {
        switch self {
        case .screenRecording: ["video.record-screen", "video.teleprompter", "video.trim", "video.burn-subtitles", "ai.transcribe", "video.to-gif"]
        case .pdf: ToolRegistry.tools(in: .pdf).map(\.id)
        case .ai: ToolRegistry.tools(in: .ai).map(\.id)
        case .batch: ["video.convert", "video.compress", "audio.convert", "image.convert", "image.compress", "image.resize", "pdf.compress", "files.batch-rename"]
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var destination: Destination = .home
    var searchText = ""
    /// Incremented to ask the home search field to take focus.
    private(set) var searchFocusRequest = 0
    /// Captured from the SwiftUI environment so non-view code (the global hotkey) can reopen the window.
    var openMainWindow: (() -> Void)?

    func open(_ destination: Destination) {
        self.destination = destination
        if case .tool(let id) = destination { AppSettings.noteToolOpened(id) }
    }

    /// Opens a tool in the main window, optionally handing it files (e.g. from the launcher).
    func openTool(_ tool: Tool, with files: [URL] = []) {
        bringMainWindowForward()
        let runner = JobCenter.shared.runner(for: tool.id)
        if let input = tool.input, !files.isEmpty, !runner.isRunning {
            let accepted = input.accepted(from: files)
            if !accepted.isEmpty { runner.inputs = accepted }
        }
        open(.tool(tool.id))
    }

    func focusSearch() {
        destination = .home
        searchFocusRequest += 1
    }

    /// Brings the app forward and focuses search. Used by the global hotkey.
    func summon() {
        bringMainWindowForward()
        focusSearch()
    }

    func bringMainWindowForward() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}
