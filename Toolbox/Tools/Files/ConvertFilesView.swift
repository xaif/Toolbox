import SwiftUI
import UniformTypeIdentifiers

struct ConvertFilesView: View {
    let tool: Tool
    @State private var runner: JobRunner
    @AppStorage("files.convert.target") private var target = "pdf"
    @AppStorage("files.convert.fixedEPUB") private var fixedEPUB = false
    @AppStorage("files.convert.reflowHTML") private var reflowHTML = false

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var targets: [String] { ConversionCatalog.commonTargets(for: runner.inputs) }
    var body: some View {
        BatchToolView(tool: tool, accepts: [.item], actionTitle: "Convert", job: {
            guard targets.contains(target) else { return nil }
            return ConversionEngine.job(target: target, fixedEPUB: fixedEPUB, reflowHTML: reflowHTML)
        }) {
            if let dependency = requiredDependency { DependencyCard(dependency: dependency) }
            if !targets.isEmpty {
                Picker("Output format", selection: $target) {
                    ForEach(targets, id: \.self) { Text(ConversionCatalog.label($0)).tag($0) }
                }
                if target == "epub" { Toggle("Preserve PDF pages as a fixed layout book", isOn: $fixedEPUB) }
                if target == "html", hasPDFs {
                    Toggle("Reflow the text instead of keeping each page's layout", isOn: $reflowHTML)
                    Text(reflowHTML ? "Headings and paragraphs only, readable on any screen. Pictures are left out."
                                    : "Each page looks like the original, with text you can select, search and copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if ["docx", "pages", "md", "xlsx"].contains(target), hasPDFs {
                    Text("PDF text and table exports use reading order and local OCR. Complex layouts may change. PowerPoint exports preserve each page as a slide image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Convert images, media, PDFs, documents, slides, spreadsheets, books, subtitles and archives locally. HTML, Markdown and EPUB pages keep their styling; CSV tables are laid out as PDF tables. PDF image exports use 300 DPI. Office documents use LibreOffice, Kindle books use Calibre and Pages files use Apple Pages.")
                .font(.callout).foregroundStyle(.secondary)
            if !runner.inputs.isEmpty && targets.isEmpty {
                Label("This selection has no shared output format. Choose compatible files.", systemImage: "info.circle")
            }
        }
        .onChange(of: runner.inputs) { _, _ in if !targets.contains(target), let first = targets.first { target = first } }
    }
    private var hasPDFs: Bool { runner.inputs.contains { $0.pathExtension.lowercased() == "pdf" } }

    private var requiredDependency: ExternalDependency? {
        let families = runner.inputs.compactMap(ConversionCatalog.family)
        // CSV and TSV become PDF tables without LibreOffice.
        let needsOffice = runner.inputs.contains { input in
            let family = ConversionCatalog.family(of: input)
            return family == .slides || (family == .spreadsheet && !(target == "pdf" && ["csv", "tsv"].contains(input.pathExtension.lowercased())))
        }
        let dependency: ExternalDependency?
        if runner.inputs.contains(where: EbookConverter.needsCalibre) { dependency = .calibre }
        else if needsOffice { dependency = .libreoffice }
        else if target == "avif" { dependency = .avif }
        else if target == "webp" && !ImageFormat.writable.contains(.webp) { dependency = .webp }
        else if families.contains(.video) || families.contains(.audio) { dependency = .ffmpeg }
        else { dependency = nil }
        return dependency.flatMap { Dependencies.shared.isAvailable($0) ? nil : $0 }
    }
}
