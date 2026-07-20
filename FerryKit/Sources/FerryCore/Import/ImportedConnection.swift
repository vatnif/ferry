import Foundation

/// A connection lifted from another client's saved-sites file (M20 checkpoint A,
/// ADR-031), reduced to the fields a Ferry profile needs. Value type; carries
/// **no secrets** (CLAUDE.md rule 6) — passwords/passphrases are prompted on
/// first connect per the credential policy.
///
/// Shared by the FileZilla (`sitemanager.xml`), Cyberduck (`.duck` bookmark
/// plist), and WinSCP (`WinSCP.ini`) importers, all of which present it through
/// the same import checklist (`ProfileImportSheet`). M11's `~/.ssh/config`
/// importer keeps its own `ImportedSSHHost` — deliberately not unified, to avoid
/// disturbing tested code (ADR-031).
public struct ImportedConnection: Identifiable, Sendable, Hashable {
    public let id = UUID()
    /// Display name (the site/bookmark/session nickname) — also the profile name.
    public let name: String
    public let scheme: TransferProtocol
    public let host: String
    public let port: Int
    /// `nil` ⇒ fall back to the local login name on import (never an empty user,
    /// which would fail auth confusingly — matching `ImportedSSHHost`).
    public let user: String?
    /// A private-key path ⇒ public-key auth; `nil` ⇒ password. Only set for
    /// SSH-based schemes (SFTP/SCP); FTP variants are password-only.
    public let identityFile: String?
    /// Ancestor folder names from the source app's tree (outermost first);
    /// empty ⇒ directly under the import folder. Rebuilt as nested folders on
    /// import so the user's organisation survives (ADR-031).
    public let folderPath: [String]

    public init(name: String,
                scheme: TransferProtocol,
                host: String,
                port: Int,
                user: String?,
                identityFile: String? = nil,
                folderPath: [String] = []) {
        self.name = name
        self.scheme = scheme
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.folderPath = folderPath
    }

    /// A summary for the import checklist: `user@host:port`.
    public var endpointSummary: String {
        let account = user.map { "\($0)@" } ?? ""
        return "\(account)\(host):\(port)"
    }

    /// Human-readable source folder path (`Parent / Child`), or "" at top level.
    public var folderPathDisplay: String { folderPath.joined(separator: " / ") }

    /// Maps to a saved connection. A block without a user falls back to the
    /// local login name (matching OpenSSH/`ImportedSSHHost`); an `identityFile`
    /// becomes public-key auth (the passphrase, if any, is prompted/stored later
    /// per the credential policy — never read from the source file).
    public func makeProfile() -> ConnectionProfile {
        ConnectionProfile(
            name: name,
            scheme: scheme,
            host: host,
            port: port,
            username: user ?? NSUserName(),
            authMethod: identityFile.map { .publicKey(privateKeyPath: $0) } ?? .password)
    }
}
