import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rules

enum RenameCase: String, CaseIterable, Identifiable {
    case unchanged, lower, upper, title, sentence
    var id: Self { self }
    var label: String {
        switch self {
        case .unchanged: "Unchanged"
        case .lower: "lowercase"
        case .upper: "UPPERCASE"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        }
    }
}

enum RenamePosition: String, CaseIterable, Identifiable {
    case prefix, suffix, replace
    var id: Self { self }
    var label: String {
        switch self {
        case .prefix: "Before name"
        case .suffix: "After name"
        case .replace: "Replace name"
        }
    }
}

enum RenameDateSource: String, CaseIterable, Identifiable {
    case today, created, modified
    var id: Self { self }
    var label: String {
        switch self {
        case .today: "Today"
        case .created: "Date created"
        case .modified: "Date modified"
        }
    }
}

enum RenameExtensionMode: String, CaseIterable, Identifiable {
    case keep, lower, upper, change, remove
    var id: Self { self }
    var label: String {
        switch self {
        case .keep: "Keep"
        case .lower: "lowercase"
        case .upper: "UPPERCASE"
        case .change: "Change to…"
        case .remove: "Remove"
        }
    }
}

struct RenameRules: Equatable {
    var findEnabled = true
    var find = ""
    var replace = ""
    var useRegex = false
    var ignoreCase = true

    var caseStyle = RenameCase.unchanged

    var prefix = ""
    var suffix = ""

    var dateEnabled = false
    var dateSource = RenameDateSource.modified
    var dateFormat = "yyyy-MM-dd"
    var datePosition = RenamePosition.prefix

    var numberEnabled = false
    var numberStart = 1
    var numberStep = 1
    var numberPadding = 2
    var numberPosition = RenamePosition.suffix
    var separator = " "

    var extensionMode = RenameExtensionMode.keep
    var newExtension = ""

    /// Validates the regular expression, if one is used.
    var regexError: String? {
        guard findEnabled, useRegex, !find.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: find)
            return nil
        } catch {
            return "Invalid regular expression."
        }
    }

    /// Applies every rule to a file name. `index` is the file's position in the list (0-based).
    func newName(for url: URL, index: Int, now: Date = Date()) -> String {
        let original = url.lastPathComponent
        var ext = url.pathExtension
        var base = ext.isEmpty ? original : String(original.dropLast(ext.count + 1))

        if findEnabled, !find.isEmpty {
            if useRegex {
                if let regex = try? NSRegularExpression(pattern: find, options: ignoreCase ? [.caseInsensitive] : []) {
                    base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replace)
                }
            } else {
                base = base.replacingOccurrences(of: find, with: replace, options: ignoreCase ? [.caseInsensitive] : [])
            }
        }

        switch caseStyle {
        case .unchanged: break
        case .lower: base = base.lowercased()
        case .upper: base = base.uppercased()
        case .title: base = base.capitalized
        case .sentence: base = base.prefix(1).uppercased() + base.dropFirst().lowercased()
        }

        base = prefix + base + suffix

        if dateEnabled {
            let date: Date
            switch dateSource {
            case .today: date = now
            case .created: date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            case .modified: date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = dateFormat.isEmpty ? "yyyy-MM-dd" : dateFormat
            let text = formatter.string(from: date).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            base = insert(text, into: base, at: datePosition)
        }

        if numberEnabled {
            let number = numberStart + index * numberStep
            let digits = String(abs(number))
            let padded = String(repeating: "0", count: max(numberPadding - digits.count, 0)) + digits
            base = insert((number < 0 ? "-" : "") + padded, into: base, at: numberPosition)
        }

        switch extensionMode {
        case .keep: break
        case .lower: ext = ext.lowercased()
        case .upper: ext = ext.uppercased()
        case .change: ext = newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        case .remove: ext = ""
        }

        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func insert(_ text: String, into base: String, at position: RenamePosition) -> String {
        switch position {
        case .prefix: base.isEmpty ? text : text + separator + base
        case .suffix: base.isEmpty ? text : base + separator + text
        case .replace: text
        }
    }
}

// MARK: - Preview

struct RenamePreviewRow: Identifiable {
    enum Status { case ok, unchanged, warning, error }
    let id: URL
    let oldName: String
    let newName: String
    let status: Status
    let message: String?
}

