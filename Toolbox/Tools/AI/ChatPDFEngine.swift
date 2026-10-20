import Foundation
import FoundationModels
import NaturalLanguage

/// A piece of one page, the unit Chat with PDF retrieves and cites.
struct ChatChunk: Hashable, Sendable {
    var id: Int
    var page: Int
    var text: String
}

/// An answered question, kept as conversation memory.
struct ChatTurn: Hashable, Sendable {
    var question: String
    var answer: String
}

/// Ranks chunks for a question: BM25 keyword scores, blended with sentence-embedding similarity when
/// NaturalLanguage has a model for the document's language (it catches answers phrased differently).
final class ChatIndex: @unchecked Sendable {
    let chunks: [ChatChunk]
    private let termCounts: [[String: Int]]
    private let lengths: [Double]
    private let averageLength: Double
    private let documentFrequency: [String: Int]
    private let embedding: NLEmbedding?
    private let vectors: [[Double]?]

    /// Splits each page into chunks of at most `limit` characters. Chunks never span pages, so each
    /// cites exactly one.
    static func chunks(_ document: AIDocumentText, limit: Int = 900) -> [ChatChunk] {
        var chunks: [ChatChunk] = []
        for page in document.pages where !page.text.isEmpty {
            for piece in AISummarizer.split(page.text, limit: limit) {
                chunks.append(ChatChunk(id: chunks.count, page: page.number, text: piece))
            }
        }
        return chunks
    }

    init(chunks: [ChatChunk], semantic: Bool = true) {
        self.chunks = chunks
        termCounts = chunks.map { chunk in Self.terms(chunk.text).reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        lengths = termCounts.map { Double($0.values.reduce(0, +)) }
        averageLength = max(lengths.reduce(0, +) / Double(max(chunks.count, 1)), 1)
        documentFrequency = termCounts.reduce(into: [:]) { result, counts in
            for term in counts.keys { result[term, default: 0] += 1 }
        }
        let sample = chunks.prefix(20).map(\.text).joined(separator: " ")
        if semantic, chunks.count <= 2000, let language = NLLanguageRecognizer.dominantLanguage(for: sample),
           let embedding = NLEmbedding.sentenceEmbedding(for: language) {
            self.embedding = embedding
            vectors = chunks.map { embedding.vector(for: String($0.text.prefix(2000))) }
        } else {
            embedding = nil
            vectors = []
        }
    }

    /// Every chunk with its relevance to `query`, best first. Scores are 0...1.
    func rank(_ query: String) -> [(chunk: ChatChunk, score: Double)] {
        let queryTerms = Set(Self.terms(query))
        let count = Double(chunks.count)
        var keyword = [Double](repeating: 0, count: chunks.count)
        for (index, counts) in termCounts.enumerated() {
            var score = 0.0
            for term in queryTerms {
                guard let frequency = counts[term].map(Double.init), let df = documentFrequency[term].map(Double.init) else { continue }
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * lengths[index] / averageLength))
            }
            keyword[index] = score
        }
        let best = keyword.max() ?? 0
        let queryVector = embedding?.vector(for: query)
        let scored = chunks.enumerated().map { index, chunk -> (chunk: ChatChunk, score: Double) in
            let lexical = best > 0 ? keyword[index] / best : 0
            guard let queryVector, let vector = vectors[index] else { return (chunk, lexical) }
            let semantic = max(Self.cosine(queryVector, vector), 0)
            return (chunk, best > 0 ? lexical * 0.75 + semantic * 0.25 : semantic * 0.5)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.chunk.id < $1.chunk.id }
    }

    /// The chunks to answer `question` with, in document order, within `budget` characters. Short
    /// documents go in whole; questions about the whole document get chunks spread across it.
    func excerpts(for question: String, history: [ChatTurn] = [], budget: Int) -> [ChatChunk] {
        let total = chunks.reduce(0) { $0 + $1.text.count }
        if total <= budget { return chunks }
        var query = question
        // Follow-ups like "why?" or "tell me more" lean on the previous question.
        if Self.terms(question).count < 3, let previous = history.last { query += " " + previous.question }
        var picked: [ChatChunk] = []
        var used = 0
        func add(_ chunk: ChatChunk) {
            guard used + chunk.text.count <= budget, !picked.contains(chunk) else { return }
            picked.append(chunk)
            used += chunk.text.count
        }
        let ranked = rank(query).filter { $0.score > 0.05 }
        if Self.isBroad(question) || ranked.isEmpty {
            let average = Double(chunks.reduce(0) { $0 + $1.text.count }) / Double(max(chunks.count, 1))
            let stride = max(Double(chunks.count) / max(Double(budget) / max(average, 1), 1), 1)
            var position = 0.0
            while Int(position) < chunks.count { add(chunks[Int(position)]); position += stride }
        } else {
            for item in ranked { add(item.chunk) }
        }
        return picked.sorted { $0.id < $1.id }
    }

    /// Questions about the document as a whole, which no keyword search answers well.
    static func isBroad(_ question: String) -> Bool {
        question.range(of: #"\b(summari[sz]e|summary|overview|tl;?dr|gist|outline|main (points?|ideas?|topics?)|key (points?|takeaways?|ideas?)|what('s| is) (this|it|the (document|pdf|file|paper)) about)\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Lowercased search terms without stop words, lightly stemmed so "invoices" matches "invoice".
    static func terms(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        let lowered = text.lowercased()
        tokenizer.string = lowered
        var terms: [String] = []
        tokenizer.enumerateTokens(in: lowered.startIndex..<lowered.endIndex) { range, _ in
            let word = String(lowered[range])
            if word.count > 1 || word.first?.isNumber == true, !stopWords.contains(word) { terms.append(stem(word)) }
            return true
        }
        return terms
    }

    private static func stem(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ing"), word.count > 5 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed"), word.count > 4 { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return String(word.dropLast()) }
        return word
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        return normA > 0 && normB > 0 ? dot / (normA.squareRoot() * normB.squareRoot()) : 0
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as", "is",
        "are", "was", "were", "be", "been", "being", "it", "its", "this", "that", "these", "those", "there", "here", "what",
        "which", "who", "whom", "whose", "when", "where", "why", "how", "do", "does", "did", "doing", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "have", "has", "had", "i", "me", "my", "we", "our", "you", "your",
        "he", "she", "him", "her", "they", "them", "their", "about", "into", "than", "then", "so", "not", "no", "any", "all",
        "some", "such", "also", "just", "only", "very", "more", "most", "other", "tell", "say", "says", "said", "document",
        "pdf", "file", "please", "give", "list", "explain", "describe", "mention", "mentioned",
    ]
}

