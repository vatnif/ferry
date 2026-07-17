import Crypto
import Foundation
import NIOSSH

/// A **read-only** view over an OpenSSH `known_hosts` file — Ferry reads the
/// user's `~/.ssh/known_hosts` to *pre-trust* hosts they already know, so the
/// TOFU prompt only fires for genuinely new endpoints (DOMAIN.md → Host key
/// trust, M11 checkpoint B). Ferry never writes this file; its own trust
/// decisions go to `HostKeyStore` (a separate, plaintext-only file).
///
/// Parses both entry styles OpenSSH emits:
/// - **plaintext** host specs: `host`, `[host]:port`, or a comma-separated list;
/// - **hashed** specs: `|1|<base64 salt>|<base64 HMAC-SHA1>` — matched by
///   recomputing `HMAC-SHA1(key: salt, message: hostspec)` (the format
///   `ssh-keygen -H` and `HashKnownHosts yes` produce).
///
/// `@cert-authority` / `@revoked` markered lines and comments are skipped.
/// Value type (parsed entries are `Sendable`), so it can ride in
/// `SFTPSource.Parameters` and re-validate identically on auto-reconnect.
public struct KnownHostsFile: Sendable {
    private let entries: [Entry]

    /// Parses `known_hosts` text. Unparseable lines are ignored, not fatal —
    /// a hand-edited file with one bad line still pre-trusts everything else.
    public init(text: String) {
        entries = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { Entry(rawLine: String($0)) }
    }

    /// Reads the file at `url`; an unreadable/absent file yields an empty view
    /// (no pre-trust, TOFU behaves exactly as before — the safe fallback).
    public init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// True when the file held no usable entries (absent, empty, all comments).
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Reads (mirror HostKeyStore's read API)

    /// Keys this file already trusts for the endpoint — merged into the TOFU
    /// validator's trusted set by `SFTPSource`.
    func trustedKeys(host: String, port: Int) -> Set<NIOSSHPublicKey> {
        let spec = HostKeyStore.hostSpec(host: host, port: port)
        var keys = Set<NIOSSHPublicKey>()
        for entry in entries where entry.matches(spec) {
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: entry.openSSH) {
                keys.insert(key)
            }
        }
        return keys
    }

    /// Fingerprints recorded for the endpoint — folded into the changed-key
    /// alarm's "was" set so a system-known host offering a new key is correctly
    /// classified as CHANGED rather than unknown.
    public func storedInfos(host: String, port: Int) -> [HostKeyInfo] {
        let spec = HostKeyStore.hostSpec(host: host, port: port)
        return entries
            .filter { $0.matches(spec) }
            .compactMap { HostKeyInfo(openSSHLine: $0.openSSH) }
    }

    public func contains(host: String, port: Int) -> Bool {
        !storedInfos(host: host, port: port).isEmpty
    }

    // MARK: Line model

    /// One parsed `known_hosts` line, matched either by literal host spec or by
    /// the hashed HMAC-SHA1 scheme.
    private struct Entry: Sendable {
        enum Match: Sendable {
            case plain([String])                    // lowercased host specs
            case hashed(salt: Data, digest: Data)   // |1|salt|hash
        }
        let match: Match
        let openSSH: String // "<keytype> <base64>"

        init?(rawLine: String) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip blanks, comments, and @cert-authority / @revoked markers —
            // Ferry pre-trusts concrete host→key lines only.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@") else {
                return nil
            }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3 else { return nil }
            self.openSSH = "\(fields[1]) \(fields[2])"

            let hostField = String(fields[0])
            if hostField.hasPrefix("|1|") {
                // |1|<base64 salt>|<base64 hash> → ["", "1", salt, hash]
                let parts = hostField.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 4,
                      let salt = Data(base64Encoded: String(parts[2])),
                      let digest = Data(base64Encoded: String(parts[3])) else { return nil }
                self.match = .hashed(salt: salt, digest: digest)
            } else {
                self.match = .plain(hostField.split(separator: ",").map { $0.lowercased() })
            }
        }

        func matches(_ spec: String) -> Bool {
            switch match {
            case .plain(let specs):
                return specs.contains(spec.lowercased())
            case .hashed(let salt, let digest):
                // OpenSSH hashes the host spec exactly as it would key a
                // plaintext entry (bare host at :22, "[host]:port" otherwise).
                let mac = HMAC<Insecure.SHA1>.authenticationCode(
                    for: Data(spec.utf8),
                    using: SymmetricKey(data: salt))
                return Data(mac) == digest
            }
        }
    }
}
