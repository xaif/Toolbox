import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Merge

struct PDFMergeView: View {
    let tool: Tool

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, reorderable: true, minimumFiles: 2,
                      actionTitle: "Merge", noun: "PDFs", job: { Settings().job(for: tool) }) {
            Settings()
            Text("Drag files in the list to change their order. Existing bookmarks are kept.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.merge.bookmarks") private var bookmarks = true

        var body: some View {
            OptionToggle("Add a bookmark for each file", isOn: $bookmarks)
        }

        func job(for tool: Tool) -> ToolJob? {
            .all { [bookmarks] inputs, context in
                context.setStatus("Merging \(inputs.count) PDFs")
                let merged = try PDFOps.merge(inputs, bookmarks: bookmarks) { context.setProgress($0 * 0.9) }
                context.setStatus("Saving")
                try PDFOps.write(merged, to: context.output(named: "Merged", extension: "pdf"))
            }
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

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            ToolSection("Options") { Settings() }
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

    private func run() {
        report.entries = []
        runner.start(Settings().job(report: report), title: tool.name, inputs: runner.inputs)
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.compress.level") private var level = PDFCompressionLevel.recommended
        @AppStorage("pdf.compress.dpi") private var dpi = 150.0
        @AppStorage("pdf.compress.quality") private var quality = 0.6

        var body: some View {
            CompressionGoalControls(prefix: "pdf.compress.goal")
            OptionPicker("Compression", selection: $level, style: .segmented, choices: [
                OptionChoice(PDFCompressionLevel.light, "Light"),
                OptionChoice(PDFCompressionLevel.recommended, "Recommended"),
                OptionChoice(PDFCompressionLevel.maximum, "Maximum"),
            ])
            OptionNote(levelDescription)
            OptionNote("Target size and percentage modes render pages as images. Text will no longer be selectable in those modes.")
            if level == .maximum {
                OptionPicker("Resolution", selection: $dpi, choices: [
                    OptionChoice(96.0, "96 DPI (screen)"),
                    OptionChoice(150.0, "150 DPI (balanced)"),
                    OptionChoice(200.0, "200 DPI (print)"),
                ])
                OptionSlider("Image quality", value: $quality, in: 0.3...0.9, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            }
        }

        private var levelDescription: String {
            switch level {
            case .light: "Recompresses images as JPEG. Text and vector graphics are untouched."
            case .recommended: "Recompresses and downsamples images for on-screen reading. Best for most documents."
            case .maximum: "Turns each page into a single image. Smallest files, ideal for scans — but text is no longer selectable."
            }
        }

        func job(for tool: Tool) -> ToolJob? { job(report: nil) }

        /// `report` collects before/after sizes for the page's Savings section.
        func job(report: PDFCompressionReport?) -> ToolJob {
            let level = level, dpi = CGFloat(dpi), quality = CGFloat(quality)
            let goal = CompressionGoal(prefix: "pdf.compress.goal")
            return .each(verb: "Compressing") { input, context, progress in
                let document = try PDFOps.open(input)
                let output = context.output(for: input, suffix: "compressed", extension: "pdf")
                if let bytes = goal.bytes(for: input) { try TargetCompression.pdf(document, to: output, bytes: bytes) }
                else { try PDFOps.compress(document, level: level, dpi: dpi, quality: quality, to: output, progress: progress) }
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
                await MainActor.run { report?.entries.append(entry) }
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

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.imageInputs, reorderable: true, minimumFiles: 1,
                      actionTitle: "Create PDF", noun: "images", job: { Settings().job(for: tool) }) {
            Settings()
            Text("Drag images in the list to set the page order. Each image gets its own page.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.images-to-pdf.pageSize") private var pageSize = PDFImageLayout.PageSize.a4
        @AppStorage("pdf.images-to-pdf.orientation") private var orientation = PDFImageLayout.Orientation.auto
        @AppStorage("pdf.images-to-pdf.margin") private var margin = 0.0
        @AppStorage("pdf.images-to-pdf.imageQuality") private var imageQuality = ImageQuality.high

        var body: some View {
            OptionPicker("Page size", selection: $pageSize, choices: PDFImageLayout.PageSize.allCases.map { OptionChoice($0, $0.label) })
            if pageSize != .fit {
                OptionPicker("Orientation", selection: $orientation, style: .segmented,
                             choices: PDFImageLayout.Orientation.allCases.map { OptionChoice($0, $0.label) })
            }
            OptionPicker("Margin", selection: $margin, style: .segmented, choices: [
                OptionChoice(0.0, "None"),
                OptionChoice(18.0, "Small"),
                OptionChoice(54.0, "Large"),
            ])
            OptionPicker("Image quality", selection: $imageQuality, style: .segmented,
                         choices: ImageQuality.allCases.map { OptionChoice($0, $0.label) })
        }

        func job(for tool: Tool) -> ToolJob? {
            .all { [pageSize, orientation, margin, imageQuality] inputs, context in
                let layout = PDFImageLayout(pageSize: pageSize, orientation: orientation, margin: CGFloat(margin),
                                            maxPixelSize: imageQuality.maxPixelSize, jpegQuality: imageQuality.jpegQuality)
                let name = inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent : "Images"
                context.setStatus("Creating PDF from \(inputs.count) image\(inputs.count == 1 ? "" : "s")")
                try PDFOps.imagesToPDF(inputs, layout: layout, to: context.output(named: name, extension: "pdf")) {
                    context.setProgress($0)
                }
            }
        }
    }
}

// MARK: - PDF to images

struct PDFToImagesView: View {
    let tool: Tool
    @State private var pages = ""

    var body: some View {
        BatchToolView(tool: tool, accepts: UTType.pdfInputs, actionTitle: "Export", noun: "PDFs",
                      job: { Settings().job(pages: pages) }) {
            Settings()
            LabeledContent("Pages") {
                TextField("All pages, or e.g. 1-3, 5", text: $pages)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }
        }
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    /// The page range is per document, so it's only on this page; the launcher exports every page.
    struct Settings: ToolSettings {
        @AppStorage("pdf.to-images.format") private var format = PDFImageFormat.png
        @AppStorage("pdf.to-images.quality") private var quality = 0.85
        @AppStorage("pdf.to-images.dpi") private var dpi = 150.0
        @AppStorage("pdf.to-images.zip") private var zip = false

        var body: some View {
            OptionPicker("Format", selection: $format, style: .segmented, choices: [
                OptionChoice(PDFImageFormat.png, "PNG"),
                OptionChoice(PDFImageFormat.jpeg, "JPEG"),
            ])
            if format == .jpeg {
                OptionSlider("Quality", value: $quality, in: 0.4...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            }
            OptionPicker("Resolution", selection: $dpi, style: .segmented, choices: [
                OptionChoice(72.0, "72 DPI"),
                OptionChoice(150.0, "150 DPI"),
                OptionChoice(300.0, "300 DPI"),
                OptionChoice(600.0, "600 DPI"),
            ])
            OptionToggle("Bundle pages in a ZIP", isOn: $zip)
            OptionNote(zip ? "Each PDF's pages are saved in one ZIP archive." : "Each PDF's pages are saved in their own folder.")
        }

        func job(for tool: Tool) -> ToolJob? { job(pages: "") }

        /// `pages` is a range like "1-3, 5"; empty exports every page.
        func job(pages: String) -> ToolJob {
            .each(verb: "Exporting") { [format, quality, dpi, zip] input, context, progress in
                let document = try PDFOps.open(input)
                let indices = pages.trimmingCharacters(in: .whitespaces).isEmpty
                    ? PDFOps.allPages(document)
                    : try PDFOps.indices(pages, pageCount: document.pageCount)
                let name = input.deletingPathExtension().lastPathComponent
                let folder = zip ? try context.makeScratchFolder() : try context.outputFolder(named: name, nextTo: input)
                try PDFOps.exportImages(document, pages: indices, to: folder, format: format,
                                        quality: CGFloat(quality), dpi: CGFloat(dpi)) { progress($0 * (zip ? 0.9 : 1)) }
                if zip {
                    try await ArchiveEngine.zipPackage(folder, to: context.output(named: name, extension: "zip", nextTo: input))
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        }
    }
}