enum RenamePlanner {
    /// Computes new names and flags problems. In copy mode every file lands in one folder,
    /// so duplicates are checked across the whole list; in place, per containing folder.
    static func preview(files: [URL], rules: RenameRules, inPlace: Bool) -> [RenamePreviewRow] {
        let now = Date()
        var names = files.enumerated().map { index, url in rules.newName(for: url, index: index, now: now) }
        if !inPlace {
            // Results are written through the job context, which replaces characters Finder dislikes.
            names = names.map { name in
                let ext = (name as NSString).pathExtension
                let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                let clean = OutputManager.sanitize(base)
                return ext.isEmpty ? clean : "\(clean).\(ext)"
            }
        }

        var counts: [String: Int] = [:]
        for (index, url) in files.enumerated() {
            counts[key(names[index], folder: inPlace ? url.deletingLastPathComponent() : nil), default: 0] += 1
        }
        let sources = Set(files.map { $0.standardizedFileURL.path.lowercased() })

        return files.enumerated().map { index, url in
            let name = names[index]
            let old = url.lastPathComponent
            var status = RenamePreviewRow.Status.ok
            var message: String?
            let base = (name as NSString).deletingPathExtension

            if name.trimmingCharacters(in: .whitespaces).isEmpty || base.trimmingCharacters(in: .whitespaces).isEmpty {
                status = .error; message = "Name is empty"
            } else if name.contains("/") || name.contains(":") {
                status = .error; message = "Names can't contain / or :"
            } else if name.utf8.count > 255 {
                status = .error; message = "Name is too long"
            } else if (counts[key(name, folder: inPlace ? url.deletingLastPathComponent() : nil)] ?? 0) > 1 {
                status = .error; message = "Duplicate name"
            } else if inPlace, name != old {
                let target = url.deletingLastPathComponent().appendingPathComponent(name)
                let caseOnlyChange = name.lowercased() == old.lowercased()
                if !caseOnlyChange, FileManager.default.fileExists(atPath: target.path),
                   !sources.contains(target.standardizedFileURL.path.lowercased()) {
                    status = .error; message = "A file with this name already exists"
                }
            }
            if status == .ok {
                if name == old {
                    status = .unchanged; message = inPlace ? "Unchanged" : nil
                } else if name.hasPrefix(".") {
                    status = .warning; message = "Will be hidden in Finder"
                }
            }
            return RenamePreviewRow(id: url, oldName: old, newName: name, status: status, message: message)
        }
    }

    private static func key(_ name: String, folder: URL?) -> String {
        // APFS is case-insensitive by default, so "A.txt" and "a.txt" collide.
        (folder?.standardizedFileURL.path ?? "") + "/" + name.lowercased()
    }
}

// MARK: - In-place renaming

struct RenameMove: Hashable, Sendable {
    let from: URL
    let to: URL
}

enum RenameExecutor {
    /// Renames files in two phases (through temporary names) so swaps and chains like
    /// a→b, b→c work. Rolls back everything if any step fails.
    static func perform(_ moves: [RenameMove]) throws {
        let fm = FileManager.default
        let pending = moves.filter { $0.from != $0.to }
        var staged: [(temp: URL, move: RenameMove)] = []
        var finished: [RenameMove] = []
        do {
            for move in pending {
                let temp = move.from.deletingLastPathComponent().appendingPathComponent(".toolbox-rename-\(UUID().uuidString)")
                try fm.moveItem(at: move.from, to: temp)
                staged.append((temp, move))
            }
            for item in staged {
                if fm.fileExists(atPath: item.move.to.path) {
                    throw ToolError.failed("“\(item.move.to.lastPathComponent)” already exists.")
                }
                try fm.moveItem(at: item.temp, to: item.move.to)
                finished.append(item.move)
            }
        } catch {
            // Undo in reverse: finished files go back to their temp names first, then everything to the original names.
            for move in finished.reversed() {
                if let temp = staged.first(where: { $0.move == move })?.temp { try? fm.moveItem(at: move.to, to: temp) }
            }
            for item in staged.reversed() { try? fm.moveItem(at: item.temp, to: item.move.from) }
            throw error
        }
    }
}

/// Remembers the last in-place rename so it can be undone, even after navigating away.
@MainActor
@Observable
final class RenameHistory {
    static let shared = RenameHistory()
    var lastMoves: [RenameMove] = []
}

/// Carries results out of the background job.
final class RenameResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RenameMove] = []
    var moves: [RenameMove] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - View

