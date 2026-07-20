import Foundation

public enum ConnectionExportError: Error, Equatable {
    /// The file isn't a Ferry connections export (wrong or missing `format` tag).
    case notAFerryExport
    /// Written by a newer Ferry — refuse rather than import a shape we can't read.
    case unsupportedFormatVersion(found: Int, supported: Int)
    /// The bytes weren't valid JSON / decodable.
    case corrupted(String)
}

/// One profile lifted from an import source, ready to add to the library: the
/// connection plus the ancestor folder names it should be nested under. Shared
/// by the Ferry-export importer (M20 checkpoint B) and the competitor importers
/// (checkpoint A map their `ImportedConnection` onto this).
public struct ImportEntry: Sendable, Hashable {
    public let profile: ConnectionProfile
    public let folderPath: [String]

    public init(profile: ConnectionProfile, folderPath: [String] = []) {
        self.profile = profile
        self.folderPath = folderPath
    }
}

/// Ferry's own portable connection format (M20 checkpoint B, ADR-032): a
/// self-describing, versioned envelope around a secret-free slice of the
/// connection tree. Reuses `ConnectionStore`'s JSON conventions (ISO-8601 dates,
/// stable sorted keys) so exports diff cleanly and back up well.
///
/// Carries **no secrets** (rule 6) — `ConnectionProfile`/`ProfileFolder` hold
/// none by construction; passwords and key passphrases stay in the Keychain and
/// are prompted on first connect after an import.
public struct ConnectionExport: Codable, Sendable, Equatable {
    /// Bumped only on an incompatible change to the exported shape.
    public static let currentFormatVersion = 1
    /// Identifies the file as a Ferry export (guards import against arbitrary JSON).
    public static let formatIdentifier = "com.gfragos.ferry.connections"

    public var format: String
    public var formatVersion: Int
    /// App/kit version that produced the file (informational).
    public var generator: String?
    public var exportedAt: Date?
    /// The exported items, in display order, secret-free.
    public var items: [SidebarItem]

    public init(items: [SidebarItem],
                generator: String? = nil,
                exportedAt: Date? = nil) {
        self.format = Self.formatIdentifier
        self.formatVersion = Self.currentFormatVersion
        self.generator = generator
        self.exportedAt = exportedAt
        self.items = items
    }
}

public extension ConnectionExport {
    /// Serializes a slice of the tree as an export document. The caller passes
    /// the chosen items; `sanitized` strips machine-specific UI-restoration state.
    static func encode(items: [SidebarItem],
                       generator: String? = nil,
                       exportedAt: Date? = nil) throws -> Data {
        let export = ConnectionExport(items: sanitized(items),
                                      generator: generator,
                                      exportedAt: exportedAt)
        return try encoder.encode(export)
    }

    /// Decodes and validates an export document. Throws a typed
    /// `ConnectionExportError` for a non-Ferry file or a future format version.
    static func decode(_ data: Data) throws -> ConnectionExport {
        let export: ConnectionExport
        do {
            export = try decoder.decode(ConnectionExport.self, from: data)
        } catch {
            throw ConnectionExportError.corrupted(error.localizedDescription)
        }
        guard export.format == formatIdentifier else {
            throw ConnectionExportError.notAFerryExport
        }
        guard export.formatVersion <= currentFormatVersion else {
            throw ConnectionExportError.unsupportedFormatVersion(
                found: export.formatVersion, supported: currentFormatVersion)
        }
        return export
    }

    /// Strips per-machine UI-restoration state (`lastLocalPath`/`lastRemotePath`)
    /// so an export doesn't carry one Mac's last-used directories to another.
    /// Everything else — including `localStartPath`/`remoteStartPath` the user
    /// configured — is preserved.
    static func sanitized(_ items: [SidebarItem]) -> [SidebarItem] {
        items.map(sanitize)
    }

    private static func sanitize(_ item: SidebarItem) -> SidebarItem {
        switch item {
        case .profile(var profile):
            profile.lastLocalPath = nil
            profile.lastRemotePath = nil
            return .profile(profile)
        case .folder(var folder):
            folder.items = folder.items.map(sanitize)
            return .folder(folder)
        }
    }

    /// Flattens a tree into importable entries (depth-first, display order),
    /// each carrying the ancestor folder names so the structure can be rebuilt.
    static func flatten(_ items: [SidebarItem]) -> [ImportEntry] {
        flatten(items, path: [])
    }

    private static func flatten(_ items: [SidebarItem], path: [String]) -> [ImportEntry] {
        items.flatMap { item -> [ImportEntry] in
            switch item {
            case .profile(let profile):
                return [ImportEntry(profile: profile, folderPath: path)]
            case .folder(let folder):
                return flatten(folder.items, path: path + [folder.name])
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
