import Foundation

public enum ConnectionStoreError: Error, Equatable {
    /// The file on disk was written by a newer Ferry — refuse to load (and
    /// thus overwrite) rather than corrupt it. The user must update the app.
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// Loads and saves the ConnectionLibrary as JSON. Stateless by design — the
/// view model owns the in-memory library; this type only touches disk.
/// The file carries NO secrets (CLAUDE.md rule 6): credentials belong to
/// CredentialVault/Keychain (M3).
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Production location: ~/Library/Application Support/Ferry/connections.json
    /// (inside the container when sandboxed — correct in both distributions).
    public static func `default`() throws -> ConnectionStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        return ConnectionStore(fileURL: support
            .appendingPathComponent("Ferry", isDirectory: true)
            .appendingPathComponent("connections.json"))
    }

    /// Missing file ⇒ a fresh empty library (first launch).
    public func load() throws -> ConnectionLibrary {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ConnectionLibrary()
        }

        // Probe the version first so a future schema fails with a precise
        // error instead of a generic decoding failure. Migrations from
        // OLDER versions hook in here when schemaVersion grows past 1.
        let probe = try Self.decoder.decode(SchemaProbe.self, from: data)
        guard probe.schemaVersion <= ConnectionLibrary.currentSchemaVersion else {
            throw ConnectionStoreError.unsupportedSchemaVersion(
                found: probe.schemaVersion,
                supported: ConnectionLibrary.currentSchemaVersion)
        }
        return try Self.decoder.decode(ConnectionLibrary.self, from: data)
    }

    /// Atomic write (temp file + rename) so a crash mid-save can never
    /// truncate the user's connection tree. Creates the directory if needed.
    public func save(_ library: ConnectionLibrary) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try Self.encoder.encode(library)
        try data.write(to: fileURL, options: .atomic)
    }

    private struct SchemaProbe: Codable { let schemaVersion: Int }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Stable, diffable output — connections.json may end up in user backups.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
