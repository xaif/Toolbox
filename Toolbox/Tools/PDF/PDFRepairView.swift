import SwiftUI
import UniformTypeIdentifiers

/// What each repaired file went through, reported back from the background job.
@MainActor
@Observable
final class PDFRepairReport {
    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let outcome: PDFRepairOutcome
    }

    var entries: [Entry] = []
}

struct PDFRepairView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var report = PDFRepairReport()

    /// PDFs, plus unfinished downloads that are often PDFs cut short.
    static let accepted: [UTType] = [.pdf] + ["crdownload", "part", "partial", "download"].compactMap { UTType(filenameExtension: $0) }

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: Self.accepted, noun: "PDFs")
                .disabled(runner.isRunning)
            if runner.phase == .succeeded, !report.entries.isEmpty {
                ToolSection("Recovery") {
                    ForEach(report.entries) { PDFRepairOutcomeRow(name: $0.name, outcome: $0.outcome) }
                }
            }
            ToolSection("How it works", footnote: "Originals are never changed; each repaired copy is a new file.") {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Remove junk before the PDF header or after the end of the file.")
                    step(2, "Rebuild the cross-reference table, catalog and page list from the objects that survive.")
                    step(3, "Rewrite the document so any viewer can open it, keeping links, forms and bookmarks.")
                    step(4, "If that fails, redraw the pages one by one, skipping broken ones.")
                    step(5, "If no pages survive, rescue the photos and scans inside the file.")
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Repair", canRun: !runner.inputs.isEmpty,
                   hint: "Add damaged PDFs to repair.", action: run)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func run() {
        report.entries = []
        runner.start(Self.job(report: report), title: tool.name, inputs: runner.inputs)
    }

    /// `report` collects each file's outcome for the page's Recovery section.
    static func job(report: PDFRepairReport?) -> ToolJob {
        .each(verb: "Repairing") { input, context, progress in
            // "report.pdf.crdownload" → "report-repaired.pdf"
            var base = input.deletingPathExtension()
            if input.pathExtension.lowercased() != "pdf", base.pathExtension.lowercased() == "pdf" { base = base.deletingPathExtension() }
            let output = context.output(named: base.lastPathComponent + "-repaired", extension: "pdf", nextTo: input)
            let outcome = try PDFRepair.repair(input, to: output, progress: progress)
            await MainActor.run { report?.entries.append(.init(name: input.lastPathComponent, outcome: outcome)) }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(text).foregroundStyle(.secondary)
        }
    }

}

/// One repaired file: what was wrong and what came back.
struct PDFRepairOutcomeRow: View {
    let name: String
    let outcome: PDFRepairOutcome

    var body: some View {
        let pages = outcome.expectedPages.map { "\(outcome.pages) of \($0) pages" }
            ?? (outcome.pages == 1 ? "1 page" : "\(outcome.pages) pages")
        let summary = outcome.damageFound ? outcome.methods.map(\.label).joined(separator: " → ") : "No damage found. Saved a clean copy."
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: outcome.isPartial ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(outcome.isPartial ? .orange : .green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(pages).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(summary).font(.callout).foregroundStyle(.secondary)
                ForEach(outcome.fixes + outcome.lost, id: \.self) { line in
                    Text("• " + line).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
