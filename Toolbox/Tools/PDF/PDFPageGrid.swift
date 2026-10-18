import PDFKit
import SwiftUI

/// Holds one opened PDF and an editable list of its pages for the grid-based tools.
/// One model exists per tool, so edits survive navigating away and back.
@MainActor
@Observable
final class PDFPageGridModel {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        let sourceIndex: Int
        /// Extra clockwise rotation applied by the user.
        var rotation = 0
    }

    private(set) var url: URL?
    private(set) var document: PDFDocument?
    var items: [Item] = []
    var selection: Set<Item.ID> = []
    private(set) var needsPassword = false
    private(set) var loadError: String?
    private(set) var isEdited = false
    private var anchor: Item.ID?
    private var thumbnails: [Int: NSImage] = [:]

    private static var models: [String: PDFPageGridModel] = [:]

    static func shared(for toolID: String) -> PDFPageGridModel {
        if let model = models[toolID] { return model }
        let model = PDFPageGridModel()
        models[toolID] = model
        return model
    }

    var pageCount: Int { document?.pageCount ?? 0 }
    var isReady: Bool { document != nil && !needsPassword }

    /// Pages in the current order with their extra rotation.
    var pageRefs: [PDFPageRef] { items.map { PDFPageRef(index: $0.sourceIndex, rotation: $0.rotation) } }

    /// Source indices of selected items, in display order.
    var selectedSourceIndices: [Int] { items.filter { selection.contains($0.id) }.map(\.sourceIndex) }

    // MARK: Loading

    func load(_ newURL: URL?) {
        guard newURL != url else { return }
        url = newURL
        document = nil
        items = []
        selection = []
        anchor = nil
        thumbnails = [:]
        needsPassword = false
        loadError = nil
        isEdited = false
        guard let newURL else { return }
        guard let opened = PDFDocument(url: newURL) else {
            loadError = "Couldn't open “\(newURL.lastPathComponent)”."
            return
        }
        document = opened
        if opened.isLocked {
            needsPassword = true
        } else {
            resetPages()
        }
    }

    /// Returns false if the password is wrong.
    func unlock(_ password: String) -> Bool {
        guard let document, document.unlock(withPassword: password) else { return false }
        needsPassword = false
        resetPages()
        return true
    }

    func resetPages() {
        items = (0..<pageCount).map { Item(sourceIndex: $0) }
        selection = []
        anchor = nil
        isEdited = false
    }

    // MARK: Selection

    /// Click handling: plain click selects one, ⌘ toggles, ⇧ extends from the last clicked item.
    func click(_ id: Item.ID, command: Bool, shift: Bool) {
        if shift, let anchor, let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == id }) {
            let range = min(from, to)...max(from, to)
            if !command { selection = [] }
            selection.formUnion(items[range].map(\.id))
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    /// Toggle used by the checkbox-style tools (Delete/Extract), where plain clicks add to the selection.
    func toggle(_ id: Item.ID, shift: Bool) {
        if shift, let anchor, let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == id }) {
            selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
        anchor = id
    }

    func selectAll() { selection = Set(items.map(\.id)) }
    func clearSelection() { selection = []; anchor = nil }

    /// Selects items whose source page is in `indices` (zero-based).
    func select(sourceIndices indices: [Int]) {
        let wanted = Set(indices)
        selection = Set(items.filter { wanted.contains($0.sourceIndex) }.map(\.id))
    }

    // MARK: Editing

    func rotateSelected(by degrees: Int) {
        for index in items.indices where selection.contains(items[index].id) {
            items[index].rotation = PDFOps.normalizedRotation(items[index].rotation + degrees)
        }
        isEdited = true
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        items.removeAll { selection.contains($0.id) }
        selection = []
        anchor = nil
        isEdited = true
    }

    func duplicateSelected() {
        var result: [Item] = []
        var newSelection: Set<Item.ID> = []
        for item in items {
            result.append(item)
            if selection.contains(item.id) {
                let copy = Item(sourceIndex: item.sourceIndex, rotation: item.rotation)
                result.append(copy)
                newSelection.insert(copy.id)
            }
        }
        items = result
        selection = newSelection
        isEdited = true
    }

    /// Moves the dragged item (or the whole selection if it's part of it) before or after `target`.
    func move(dragged: Item.ID, onto target: Item.ID, after: Bool) {
        let moving = selection.contains(dragged) ? items.filter { selection.contains($0.id) } : items.filter { $0.id == dragged }
        guard !moving.contains(where: { $0.id == target }) else { return }
        let movingIDs = Set(moving.map(\.id))
        var remaining = items.filter { !movingIDs.contains($0.id) }
        guard let targetIndex = remaining.firstIndex(where: { $0.id == target }) else { return }
        remaining.insert(contentsOf: moving, at: after ? targetIndex + 1 : targetIndex)
        guard remaining.map(\.id) != items.map(\.id) else { return }
        items = remaining
        isEdited = true
    }

    func moveSelection(by offset: Int) {
        guard !selection.isEmpty else { return }
        var result = items
        let indices = result.indices.filter { selection.contains(result[$0].id) }
        if offset < 0 {
            for index in indices where index > 0 && !selection.contains(result[index - 1].id) { result.swapAt(index, index - 1) }
        } else {
            for index in indices.reversed() where index < result.count - 1 && !selection.contains(result[index + 1].id) { result.swapAt(index, index + 1) }
        }
        items = result
        isEdited = true
    }

    // MARK: Thumbnails

    func cachedThumbnail(for sourceIndex: Int) -> NSImage? { thumbnails[sourceIndex] }

    func loadThumbnail(for sourceIndex: Int, maxDimension: CGFloat) async {
        guard thumbnails[sourceIndex] == nil, let page = document?.page(at: sourceIndex) else { return }
        let image = await Task.detached(priority: .userInitiated) {
            PDFOps.thumbnail(page, maxDimension: maxDimension)
        }.value
        if let image, document?.page(at: sourceIndex) === page { thumbnails[sourceIndex] = image }
    }
}

