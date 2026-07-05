import Foundation

/// Root of the persisted connection tree. A value type — the view model owns
/// the current instance; ConnectionStore persists it.
public struct ConnectionLibrary: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Top-level items in display order (folders and loose profiles mix freely).
    public var items: [SidebarItem]

    public init(schemaVersion: Int = ConnectionLibrary.currentSchemaVersion,
                items: [SidebarItem] = []) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}

// MARK: - Queries

public extension ConnectionLibrary {
    /// All profiles in the tree, depth-first in display order.
    var allProfiles: [ConnectionProfile] {
        Self.collectProfiles(in: items)
    }

    func profile(withID id: UUID) -> ConnectionProfile? {
        allProfiles.first { $0.id == id }
    }

    func folder(withID id: UUID) -> ProfileFolder? {
        Self.findFolder(id: id, in: items)
    }

    func contains(itemID: UUID) -> Bool {
        Self.findItem(id: itemID, in: items) != nil
    }

    /// The folder directly containing the item, or nil when the item sits at
    /// the root (or doesn't exist — disambiguate with `contains(itemID:)`).
    func parentFolderID(ofItem id: UUID) -> UUID? {
        Self.findParent(of: id, in: items, currentParent: nil)
    }

    /// All folders, depth-first in display order — feeds the "Save in folder"
    /// picker and "Move to" menus.
    var allFolders: [ProfileFolder] {
        Self.collectFolders(in: items)
    }

    private static func findParent(of id: UUID, in items: [SidebarItem], currentParent: UUID?) -> UUID? {
        for item in items {
            if item.id == id { return currentParent }
            if case .folder(let folder) = item,
               let found = findParent(of: id, in: folder.items, currentParent: folder.id) {
                return found
            }
        }
        return nil
    }

    private static func collectFolders(in items: [SidebarItem]) -> [ProfileFolder] {
        items.flatMap { item -> [ProfileFolder] in
            guard case .folder(let folder) = item else { return [] }
            return [folder] + collectFolders(in: folder.items)
        }
    }

    private static func collectProfiles(in items: [SidebarItem]) -> [ConnectionProfile] {
        items.flatMap { item -> [ConnectionProfile] in
            switch item {
            case .profile(let profile): [profile]
            case .folder(let folder): collectProfiles(in: folder.items)
            }
        }
    }

    private static func findFolder(id: UUID, in items: [SidebarItem]) -> ProfileFolder? {
        for item in items {
            guard case .folder(let folder) = item else { continue }
            if folder.id == id { return folder }
            if let nested = findFolder(id: id, in: folder.items) { return nested }
        }
        return nil
    }

    private static func findItem(id: UUID, in items: [SidebarItem]) -> SidebarItem? {
        for item in items {
            if item.id == id { return item }
            if case .folder(let folder) = item,
               let nested = findItem(id: id, in: folder.items) { return nested }
        }
        return nil
    }
}

// MARK: - Mutations (all return false / nil when the target doesn't exist)

public extension ConnectionLibrary {
    /// Inserts an item into `folderID` (nil = root) at `index`
    /// (nil / out of range = append).
    @discardableResult
    mutating func add(_ item: SidebarItem, toFolder folderID: UUID? = nil, at index: Int? = nil) -> Bool {
        guard let folderID else {
            items.insert(item, at: clampedIndex(index, count: items.count))
            return true
        }
        return Self.insert(item, intoFolder: folderID, at: index, in: &items)
    }

    /// Removes and returns the item (profile or whole folder subtree).
    @discardableResult
    mutating func removeItem(withID id: UUID) -> SidebarItem? {
        Self.remove(id: id, from: &items)
    }

    /// Replaces an existing profile in place (position unchanged) and bumps
    /// its `modifiedAt`.
    @discardableResult
    mutating func updateProfile(_ profile: ConnectionProfile) -> Bool {
        var updated = profile
        updated.modifiedAt = Date()
        return Self.replaceProfile(updated, in: &items)
    }

    /// Renames a folder in place.
    @discardableResult
    mutating func renameFolder(withID id: UUID, to name: String) -> Bool {
        Self.mutateFolder(id: id, in: &items) { $0.name = name }
    }

    /// Records the expand/collapse UI state.
    @discardableResult
    mutating func setFolderExpanded(withID id: UUID, _ expanded: Bool) -> Bool {
        Self.mutateFolder(id: id, in: &items) { $0.isExpanded = expanded }
    }

    /// Moves an item to a new parent (nil = root) and index. Refuses moving a
    /// folder into itself or its own subtree. On any failure the library is
    /// left unchanged.
    @discardableResult
    mutating func move(itemID: UUID, toFolder folderID: UUID?, at index: Int? = nil) -> Bool {
        guard let item = Self.findItem(id: itemID, in: items) else { return false }
        if let folderID {
            // Target must exist and not be inside the moved subtree.
            guard folder(withID: folderID) != nil else { return false }
            if case .folder(let movedFolder) = item {
                if movedFolder.id == folderID { return false }
                if Self.findFolder(id: folderID, in: movedFolder.items) != nil { return false }
            }
        }
        let snapshot = items
        guard let removed = Self.remove(id: itemID, from: &items) else { return false }
        if add(removed, toFolder: folderID, at: index) { return true }
        items = snapshot
        return false
    }

    private func clampedIndex(_ index: Int?, count: Int) -> Int {
        guard let index else { return count }
        return min(max(index, 0), count)
    }

    private static func insert(_ item: SidebarItem, intoFolder folderID: UUID,
                               at index: Int?, in items: inout [SidebarItem]) -> Bool {
        mutateFolder(id: folderID, in: &items) { folder in
            let end = folder.items.count
            let at = index.map { min(max($0, 0), end) } ?? end
            folder.items.insert(item, at: at)
        }
    }

    private static func remove(id: UUID, from items: inout [SidebarItem]) -> SidebarItem? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            return items.remove(at: index)
        }
        for index in items.indices {
            guard case .folder(var folder) = items[index] else { continue }
            if let removed = remove(id: id, from: &folder.items) {
                items[index] = .folder(folder)
                return removed
            }
        }
        return nil
    }

    private static func replaceProfile(_ profile: ConnectionProfile, in items: inout [SidebarItem]) -> Bool {
        for index in items.indices {
            switch items[index] {
            case .profile(let existing) where existing.id == profile.id:
                items[index] = .profile(profile)
                return true
            case .folder(var folder):
                if replaceProfile(profile, in: &folder.items) {
                    items[index] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    private static func mutateFolder(id: UUID, in items: inout [SidebarItem],
                                     _ mutate: (inout ProfileFolder) -> Void) -> Bool {
        for index in items.indices {
            guard case .folder(var folder) = items[index] else { continue }
            if folder.id == id {
                mutate(&folder)
                items[index] = .folder(folder)
                return true
            }
            if mutateFolder(id: id, in: &folder.items, mutate) {
                items[index] = .folder(folder)
                return true
            }
        }
        return false
    }
}
