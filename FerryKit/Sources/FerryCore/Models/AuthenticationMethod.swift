import Foundation

/// How a connection authenticates. The method is stored in the profile;
/// the secrets themselves (password, key passphrase) live only in the
/// Keychain via CredentialVault (M3) — DOMAIN.md → Credential policy.
public enum AuthenticationMethod: Codable, Hashable, Sendable {
    /// Password kept in the Keychain (or prompted when not stored).
    case password
    /// Private key file on disk; optional passphrase kept in the Keychain.
    case publicKey(privateKeyPath: String)
    /// ssh-agent. Direct builds only — hidden behind APPSTORE flag in UI.
    case agent
}