struct BatchRenameView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var rules = RenameRules()
    @State private var inPlace = false
    @State private var resultBox = RenameResultBox()
    @State private var undoError: String?
    @State private var history = RenameHistory.shared
    /// Set when the inputs are updated to the renamed files, so the success state stays visible.
    @State private var keepResultOnNextInputChange = false

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var rows: [RenamePreviewRow] {
        RenamePlanner.preview(files: runner.inputs, rules: rules, inPlace: inPlace)
    }

    var body: some View {
        let rows = rows
        let errors = rows.filter { $0.status == .error }.count
        let changes = rows.filter { $0.status == .ok || $0.status == .warning }.count
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: [.data], reorderable: true, noun: "files")
                .disabled(runner.isRunning)
            if !runner.inputs.isEmpty {
                HStack {
                    Text("Numbering follows the list order. Drag to reorder, or").foregroundStyle(.secondary)
                    Menu("Sort") {
                        Button("By Name") {
                            runner.inputs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        }
                        Button("By Date Modified") {
                            runner.inputs.sort { modified($0) < modified($1) }
                        }
                        Button("By Date Created") {
                            runner.inputs.sort { created($0) < created($1) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .font(.callout)
            }

            rulesSection.disabled(runner.isRunning)

            ToolSection("Result") {
                Picker("Mode", selection: $inPlace) {
                    Text("Save renamed copies (originals untouched)").tag(false)
                    Text("Rename the original files").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(runner.isRunning)
                if inPlace {
                    Label("Files are renamed where they are. You can undo the last rename here.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !history.lastMoves.isEmpty {
                    HStack {
                        Text("Renamed \(history.lastMoves.count) file\(history.lastMoves.count == 1 ? "" : "s") in place.")
                            .foregroundStyle(.secondary)
                        Button("Undo Rename", action: undo)
                            .disabled(runner.isRunning)
                    }
                }
                if let undoError {
                    Label(undoError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            if !rows.isEmpty {
                previewSection(rows: rows, errors: errors, changes: changes)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: inPlace ? "Rename Files" : "Save Copies",
                   canRun: !rows.isEmpty && errors == 0 && changes > 0 && rules.regexError == nil,
                   hint: hint(rows: rows, errors: errors, changes: changes),
                   idleMessage: inPlace ? "Files are renamed where they are. You can undo the last rename."
                                        : "Originals stay untouched. Renamed copies go to a new folder.",
                   action: start)
        }
        .onChange(of: runner.phase) {
            guard runner.phase == .succeeded, inPlace else { return }
            let moves = resultBox.moves
            guard !moves.isEmpty else { return }
            history.lastMoves = moves
            let mapping = Dictionary(uniqueKeysWithValues: moves.map { ($0.from, $0.to) })
            keepResultOnNextInputChange = true
            runner.inputs = runner.inputs.map { mapping[$0] ?? $0 }
            resultBox.moves = []
        }
        .onChange(of: runner.inputs) {
            if keepResultOnNextInputChange { keepResultOnNextInputChange = false } else if !runner.isRunning { runner.reset() }
        }
        .onChange(of: rules) { if !runner.isRunning { runner.reset() } }
        .onChange(of: inPlace) { if !runner.isRunning { runner.reset() } }
    }

    // MARK: Rules UI

    private var rulesSection: some View {
        ToolSection("Rules") {
            Toggle("Find and replace", isOn: $rules.findEnabled)
            if rules.findEnabled {
                HStack {
                    TextField("Find", text: $rules.find).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField(rules.useRegex ? "Replace ($1 for groups)" : "Replace with", text: $rules.replace)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.leading, 20)
                HStack(spacing: 16) {
                    Toggle("Regular expression", isOn: $rules.useRegex)
                    Toggle("Ignore case", isOn: $rules.ignoreCase)
                    if let error = rules.regexError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 20)
            }

            Divider()
            HStack {
                TextField("Add prefix", text: $rules.prefix).textFieldStyle(.roundedBorder)
                TextField("Add suffix", text: $rules.suffix).textFieldStyle(.roundedBorder)
            }
            Picker("Change case", selection: $rules.caseStyle) {
                ForEach(RenameCase.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()

            Divider()
            Toggle("Add numbers", isOn: $rules.numberEnabled)
            if rules.numberEnabled {
                HStack(spacing: 14) {
                    LabeledContent("Start") { RenameNumberField(value: $rules.numberStart) }
                    LabeledContent("Step") { RenameNumberField(value: $rules.numberStep) }
                    LabeledContent("Digits") {
                        Picker("Digits", selection: $rules.numberPadding) {
                            ForEach(1...6, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Picker("Position", selection: $rules.numberPosition) {
                        ForEach(RenamePosition.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.leading, 20)
            }

            Toggle("Add date", isOn: $rules.dateEnabled)
            if rules.dateEnabled {
                HStack(spacing: 14) {
                    Picker("Date", selection: $rules.dateSource) {
                        ForEach(RenameDateSource.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("Format", text: $rules.dateFormat)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .help("Date format, e.g. yyyy-MM-dd or yyyyMMdd_HHmm")
                    Picker("Position", selection: $rules.datePosition) {
                        ForEach(RenamePosition.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(.leading, 20)
            }
            if rules.numberEnabled || rules.dateEnabled {
                LabeledContent("Separator") {
                    TextField("Separator", text: $rules.separator)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }

            Divider()
            HStack {
                Picker("Extension", selection: $rules.extensionMode) {
                    ForEach(RenameExtensionMode.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if rules.extensionMode == .change {
                    TextField("e.g. jpg", text: $rules.newExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }
        }
    }

    private func previewSection(rows: [RenamePreviewRow], errors: Int, changes: Int) -> some View {
        ToolSection("Preview", footnote: errors > 0 ? "Fix the highlighted names to continue." : nil) {
            HStack(spacing: 14) {
                Label("\(changes) to rename", systemImage: "pencil").foregroundStyle(.secondary)
                if errors > 0 {
                    Label("\(errors) problem\(errors == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            Table(rows) {
                TableColumn("Original") { row in
                    Text(row.oldName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                TableColumn("New Name") { row in
                    Text(row.newName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.status == .error ? Color.orange : .primary)
                        .fontWeight(row.status == .ok || row.status == .warning ? .medium : .regular)
                }
                TableColumn("") { row in
                    statusView(row)
                }
                .width(min: 120, ideal: 170)
            }
            .frame(height: min(CGFloat(rows.count) * 24 + 32, 320))
        }
    }

    @ViewBuilder
    private func statusView(_ row: RenamePreviewRow) -> some View {
        switch row.status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .unchanged: Text(row.message ?? "").foregroundStyle(.tertiary)
        case .warning: Label(row.message ?? "", systemImage: "exclamationmark.circle").foregroundStyle(.yellow)
        case .error: Label(row.message ?? "", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func hint(rows: [RenamePreviewRow], errors: Int, changes: Int) -> String {
        if rows.isEmpty { return "Add files to get started." }
        if rules.regexError != nil { return "Fix the regular expression." }
        if errors > 0 { return "Some new names have problems." }
        if changes == 0 { return "Set a rule to change the names." }
        return ""
    }

    // MARK: Actions

    private func start() {
        let rows = rows
        undoError = nil
        if inPlace {
            let moves = rows.filter { $0.newName != $0.oldName }
                .map { RenameMove(from: $0.id, to: $0.id.deletingLastPathComponent().appendingPathComponent($0.newName)) }
            let box = resultBox
            box.moves = []
            runner.start(title: tool.name, publishesFiles: false) { context in
                context.setStatus("Renaming \(moves.count) files")
                try RenameExecutor.perform(moves)
                box.moves = moves
                context.setProgress(1)
            }
        } else {
            let items = rows.map { (source: $0.id, name: $0.newName) }
            runner.start(title: tool.name) { context in
                for (index, item) in items.enumerated() {
                    try Task.checkCancellation()
                    context.setStatus("Copying \(index + 1) of \(items.count): \(item.name)")
                    let ext = (item.name as NSString).pathExtension
                    let base = ext.isEmpty ? item.name : String(item.name.dropLast(ext.count + 1))
                    try FileManager.default.copyItem(at: item.source, to: context.output(named: base, extension: ext))
                    context.setProgress(Double(index + 1) / Double(items.count))
                }
            }
        }
    }

    private func undo() {
        let reversed = history.lastMoves.map { RenameMove(from: $0.to, to: $0.from) }
        do {
            for move in reversed where !FileManager.default.fileExists(atPath: move.from.path) {
                throw ToolError.failed("“\(move.from.lastPathComponent)” was moved or deleted, so the rename can't be undone.")
            }
            try RenameExecutor.perform(reversed)
            let mapping = Dictionary(uniqueKeysWithValues: reversed.map { ($0.from, $0.to) })
            history.lastMoves = []
            runner.inputs = runner.inputs.map { mapping[$0] ?? $0 }
            runner.reset()
            undoError = nil
        } catch {
            undoError = error.localizedDescription
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

private struct RenameNumberField: View {
    @Binding var value: Int

    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
    }
}
