import SwiftUI

enum FileTools {
    static let all: [Tool] = [
        Tool(id: "files.convert", name: "Convert Files", category: .files, symbol: "arrow.triangle.2.circlepath",
             summary: "Convert documents, slides, spreadsheets, books, media, subtitles and archives locally.",
             keywords: ConversionFamily.allCases.flatMap(\.extensions) + ["word to pdf", "pdf to word", "excel to pdf", "pdf to excel",
                 "powerpoint to pdf", "pdf to powerpoint", "markdown to pdf", "html to pdf", "pdf to html", "csv to pdf",
                 "ebook to pdf", "kindle", "pdf to epub"], input: ToolInput(types: [.item])) { ConvertFilesView(tool: $0) },
        Tool(id: "files.actions", name: "File Actions", category: .files, symbol: "square.and.arrow.up",
             summary: "AirDrop, float, copy, move, copy paths and open a terminal.",
             keywords: ["airdrop", "float", "shelf", "clipboard", "move", "terminal", "path"], input: ToolInput(types: [.item], expandsFolders: false)) { FileActionsView(tool: $0) },
        Tool(id: "files.extract-archive", name: "Extract Archives", shortName: "Extract", category: .files, symbol: "archivebox",
             summary: "Unpack ZIP, TAR, GZIP and RAR files into a new folder.",
             keywords: ["unzip", "unpack", "zip", "tar", "gzip", "rar"], input: ToolInput(types: ConversionFamily.archive.types),
             quickAction: QuickAction("Extract") { _ in ArchiveToolView.extractJob }) { ArchiveToolView(tool: $0) },
        Tool(id: "files.create-archive", name: "Create Archive", category: .files, symbol: "archivebox.fill",
             summary: "Package files and folders as ZIP, TAR or GZIP.", keywords: ["zip", "tar", "gzip", "compress folder"]) { ArchiveToolView(tool: $0) },
        Tool(id: "files.metadata", name: "Edit Metadata", shortName: "Metadata", category: .files, symbol: "tag",
             summary: "Read, edit or remove embedded photo, audio, video and PDF tags.",
             keywords: ["exif", "gps", "artist", "album", "author", "privacy", "remove metadata"], requirements: [.exiftool], input: .anyFiles) { MetadataView(tool: $0) },
        Tool(id: "files.batch-rename", name: "Batch Rename", category: .files, symbol: "character.cursor.ibeam",
             summary: "Rename many files at once with find & replace, numbering and more.",
             keywords: ["rename", "bulk", "numbering", "sequence", "replace", "regex"], input: .anyFiles) { BatchRenameView(tool: $0) },
    ]
}
