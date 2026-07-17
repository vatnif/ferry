@preconcurrency import Citadel
import Crypto
import Foundation

/// Why a private key file could not be turned into an authentication method.
/// Distinguishes the passphrase cases so the UI can prompt (vs. hard-fail).
public enum SSHKeyLoadError: Error, Equatable {
    /// The key is encrypted and no passphrase was supplied — prompt the user.
    case passphraseRequired
    /// A passphrase was supplied but did not decrypt the key.
    case incorrectPassphrase
    /// A key algorithm Ferry can't load from an OpenSSH file (e.g. ECDSA — see
    /// note below), or a legacy PEM container. `label` is human-readable.
    case unsupportedKeyType(label: String)
    /// The bytes are not a recognizable OpenSSH private key.
    case malformed(reason: String)
}

/// Turns a private-key file's bytes into a Citadel `SSHAuthenticationMethod`.
///
/// The app layer reads the file (handling sandbox / security-scoped access)
/// and hands the bytes here; parsing — including the bcrypt-KDF passphrase
/// decrypt — happens in FerryCore. Supported: OpenSSH-format (`-----BEGIN
/// OPENSSH PRIVATE KEY-----`) **ed25519** and **RSA** keys, encrypted or not
/// (Citadel handles aes*-ctr + bcrypt). ECDSA is rejected with a clear error:
/// Citadel has OpenSSH private-key parsers only for ed25519 and RSA (ADR-017).
enum SSHKeyLoader {
    static func authenticationMethod(username: String,
                                     pem: Data,
                                     passphrase: String?) throws -> SSHAuthenticationMethod {
        guard let text = String(data: pem, encoding: .utf8) else {
            throw SSHKeyLoadError.malformed(reason: "not UTF-8 text")
        }
        let header = try parseHeader(pem: pem, text: text)
        let decryptionKey = passphrase.flatMap { $0.data(using: .utf8) }

        do {
            switch header.keyType {
            case "ssh-ed25519":
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: text,
                                                            decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)
            case "ssh-rsa":
                let key = try Insecure.RSA.PrivateKey(sshRsa: text,
                                                      decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)
            default:
                throw SSHKeyLoadError.unsupportedKeyType(label: displayLabel(header.keyType))
            }
        } catch let error as SSHKeyLoadError {
            throw error
        } catch {
            // Citadel surfaces decrypt failures through several internal error
            // types; classify by what we already know about the container
            // rather than matching them one by one.
            if header.isEncrypted {
                throw passphrase == nil ? SSHKeyLoadError.passphraseRequired
                                        : SSHKeyLoadError.incorrectPassphrase
            }
            throw SSHKeyLoadError.malformed(reason: String(describing: error))
        }
    }

    /// True if the key is encrypted (would need a passphrase). Lets the app
    /// decide whether to prompt before attempting a load.
    static func isEncrypted(pem: Data) throws -> Bool {
        guard let text = String(data: pem, encoding: .utf8) else {
            throw SSHKeyLoadError.malformed(reason: "not UTF-8 text")
        }
        return try parseHeader(pem: pem, text: text).isEncrypted
    }

    // MARK: OpenSSH envelope parsing

    private struct Header {
        let keyType: String   // "ssh-ed25519", "ssh-rsa", "ecdsa-…"
        let isEncrypted: Bool // cipher name != "none"
    }

    private static let authMagic = Array("openssh-key-v1\0".utf8)

    /// Reads just enough of the (unencrypted) OpenSSH v1 header to learn the
    /// cipher name and the embedded key type — the public-key section is never
    /// encrypted, so this works without a passphrase.
    private static func parseHeader(pem: Data, text: String) throws -> Header {
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else {
            // Legacy PEM (`BEGIN RSA/EC/PRIVATE KEY`) isn't the openssh-key-v1
            // container Citadel parses. Point the user at conversion.
            let label = text.contains("PRIVATE KEY")
                ? "a legacy PEM key (convert with: ssh-keygen -p -o -f <key>)"
                : "an unrecognized file"
            throw SSHKeyLoadError.unsupportedKeyType(label: label)
        }

        let blob = try base64Body(of: text)
        var reader = ByteReader(blob)
        guard reader.consume(prefix: authMagic) else {
            throw SSHKeyLoadError.malformed(reason: "missing openssh-key-v1 magic")
        }
        guard let cipher = reader.readSSHString(),
              let cipherName = String(data: cipher, encoding: .utf8),
              reader.readSSHString() != nil,       // kdfname
              reader.readSSHString() != nil,       // kdfoptions
              reader.readUInt32() != nil,          // number of keys
              let publicKey = reader.readSSHString() // first public key blob
        else {
            throw SSHKeyLoadError.malformed(reason: "truncated header")
        }

        var pubReader = ByteReader([UInt8](publicKey))
        guard let typeField = pubReader.readSSHString(),
              let keyType = String(data: typeField, encoding: .utf8) else {
            throw SSHKeyLoadError.malformed(reason: "missing key type")
        }
        return Header(keyType: keyType, isEncrypted: cipherName != "none")
    }

    private static func base64Body(of pem: String) throws -> [UInt8] {
        let base64 = pem.split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else {
            throw SSHKeyLoadError.malformed(reason: "invalid base64 body")
        }
        return [UInt8](data)
    }

    private static func displayLabel(_ keyType: String) -> String {
        if keyType.hasPrefix("ecdsa-") { return "ECDSA (not supported — use ed25519 or RSA)" }
        return keyType
    }

    /// Minimal big-endian reader for the length-prefixed SSH string format.
    private struct ByteReader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func consume(prefix: [UInt8]) -> Bool {
            guard bytes.count - index >= prefix.count,
                  Array(bytes[index..<index + prefix.count]) == prefix else { return false }
            index += prefix.count
            return true
        }

        mutating func readUInt32() -> UInt32? {
            guard bytes.count - index >= 4 else { return nil }
            let value = bytes[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            index += 4
            return value
        }

        mutating func readSSHString() -> Data? {
            guard let length = readUInt32() else { return nil }
            let count = Int(length)
            guard bytes.count - index >= count else { return nil }
            let slice = bytes[index..<index + count]
            index += count
            return Data(slice)
        }
    }
}
