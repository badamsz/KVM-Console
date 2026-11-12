import Foundation

extension Array where Element: Identifiable {
    /// Moves the element `id` to the place of the element `destination`: after it
    /// when moving down the list, before it when moving up. Elements in between
    /// keep their order, so items a view hides (unplugged USB KVMs) stay put.
    /// Returns false when either element is missing or they are the same.
    @discardableResult
    public mutating func move(_ id: Element.ID, onto destination: Element.ID) -> Bool {
        guard id != destination,
              let from = firstIndex(where: { $0.id == id }),
              let to = firstIndex(where: { $0.id == destination }) else { return false }
        insert(remove(at: from), at: to)
        return true
    }
}
