import SwiftUI
import QuickLookUI

/// Rounded, tinted square with a tool's symbol.
struct ToolIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    init(tool: Tool, size: CGFloat = 28) {
        self.symbol = tool.symbol
        self.tint = tool.category.tint
        self.size = size
    }

    init(symbol: String, tint: Color, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

struct ToolHeader: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 14) {
            ToolIcon(tool: tool, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.title2.weight(.semibold))
                Text(tool.summary).foregroundStyle(.secondary)
            }
        }
    }
}

/// A titled group of controls inside a tool page.
struct ToolSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Standard layout for every tool: header, dependency check, scrolling content, results and a bottom action bar.
///
/// Pass `runner` to show finished results and to get the default action bar via `footer`.
struct ToolPage<Content: View, Footer: View>: View {
    let tool: Tool
    var runner: JobRunner?
    var scrolls = true
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    @Environment(Dependencies.self) private var dependencies

    init(tool: Tool, runner: JobRunner? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.tool = tool
        self.runner = runner
        self.scrolls = scrolls
        self.content = content()
        self.footer = footer()
    }

    private var missing: [ExternalDependency] {
        tool.requirements.filter { !dependencies.isAvailable($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView {
                    body(for: missing)
                        .padding(24)
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            } else {
                body(for: missing)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if missing.isEmpty, Footer.self != EmptyView.self {
                Divider()
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
        }
        .navigationTitle(tool.name)
        .navigationSubtitle(tool.category.name)
    }

    @ViewBuilder
    private func body(for missing: [ExternalDependency]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ToolHeader(tool: tool)
            if missing.isEmpty {
                content
                if let runner, runner.phase == .succeeded, !runner.outputs.isEmpty {
                    ResultsSection(runner: runner)
                }
            } else {
                ForEach(missing) { DependencyCard(dependency: $0) }
            }
        }
    }
}

extension ToolPage where Footer == EmptyView {
    init(tool: Tool, runner: JobRunner? = nil, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(tool: tool, runner: runner, scrolls: scrolls, content: content, footer: { EmptyView() })
    }
}

/// Bottom bar with progress, status and the primary action.
struct JobBar: View {
    let runner: JobRunner
    var actionTitle: String
    var canRun = true
    /// Shown when idle and the action is disabled, e.g. "Add at least two files".
    var hint: String?
    /// Shown when idle and ready. Defaults to the "originals untouched" note.
    var idleMessage = "Originals stay untouched. Results go to a new folder."
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            statusView
                .frame(maxWidth: .infinity, alignment: .leading)
            if runner.isRunning {
                Button("Cancel", role: .cancel) { runner.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button(action: action) {
                    Text(actionTitle).frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canRun)
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var statusView: some View {
        switch runner.phase {
        case .idle:
            if let hint, !canRun {
                Text(hint).foregroundStyle(.secondary)
            } else {
                Text(idleMessage)
                    .foregroundStyle(.tertiary)
            }
        case .running:
            HStack(spacing: 10) {
                ProgressView(value: runner.progress)
                    .frame(maxWidth: 220)
                VStack(alignment: .leading, spacing: 0) {
                    Text(runner.status).lineLimit(1).truncationMode(.middle)
                    if let started = runner.startedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .succeeded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let folder = runner.outputFolder {
                    Text("Saved to \(folder.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(runner.outputs.isEmpty ? [folder] : runner.outputs)
                    }
                    .buttonStyle(.link)
                } else {
                    Text("Done")
                }
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).textSelection(.enabled).lineLimit(3)
            }
        case .cancelled:
            Label("Cancelled. Nothing was saved.", systemImage: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// Lists the files a finished job produced.
struct ResultsSection: View {
    let runner: JobRunner

    var body: some View {
        ToolSection("Results") {
            ForEach(runner.outputs.prefix(50), id: \.self) { url in
                HStack(spacing: 10) {
                    FileThumbnail(url: url, size: 28)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(FileSize.string(for: url)).foregroundStyle(.secondary).font(.callout.monospacedDigit())
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Open")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }
            if runner.outputs.count > 50 {
                Text("and \(runner.outputs.count - 50) more…").foregroundStyle(.secondary)
            }
        }
    }
}

enum FileSize {
    static func bytes(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true {
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let item = enumerator?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    static func string(for url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: bytes(for: url), countStyle: .file)
    }
}
