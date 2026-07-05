import Foundation

/// A saved connection. Carries NO secrets — passwords and passphrases are
/// Keychain items keyed by `id` (DOMAIN.md → Credential policy). Deleting a
/// profile must also delete its Keychain items (CredentialVault, M3).
public struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var scheme: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthenticationMethod

    /// Directory each pane opens on connect; nil = server default / user home.
    public var remoteStartPath: String?
    public var localStartPath: String?

    /// Protocol-level no-ops every 30 s + auto-reconnect (DOMAIN.md).
    public var keepAlive: Bool
    public var tunnels: [TunnelConfiguration]

    /// UI restoration state — updated on disconnect, not user-edited.
    public var lastLocalPath: String?
    public var lastRemotePath: String?

    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                scheme: TransferProtocol,
                host: String,
                port: Int? = nil,
                username: String,
                authMethod: AuthenticationMethod = .password,
                remoteStartPath: String? = nil,
                localStartPath: String? = nil,
                keepAlive: Bool = true,
                tunnels: [TunnelConfiguration] = [],
                lastLocalPath: String? = nil,
                lastRemotePath: String? = nil,
                createdAt: Date = Date(),
                modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.port = port ?? scheme.defaultPort
        self.username = username
        self.authMethod = authMethod
        self.remoteStartPath = remoteStartPath
        self.localStartPath = localStartPath
        self.keepAlive = keepAlive
        self.tunnels = tunnels
        self.lastLocalPath = lastLocalPath
        self.lastRemotePath = lastRemotePath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
