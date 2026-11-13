import SwiftUI

/// Saves web pages as Markdown files, one per link, converted by markdown.new (see `WebsiteMarkdown`).
struct WebsiteMarkdownView: View {
    let tool: Tool

    @State private var runner: JobRunner
    @State private var text = ""
    @State private var copied = false
    @AppStorage("files.website-to-markdown.keepsImages") private var keepsImages = false
    @AppStorage("files.website-to-markdown.rendersInBrowser") private var rendersInBrowser = false
    @AppStorage("files.website-to-markdown.addsSource") private var addsSource = true

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    private var links: [URL] { WebsiteMarkdown.links(in: text) }

    var body: some View {
        ToolPage(tool: tool, runner: runner) {
            Group {
                LinkListEditor(text: $text, count: links.count, placeholder: "Paste one or more web page links, one per line")

                ToolSection("Options", footnote: "Toolbox sends each link to markdown.new, a free service that reads the page and returns Markdown. Only public pages work, up to 500 a day.") {
                    Toggle("Keep images", isOn: $keepsImages)
                    Toggle("Add the page's title and link at the top", isOn: $addsSource)
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Render the page in a browser first", isOn: $rendersInBrowser)
                        Text("Slower. Turn it on when a page loads its content with JavaScript and comes out empty or incomplete.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(runner.isRunning)

            if runner.phase == .succeeded, !runner.outputs.isEmpty {
                Button(action: copyMarkdown) {
                    Label(copied ? "Copied" : "Copy Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
        } footer: {
            JobBar(runner: runner, actionTitle: "Convert", canRun: !links.isEmpty, hint: "Paste a link to get started.",
                   idleMessage: idleMessage, action: start)
        }
        .onChange(of: runner.phase) { copied = false }
    }

    /// The pages have no original to sit next to, so they go to Downloads unless a folder is set.
    private var idleMessage: String {
        AppSettings.outputMode == .ask
            ? "You'll choose where the Markdown files go."
            : "Markdown files go to \((OutputManager.fixedFolder ?? OutputManager.downloadsFolder).lastPathComponent)."
    }

    private func start() {
        let links = links
        let options = WebsiteMarkdown.Options(keepsImages: keepsImages, rendersInBrowser: rendersInBrowser, addsSource: addsSource)
        runner.start(title: tool.name) { context in
            for (index, link) in links.enumerated() {
                try Task.checkCancellation()
                let prefix = links.count > 1 ? "\(index + 1) of \(links.count): " : ""
                context.setStatus(prefix + "Converting \(link.host() ?? link.absoluteString)")
                // The service reports no progress, so each page counts once it's back.
                context.setProgress((Double(index) + 0.1) / Double(links.count))
                let page: WebsiteMarkdown.Page
                do {
                    page = try await WebsiteMarkdown.convert(link, options: options)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ToolError.failed(links.count > 1 ? "\(link.absoluteString): \(error.localizedDescription)" : error.localizedDescription)
                }
                let output = context.output(named: WebsiteMarkdown.fileName(for: page), extension: "md")
                try Data(WebsiteMarkdown.document(for: page, options: options).utf8).write(to: output)
            }
            context.setProgress(1)
        }
    }

    /// Copies the saved pages' Markdown, one after another.
    private func copyMarkdown() {
        let pages = runner.outputs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard !pages.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pages.joined(separator: "\n"), forType: .string)
        copied = true
    }
}
