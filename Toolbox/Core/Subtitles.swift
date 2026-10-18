import Foundation

/// One timed caption.
struct SubtitleCue: Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// A word with its timing, used to build well-sized caption cues.
struct TimedWord: Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, vtt, txt

    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var label: String {
        switch self {
        case .srt: "SubRip (.srt)"
        case .vtt: "WebVTT (.vtt)"
        case .txt: "Plain text (.txt)"
        }
    }
}

enum Subtitles {
    // MARK: Building cues

    /// Groups words into readable cues: at most `maxCharacters` per cue (≈2 lines), `maxDuration`
    /// seconds long, breaking early at sentence ends and long pauses.
    static func cues(from words: [TimedWord], maxCharacters: Int = 80, maxDuration: Double = 6, pause: Double = 0.8) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { cues.append(SubtitleCue(start: first.start, end: max(last.end, first.start + 0.3), text: wrap(text))) }
            current.removeAll()
        }

        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = current.last, let first = current.first {
                let length = current.map(\.text).joined(separator: " ").count + 1 + trimmed.count
                if length > maxCharacters || word.end - first.start > maxDuration || word.start - last.end > pause {
                    flush()
                }
            }
            current.append(TimedWord(start: word.start, end: word.end, text: trimmed))
            if let end = trimmed.last, ".!?".contains(end), current.map(\.text).joined(separator: " ").count > maxCharacters / 3 {
                flush()
            }
        }
        flush()
        // Avoid overlaps.
        for index in cues.indices.dropLast() where cues[index].end > cues[index + 1].start {
            cues[index].end = cues[index + 1].start
        }
        return cues
    }

    /// Splits a cue's text into two balanced lines when it's long.
    static func wrap(_ text: String, lineLength: Int = 42) -> String {
        guard text.count > lineLength else { return text }
        let words = text.split(separator: " ")
        var best = text
        var bestDelta = Int.max
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            let delta = abs(first.count - second.count)
            if delta < bestDelta { bestDelta = delta; best = first + "\n" + second }
        }
        return best
    }

    // MARK: Writing

    static func serialize(_ cues: [SubtitleCue], as format: SubtitleFormat) -> String {
        switch format {
        case .srt:
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n" + cues.map { cue in
                "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
            }.joined(separator: "\n")
        case .txt:
            return cues.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ") + "\n"
        }
    }

    static func timestamp(_ seconds: Double, separator: String) -> String {
        let totalMillis = Int((max(seconds, 0) * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis / 60_000) % 60
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis)
    }

    // MARK: Reading

    /// Parses SRT or WebVTT text.
    static func parse(_ text: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        return numbers.count == 3 ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2] : numbers[0] * 60 + numbers[1]
    }

    static func load(from url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let cues = parse(text)
        guard !cues.isEmpty else { throw ToolError.failed("No subtitles found in “\(url.lastPathComponent)”.") }
        return cues
    }
}
