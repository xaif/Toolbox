import SwiftUI
import UniformTypeIdentifiers

/// Pages recognized per file, reported back from the background job.
@MainActor
@Observable
final class PDFOCRReport {
    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let result: PDFOCRResult
    }

    var entries: [Entry] = []
}

/// Make PDF Searchable: adds an invisible OCR text layer to scanned pages.
struct PDFSearchableView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var report = PDFOCRReport()

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            FileListInput(files: $runner.inputs, accepts: UTType.pdfInputs, noun: "PDFs")
                .disabled(runner.isRunning)
            ToolSection("Options", footnote: "Text is recognized on your Mac with Apple's Vision framework. Pages look exactly the same.") {
                Settings()
            }
            .disabled(runner.isRunning)
            if !report.entries.isEmpty, runner.phase == .succeeded {
                ToolSection("Recognized") {
                    ForEach(report.entries) { entry in
                        HStack {
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(summary(entry.result)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Make Searchable", canRun: !runner.inputs.isEmpty,
                   hint: "Add scanned PDFs to get started.", action: run)
        }
        .onChange(of: runner.inputs) { if !runner.isRunning { runner.reset() } }
    }

    private func run() {
        report.entries = []
        runner.start(Settings().job(report: report), title: tool.name, inputs: runner.inputs)
    }

    private func summary(_ result: PDFOCRResult) -> String {
        func pages(_ count: Int) -> String { "\(count) page\(count == 1 ? "" : "s")" }
        if result.recognizedPages == 0 { return "Already searchable — saved unchanged" }
        if result.skippedPages == 0 { return "\(pages(result.recognizedPages)) recognized" }
        return "\(pages(result.recognizedPages)) recognized, \(pages(result.skippedPages)) already had text"
    }

    /// The saved options, shown on this page and in the launcher, and the job they configure.
    struct Settings: ToolSettings {
        @AppStorage("pdf.ocr.language") private var languageID = ""
        @AppStorage("pdf.ocr.correction") private var languageCorrection = true
        @AppStorage("pdf.ocr.redo") private var redo = false
        @AppStorage("pdf.ocr.dpi") private var dpi = 300.0

        static let languages = AIOCR.supportedLanguages
            .sorted { AIOCR.displayName(for: $0).localizedCaseInsensitiveCompare(AIOCR.displayName(for: $1)) == .orderedAscending }

        static var languageChoices: [OptionChoice<String>] {
            [OptionChoice("", "Detect automatically")] + languages.enumerated().map { index, language in
                OptionChoice(language.maximalIdentifier, AIOCR.displayName(for: language), dividerBefore: index == 0)
            }
        }

        var body: some View {
            OptionPicker("Language", selection: $languageID, choices: Self.languageChoices)
            OptionToggle("Correct recognized words using the language", isOn: $languageCorrection)
            OptionPicker("Resolution", selection: $dpi, style: .segmented, choices: [
                OptionChoice(200.0, "200 DPI"),
                OptionChoice(300.0, "300 DPI"),
                OptionChoice(400.0, "400 DPI"),
            ])
            OptionToggle("Redo pages that already have text", isOn: $redo)
            OptionNote(redo
                       ? "Pages with an existing text layer are replaced by an image of the page with new recognized text."
                       : "Pages that already have selectable text are left as they are.")
        }

        func job(for tool: Tool) -> ToolJob? { job(report: nil) }

        /// `report` collects per-file page counts for the page's summary.
        func job(report: PDFOCRReport?) -> ToolJob {
            let options = AIOCR.Options(languages: languageID.isEmpty ? [] : [Locale.Language(identifier: languageID)],
                                        usesLanguageCorrection: languageCorrection)
            let redo = redo, dpi = CGFloat(dpi)
            return .each(verb: "Recognizing") { input, context, progress in
                let output = context.output(for: input, suffix: "searchable", extension: "pdf")
                let result = try await PDFTextLayer.makeSearchable(input, options: options, redo: redo, dpi: dpi,
                                                                   to: output, progress: progress)
                let entry = PDFOCRReport.Entry(name: input.lastPathComponent, result: result)
                await MainActor.run { report?.entries.append(entry) }
            }
        }
    }
}
