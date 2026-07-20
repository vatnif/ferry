import Foundation

/// Imports connections from Cyberduck **bookmarks** — the `.duck` XML property
/// lists in `~/Library/Application Support/Cyberduck/Bookmarks/` (M20 checkpoint
/// A, ADR-031). Read-only; Ferry never writes them.
///
/// Only the Bookmarks folder is read (not History — those are transient
/// recently-visited servers, user decision 2026-07-20). Bookmarks are flat, so
/// imported connections have an empty `folderPath`.
///
/// **No secrets** (rule 6): Cyberduck keeps passwords in the login Keychain, not
/// the bookmark file, so there is nothing secret to skip here — but we still map
/// only the non-secret fields. Providers Ferry can't speak (S3, WebDAV, Backblaze,
/// Google Drive, …) are skipped.
public enum CyberduckImporter {
    /// Parses every `*.duck` bookmark in a directory, sorted by display name.
    public static func parse(bookmarksDirectory url: URL) -> [ImportedConnection] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "duck" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(parse(plistData:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses a single `.duck` plist. Returns nil when the file isn't a bookmark
    /// dictionary or its protocol isn't one Ferry supports.
    public static func parse(plistData data: Data) -> ImportedConnection? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              let host = string(dict["Hostname"])?.nonEmpty else {
            return nil
        }
        guard let scheme = scheme(forProtocol: string(dict["Protocol"]) ?? "") else { return nil }

        let port = Int(string(dict["Port"]) ?? "") ?? scheme.defaultPort
        let name = string(dict["Nickname"])?.nonEmpty ?? host
        let user = string(dict["Username"])?.nonEmpty
        let identityFile = scheme.usesSSH ? string(dict["Private Key File"])?.nonEmpty : nil

        return ImportedConnection(name: name, scheme: scheme, host: host, port: port,
                                  user: user, identityFile: identityFile)
    }

    // MARK: Mapping

    /// Cyberduck protocol identifier → Ferry's scheme. Unknown providers (s3,
    /// dav/davs, googledrive, azure, b2, …) return nil so the bookmark is skipped.
    static func scheme(forProtocol raw: String) -> TransferProtocol? {
        switch raw.lowercased() {
        case "sftp": return .sftp
        case "ftp": return .ftp
        case "ftps", "ftp-ssl": return .ftps
        default: return nil
        }
    }

    /// Reads a plist value as a trimmed string (handles the String and NSNumber
    /// Port representations Cyberduck has used across versions).
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}
