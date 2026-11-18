import Foundation
import KVMKit
import SwiftUI

/// The user's own key combinations for the Send Keys menu, shared by every
/// console and saved in `UserDefaults` as they change.
@MainActor
@Observable
final class CustomKeyCombos {
    static let shared = CustomKeyCombos()

    var items: [KeyComboItem] {
        didSet { KeyComboStorage.save(items, to: defaults) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = KeyComboStorage.load(from: defaults)
    }

    /// Adds the item, or replaces the one with the same id.
    func upsert(_ item: KeyComboItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }
}
