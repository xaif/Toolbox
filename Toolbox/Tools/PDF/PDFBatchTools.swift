import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Merge

struct PDFMergeView: View {
    let tool: Tool
    @State private var bookmarks = true

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Merge", noun: "PDFs") {
            Toggle("Add a bookmark for each file", isOn: $bookmarks)
            Text("Drag files in the list to change their order. Existing bookmarks are kept.")
                .font(.callout).foregroundStyle(.secondary)
        } all: { [bookmarks] inputs, context in
            context.setStatus("Merging \(inputs.count) PDFs")
            let merged = try PDFOps.merge(inputs, bookmarks: bookmarks) { context.setProgress($0 * 0.9) }
            context.setStatus("Saving")
            try PDFOps.write(merged, to: context.output(named: "Merged", extension: "pdf"))
        }
    }
}

// MARK: - Compress

/// Before/after sizes reported back from the background job.
@MainActor
@Observable
final class PDFCompressionReport {
    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let before: Int64
        let after: Int64
        let keptOriginal: Bool
    }

    var entries: [Entry] = []
}

struct PDFCompressView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var report = PDFCompressionReport()
    @State private var level = PDFCompressionLevel.recommended
    @State private var dpi = 150.0
    @State private var quality = 0.6

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            ToolSection("Options") {
                Picker("Compression", selection: $level) {
                    Text("Light").tag(PDFCompressionLevel.light)
                    Text("Recommended").tag(PDFCompressionLevel.recommended)
                    Text("Maximum").tag(PDFCompressionLevel.maximum)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(levelDescription).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if level == .maximum {
                    Picker("Resolution", selection: $dpi) {
                        Text("96 DPI (screen)").tag(96.0)
                        Text("150 DPI (balanced)").tag(150.0)
                        Text("200 DPI (print)").tag(200.0)
                    }
                    .fixedSize()
                    LabeledContent("Image quality") {
                        HStack {
                            Slider(value: $quality, in: 0.3...0.9, step: 0.05).frame(width: 200)
                            Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            .disabled(runner.isRunning)
            if !report.entries.isEmpty, runner.phase == .succeeded {
                ToolSection("Savings") {
                    ForEach(report.entries) { entry in
                        HStack {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if entry.keptOriginal {
                                Text("Already optimized — original kept").foregroundStyle(.secondary)
                            } else {
                                Text("\(format(entry.before)) → \(format(entry.after))").monospacedDigit()
                                Text("−\(percent(entry))%").monospacedDigit().foregroundStyle(.green).frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Compress", canRun: !runner.inputs.isEmpty,
                   hint: "Add PDFs to compress.", action: run)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private var levelDescription: String {
        switch level {
        case .light: "Recompresses images as JPEG. Text and vector graphics are untouched."
        case .recommended: "Recompresses and downsamples images for on-screen reading. Best for most documents."
        case .maximum: "Turns each page into a single image. Smallest files, ideal for scans — but text is no longer selectable."
        }
    }

    private func run() {
        let inputs = runner.inputs
        let level = level, dpi = CGFloat(dpi), quality = CGFloat(quality)
        let report = report
        report.entries = []
        runner.start(title: tool.name) { context in
            try await context.forEach(inputs, verb: "Compressing") { input, progress in
                let document = try PDFOps.open(input)
                let output = context.output(for: input, suffix: "compressed", extension: "pdf")
                try PDFOps.compress(document, level: level, dpi: dpi, quality: quality, to: output, progress: progress)
                let before = PDFOps.fileSize(input)
                var after = PDFOps.fileSize(output)
                let keptOriginal = after >= before
                if keptOriginal {
                    // Never hand back a bigger file: keep the original bytes instead.
                    try FileManager.default.removeItem(at: output)
                    try FileManager.default.copyItem(at: input, to: output)
                    after = before
                }
                let entry = PDFCompressionReport.Entry(name: input.lastPathComponent, before: before, after: after, keptOriginal: keptOriginal)
                await MainActor.run { report.entries.append(entry) }
            }
        }
    }

    private func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func percent(_ entry: PDFCompressionReport.Entry) -> Int {
        guard entry.before > 0 else { return 0 }
        return Int((Double(entry.before - entry.after) / Double(entry.before) * 100).rounded())
    }
}

// MARK: - Add password

struct PDFAddPasswordView: View {
    let tool: Tool
    @State private var password = ""
    @State private var confirmation = ""
    @State private var restrict = false
    @State private var ownerPassword = ""
    @State private var allowPrinting = true
    @State private var allowCopying = false
    @State private var allowEditing = false

    private var passwordsMatch: Bool { !password.isEmpty && password == confirmation }

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Protect", verb: "Protecting", noun: "PDFs",
                      canRun: passwordsMatch) {
            LabeledContent("Password") {
                SecureField("Required to open the PDF", text: $password)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
            LabeledContent("Confirm") {
                HStack {
                    SecureField("Type it again", text: $confirmation)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if !confirmation.isEmpty {
                        Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(passwordsMatch ? .green : .red)
                            .help(passwordsMatch ? "Passwords match" : "Passwords don't match")
                    }
                }
            }
            Toggle("Restrict what people can do after opening", isOn: $restrict)
            if restrict {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Allow printing", isOn: $allowPrinting)
                    Toggle("Allow copying text and images", isOn: $allowCopying)
                    Toggle("Allow editing and annotating", isOn: $allowEditing)
                    LabeledContent("Permissions password") {
                        SecureField("Optional", text: $ownerPassword)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    Text("Needed to change these permissions later. Leave empty to lock them permanently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
            Text("Protected with AES encryption. Links and bookmarks keep working.")
                .font(.caption).foregroundStyle(.secondary)
        } each: { [password, restrict, ownerPassword, allowPrinting, allowCopying, allowEditing] input, context, progress in
            let document = try PDFOps.open(input)
            var protection = PDFProtection(userPassword: password)
            if restrict {
                protection.ownerPassword = ownerPassword
                protection.allowPrinting = allowPrinting
                protection.allowCopying = allowCopying
                protection.allowEditing = allowEditing
            }
            try PDFOps.encrypt(document, protection: protection,
                               to: context.output(for: input, suffix: "protected", extension: "pdf"), progress: progress)
        }
    }
}

// MARK: - Remove password

struct PDFRemovePasswordView: View {
    let tool: Tool

    enum LockState {
        case locked, restricted, notProtected, unreadable
    }

    @State private var runner: JobRunner
    @State private var samePassword = true
    @State private var sharedPassword = ""
    @State private var passwords: [URL: String] = [:]
    /// Cached per file; opening PDFs on every redraw would be slow.
    @State private var states: [URL: LockState] = [:]

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var lockedFiles: [URL] { runner.inputs.filter { states[$0] == .locked } }
    private var problemFiles: [URL] { runner.inputs.filter { states[$0] == .notProtected || states[$0] == .unreadable } }

    private var canRun: Bool {
        guard !runner.inputs.isEmpty, problemFiles.isEmpty else { return false }
        if samePassword { return lockedFiles.isEmpty || !sharedPassword.isEmpty }
        return lockedFiles.allSatisfy { !(passwords[$0] ?? "").isEmpty }
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            if !runner.inputs.isEmpty {
                ToolSection("Passwords", footnote: "Toolbox can only unlock PDFs you know the password for.") {
                    if lockedFiles.count > 1 {
                        Toggle("Use the same password for all files", isOn: $samePassword)
                    }
                    if samePassword || lockedFiles.count <= 1 {
                        if !lockedFiles.isEmpty {
                            LabeledContent("Password") {
                                SecureField("Password", text: $sharedPassword)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            }
                        }
                    }
                    ForEach(runner.inputs, id: \.self) { url in
                        HStack(spacing: 8) {
                            statusIcon(states[url] ?? .unreadable)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            switch states[url] ?? .unreadable {
                            case .locked:
                                if !samePassword && lockedFiles.count > 1 {
                                    SecureField("Password", text: binding(for: url))
                                        .textFieldStyle(.roundedBorder).frame(width: 200)
                                } else {
                                    Text("Needs password").foregroundStyle(.secondary)
                                }
                            case .restricted: Text("Permissions only — no password needed").foregroundStyle(.secondary)
                            case .notProtected: Text("Not password-protected — remove it").foregroundStyle(.orange)
                            case .unreadable: Text("Can't be opened").foregroundStyle(.red)
                            }
                        }
                    }
                }
                .disabled(runner.isRunning)
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Remove Password", canRun: canRun,
                   hint: runner.inputs.isEmpty ? "Add protected PDFs." : (problemFiles.isEmpty ? "Enter the password." : "Remove files that aren't protected."),
                   action: run)
        }
        .onChange(of: runner.inputs, initial: true) {
            states = Dictionary(uniqueKeysWithValues: runner.inputs.map { ($0, states[$0] ?? lockState($0)) })
            if !runner.isRunning { runner.reset() }
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: LockState) -> some View {
        switch state {
        case .locked: Image(systemName: "lock.fill").foregroundStyle(.secondary)
        case .restricted: Image(systemName: "lock.badge.clock").foregroundStyle(.secondary)
        case .notProtected: Image(systemName: "lock.open").foregroundStyle(.orange)
        case .unreadable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func binding(for url: URL) -> Binding<String> {
        Binding(get: { passwords[url] ?? "" }, set: { passwords[url] = $0 })
    }

    private func lockState(_ url: URL) -> LockState {
        guard let document = PDFDocument(url: url) else { return .unreadable }
        if document.isLocked { return .locked }
        return document.isEncrypted ? .restricted : .notProtected
    }

    private func run() {
        let inputs = runner.inputs
        let lookup = inputs.reduce(into: [URL: String]()) { result, url in
            result[url] = samePassword || lockedFiles.count <= 1 ? sharedPassword : (passwords[url] ?? "")
        }
        runner.start(title: tool.name) { context in
            try await context.forEach(inputs, verb: "Unlocking") { input, progress in
                let unlocked = try PDFOps.removePassword(from: input, password: lookup[input] ?? "")
                progress(0.5)
                let output = context.output(for: input, suffix: "unlocked", extension: "pdf")
                try PDFOps.write(unlocked, to: output)
                guard let check = PDFDocument(url: output), !check.isEncrypted else {
                    throw ToolError.failed("Couldn't remove the password.")
                }
                progress(1)
            }
        }
    }
}

// MARK: - Images to PDF

struct PDFImagesToPDFView: View {
    let tool: Tool

    enum ImageQuality: String, CaseIterable, Identifiable {
        case original, high, medium, small
        var id: Self { self }
        var label: String {
            switch self {
            case .original: "Original"
            case .high: "High"
            case .medium: "Medium"
            case .small: "Small file"
            }
        }
        var jpegQuality: CGFloat? {
            switch self {
            case .original: nil
            case .high: 0.85
            case .medium: 0.7
            case .small: 0.5
            }
        }
        var maxPixelSize: Int? {
            switch self {
            case .original, .high: nil
            case .medium: 2400
            case .small: 1600
            }
        }
    }

    @State private var pageSize = PDFImageLayout.PageSize.a4
    @State private var orientation = PDFImageLayout.Orientation.auto
    @State private var margin: CGFloat = 0
    @State private var imageQuality = ImageQuality.high

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, reorderable: true, minimumFiles: 1,
                      actionTitle: "Create PDF", noun: "images") {
            Picker("Page size", selection: $pageSize) {
                ForEach(PDFImageLayout.PageSize.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            if pageSize != .fit {
                Picker("Orientation", selection: $orientation) {
                    ForEach(PDFImageLayout.Orientation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Picker("Margin", selection: $margin) {
                Text("None").tag(CGFloat(0))
                Text("Small").tag(CGFloat(18))
                Text("Large").tag(CGFloat(54))
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Image quality", selection: $imageQuality) {
                ForEach(ImageQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("Drag images in the list to set the page order. Each image gets its own page.")
                .font(.callout).foregroundStyle(.secondary)
        } all: { [pageSize, orientation, margin, imageQuality] inputs, context in
            let layout = PDFImageLayout(pageSize: pageSize, orientation: orientation, margin: margin,
                                        maxPixelSize: imageQuality.maxPixelSize, jpegQuality: imageQuality.jpegQuality)
            let name = inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent : "Images"
            context.setStatus("Creating PDF from \(inputs.count) image\(inputs.count == 1 ? "" : "s")")
            try PDFOps.imagesToPDF(inputs, layout: layout, to: context.output(named: name, extension: "pdf")) {
                context.setProgress($0)
            }
        }
    }
}

// MARK: - PDF to images

struct PDFToImagesView: View {
    let tool: Tool
    @State private var format = PDFImageFormat.png
    @State private var quality = 0.85
    @State private var dpi = 150.0
    @State private var pages = ""

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Export", verb: "Exporting", noun: "PDFs") {
            Picker("Format", selection: $format) {
                Text("PNG").tag(PDFImageFormat.png)
                Text("JPEG").tag(PDFImageFormat.jpeg)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if format == .jpeg {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $quality, in: 0.4...1, step: 0.05).frame(width: 200)
                        Text("\(Int(quality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Picker("Resolution", selection: $dpi) {
                Text("72 DPI").tag(72.0)
                Text("150 DPI").tag(150.0)
                Text("300 DPI").tag(300.0)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            LabeledContent("Pages") {
                TextField("All pages, or e.g. 1-3, 5", text: $pages)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
            Text("Each PDF's pages are saved in their own folder.").font(.callout).foregroundStyle(.secondary)
        } each: { [format, quality, dpi, pages] input, context, progress in
            let document = try PDFOps.open(input)
            let indices = pages.trimmingCharacters(in: .whitespaces).isEmpty
                ? PDFOps.allPages(document)
                : try PDFOps.indices(pages, pageCount: document.pageCount)
            let folder = try context.outputFolder(named: input.deletingPathExtension().lastPathComponent)
            try PDFOps.exportImages(document, pages: indices, to: folder, format: format,
                                    quality: CGFloat(quality), dpi: CGFloat(dpi), progress: progress)
        }
    }
}
