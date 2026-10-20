import Foundation

/// Every tool in the app, in display order. Each category registers its tools in its own file.
enum ToolRegistry {
    static let all: [Tool] = [
        VideoTools.all, ExtendedMediaTools.video, AudioTools.all, ExtendedMediaTools.audio,
        ImageTools.all, ExtendedImageTools.all,
        PDFTools.all, PDFEditorTools.all, PDFStampTools.all, PDFOCRTools.all, CreatePDFTools.all, PDFIntegrityTools.all,
        AITools.all, SpeechAITools.all, FileTools.all, ShareTools.all, BusinessTools.all,
    ].flatMap { $0 }

    private static let byID: [String: Tool] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func tool(_ id: String) -> Tool? { byID[id] }

    static func tools(in category: ToolCategory) -> [Tool] { all.filter { $0.category == category } }

    /// Ranked search across names, categories and keywords. Every query word must match somewhere.
    static func search(_ query: String) -> [Tool] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        var scored: [(Tool, Int)] = []
        for tool in all {
            let name = tool.name.lowercased()
            let nameWords = name.split(separator: " ").map(String.init)
            let haystack = ([name, tool.shortName.lowercased(), tool.category.name.lowercased(), tool.category.rawValue]
                + tool.keywords.map { $0.lowercased() }).joined(separator: " ")
            var score = 0
            var matchedAll = true
            for word in words {
                if name.hasPrefix(word) { score += 100 }
                else if nameWords.contains(where: { $0.hasPrefix(word) }) { score += 60 }
                else if name.contains(word) { score += 30 }
                else if haystack.split(separator: " ").contains(where: { $0.hasPrefix(word) }) { score += 15 }
                else if haystack.contains(word) { score += 5 }
                else { matchedAll = false; break }
            }
            // A multi-word query that spells out a keyword phrase ("word to pdf") beats scattered word matches.
            if matchedAll, words.count > 1 {
                let keywords = tool.keywords.map { $0.lowercased() }
                if keywords.contains(phrase) { score += 200 }
                else if keywords.contains(where: { $0.hasPrefix(phrase) }) { score += 120 }
            }
            if matchedAll { scored.append((tool, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.map(\.0)
    }

    /// Shown under the empty home search field.
    static let suggestedIDs = ["video.record-screen", "video.compress", "pdf.merge", "ai.transcribe",
                               "image.remove-background", "video.download", "ai.extract-text", "files.batch-rename"]
    static var suggestions: [Tool] { suggestedIDs.compactMap(tool) }
}
