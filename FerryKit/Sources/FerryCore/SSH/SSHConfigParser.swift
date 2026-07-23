import Foundation

/// One host parsed from an OpenSSH `~/.ssh/config` `Host` block, reduced to the
/// fields a Ferry connection needs (M11 checkpoint B → Import…). Value type.
public struct ImportedSSHHost: Identifiable, Sendable, Hashable {
    public let id = UUID()
    /// The `Host` alias (the block name) — used as the profile name.
    public let alias: String
    /// `HostName` if present, else the alias itself (OpenSSH's own fallback).
    public let hostName: String
    public let port: Int
    /// `User`, or nil when the config leaves it to the ssh default.
    public let user: String?
    /// `IdentityFile` (tilde-expanded), or nil ⇒ password auth.
    public let identityFile: String?

    /// A summary for the import checklist: `user@host:port`.
    public var endpointSummary: String {
        let account = user.map { "\($0)@" } ?? ""
        return "\(account)\(hostName):\(port)"
    }

    /// Maps to a saved connection. SFTP by default; an `IdentityFile` becomes
    /// public-key auth (the passphrase, if any, is prompted/stored later per the
    /// credential policy — never read from the config). A block without `User`
    /// falls back to the local login name, matching OpenSSH — an empty username
    /// would just fail auth confusingly.
    public func makeProfile() -> ConnectionProfile {
        ConnectionProfile(
            name: alias,
            scheme: .sftp,
            host: hostName,
            port: port,
            username: user ?? NSUserName(),
            authMethod: identityFile.map { .publicKey(privateKeyPath: $0) } ?? .password)
    }
}

/// Parses `~/.ssh/config` into importable hosts. Read-only; Ferry never writes
/// this file. Deliberately narrow — it lifts concrete `Host` blocks into
/// connection profiles, not a full ssh_config evaluator:
///
/// - keywords are case-insensitive, `key value` or `key=value`;
/// - wildcard/negated `Host` patterns (`*`, `?`, `!…`) are skipped — they are
///   defaults, not endpoints;
/// - a `Host` line with several patterns imports under its first concrete one;
/// - `Match` blocks (and any other non-`Host` block) end the current host;
/// - `IdentityFile` is tilde-expanded; `ProxyJump`/`ProxyCommand` are ignored
///   (imported without a tunnel — noted in DECISIONS/DOMAIN).
public enum SSHConfigParser {
    public static func parse(contentsOf url: URL) -> [ImportedSSHHost] {
        parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public static func parse(_ text: String) -> [ImportedSSHHost] {
        var hosts: [ImportedSSHHost] = []
        var current: Builder?

        func flush() {
            if let built = current?.build() { hosts.append(built) }
            current = nil
        }

        // \.isNewline, not "\n": Swift folds CRLF into one Character, so a
        // Windows-copied config would otherwise parse as a single line.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (keyword, value) = splitKeyword(line) else { continue }

            switch keyword.lowercased() {
            case "host":
                flush()
                // First concrete (non-wildcard, non-negated) pattern is the alias.
                let alias = value
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                    .first(where: { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") })
                current = alias.map(Builder.init(alias:))
            case "match":
                // A Match block is not a concrete host — end the current one.
                flush()
            case "hostname":
                current?.hostName = value
            case "port":
                current?.port = Int(value)
            case "user":
                current?.user = value
            case "identityfile":
                current?.identityFile = expandTilde(value)
            default:
                break // ProxyJump/ProxyCommand/etc. — ignored (see doc comment).
            }
        }
        flush()
        return hosts
    }

    // MARK: Line lexing

    /// Splits a line into keyword + value, tolerating every separator OpenSSH
    /// accepts: `keyword value`, `keyword=value`, and `keyword = value`. Returns
    /// nil for a keyword with no value.
    private static func splitKeyword(_ line: String) -> (String, String)? {
        // The keyword runs up to the first whitespace or '='.
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return nil
        }
        let keyword = String(line[line.startIndex..<sep])
        guard !keyword.isEmpty else { return nil }
        // Skip the separator run: any spaces, then an optional single '=', then
        // more spaces — so "key = value" and "key=value" both yield "value".
        var rest = String(line[sep...])
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return rest.isEmpty ? nil : (keyword, dequote(rest))
    }

    private static func dequote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: Block accumulator

    private struct Builder {
        let alias: String
        var hostName: String?
        var port: Int?
        var user: String?
        var identityFile: String?

        init(alias: String) { self.alias = alias }

        func build() -> ImportedSSHHost {
            ImportedSSHHost(alias: alias,
                            hostName: hostName ?? alias,
                            port: port ?? 22,
                            user: user,
                            identityFile: identityFile)
        }
    }
}