/// Answers questions about a document with Apple's on-device model.
enum ChatAnswerer {
    /// Characters of excerpts per question. The context window also holds the instructions, the
    /// conversation and the answer, so excerpts get about 40% of it at ~4 characters per token.
    static var excerptBudget: Int {
        max(2400, Int(Double(SystemLanguageModel.default.contextSize) * 1.6))
    }

    static func instructions(for document: AIDocumentText) -> String {
        let example = "[\(document.citationPrefix) 3]"
        return """
        You answer questions about the document “\(document.name)” using only the excerpts you're given. \
        Each excerpt starts with where it comes from, like \(example). After each fact, cite where it came from \
        in square brackets, like \(example). If the excerpts don't contain the answer, say that you couldn't find it \
        in the document. Never make up facts, names or numbers. Answer in the language of the question, briefly and clearly.
        """
    }

    static func prompt(_ question: String, excerpts: [ChatChunk], history: [ChatTurn], prefix: String) -> String {
        var text = "Excerpts from the document:\n\n"
        for chunk in excerpts { text += "[\(prefix) \(chunk.page)]\n\(chunk.text)\n\n" }
        if !history.isEmpty {
            text += "Earlier in this conversation:\n"
            for turn in history { text += "Q: \(turn.question)\nA: \(turn.answer.prefix(600))\n" }
            text += "\n"
        }
        return text + "Question: \(question)"
    }

