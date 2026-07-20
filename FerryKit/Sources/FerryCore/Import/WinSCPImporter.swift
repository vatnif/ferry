import Foundation

/// Imports connections from an exported **`WinSCP.ini`** (M20 checkpoint A,
/// ADR-031). WinSCP is Windows-only, so there is no macOS install or registry to
/// read — the user exports their sessions (WinSCP ▸ *Export/Backup Configuration*
/// → INI file) and points Ferry at the file. Read-only.
///
/// Each `[Sessions\<name>]` section becomes a connection. The section name is
/// WinSCP-percent-encoded with `/` separating folders, so the hierarchy is
/// preserved: split on `/`, percent-decode each component → last is the name,
/// the rest is `folderPath`.
///
/// **No secrets** (rule 6): the obfuscated `Password` value is never read.
/// Sessions using protocols Ferry can't speak (WebDAV, S3) are skipped, as is
/// the `Default Settings` template.
///
/// Key-auth caveat (surfaced in help/DOMAIN): `PublicKeyFile` points at a PuTTY
/// `.ppk` key, which Ferry's `SSHKeyLoader` cannot load — the path is imported
/// as-is so the user can repoint it at a converted OpenSSH key.
public enum WinSCPImporter {
    public static func parse(contentsOf url: URL) -> [ImportedConnection] {
        parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public static func parse(_ text: String) -> [ImportedConnection] {
        var results: [ImportedConnection] = []
        var currentRawName: String?
        var fields: [String: String] = [:]

        func flush() {
            if let rawName = currentRawName, let connection = build(rawName: rawName, fields: fields) {
                results.append(connection)
            }
            currentRawName = nil
            fields = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                let section = String(line.dropFirst().dropLast())
                // Only session sections; ignore [Configuration\...] etc.
                if let range = section.range(of: "Sessions\\") {
                    currentRawName = String(section[range.upperBound...])
                }
            } else if currentRawName != nil, let eq = line.firstIndex(of: "=") {
                let key = String(line[line.startIndex..<eq])
                let value = String(line[line.index(after: eq)...])
                fields[key] = value
            }
        }
        flush()
        return results
    }

    // MARK: Mapping

    /// WinSCP `TFSProtocol` → Ferry's scheme, upgraded to FTPS when the `Ftps`
    /// TLS flag is set. Absent protocol ⇒ SFTP (WinSCP's default). WebDAV/S3 and
    /// anything unrecognised return nil so the session is skipped.
    static func scheme(fsProtocol: Int?, ftps: Int?) -> TransferProtocol? {
        switch fsProtocol ?? 1 {
        case 0: return .scp                                   // SCP
        case 1, 2: return .sftp                               // SFTP / SFTP-only
        case 5: return (ftps ?? 0) != 0 ? .ftps : .ftp        // FTP, TLS ⇒ FTPS
        default: return nil                                   // 6 WebDAV, 7 S3, …
        }
    }

    /// Decodes a WinSCP-encoded session path into folder components + name.
    /// Folders are separated by literal `/`; each component is percent-decoded
    /// (so an escaped `%2F` inside a name comes back as `/`).
    static func decodePath(_ raw: String) -> (folderPath: [String], name: String)? {
        let components = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { ($0.removingPercentEncoding ?? String($0)) }
            .filter { !$0.isEmpty }
        guard let name = components.last else { return nil }
        return (Array(components.dropLast()), name)
    }

    // MARK: Build

    private static func build(rawName: String, fields: [String: String]) -> ImportedConnection? {
        func value(_ key: String) -> String? {
            fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        guard let host = value("HostName") else { return nil }
        guard let (folderPath, name) = decodePath(rawName) else { return nil }
        // The template session carries defaults, not a real site.
        guard name != "Default Settings" else { return nil }

        let scheme = scheme(fsProtocol: Int(value("FSProtocol") ?? ""),
                            ftps: Int(value("Ftps") ?? ""))
        guard let scheme else { return nil }

        let port = Int(value("PortNumber") ?? "") ?? scheme.defaultPort
        let user = value("UserName")
        let identityFile = scheme.usesSSH ? value("PublicKeyFile") : nil

        return ImportedConnection(name: name, scheme: scheme, host: host, port: port,
                                  user: user, identityFile: identityFile, folderPath: folderPath)
    }
}
