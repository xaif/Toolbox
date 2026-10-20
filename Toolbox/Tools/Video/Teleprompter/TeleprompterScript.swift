import Foundation
import SwiftUI

/// A script for the teleprompter. Lines starting with `#` begin a cue, a named section you can jump to.
/// Text in square brackets is a note to yourself: dimmed on screen and never counted as words.
struct TeleprompterScript: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var text: String
    var modified = Date()

    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled Script" : title
    }
}

/// One section of a script. Text before the first `#` line is an untitled opening cue.
struct TeleprompterCue: Identifiable, Equatable, Sendable {
    let id: Int
    var title: String?
    var text: String
    var words: Int

    /// A label for cue lists, e.g. "Intro" or "Opening".
    var label: String { title ?? (id == 0 ? "Opening" : "Cue \(id + 1)") }
}

enum TeleprompterParser {
    static func cues(in text: String) -> [TeleprompterCue] {
        var cues: [TeleprompterCue] = []
        var title: String?
        var lines: [Substring] = []
        var started = false

        func finish() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { lines = [] }
            // Skip an empty opening before the first heading.
            guard started || title != nil || !body.isEmpty else { return }
            cues.append(TeleprompterCue(id: cues.count, title: title, text: body, words: wordCount(body)))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                finish()
                started = true
                let name = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                title = name.isEmpty ? nil : name
            } else {
                lines.append(line)
            }
        }
        finish()
        return cues
    }

    /// Words you'll say: notes in square brackets don't count. Works for languages without spaces too.
    static func wordCount(_ text: String) -> Int {
        let spoken = withoutNotes(text)
        var count = 0
        spoken.enumerateSubstrings(in: spoken.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func withoutNotes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\[\]\n]*\]"#, with: " ", options: .regularExpression)
    }

    /// The text as shown in the prompter: notes dimmed and italic, `- ` and `* ` lines as bullets.
    static func styled(_ text: String, noteColor: Color) -> AttributedString {
        var result = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var line = String(line)
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                line = "•  " + trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
            result += styledLine(line, noteColor: noteColor)
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    private static func styledLine(_ line: String, noteColor: Color) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(line)
        // The innermost [ … ] pairs, like `withoutNotes`.
        while let close = rest.firstIndex(of: "]") {
            if let open = rest[..<close].lastIndex(of: "[") {
                result += AttributedString(String(rest[..<open]))
                var note = AttributedString(String(rest[open...close]))
                note.foregroundColor = noteColor
                note.inlinePresentationIntent = .emphasized
                result += note
            } else {
                result += AttributedString(String(rest[...close]))
            }
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}

// MARK: - Library

/// Your scripts, as JSON in Application Support/Toolbox/Teleprompter. Nothing leaves the Mac.
@MainActor
@Observable
final class TeleprompterLibrary {
    static let shared = TeleprompterLibrary(folder: BusinessStorage.defaultFolder("Teleprompter"))

    let folder: URL
    private(set) var scripts: [TeleprompterScript]
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "teleprompter.selectedScript") }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var fileURL: URL { folder.appendingPathComponent("scripts.json") }

    init(folder: URL) {
        self.folder = folder
        let stored = BusinessStorage.load([TeleprompterScript].self, from: folder.appendingPathComponent("scripts.json"))
        scripts = stored ?? [Self.welcome]
        let saved = UserDefaults.standard.string(forKey: "teleprompter.selectedScript").flatMap(UUID.init(uuidString:))
        selectedID = scripts.first { $0.id == saved }?.id ?? scripts.first?.id
        // Keep the welcome script, and its ID, from the first launch on.
        if stored == nil { saveNow() }
    }

    var selected: TeleprompterScript? {
        scripts.first { $0.id == selectedID }
    }

    func script(_ id: UUID?) -> TeleprompterScript? {
        scripts.first { $0.id == id }
    }

    @discardableResult
    func add(title: String = "", text: String = "") -> TeleprompterScript {
        let script = TeleprompterScript(title: title, text: text)
        scripts.insert(script, at: 0)
        selectedID = script.id
        scheduleSave()
        return script
    }

    func update(_ id: UUID, title: String? = nil, text: String? = nil) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        if let title { scripts[index].title = title }
        if let text { scripts[index].text = text }
        scripts[index].modified = Date()
        scheduleSave()
    }

    func duplicate(_ id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        var copy = scripts[index]
        copy.id = UUID()
        copy.title = copy.displayTitle + " copy"
        copy.modified = Date()
        scripts.insert(copy, at: index + 1)
        selectedID = copy.id
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts.remove(at: index)
        if selectedID == id { selectedID = scripts.indices.contains(index) ? scripts[index].id : scripts.last?.id }
        scheduleSave()
    }

    /// Writes right away instead of waiting for typing to pause.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? BusinessStorage.save(scripts, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    static let welcome = TeleprompterScript(title: "Welcome to Teleprompter", text: """
    # Welcome
    This is your teleprompter. It sits right under your camera, so you can read your script and still look people in the eye.

    # How it scrolls
    Start talking and the text moves with you. Stop, and it waits for you. [smile] Words in square brackets are notes to yourself. They're dimmed and never counted.

    # Cues
    Every line that starts with a hash sign begins a cue. Jump to any cue from the prompter, the keyboard or your phone, then go back to where you left off.

    # Short notes
    - Bullet points work too
    - Hover over the prompter to pause
    - Nobody sees it when you share your screen
    """)
}