    /// Streams the answer through `onPartial` and returns it. When the excerpts overflow the context
    /// window, retries with fewer of them and less history.
    static func answer(_ question: String, document: AIDocumentText, index: ChatIndex, history: [ChatTurn],
                       onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        let availability = AISummarizer.availability
        guard availability == .available else { throw ToolError.unsupported(message(for: availability)) }
        var budget = excerptBudget
        var memory = Array(history.suffix(3))
        while true {
            let excerpts = index.excerpts(for: question, history: memory, budget: budget)
            let session = LanguageModelSession(instructions: instructions(for: document))
            let prompt = prompt(question, excerpts: excerpts, history: memory, prefix: document.citationPrefix)
            do {
                var final = ""
                for try await snapshot in session.streamResponse(to: prompt) {
                    final = AISummarizer.tidy(snapshot.content)
                    onPartial(final)
                }
                return final.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, budget > 1200 {
                    budget /= 2
                    memory = Array(memory.suffix(1))
                    onPartial("")
                    continue
                }
                throw friendly(error)
            }
        }
    }

    static func message(for availability: AISummarizer.Availability) -> String {
        switch availability {
        case .available: ""
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence, which Chat with PDF uses."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to chat with documents."
        case .modelNotReady: "Apple Intelligence is still getting ready (the model may be downloading). Try again in a little while."
        case .other(let reason): "The on-device model isn't available (\(reason))."
        }
    }

    static func friendly(_ error: LanguageModelSession.GenerationError) -> Error {
        switch error {
        case .exceededContextWindowSize: ToolError.failed("This question and conversation are too long for the on-device model. Clear the chat and try again.")
        case .guardrailViolation: ToolError.failed("The on-device model declined to answer this question.")
        case .unsupportedLanguageOrLocale: ToolError.failed("The on-device model doesn't support this language yet.")
        case .assetsUnavailable: ToolError.failed("The on-device model isn't ready yet. Try again shortly.")
        default: error
        }
    }
}

/// Page citations in answers, like "[p. 3]" or "[pp. 4, 7]".
enum ChatCitations {
    static let scheme = "toolbox-cite"

    private static let pattern = #"[\[(]((?:pp?\.|pages?|parts?|§)\s*\d+(?:\s*(?:,|and|&|–|-|—)\s*(?:pp?\.\s*)?\d+)*)[\])]"#

    /// The page numbers cited in `text`, in order of first mention.
    static func pages(in text: String) -> [Int] {
        var pages: [Int] = []
        for match in matches(in: text) {
            for page in numbers(in: match.label) where !pages.contains(page) { pages.append(page) }
        }
        return pages
    }

    /// `text` as Markdown with each cited page made a link (`toolbox-cite:3`).
    static func linkedMarkdown(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in matches(in: text) {
            result += text[cursor..<match.range.lowerBound]
            let pages = numbers(in: match.label)
            if pages.count == 1 {
                result += "[\\[\(match.label)\\]](\(scheme):\(pages[0]))"
            } else {
                let prefix = match.label.lowercased().hasPrefix("part") ? "part" : "p."
                result += pages.map { "[\\[\(prefix) \($0)\\]](\(scheme):\($0))" }.joined(separator: " ")
            }
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// The page a citation link opens.
    static func page(for url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }

    private static func matches(in text: String) -> [(range: Range<String.Index>, label: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text) else { return nil }
            return (range, String(text[label]))
        }
    }

    /// "3", "3, 5", "3–5" (a span) → page numbers.
    private static func numbers(in label: String) -> [Int] {
        var pages: [Int] = []
        let scanner = label.replacingOccurrences(of: "—", with: "–").replacingOccurrences(of: "-", with: "–")
        let parts = scanner.components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap { $0.components(separatedBy: " and ") }
        for part in parts {
            let values = part.components(separatedBy: "–").compactMap { Int($0.filter(\.isNumber)) }
            if values.count == 2, values[0] <= values[1], values[1] - values[0] < 20 {
                pages.append(contentsOf: values[0]...values[1])
            } else {
                pages.append(contentsOf: values)
            }
        }
        return pages
    }
}
