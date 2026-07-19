import Foundation

/// A pure, ordered collection of tabs with a single selection — the model
/// behind the main window's connection tab strip (M16 checkpoint B, ADR-027).
///
/// It is generic over any `Identifiable` element so the fiddly bits (which tab
/// becomes selected after the selected one closes, index-preserving reorder)
/// are unit-testable in isolation from the app's `@MainActor` session types.
/// The app instantiates it as `OrderedTabs<ConnectionTab>`.
///
/// Not `Sendable`: the app's `Element` (`ConnectionTab`) is a main-actor class,
/// and every mutation here happens on the main actor.
public struct OrderedTabs<Element: Identifiable> {
    public private(set) var tabs: [Element]
    /// The selected tab's id, or nil only when there are no tabs.
    public private(set) var selectedID: Element.ID?

    public init(tabs: [Element] = [], selectedID: Element.ID? = nil) {
        self.tabs = tabs
        if let selectedID, tabs.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = tabs.first?.id
        }
    }

    public var count: Int { tabs.count }
    public var isEmpty: Bool { tabs.isEmpty }

    /// The currently selected tab, or nil when empty.
    public var selected: Element? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    public func contains(_ id: Element.ID) -> Bool {
        tabs.contains { $0.id == id }
    }

    public func index(of id: Element.ID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    public func tab(_ id: Element.ID) -> Element? {
        tabs.first { $0.id == id }
    }

    /// Appends a tab. When `select` is true (the default) it becomes the
    /// selection; the first-ever tab is always selected regardless.
    public mutating func append(_ element: Element, select: Bool = true) {
        tabs.append(element)
        if select || selectedID == nil { selectedID = element.id }
    }

    /// Selects `id` if present; a no-op for an unknown id.
    public mutating func select(_ id: Element.ID) {
        guard contains(id) else { return }
        selectedID = id
    }

    /// Removes the tab with `id`, returning it so the caller can tear it down.
    /// When the *selected* tab is removed, selection moves to the tab that
    /// slid into its slot, else the new last tab, else nil (now empty).
    /// Removing a non-selected tab leaves the selection untouched.
    @discardableResult
    public mutating func close(_ id: Element.ID) -> Element? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)
        if selectedID == id {
            if tabs.isEmpty {
                selectedID = nil
            } else {
                selectedID = tabs[Swift.min(index, tabs.count - 1)].id
            }
        }
        return removed
    }

    /// Moves the tab at `from` to land at `to` (both clamped), preserving which
    /// tab is selected. Out-of-range `from` is a no-op.
    public mutating func move(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let element = tabs.remove(at: from)
        let clamped = Swift.max(0, Swift.min(to, tabs.count))
        tabs.insert(element, at: clamped)
    }
}
