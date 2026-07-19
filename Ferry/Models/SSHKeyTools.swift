import Foundation
import FerryCore

/// Read + (Direct-only) manage the user's `~/.ssh` keys for Settings ▸ Keys
/// (M16). Listing is read-only and works in both builds — though the App Store
/// sandbox resolves an empty `~/.ssh` (like the M11 known_hosts/config
/// features, ADR-017), so the list is simply empty there. Generation and
/// import shell out / write into `~/.ssh` and are therefore Direct-only.
enum SSHKeyTools {
    struct KeyEntry: Identifiable, Hashable {
        var id: String { path }
        let name: String
        /// Human label from the public key's algorithm (`ED25519`, `RSA`, …).
        let type: String
        /// Path to the private key (the `.pub` sibling minus the extension).
        let path: String
    }

    static var sshDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// One entry per `*.pub` found in `~/.ssh` (a public key implies a keypair).
    /// Parses the algorithm from the first field; never reads private-key bytes.
    static func listKeys() -> [KeyEntry] {
        let dir = sshDirectoryURL
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".pub") }.sorted().compactMap { pub in
            let pubURL = dir.appendingPathComponent(pub)
            let name = String(pub.dropLast(4))
            let type = (try? String(contentsOf: pubURL, encoding: .utf8))
                .flatMap(algorithmLabel(fromPublicKey:)) ?? "SSH key"
            return KeyEntry(name: name, type: type, path: dir.appendingPathComponent(name).path)
        }
    }

    /// "`ssh-ed25519 AAAA… comment`" → "ED25519". Best-effort display only.
    static func algorithmLabel(fromPublicKey text: String) -> String? {
        guard let first = text.split(separator: " ").first else { return nil }
        switch first {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa": return "RSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521": return "ECDSA"
        case "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com": return "Security key"
        default: return String(first)
        }
    }

    #if !APPSTORE
    enum KeyType: String, CaseIterable, Identifiable {
        case ed25519, rsa
        var id: String { rawValue }
        var displayName: String { self == .ed25519 ? "Ed25519 (recommended)" : "RSA 4096" }
    }

    enum ToolError: LocalizedError {
        case alreadyExists(String)
        case keygenFailed(String)
        case notAPrivateKey
        var errorDescription: String? {
            switch self {
            case .alreadyExists(let name): return "A key named “\(name)” already exists in ~/.ssh."
            case .keygenFailed(let detail): return detail.isEmpty ? "ssh-keygen failed." : detail
            case .notAPrivateKey: return "That file doesn’t look like an OpenSSH or PEM private key."
            }
        }
    }

    /// Generates a new keypair in `~/.ssh` via the system `ssh-keygen` (Direct
    /// builds only — the sandbox blocks both the process launch and the write).
    /// The passphrase, if any, is passed via `-N` and never stored by Ferry.
    static func generate(name: String, type: KeyType, passphrase: String, comment: String) throws {
        let dir = sshDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: keyURL.path) else {
            throw ToolError.alreadyExists(name)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var args = ["-t", type.rawValue]
        if type == .rsa { args += ["-b", "4096"] }
        args += ["-f", keyURL.path, "-N", passphrase, "-C", comment, "-q"]
        process.arguments = args
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ToolError.keygenFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Copies an existing private key (and its `.pub`, if present) into
    /// `~/.ssh` after a light header sanity check (Direct builds only).
    static func importKey(from url: URL) throws {
        let bytes = try Data(contentsOf: url)
        guard let head = String(data: bytes.prefix(64), encoding: .utf8),
              head.contains("PRIVATE KEY") else {
            throw ToolError.notAPrivateKey
        }
        let dir = sshDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.alreadyExists(url.lastPathComponent)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        // Bring the public half along if it sits next to the private key.
        let pub = url.appendingPathExtension("pub")
        if FileManager.default.fileExists(atPath: pub.path) {
            let pubDestination = dir.appendingPathComponent(pub.lastPathComponent)
            if !FileManager.default.fileExists(atPath: pubDestination.path) {
                try? FileManager.default.copyItem(at: pub, to: pubDestination)
            }
        }
    }
    #endif
}
