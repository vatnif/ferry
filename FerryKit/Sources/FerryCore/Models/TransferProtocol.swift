import Foundation

/// Wire protocol a connection speaks. Raw values are persisted in
/// connections.json — never rename a case without a schema migration.
public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp
    case ftp
    case ftps
    case scp

    public var defaultPort: Int {
        switch self {
        case .sftp, .scp: 22
        case .ftp: 21
        case .ftps: 990
        }
    }

    /// User-facing name (mockup screen 2 segmented control).
    public var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .scp: "SCP"
        }
    }

    /// SSH-based protocols share session infrastructure and auth options
    /// (key/agent); FTP variants are password-only (DESIGN.md screen 2).
    public var usesSSH: Bool {
        switch self {
        case .sftp, .scp: true
        case .ftp, .ftps: false
        }
    }
}
