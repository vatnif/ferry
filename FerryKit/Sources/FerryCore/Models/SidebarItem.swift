import Foundation

/// One node of the connection-manager tree (mockup screen 1 sidebar):
/// either a folder (which nests further items, any depth) or a profile.
public enum SidebarItem: Identifiable, Hashable, Sendable {
    case folder(ProfileFolder)
    case profile(ConnectionProfile)

    public var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .profile(let profile): profile.id
        }
    }

    public var name: String {
        switch self {
        case .folder(let folder): folder.name
        case .profile(let profile): profile.name
        }
    }
}

/// A user-created organizational folder. Order of `items` is the display
/// order (drag-to-reorganize persists here).
public struct ProfileFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isExpanded: Bool
    public var items: [SidebarItem]

    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true, items: [SidebarItem] = []) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.items = items
    }
}

// Hand-written Codable: persists a clean discriminator
// ({"type":"folder",...} / {"type":"profile",...}) instead of the synthesized
// "_0" shape — connections.json is a long-lived schema (DOMAIN.md).
extension SidebarItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, folder, profile }
    private enum Discriminator: String, Codable { case folder, profile }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .folder:
            self = .folder(try container.decode(ProfileFolder.self, forKey: .folder))
        case .profile:
            self = .profile(try container.decode(ConnectionProfile.self, forKey: .profile))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try container.encode(Discriminator.folder, forKey: .type)
            try container.encode(folder, forKey: .folder)
        case .profile(let profile):
            try container.encode(Discriminator.profile, forKey: .type)
            try container.encode(profile, forKey: .profile)
        }
    }
}
