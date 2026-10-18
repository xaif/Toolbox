import SwiftUI

enum FileTools {
    static let all: [Tool] = [
        Tool(id: "files.batch-rename", name: "Batch Rename", category: .files, symbol: "character.cursor.ibeam",
             summary: "Rename many files at once with find & replace, numbering and more.",
             keywords: ["rename", "bulk", "numbering", "sequence", "replace"]) { PlaceholderToolView(tool: $0) },
    ]
}
