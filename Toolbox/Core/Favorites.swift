import Foundation
import Observation

/// Tools the user pinned, shown first in the quick launcher and the sidebar.
@MainActor
@Observable
final class Favorites {
    static let shared = Favorites()

    private(set) var ids: [String] {
        didSet { UserDefaults.standard.set(ids, forKey: SettingsKey.favoriteTools) }
    }

    private init() {
        ids = UserDefaults.standard.stringArray(forKey: SettingsKey.favoriteTools) ?? []
    }

    var tools: [Tool] { ids.compactMap(ToolRegistry.tool) }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
    }

    /// Moves a favorite up (-1) or down (+1).
    func move(_ id: String, by offset: Int) {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        ids.move(fromOffsets: source, toOffset: destination)
    }
}
