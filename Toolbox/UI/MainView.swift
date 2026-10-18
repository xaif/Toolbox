import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            #if DEBUG
            // Development hook: `open Toolbox.app --args -debugOpenTool video.compress -debugInputs /a.mp4,/b.mp4`
            if let id = UserDefaults.standard.string(forKey: "debugOpenTool"), ToolRegistry.tool(id) != nil {
                let inputs = (UserDefaults.standard.string(forKey: "debugInputs") ?? "")
                    .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                JobCenter.shared.runner(for: id).inputs = inputs
                model.open(.tool(id))
            }
            #endif
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.destination {
        case .home:
            HomeView()
        case .category(let category):
            CollectionPage(title: category.name, subtitle: nil, symbol: category.symbol,
                           tint: category.tint, tools: ToolRegistry.tools(in: category))
        case .collection(let collection):
            CollectionPage(title: collection.title, subtitle: collection.subtitle, symbol: collection.symbol,
                           tint: collection.tint, tools: collection.toolIDs.compactMap(ToolRegistry.tool))
        case .tool(let id):
            if let tool = ToolRegistry.tool(id) {
                tool.makeView(tool).id(id)
            } else {
                ContentUnavailableView("Tool not found", systemImage: "questionmark.app")
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<ToolCategory> = []

    var body: some View {
        List(selection: selection) {
            Label("Home", systemImage: "square.grid.2x2").tag(Destination.home)
            ForEach(ToolCategory.allCases) { category in
                Section(isExpanded: expansion(for: category)) {
                    ForEach(ToolRegistry.tools(in: category)) { tool in
                        SidebarRow(tool: tool).tag(Destination.tool(tool.id))
                    }
                } header: {
                    Text(category.name)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<Destination?> {
        Binding(get: { model.destination }, set: { if let value = $0 { model.open(value) } })
    }

    private func expansion(for category: ToolCategory) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(category) },
                set: { if $0 { collapsed.remove(category) } else { collapsed.insert(category) } })
    }
}

private struct SidebarRow: View {
    let tool: Tool
    @State private var runner: JobRunner

    init(tool: Tool) {
        self.tool = tool
        _runner = State(initialValue: JobCenter.shared.runner(for: tool.id))
    }

    var body: some View {
        HStack {
            Label {
                Text(tool.shortName)
            } icon: {
                Image(systemName: tool.symbol).foregroundStyle(tool.category.tint)
            }
            Spacer()
            if runner.isRunning {
                ProgressView(value: runner.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
    }
}

/// Grid of tools for a category or a featured collection.
struct CollectionPage: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let tools: [Tool]

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    ToolIcon(symbol: symbol, tint: tint, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.title2.weight(.semibold))
                        if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                        else { Text("\(tools.count) tools").foregroundStyle(.secondary) }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(tools) { tool in
                        ToolTile(tool: tool) { model.open(.tool(tool.id)) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
    }
}

/// A clickable card for a tool.
struct ToolTile: View {
    let tool: Tool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ToolIcon(tool: tool, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? tool.category.tint.opacity(0.6) : Color.secondary.opacity(0.15)))
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
