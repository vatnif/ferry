import Foundation

/// A saved port forward on a connection profile (mockup screen 4).
/// The live TunnelEngine arrives in M14; the schema is fixed now so
/// profiles don't need migrating later.
public struct TunnelConfiguration: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Listen locally, forward to a destination reachable from the server.
        case local
        /// Listen on the server, forward to a destination reachable locally.
        case remote
        /// Dynamic SOCKS proxy listening locally; no fixed destination.
        case socks
    }

    public var id: UUID
    public var kind: Kind
    public var listenHost: String
    public var listenPort: Int
    /// nil for .socks (dynamic destination).
    public var destinationHost: String?
    public var destinationPort: Int?
    /// Whether the tunnel participates in "start automatically on connect".
    public var isEnabled: Bool

    public init(id: UUID = UUID(),
                kind: Kind,
                listenHost: String = "127.0.0.1",
                listenPort: Int,
                destinationHost: String? = nil,
                destinationPort: Int? = nil,
                isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.isEnabled = isEnabled
    }
}
