import SwiftUI

/// Start screen: one search field with live suggestions, feature cards and every tool by category.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var highlighted = 0

    private var results: [Tool] {
        model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? ToolRegistry.suggestions
            : ToolRegistry.search(model.searchText)
    }

    private var isSearching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 22) {
                    if Updater.shared.showsBanner {
                        UpdateBanner(updater: Updater.shared)
                            .frame(maxWidth: 640)
                    }
                    VStack(spacing: 6) {
                        Text("What do you want to do?")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(ToolRegistry.all.count) tools for media, documents, PDFs, archives and on-device AI. Everything runs on your Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)

                VStack(spacing: 0) {
                    searchField
                    suggestionList
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                .frame(maxWidth: 640)

                if !isSearching {
                    featureCards
                    allTools
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Toolbox")
        .onAppear { searchFocused = true }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onChange(of: model.searchText) { highlighted = 0 }
    }

    private var searchField: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            BrandGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            TextField("Search tools — try “compress”, “pdf” or “gif”", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) {
                    if model.searchText.isEmpty { return .ignored }
                    model.searchText = ""
                    return .handled
                }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            if AppSettings.hotKeyEnabled {
                Text(HotKeyShortcut.current.displayString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("Press this in any app to open the quick launcher")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var suggestionList: some View {
        Divider()
        VStack(alignment: .leading, spacing: 2) {
            Text(isSearching ? (results.isEmpty ? "No matching tools" : "Results") : "Suggestions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(Array(results.prefix(8).enumerated()), id: \.element.id) { index, tool in
                Button { model.open(.tool(tool.id)) } label: {
                    HStack(spacing: 10) {
                        ToolIcon(tool: tool, size: 26)
                        Text(tool.name).foregroundStyle(.primary)
                        Text(tool.summary).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if index == highlighted {
                            Image(systemName: "return").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == highlighted ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(6)
    }

    private var featureCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            ForEach(FeaturedCollection.allCases) { collection in
                FeatureCard(collection: collection) { model.open(collection.destination) }
            }
        }
    }

    private var allTools: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ToolCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Button { model.open(.category(category)) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol).foregroundStyle(category.tint)
                            Text(category.name).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(ToolRegistry.tools(in: category).count)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(ToolRegistry.tools(in: category)) { tool in
                            CompactToolButton(tool: tool) { model.open(.tool(tool.id)) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func move(_ delta: Int) {
        let count = min(results.count, 8)
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func openHighlighted() {
        let visible = Array(results.prefix(8))
        guard visible.indices.contains(highlighted) else { return }
        model.open(.tool(visible[highlighted].id))
    }
}

private struct FeatureCard: View {
    let collection: FeaturedCollection
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: collection.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("⌘\(String(collection.shortcut.character))")
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 6)
                Text(collection.title).font(.headline).foregroundStyle(.white)
                Text(collection.subtitle).font(.callout).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                LinearGradient(colors: [collection.tint.opacity(0.9), collection.tint.mix(with: .black, by: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: collection.tint.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 12 : 6, y: 4)
            .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }
}

private struct CompactToolButton: View {
    let tool: Tool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ToolIcon(tool: tool, size: 22)
                Text(tool.shortName).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tool.summary)
    }
}
