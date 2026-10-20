import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Scans of the selected files and of the cleaned copies.
@MainActor
@Observable
final class PDFPrivacyStore {
    struct Cleaned: Identifiable {
        let id = UUID()
        let source: String
        let report: PDFPrivacyReport
    }

    var reports: [URL: PDFPrivacyReport] = [:]
    var cleaned: [Cleaned] = []

    func scan(_ urls: [URL]) async {
        reports = reports.filter { urls.contains($0.key) }
        for url in urls where reports[url] == nil {
            let report = await Task.detached(priority: .userInitiated) { PDFPrivacyScanner.scan(url) }.value
            guard !Task.isCancelled else { return }
            reports[url] = report
        }
    }

    func rescan(_ urls: [URL]) async {
        reports = [:]
        await scan(urls)
    }
}

struct PDFPrivacyScanView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var store = PDFPrivacyStore()

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var scanned: [PDFPrivacyReport] { runner.inputs.compactMap { store.reports[$0] } }
    private var isScanning: Bool { scanned.count < runner.inputs.count }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            if !runner.inputs.isEmpty {
                ToolSection("Findings", footnote: "Scanned on your Mac. Nothing is uploaded.") {
                    ForEach(Array(runner.inputs.enumerated()), id: \.element) { index, url in
                        if index > 0 { Divider() }
                        if let report = store.reports[url] {
                            PDFPrivacyReportView(report: report)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Scanning \(url.lastPathComponent)…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("Scan Again") { Task { await store.rescan(runner.inputs) } }
                        Spacer()
                        Button("Copy Report") { copy(PDFPrivacyReport.markdown(scanned)) }
                        Button("Save Report…") { save(PDFPrivacyReport.markdown(scanned)) }
                    }
                    .disabled(isScanning)
                }
            }
            ToolSection("Clean") { Settings() }
                .disabled(runner.isRunning)
            if runner.phase == .succeeded, !store.cleaned.isEmpty {
                ToolSection("After cleaning", footnote: "What's on the pages isn't changed. Hidden text stays: check it with the page itself.") {
                    ForEach(Array(store.cleaned.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        PDFPrivacyReportView(report: entry.report, cleanedFrom: entry.source)
                    }
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Clean & Save", canRun: !runner.inputs.isEmpty,
                   hint: "Add PDFs to scan for hidden data.", action: clean)
        }
        .task(id: runner.inputs) { await store.scan(runner.inputs) }
        .onChange(of: runner.inputs) {
            if !runner.isRunning {
                runner.reset()
                store.cleaned = []
            }
        }
    }

    private func clean() {
        store.cleaned = []
        runner.start(Settings().job(store: store), title: tool.name, inputs: runner.inputs)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PDF Privacy Report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The saved cleaning options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.privacy-scan.metadata") private var metadata = true
        @AppStorage("pdf.privacy-scan.comments") private var comments = PDFPrivacyCleaner.CommentPolicy.remove
        @AppStorage("pdf.privacy-scan.images") private var images = true
        @AppStorage("pdf.privacy-scan.forms") private var forms = false
        @AppStorage("pdf.privacy-scan.links") private var keepLinks = true

        var body: some View {
            OptionToggle("Remove author, app and date details", isOn: $metadata)
            OptionToggle("Remove photo locations and camera details", isOn: $images)
            OptionPicker("Comments", selection: $comments, style: .segmented,
                         choices: PDFPrivacyCleaner.CommentPolicy.allCases.map { OptionChoice($0, $0.label) })
            OptionToggle("Remove form fields and what's typed in them", isOn: $forms)
            OptionToggle("Keep web links", isOn: $keepLinks)
            OptionNote("Attachments, scripts, automatic actions, XMP metadata, page thumbnails, private app data and earlier saved versions are always removed. Pages, text and bookmarks stay as they are.")
        }

        private var options: PDFPrivacyCleaner.Options {
            PDFPrivacyCleaner.Options(metadata: metadata, comments: comments, forms: forms, images: images, keepLinks: keepLinks)
        }

        func job(for tool: Tool) -> ToolJob? { job(store: nil) }

        /// `store` collects the scans of the cleaned copies for the page.
        func job(store: PDFPrivacyStore?) -> ToolJob { Self.job(options: options, store: store) }

        static func job(options: PDFPrivacyCleaner.Options, store: PDFPrivacyStore? = nil) -> ToolJob {
            .each(verb: "Cleaning") { input, context, progress in
                let output = context.output(for: input, suffix: "clean", extension: "pdf")
                let report = try PDFPrivacyCleaner.clean(input, to: output, options: options)
                progress(1)
                await MainActor.run { store?.cleaned.append(.init(source: input.lastPathComponent, report: report)) }
            }
        }
    }
}

/// One file's findings.
struct PDFPrivacyReportView: View {
    let report: PDFPrivacyReport
    /// The original's name, when this is the scan of a cleaned copy.
    var cleanedFrom: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(cleanedFrom.map { "\($0) → \(report.fileName)" } ?? report.fileName)
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer()
                badge
            }
            if let error = report.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if report.findings.isEmpty {
                Label(cleanedFrom == nil ? "No hidden data found." : "No hidden data left.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(report.findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(finding.severity).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title)
                            Text(finding.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if let pages = finding.pageDescription {
                            Text(pages).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        let (label, color): (String, Color) = switch report.highest {
        case .high: ("High risk", .red)
        case .medium: ("Medium risk", .orange)
        case .low: ("Low risk", .yellow)
        case nil: (report.error == nil ? "Clean" : "Not scanned", report.error == nil ? .green : .secondary)
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func icon(_ severity: PDFPrivacyFinding.Severity) -> some View {
        let (symbol, color): (String, Color) = switch severity {
        case .high: ("exclamationmark.octagon.fill", .red)
        case .medium: ("exclamationmark.triangle.fill", .orange)
        case .low: ("info.circle.fill", .secondary)
        }
        return Image(systemName: symbol).foregroundStyle(color)
    }
}
