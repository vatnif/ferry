import Crypto
import Foundation
import NIOSSH

/// A server's SSH host key, in the forms the UI and the store need: a
/// human-readable algorithm label, the OpenSSH SHA256 fingerprint shown in
/// screen 3, and the OpenSSH one-line encoding used as the storage/transfer
/// currency (so the app layer never has to touch NIOSSH types). Value type —
/// safe to hand across the actor boundary and into SwiftUI.
public struct HostKeyInfo: Sendable, Equatable, Hashable, Identifiable {
    /// Display label, e.g. "ED25519", "RSA", "ECDSA".
    public let algorithm: String
    /// OpenSSH key-type prefix, e.g. "ssh-ed25519".
    public let keyType: String
    /// OpenSSH-style fingerprint: "SHA256:<base64, no padding>".
    public let sha256: String
    /// OpenSSH one-line public key: "<keyType> <base64>" (no comment).
    public let openSSH: String

    public var id: String { openSSH }

    /// As rendered in the fingerprint box on screen 3: "ED25519 · SHA256:…".
    public var displayFingerprint: String { "\(algorithm) · \(sha256)" }

    public init(algorithm: String, keyType: String, sha256: String, openSSH: String) {
        self.algorithm = algorithm
        self.keyType = keyType
        self.sha256 = sha256
        self.openSSH = openSSH
    }

    /// Derives all forms from a live NIOSSH host key. The SHA256 fingerprint
    /// is computed exactly as OpenSSH does: SHA-256 over the raw (base64-decoded)
    /// public-key blob, base64-encoded without trailing '=' padding.
    public init(publicKey: NIOSSHPublicKey) {
        let line = String(openSSHPublicKey: publicKey) // "<type> <base64>"
        self = HostKeyInfo(openSSHLine: line) ?? Self.fallback(line: line)
    }

    /// Builds from an OpenSSH one-line encoding ("<type> <base64> [comment]").
    /// Returns nil if the line is not a parseable OpenSSH public key.
    public init?(openSSHLine line: String) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        let keyType = String(fields[0])
        let base64 = String(fields[1])
        guard let blob = Data(base64Encoded: base64) else { return nil }

        let digest = SHA256.hash(data: blob)
        let fingerprint = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")

        self.init(algorithm: Self.algorithmLabel(for: keyType),
                  keyType: keyType,
                  sha256: "SHA256:\(fingerprint)",
                  openSSH: "\(keyType) \(base64)")
    }

    /// Last resort if NIOSSH ever hands us an encoding we can't split — keeps
    /// the raw line usable rather than crashing. Never expected in practice.
    private static func fallback(line: String) -> HostKeyInfo {
        HostKeyInfo(algorithm: "UNKNOWN", keyType: "", sha256: "SHA256:?", openSSH: line)
    }

    private static func algorithmLabel(for keyType: String) -> String {
        switch keyType {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa": return "RSA"
        case "ssh-dss": return "DSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return "ECDSA"
        default:
            return keyType.uppercased()
        }
    }
}
