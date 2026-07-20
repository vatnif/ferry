import Foundation

/// Ferry's own trust anchor for FTPS self-signed / private-CA certificates —
/// the TLS analog of `HostKeyStore` (DOMAIN.md → FTP/FTPS, ADR-033). When a
/// server's certificate does not chain to a system-trusted root, the user is
/// shown its fingerprint and can trust it; that decision is recorded here and
/// re-applied identically on every later connect and on supervised auto-reconnect
/// (pinned by SHA-256), so trust can never be silently downgraded.
///
/// Persisted as a small JSON file at
/// `~/Library/Application Support/Ferry/trusted_certs.json` (inside the container
/// when sandboxed — correct in both distributions). Keyed by `host:port`: an
/// endpoint trusts exactly one certificate (unlike SSH, where a host may offer
/// several key types). A certificate is public information, never a secret
/// (rule 6) — only its fingerprint + display fields are stored, no private
/// material is ever involved.
///
/// Stateless persister (mirrors ConnectionStore / HostKeyStore): the file is the
/// single source of truth, so a trust decision made in one place is seen
/// everywhere.
public struct CertificateTrustStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Production location, alongside connections.json and known_hosts.
    public static func `default`() throws -> CertificateTrustStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        return CertificateTrustStore(fileURL: support
            .appendingPathComponent("Ferry", isDirectory: true)
            .appendingPathComponent("trusted_certs.json"))
    }

    // MARK: - Reads

    /// The certificate Ferry currently trusts for this endpoint, or nil for
    /// first contact. Used to build the pin handed to `FTPSource.connect`.
    public func trustedCertificate(host: String, port: Int) throws -> CertificateInfo? {
        try load().certificates[Self.key(host: host, port: port)]
    }

    /// 0 or 1 stored certificate for the endpoint — array-shaped to mirror
    /// `HostKeyStore.storedInfos`, for the "was → now" changed-cert comparison.
    public func storedInfos(host: String, port: Int) throws -> [CertificateInfo] {
        try trustedCertificate(host: host, port: port).map { [$0] } ?? []
    }

    public func contains(host: String, port: Int) throws -> Bool {
        try trustedCertificate(host: host, port: port) != nil
    }

    /// One trusted endpoint for the Settings ▸ Keys "Manage trusted certificates"
    /// list — the parsed host/port plus the certificate it trusts.
    public struct TrustedCertificate: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public let host: String
        public let port: Int
        public let certificate: CertificateInfo
        /// `host` for port 21, else `host:port` — for display.
        public var endpoint: String { port == 21 ? host : "\(host):\(port)" }
    }

    /// Every trusted endpoint, for the management UI, sorted by endpoint.
    public func allTrustedCertificates() throws -> [TrustedCertificate] {
        try load().certificates.compactMap { key, info in
            guard let (host, port) = Self.parseKey(key) else { return nil }
            return TrustedCertificate(host: host, port: port, certificate: info)
        }
        .sorted { ($0.endpoint, $0.certificate.sha256) < ($1.endpoint, $1.certificate.sha256) }
    }

    // MARK: - Writes (driven by the user's trust decisions)

    /// Records a newly trusted certificate for the endpoint (first-contact
    /// "Trust & Connect"). Idempotent; overwrites any prior entry for the
    /// endpoint (the changed-cert path routes through `replace`, but both upsert).
    public func trust(_ info: CertificateInfo, host: String, port: Int) throws {
        var file = try load()
        file.certificates[Self.key(host: host, port: port)] = info
        try save(file)
    }

    /// Replaces the trusted certificate for the endpoint (changed-cert alarm →
    /// "Replace Certificate & Connect"). No silent path reaches here — the UI
    /// gates it behind a second confirmation.
    public func replace(with info: CertificateInfo, host: String, port: Int) throws {
        try trust(info, host: host, port: port)
    }

    /// Drops the trusted certificate for the endpoint.
    public func remove(host: String, port: Int) throws {
        var file = try load()
        file.certificates.removeValue(forKey: Self.key(host: host, port: port))
        try save(file)
    }

    // MARK: - File model & IO

    private struct StoreFile: Codable {
        var version: Int = 1
        var certificates: [String: CertificateInfo] = [:]
    }

    private func load() throws -> StoreFile {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return StoreFile() }
        // A corrupt/foreign file must not wedge trust: start clean rather than
        // throw (the next trust decision rewrites it). Certs aren't secrets, so
        // there is nothing to lose but re-prompting.
        return (try? JSONDecoder().decode(StoreFile.self, from: data)) ?? StoreFile()
    }

    private func save(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    // MARK: - Keying

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Inverse of `key`: "host:port" → (host, port). Tolerates IPv6 literals by
    /// splitting on the last colon.
    static func parseKey(_ key: String) -> (host: String, port: Int)? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        let host = String(key[key.startIndex..<colon])
        guard let port = Int(key[key.index(after: colon)...]), !host.isEmpty else { return nil }
        return (host, port)
    }
}