/// How the grid shows selection.
enum PDFPageGridStyle {
    /// Organize: highlight selection, drag to reorder.
    case organize
    /// Delete: selected pages are crossed out.
    case markForDeletion
    /// Extract: selected pages get a checkmark.
    case check
    /// Read-only preview; `group` returns a group number per position to tint pages (used by Split).
    case preview(group: (Int) -> Int?)
}

/// A grid of page thumbnails with multi-selection, keyboard shortcuts and drag-to-reorder.
struct PDFPageGrid: View {
    @Bindable var model: PDFPageGridModel
    var style: PDFPageGridStyle
    var thumbnailSize: CGFloat = 132

    @State private var dropTarget: (id: PDFPageGridModel.Item.ID, after: Bool)?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reorderable: Bool { if case .organize = style { true } else { false } }
    private var interactive: Bool { if case .preview = style { false } else { true } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize + 16), spacing: 14)], spacing: 16) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { position, item in
                    cell(item, position: position)
                }
            }
            .padding(14)
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .focusable(interactive)
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand {
            if reorderable { model.deleteSelected() }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            if interactive { model.selectAll() }
        }
        .onKeyPress(.escape) {
            guard interactive, !model.selection.isEmpty else { return .ignored }
            model.clearSelection()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard reorderable, NSEvent.modifierFlags.contains(.option) else { return .ignored }
            model.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard reorderable, NSEvent.modifierFlags.contains(.option) else { return .ignored }
            model.moveSelection(by: 1)
            return .handled
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.items)
    }

    @ViewBuilder
    private func cell(_ item: PDFPageGridModel.Item, position: Int) -> some View {
        let selected = model.selection.contains(item.id)
        let groupNumber: Int? = { if case .preview(let group) = style { return group(position) } else { return nil } }()
        VStack(spacing: 6) {
            ZStack {
                PDFThumbnailImage(model: model, sourceIndex: item.sourceIndex, maxDimension: thumbnailSize)
                    .rotationEffect(.degrees(Double(item.rotation)))
                    .opacity(isMarkedForDeletion(selected) ? 0.35 : 1)
                if isMarkedForDeletion(selected) {
                    Image(systemName: "xmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            .frame(width: thumbnailSize, height: thumbnailSize)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlight(selected: selected, group: groupNumber))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor(selected: selected, group: groupNumber), lineWidth: selected || groupNumber != nil ? 2.5 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if case .check = style {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : Color.secondary.opacity(0.6))
                        .padding(4)
                }
            }
            .overlay(alignment: dropTarget?.after == true ? .trailing : .leading) {
                if let dropTarget, dropTarget.id == item.id {
                    Capsule().fill(Color.accentColor).frame(width: 4).padding(.vertical, 4)
                        .offset(x: dropTarget.after ? 9 : -9)
                }
            }
            HStack(spacing: 4) {
                Text("\(position + 1)").font(.callout.weight(selected ? .semibold : .regular).monospacedDigit())
                if item.sourceIndex != position || item.rotation != 0, reorderable {
                    Text(item.sourceIndex != position ? "(p. \(item.sourceIndex + 1))" : "")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.rotation != 0 {
                        Image(systemName: "rotate.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let groupNumber {
                    Text("File \(groupNumber + 1)").font(.caption).foregroundStyle(groupTint(groupNumber))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard interactive else { return }
            focused = true
            let flags = NSEvent.modifierFlags
            switch style {
            case .organize: model.click(item.id, command: flags.contains(.command), shift: flags.contains(.shift))
            case .markForDeletion, .check: model.toggle(item.id, shift: flags.contains(.shift))
            case .preview: break
            }
        }
        .modifier(PDFReorderModifier(enabled: reorderable, item: item, model: model, width: thumbnailSize + 12, dropTarget: $dropTarget))
        .help(interactive ? "Page \(item.sourceIndex + 1)" : "")
    }

    private func isMarkedForDeletion(_ selected: Bool) -> Bool {
        if case .markForDeletion = style { selected } else { false }
    }

    private func highlight(selected: Bool, group: Int?) -> Color {
        if let group { return groupTint(group).opacity(0.12) }
        switch style {
        case .markForDeletion: return selected ? Color.red.opacity(0.10) : .clear
        default: return selected ? Color.accentColor.opacity(0.15) : .clear
        }
    }

    private func borderColor(selected: Bool, group: Int?) -> Color {
        if let group { return groupTint(group).opacity(0.7) }
        switch style {
        case .markForDeletion: return selected ? .red : .clear
        default: return selected ? .accentColor : .clear
        }
    }

    private func groupTint(_ group: Int) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        return palette[group % palette.count]
    }
}

/// Drag source + drop target used for reordering pages.
private struct PDFReorderModifier: ViewModifier {
    let enabled: Bool
    let item: PDFPageGridModel.Item
    let model: PDFPageGridModel
    /// Cell width, used to tell drops on the left half (insert before) from the right half (after).
    let width: CGFloat
    @Binding var dropTarget: (id: PDFPageGridModel.Item.ID, after: Bool)?

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(item.id.uuidString) {
                    PDFThumbnailImage(model: model, sourceIndex: item.sourceIndex, maxDimension: 80)
                        .rotationEffect(.degrees(Double(item.rotation)))
                        .overlay(alignment: .topTrailing) {
                            if model.selection.contains(item.id), model.selection.count > 1 {
                                Text("\(model.selection.count)").font(.caption.bold()).foregroundStyle(.white)
                                    .padding(5).background(Circle().fill(Color.accentColor))
                            }
                        }
                }
                .onDrop(of: [.text], delegate: PDFPageDropDelegate(item: item, width: width, dropTarget: $dropTarget) { dragged, after in
                    model.move(dragged: dragged, onto: item.id, after: after)
                })
        } else {
            content
        }
    }
}

private struct PDFPageDropDelegate: DropDelegate {
    let item: PDFPageGridModel.Item
    let width: CGFloat
    @Binding var dropTarget: (id: PDFPageGridModel.Item.ID, after: Bool)?
    let perform: (PDFPageGridModel.Item.ID, Bool) -> Void

    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if dropTarget?.id == item.id { dropTarget = nil } }

    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.x > width / 2
        dropTarget = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let text) = result, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { perform(id, after) }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        dropTarget = (item.id, info.location.x > width / 2)
    }
}

/// Lazily rendered thumbnail for one source page.
struct PDFThumbnailImage: View {
    let model: PDFPageGridModel
    let sourceIndex: Int
    var maxDimension: CGFloat

    var body: some View {
        Group {
            if let image = model.cachedThumbnail(for: sourceIndex) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .aspectRatio(0.77, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            }
        }
        .frame(maxWidth: maxDimension, maxHeight: maxDimension)
        .task(id: sourceIndex) { await model.loadThumbnail(for: sourceIndex, maxDimension: maxDimension) }
    }
}

/// Shown in grid tools while the chosen PDF is password-protected.
struct PDFUnlockPrompt: View {
    let model: PDFPageGridModel
    @State private var password = ""
    @State private var wrong = false

    var body: some View {
        ToolSection("This PDF is locked") {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock).disabled(password.isEmpty)
                if wrong {
                    Text("Incorrect password").foregroundStyle(.red)
                }
            }
        }
    }

    private func unlock() {
        wrong = !model.unlock(password)
        if !wrong { password = "" }
    }
}
